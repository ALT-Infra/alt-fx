const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

const MacOSStart = struct {
    seconds: u64,
    microseconds: u64,
};

const Identity = union(enum) {
    linux_start_ticks: u64,
    macos_start: MacOSStart,

    fn eql(self: Identity, other: Identity) bool {
        return switch (self) {
            .linux_start_ticks => |ticks| switch (other) {
                .linux_start_ticks => |other_ticks| ticks == other_ticks,
                else => false,
            },
            .macos_start => |start| switch (other) {
                .macos_start => |other_start| start.seconds == other_start.seconds and
                    start.microseconds == other_start.microseconds,
                else => false,
            },
        };
    }
};

const TrackedProcess = struct {
    pid: std.posix.pid_t,
    identity: Identity,
};

/// Tracks descendants even after they create a new session or process group.
/// Call refresh while the original leader is alive, then signalAll during
/// cleanup. Identity checks prevent a recycled PID from being signaled.
pub const Tracker = struct {
    alloc: Allocator,
    processes: std.ArrayList(TrackedProcess) = .empty,
    macos_child_buffer: []std.posix.pid_t = &.{},

    pub fn init(alloc: Allocator) !Tracker {
        var tracker = Tracker{ .alloc = alloc };
        errdefer tracker.deinit();
        if (comptime builtin.os.tag == .macos) {
            const reported = Darwin.proc_listchildpids(0, null, 0);
            const capacity: usize = if (reported > 0)
                @max(@as(usize, @intCast(reported)) + 256, 1024)
            else
                1024;
            tracker.macos_child_buffer = try alloc.alloc(
                std.posix.pid_t,
                capacity,
            );
        }
        return tracker;
    }

    pub fn deinit(self: *Tracker) void {
        self.processes.deinit(self.alloc);
        if (self.macos_child_buffer.len > 0) {
            self.alloc.free(self.macos_child_buffer);
        }
        self.* = undefined;
    }

    pub fn refresh(self: *Tracker, root_pid: std.posix.pid_t) !void {
        var parent_index: usize = 0;
        while (parent_index <= self.processes.items.len) : (parent_index += 1) {
            const parent_pid = if (parent_index == 0)
                root_pid
            else
                self.processes.items[parent_index - 1].pid;
            try self.appendDirectChildren(parent_pid);
        }
    }

    pub fn signalAll(self: *Tracker, signal: std.posix.SIG) usize {
        return self.signalProcesses(signal, null);
    }

    pub fn signalOutsideProcessGroup(
        self: *Tracker,
        signal: std.posix.SIG,
        preserved_group: std.posix.pid_t,
    ) usize {
        return self.signalProcesses(signal, preserved_group);
    }

    fn signalProcesses(
        self: *Tracker,
        signal: std.posix.SIG,
        preserved_group: ?std.posix.pid_t,
    ) usize {
        var signaled: usize = 0;
        var index = self.processes.items.len;
        while (index > 0) {
            index -= 1;
            const process = self.processes.items[index];
            const actual = captureIdentity(self.alloc, process.pid) catch continue;
            if (!process.identity.eql(actual)) continue;
            if (!shouldSignalProcess(
                processGroupId(process.pid),
                preserved_group,
            )) continue;
            std.posix.kill(process.pid, signal) catch |err| switch (err) {
                error.ProcessNotFound => continue,
                else => continue,
            };
            signaled += 1;
        }
        return signaled;
    }

    pub fn anyAlive(self: *Tracker) bool {
        for (self.processes.items) |process| {
            const actual = captureIdentity(self.alloc, process.pid) catch continue;
            if (process.identity.eql(actual)) return true;
        }
        return false;
    }

    fn appendDirectChildren(
        self: *Tracker,
        parent_pid: std.posix.pid_t,
    ) !void {
        switch (builtin.os.tag) {
            .linux => try self.appendLinuxChildren(parent_pid),
            .macos => try self.appendMacOSChildren(parent_pid),
            else => return error.ProcessTreeUnsupported,
        }
    }

    fn appendLinuxChildren(
        self: *Tracker,
        parent_pid: std.posix.pid_t,
    ) !void {
        if (comptime builtin.os.tag != .linux) return error.ProcessTreeUnsupported;
        const path = try std.fmt.allocPrint(
            self.alloc,
            "/proc/{d}/task/{d}/children",
            .{ parent_pid, parent_pid },
        );
        defer self.alloc.free(path);
        var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        var buffer: [64 * 1024]u8 = undefined;
        const read_len = readLinuxChildrenFile(file, &buffer) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        var children = std.mem.tokenizeAny(u8, buffer[0..read_len], " \t\r\n");
        while (children.next()) |pid_text| {
            const pid = std.fmt.parseInt(std.posix.pid_t, pid_text, 10) catch continue;
            try self.track(pid);
        }
    }

    fn appendMacOSChildren(
        self: *Tracker,
        parent_pid: std.posix.pid_t,
    ) !void {
        if (comptime builtin.os.tag != .macos) return error.ProcessTreeUnsupported;
        const count = Darwin.proc_listchildpids(
            parent_pid,
            self.macos_child_buffer.ptr,
            @intCast(self.macos_child_buffer.len * @sizeOf(std.posix.pid_t)),
        );
        if (count <= 0) return;
        const child_count = @min(
            @as(usize, @intCast(count)),
            self.macos_child_buffer.len,
        );
        for (self.macos_child_buffer[0..child_count]) |pid| {
            if (pid > 0) try self.track(pid);
        }
    }

    fn track(self: *Tracker, pid: std.posix.pid_t) !void {
        const identity = captureIdentity(self.alloc, pid) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        for (self.processes.items) |*process| {
            if (process.pid != pid) continue;
            process.identity = identity;
            return;
        }
        try self.processes.append(self.alloc, .{
            .pid = pid,
            .identity = identity,
        });
    }
};

