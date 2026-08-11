const std = @import("std");
const builtin = @import("builtin");
const command_admission = @import("../permissions/command_admission.zig");
const command_effect = @import("../shell_command/command_effect.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const local_executor = @import("local_executor.zig");
const sandbox = @import("../permissions/sandbox.zig");

pub const RouteKind = local_executor.RouteKind;
pub const PreparedCommandRoute = local_executor.PreparedCommand;
pub const RoutedCommandResult = local_executor.CommandResult;

/// Upper bound for raw callback bytes that can still be represented by the
/// route's ordinary foreground result. Above this bound the route either
/// rejects output or promotes it to an unordered command artifact.
pub fn foregroundResultComparisonLimit(
    route: PreparedCommandRoute,
    approved_shell_limit: usize,
) usize {
    return local_executor.foregroundResultComparisonLimit(route, approved_shell_limit);
}

pub const AuthorizedBackgroundCommand = struct {
    command_ctx: command_admission.CommandContext,
    source: command_admission.ShellAuthorizationSource,
};

pub fn prepareAuthorizedRoute(
    alloc: std.mem.Allocator,
    command_ctx: command_admission.CommandContext,
    authority: command_admission.CommandExecutionAuthority,
) !PreparedCommandRoute {
    if (command_ctx.target_os != builtin.os.tag) return error.CommandTargetMismatch;
    if (sandbox.resolveBackend(command_ctx.resolved_backend) != command_ctx.resolved_backend) {
        return error.CommandBackendNotResolved;
    }

    return switch (authority) {
        .direct_only => |fingerprint| blk: {
            if (!fingerprint.matches(command_ctx)) return error.CommandAdmissionChanged;
            var admission = command_effect.plan(
                alloc,
                command_ctx.command,
                command_ctx.resolved_cwd,
                command_ctx.background,
                command_ctx.resolved_backend,
                command_ctx.target_os,
            ) catch return error.CommandAdmissionChanged;
            switch (admission) {
                .direct_read_only => |plan| {
                    debug_trace.logf("core", "run_command authority=direct_only route=direct_read_only", .{});
                    break :blk .{ .direct_read_only = plan };
                },
                .approval_required => {
                    admission.deinit(alloc);
                    return error.CommandAdmissionChanged;
                },
            }
        },
        .shell_allowed => |shell| blk: {
            if (!shell.fingerprint.matches(command_ctx)) {
                return error.CommandAuthorityContextMismatch;
            }
            const admission = command_effect.plan(
                alloc,
                command_ctx.command,
                command_ctx.resolved_cwd,
                command_ctx.background,
                command_ctx.resolved_backend,
                command_ctx.target_os,
            ) catch break :blk .{ .approved_shell = .{
                .command_ctx = command_ctx,
                .reason = .planning_failure,
                .source = shell.source,
            } };
            switch (admission) {
                .direct_read_only => |plan| {
                    debug_trace.logf("core", "run_command authority=shell_allowed source={s} route=direct_read_only", .{@tagName(shell.source)});
                    break :blk .{ .direct_read_only = plan };
                },
                .approval_required => |reason| {
                    debug_trace.logf("core", "run_command authority=shell_allowed source={s} route=approved_shell reason={s}", .{ @tagName(shell.source), @tagName(reason) });
                    break :blk .{ .approved_shell = .{
                        .command_ctx = command_ctx,
                        .reason = reason,
                        .source = shell.source,
                    } };
                },
            }
        },
    };
}

pub fn executePreparedRoute(
    cfg: sandbox.Config,
    alloc: std.mem.Allocator,
    route: PreparedCommandRoute,
) !RoutedCommandResult {
    return local_executor.executePreparedCommand(cfg, alloc, route);
}

pub fn executePlannedCommand(
    cfg: sandbox.Config,
    alloc: std.mem.Allocator,
    command_ctx: command_admission.CommandContext,
    authority: command_admission.CommandExecutionAuthority,
) !RoutedCommandResult {
    try validateConfigContext(cfg, command_ctx);
    const route = try prepareAuthorizedRoute(alloc, command_ctx, authority);
    return executePreparedRoute(cfg, alloc, route);
}

pub fn authorizeBackground(
    alloc: std.mem.Allocator,
    command_ctx: command_admission.CommandContext,
    authority: command_admission.CommandExecutionAuthority,
) !AuthorizedBackgroundCommand {
    if (!command_ctx.background) return error.CommandIsNotBackground;
    if (command_ctx.target_os != builtin.os.tag) return error.CommandTargetMismatch;
    if (sandbox.resolveBackend(command_ctx.resolved_backend) != command_ctx.resolved_backend) {
        return error.CommandBackendNotResolved;
    }

    const shell = switch (authority) {
        .direct_only => return error.BackgroundRequiresShellAuthority,
        .shell_allowed => |shell| shell,
    };
    if (!shell.fingerprint.matches(command_ctx)) {
        return error.CommandAuthorityContextMismatch;
    }

    var admission = command_effect.plan(
        alloc,
        command_ctx.command,
        command_ctx.resolved_cwd,
        command_ctx.background,
        command_ctx.resolved_backend,
        command_ctx.target_os,
    ) catch return error.BackgroundAuthorizationChanged;
    defer admission.deinit(alloc);
    switch (admission) {
        .direct_read_only => return error.BackgroundAuthorizationChanged,
        .approval_required => |reason| {
            if (reason != .background_process) {
                return error.BackgroundAuthorizationChanged;
            }
        },
    }

    debug_trace.logf("core", "run_command background_authorized=true source={s}", .{@tagName(shell.source)});
    return .{
        .command_ctx = command_ctx,
        .source = shell.source,
    };
}

pub fn validateConfigContext(
    cfg: sandbox.Config,
    command_ctx: command_admission.CommandContext,
) !void {
    if (sandbox.resolveBackend(cfg.backend) != command_ctx.resolved_backend) {
        return error.CommandBackendMismatch;
    }
    if (command_ctx.target_os != builtin.os.tag) return error.CommandTargetMismatch;
}

fn context(command: []const u8, background: bool) command_admission.CommandContext {
    return .{
        .command = command,
        .resolved_cwd = "/tmp",
        .background = background,
        .resolved_backend = .none,
        .target_os = builtin.os.tag,
    };
}

fn directAuthority(ctx: command_admission.CommandContext) command_admission.CommandExecutionAuthority {
    return .{ .direct_only = .init(ctx) };
}

fn shellAuthority(
    ctx: command_admission.CommandContext,
    source: command_admission.ShellAuthorizationSource,
) command_admission.CommandExecutionAuthority {
    return .{ .shell_allowed = .{
        .fingerprint = .init(ctx),
        .source = source,
    } };
}

test {
    _ = @import("local_executor.zig");
}

test "router revalidates direct-only authority and rejects changed admission" {
    const ctx = context("pwd", false);
    var route = try prepareAuthorizedRoute(std.testing.allocator, ctx, directAuthority(ctx));
    defer route.deinit(std.testing.allocator);
    try std.testing.expect(route == .direct_read_only);

    var changed = ctx;
    changed.command = "touch changed";
    try std.testing.expectError(
        error.CommandAdmissionChanged,
        prepareAuthorizedRoute(std.testing.allocator, changed, directAuthority(ctx)),
    );
}

test "router keeps direct grammar on the safer route for every shell source" {
    const ctx = context("pwd", false);
    const sources = [_]command_admission.ShellAuthorizationSource{
        .configured_rule,
        .session_grant,
        .js_host_workspace_sandbox,
        .interactive_once,
        .interactive_always,
        .auto_mode,
        .auto_classifier,
        .yolo,
    };
    for (sources) |source| {
        var route = try prepareAuthorizedRoute(
            std.testing.allocator,
            ctx,
            shellAuthority(ctx, source),
        );
        defer route.deinit(std.testing.allocator);
        try std.testing.expect(route == .direct_read_only);
    }
}

test "router permits approval-bearing grammar only with sourced shell authority" {
    const ctx = context("touch created.txt", false);
    try std.testing.expectError(
        error.CommandAdmissionChanged,
        prepareAuthorizedRoute(std.testing.allocator, ctx, directAuthority(ctx)),
    );

    var route = try prepareAuthorizedRoute(
        std.testing.allocator,
        ctx,
        shellAuthority(ctx, .configured_rule),
    );
    defer route.deinit(std.testing.allocator);
    try std.testing.expect(route == .approved_shell);
    try std.testing.expectEqual(
        @as(usize, 1024),
        foregroundResultComparisonLimit(route, 1024),
    );
    try std.testing.expectEqual(command_effect.ApprovalReason.filesystem_write, route.approved_shell.reason);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.configured_rule,
        route.approved_shell.source,
    );
}

