const std = @import("std");
const builtin = @import("builtin");
const host = @import("host.zig");
const native_secret_store = @import("native_secret_store.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

pub const clipboard = host.Clipboard{
    .copy_fn = copyToClipboard,
};

pub const secret_store = native_secret_store.provider;

fn copyToClipboard(_: ?*anyopaque, text: []const u8) host.ClipboardError!bool {
    const argv = clipboardCommand(builtin.os.tag) orelse return false;
    const io = io_mod.getIo();
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        debug_trace.logf("host", "clipboard copy spawn failed err={s}", .{@errorName(err)});
        return error.CopyFailed;
    };
    defer child.kill(io);

    if (child.stdin) |*stdin| {
        stdin.writeStreamingAll(io, text) catch |err| {
            stdin.close(io);
            child.stdin = null;
            debug_trace.logf("host", "clipboard copy write failed err={s}", .{@errorName(err)});
            return error.CopyFailed;
        };
        stdin.close(io);
        child.stdin = null;
    } else {
        debug_trace.logf("host", "clipboard copy failed reason=stdin_unavailable", .{});
        return error.CopyFailed;
    }

    const term = child.wait(io) catch |err| {
        debug_trace.logf("host", "clipboard copy wait failed err={s}", .{@errorName(err)});
        return error.CopyFailed;
    };
    if (!copySucceeded(term)) {
        logUnsuccessfulTerm(term);
        return error.CopyFailed;
    }
    return true;
}

fn clipboardCommand(os_tag: std.Target.Os.Tag) ?[]const []const u8 {
    return switch (os_tag) {
        .macos => &.{"pbcopy"},
        .linux => &.{ "xclip", "-selection", "clipboard" },
        else => null,
    };
}

fn copySucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        .signal, .stopped, .unknown => false,
    };
}

fn logUnsuccessfulTerm(term: std.process.Child.Term) void {
    switch (term) {
        .exited => |code| debug_trace.logf("host", "clipboard copy failed exit_code={d}", .{code}),
        .signal => |signal| debug_trace.logf("host", "clipboard copy failed term=signal signal={d}", .{@intFromEnum(signal)}),
        .stopped => |signal| debug_trace.logf("host", "clipboard copy failed term=stopped signal={d}", .{@intFromEnum(signal)}),
        .unknown => |status| debug_trace.logf("host", "clipboard copy failed term=unknown status={d}", .{status}),
    }
}

test "native clipboard selects the platform command" {
    try std.testing.expectEqualStrings("pbcopy", clipboardCommand(.macos).?[0]);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "xclip", "-selection", "clipboard" },
        clipboardCommand(.linux).?,
    );
    try std.testing.expect(clipboardCommand(.windows) == null);
    try std.testing.expect(clipboardCommand(.wasi) == null);
}

test "native clipboard accepts only a successful exit" {
    try std.testing.expect(copySucceeded(.{ .exited = 0 }));
    try std.testing.expect(!copySucceeded(.{ .exited = 1 }));
    try std.testing.expect(!copySucceeded(.{ .signal = .TERM }));
    try std.testing.expect(!copySucceeded(.{ .stopped = .STOP }));
    try std.testing.expect(!copySucceeded(.{ .unknown = 1 }));
}