fn shouldSignalProcess(
    process_group: ?std.posix.pid_t,
    preserved_group: ?std.posix.pid_t,
) bool {
    const preserved = preserved_group orelse return true;
    const actual = process_group orelse return false;
    return actual != preserved;
}

fn processGroupId(pid: std.posix.pid_t) ?std.posix.pid_t {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
    const process_group = getpgid(pid);
    return if (process_group >= 0) process_group else null;
}

extern "c" fn getpgid(pid: std.posix.pid_t) std.posix.pid_t;

fn readLinuxChildrenFile(file: std.Io.File, buffer: []u8) !usize {
    if (comptime builtin.os.tag != .linux) return error.ProcessTreeUnsupported;
    while (true) {
        const result = std.posix.system.read(file.handle, buffer.ptr, buffer.len);
        switch (std.posix.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            .SRCH, .NOENT => return error.ProcessNotFound,
            else => return error.ProcessTreeInspectionFailed,
        }
    }
}

test "process-group exclusion preserves the captured command grace" {
    try std.testing.expect(shouldSignalProcess(41, null));
    try std.testing.expect(!shouldSignalProcess(41, 41));
    try std.testing.expect(shouldSignalProcess(42, 41));
    try std.testing.expect(!shouldSignalProcess(null, 41));
}

fn captureIdentity(alloc: Allocator, pid: std.posix.pid_t) !Identity {
    return switch (builtin.os.tag) {
        .linux => .{ .linux_start_ticks = try captureLinuxStartTicks(alloc, pid) },
        .macos => .{ .macos_start = try captureMacOSStart(pid) },
        else => error.ProcessTreeUnsupported,
    };
}

fn captureLinuxStartTicks(alloc: Allocator, pid: std.posix.pid_t) !u64 {
    if (comptime builtin.os.tag != .linux) return error.ProcessTreeUnsupported;
    const path = try std.fmt.allocPrint(alloc, "/proc/{d}/stat", .{pid});
    defer alloc.free(path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ProcessNotFound,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    var buffer: [4096]u8 = undefined;
    const read_len = try readLinuxProcFile(file, &buffer);
    const stat = buffer[0..read_len];
    const close_paren = std.mem.lastIndexOfScalar(u8, stat, ')') orelse
        return error.ProcessIdentityUnavailable;
    var fields = std.mem.tokenizeScalar(u8, stat[close_paren + 1 ..], ' ');
    var field_number: usize = 3;
    while (fields.next()) |field| : (field_number += 1) {
        if (field_number == 22) {
            return std.fmt.parseUnsigned(u64, field, 10) catch
                error.ProcessIdentityUnavailable;
        }
    }
    return error.ProcessIdentityUnavailable;
}

fn readLinuxProcFile(file: std.Io.File, buffer: []u8) !usize {
    if (comptime builtin.os.tag != .linux) return error.ProcessTreeUnsupported;
    while (true) {
        const result = std.posix.system.read(file.handle, buffer.ptr, buffer.len);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                const read_len: usize = @intCast(result);
                if (read_len == 0) return error.ProcessNotFound;
                return read_len;
            },
            .INTR => continue,
            .SRCH => return error.ProcessNotFound,
            else => return error.ProcessIdentityUnavailable,
        }
    }
}

fn captureMacOSStart(pid: std.posix.pid_t) !MacOSStart {
    if (comptime builtin.os.tag != .macos) return error.ProcessTreeUnsupported;
    var info: Darwin.ProcBsdInfo = undefined;
    const read_len = Darwin.proc_pidinfo(
        pid,
        3,
        0,
        &info,
        @sizeOf(Darwin.ProcBsdInfo),
    );
    if (read_len == 0) return error.ProcessNotFound;
    if (read_len != @sizeOf(Darwin.ProcBsdInfo)) {
        return error.ProcessIdentityUnavailable;
    }
    return .{
        .seconds = info.pbi_start_tvsec,
        .microseconds = info.pbi_start_tvusec,
    };
}

const Darwin = struct {
    const ProcBsdInfo = extern struct {
        pbi_flags: u32,
        pbi_status: u32,
        pbi_xstatus: u32,
        pbi_pid: u32,
        pbi_ppid: u32,
        pbi_uid: u32,
        pbi_gid: u32,
        pbi_ruid: u32,
        pbi_rgid: u32,
        pbi_svuid: u32,
        pbi_svgid: u32,
        rfu_1: u32,
        pbi_comm: [16]u8,
        pbi_name: [32]u8,
        pbi_nfiles: u32,
        pbi_pgid: u32,
        pbi_pjobc: u32,
        e_tdev: u32,
        e_tpgid: u32,
        pbi_nice: i32,
        pbi_start_tvsec: u64,
        pbi_start_tvusec: u64,
    };

    extern "c" fn proc_listchildpids(
        ppid: c_int,
        buffer: ?*anyopaque,
        buffersize: c_int,
    ) c_int;

    extern "c" fn proc_pidinfo(
        pid: c_int,
        flavor: c_int,
        arg: u64,
        buffer: *anyopaque,
        buffersize: c_int,
    ) c_int;
};

test "tracked identity distinguishes process instances" {
    const linux = Identity{ .linux_start_ticks = 42 };
    try std.testing.expect(linux.eql(.{ .linux_start_ticks = 42 }));
    try std.testing.expect(!linux.eql(.{ .linux_start_ticks = 43 }));
    try std.testing.expect(!linux.eql(.{ .macos_start = .{
        .seconds = 42,
        .microseconds = 0,
    } }));
}