test "router rejects shell fingerprint backend and target mismatches" {
    const ctx = context("git status", false);
    var changed = ctx;
    changed.resolved_cwd = "/other";
    try std.testing.expectError(
        error.CommandAuthorityContextMismatch,
        prepareAuthorizedRoute(
            std.testing.allocator,
            changed,
            shellAuthority(ctx, .interactive_once),
        ),
    );

    const cfg = sandbox.Config{
        .backend = .macos,
        .workspace_root = "/tmp",
        .max_command_output_bytes = 1024,
    };
    try std.testing.expectError(error.CommandBackendMismatch, validateConfigContext(cfg, ctx));
}

test "router authorizes background only from matching sourced shell authority" {
    const ctx = context("pwd", true);
    try std.testing.expectError(
        error.BackgroundRequiresShellAuthority,
        authorizeBackground(std.testing.allocator, ctx, directAuthority(ctx)),
    );

    const token = try authorizeBackground(
        std.testing.allocator,
        ctx,
        shellAuthority(ctx, .interactive_always),
    );
    try std.testing.expectEqualStrings("pwd", token.command_ctx.command);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.interactive_always,
        token.source,
    );

    var foreground = ctx;
    foreground.background = false;
    try std.testing.expectError(
        error.CommandIsNotBackground,
        authorizeBackground(
            std.testing.allocator,
            foreground,
            shellAuthority(foreground, .configured_rule),
        ),
    );
}

test "router executes direct plan without consulting approved shell capacity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ctx = context("printf x | wc -c", false);
    const routed = try executePlannedCommand(.{
        .backend = .none,
        .workspace_root = "/tmp",
        .max_command_output_bytes = 1,
    }, arena, ctx, directAuthority(ctx));
    try std.testing.expectEqual(RouteKind.direct_read_only, routed.route);
    try std.testing.expect(std.mem.find(u8, routed.result.output, "<stdout>\n1\n</stdout>") != null);
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        routed.result.command_result.?.foreground.output_file,
    );
}
