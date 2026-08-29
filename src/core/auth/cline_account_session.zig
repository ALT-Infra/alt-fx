const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;
const max_auth_file_bytes: usize = 64 * 1024;
const expiry_skew_ms: i64 = 60 * 1000;
const mutation_lock_file_name = "cline-account-auth.lock";
const mutation_lock_deadline_ms: u64 = 2000;
const auth_file_name = profile_paths.cline_account_auth_file_name;

pub fn refreshDeadlineMs(expires_at_ms: i64) i64 {
    return @max(expires_at_ms - expiry_skew_ms, 0);
}

pub const Session = struct {
    access_token: []u8,
    refresh_token: []u8,
    expires_at_ms: i64,
    account_id: []u8,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        alloc.free(self.account_id);
        self.* = undefined;
    }

    pub fn expired(self: Session, now_ms: i64) bool {
        return refreshDeadlineMs(self.expires_at_ms) <= now_ms;
    }
};

pub const DeleteOutcome = enum { deleted, missing, deleted_not_durable };

pub const Mutation = struct {
    fx_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,

    pub fn deinit(self: *Mutation) void {
        self.lock.release();
        self.fx_dir.close();
        self.* = undefined;
    }

    pub fn load(self: *Mutation, alloc: Allocator) !?Session {
        return loadFromDir(alloc, &self.fx_dir.dir, true);
    }

    pub fn save(self: *Mutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        try io_mod.durableReplaceVerified(alloc, &self.fx_dir, auth_file_name, text);
    }

    pub fn delete(self: *Mutation) !DeleteOutcome {
        self.fx_dir.dir.deleteFile(io_mod.getIo(), auth_file_name) catch |err| switch (err) {
            error.FileNotFound => return .missing,
            else => return err,
        };
        const durable: io_mod.DurableOps = .{};
        durable.sync_dir(durable.ctx, self.fx_dir.dir) catch return .deleted_not_durable;
        return .deleted;
    }
};

pub fn load(alloc: Allocator) !?Session {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch return null;
    defer home_dir.close(io_mod.getIo());
    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer fx_dir.close(io_mod.getIo());
    return loadFromDir(alloc, &fx_dir, false);
}

fn loadFromDir(alloc: Allocator, fx_dir: *std.Io.Dir, report_failure: bool) !?Session {
    var file = fx_dir.openFile(io_mod.getIo(), auth_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("auth", "Cline account load failed step=open_file err={s}", .{@errorName(err)});
            if (report_failure) return err;
            return null;
        },
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return null;
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes);
    defer secret.zeroAndFree(alloc, bytes);
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "Cline account load failed step=parse err={s}", .{@errorName(err)});
            return null;
        },
    };
}

pub fn saveNewSession(alloc: Allocator, session: Session) !void {
    if (comptime host_target.is_wasm) return error.ClineOAuthUnavailable;
    var mutation = try beginMutation();
    defer mutation.deinit();
    try mutation.save(alloc, session);
}

pub fn beginExistingMutation() !?Mutation {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) };
    defer home_dir.close();
    const fx_dir = openExistingPrivateFxDir(&home_dir) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try lockMutation(fx_dir);
}

fn beginMutation() !Mutation {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) };
    defer home_dir.close();
    return lockMutation(try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name));
}

fn lockMutation(open_fx_dir: io_mod.VerifiedDir) !Mutation {
    var fx_dir = open_fx_dir;
    errdefer fx_dir.close();
    var lock = try io_mod.acquireTimedAdvisoryLock(&fx_dir, mutation_lock_file_name, mutation_lock_deadline_ms);
    errdefer lock.release();
    return .{ .fx_dir = fx_dir, .lock = lock };
}

fn openExistingPrivateFxDir(home_dir: *io_mod.VerifiedDir) !io_mod.VerifiedDir {
    var dir = try home_dir.dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer dir.close(io_mod.getIo());
    const initial = try dir.stat(io_mod.getIo());
    if (initial.kind != .directory or initial.permissions.toMode() & 0o200 == 0) return error.DurablePathUnsafe;
    dir.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o700)) catch return error.PrivateStatePermissionsUnsupported;
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory or stat.permissions.toMode() & 0o777 != 0o700) return error.PrivateStatePermissionsUnsupported;
    return .{ .dir = dir };
}

pub fn parse(alloc: Allocator, bytes: []const u8) !Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidClineAuthSession;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidClineAuthSession;
    if (version != .integer or version.integer != 1) return error.InvalidClineAuthSession;
    const access_token = try requiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try requiredString(alloc, object, "refresh_token");
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const account_id = try requiredString(alloc, object, "account_id");
    errdefer alloc.free(account_id);
    const expires = object.get("expires_at_ms") orelse return error.InvalidClineAuthSession;
    if (expires != .integer or expires.integer <= 0) return error.InvalidClineAuthSession;
    return .{ .access_token = access_token, .refresh_token = refresh_token, .expires_at_ms = expires.integer, .account_id = account_id };
}

fn stringify(alloc: Allocator, session: Session) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"version\":1,\"access_token\":");
    try std.json.Stringify.value(session.access_token, .{}, &out.writer);
    try out.writer.writeAll(",\"refresh_token\":");
    try std.json.Stringify.value(session.refresh_token, .{}, &out.writer);
    try out.writer.print(",\"expires_at_ms\":{d},\"account_id\":", .{session.expires_at_ms});
    try std.json.Stringify.value(session.account_id, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn requiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidClineAuthSession;
    if (value != .string or value.string.len == 0 or value.string.len > 16 * 1024) return error.InvalidClineAuthSession;
    for (value.string) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidClineAuthSession;
    return alloc.dupe(u8, value.string);
}

test "Cline account session round trips" {
    const alloc = std.testing.allocator;
    var original = Session{
        .access_token = try alloc.dupe(u8, "access"),
        .refresh_token = try alloc.dupe(u8, "refresh"),
        .expires_at_ms = 1234,
        .account_id = try alloc.dupe(u8, "user_123"),
    };
    defer original.deinit(alloc);
    const text = try stringify(alloc, original);
    defer secret.zeroAndFree(alloc, text);
    var restored = try parse(alloc, text);
    defer restored.deinit(alloc);
    try std.testing.expectEqualStrings(original.access_token, restored.access_token);
    try std.testing.expectEqualStrings(original.account_id, restored.account_id);
}
