const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const CommandResult = struct {
    exit_code: i64,
    stdout: []u8,
    stderr: []u8,
    duration_ms: ?u64 = null,

    pub fn deinit(self: *CommandResult, alloc: Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
        self.* = undefined;
    }

    /// Caller owns the returned copy.
    pub fn clone(self: CommandResult, alloc: Allocator) !CommandResult {
        const stdout = try alloc.dupe(u8, self.stdout);
        errdefer alloc.free(stdout);
        const stderr = try alloc.dupe(u8, self.stderr);
        errdefer alloc.free(stderr);
        return .{
            .exit_code = self.exit_code,
            .stdout = stdout,
            .stderr = stderr,
            .duration_ms = self.duration_ms,
        };
    }
};

pub const Control = struct {
    cancel_flag: ?*std.atomic.Value(bool) = null,
    timeout_ms: ?usize = null,
    started_ms: i64,

    pub fn check(self: Control) !void {
        if (self.cancel_flag) |flag| {
            if (flag.load(.seq_cst)) return error.Cancelled;
        }
        if (self.timeout_ms) |timeout_ms| {
            const now_ms = io_mod.milliTimestamp();
            const elapsed_ms: u64 = if (now_ms > self.started_ms) @intCast(now_ms - self.started_ms) else 0;
            if (elapsed_ms >= timeout_ms) return error.TimeoutExpired;
        }
    }

    pub fn canInterrupt(self: Control) bool {
        return self.cancel_flag != null or self.timeout_ms != null;
    }
};

pub const VercelOutcome = union(enum) {
    success: CommandResult,
    unavailable,
    request_failed,
};

pub const ProviderError = error{
    OutOfMemory,
    Cancelled,
    TimeoutExpired,
};

pub const ProviderFn = *const fn (
    ?*anyopaque,
    Allocator,
    []const u8,
    []const u8,
    Control,
) ProviderError!VercelOutcome;

pub const Provider = struct {
    ctx: ?*anyopaque = null,
    execute_fn: ProviderFn,

    pub fn execute(
        self: Provider,
        alloc: Allocator,
        command: []const u8,
        cwd: []const u8,
        control: Control,
    ) ProviderError!VercelOutcome {
        return self.execute_fn(self.ctx, alloc, command, cwd, control);
    }
};
