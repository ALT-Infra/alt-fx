const std = @import("std");
const types = @import("../../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Reason = enum {
    approval_published,
    origin_step_invalidated,
};

pub const Token = struct {
    turn_id: u64,
    origin_epoch: usize,
    expected_epoch: usize,
    runtime_generation: u64,
    action_generation: u64,
    call_id: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
    server_name: []const u8,
};

pub const State = union(enum) {
    open,
    blocked: Token,
    closed,
};

pub const ToolClass = enum { non_mcp, dynamic_mcp };

pub const ToolDecision = enum {
    execute,
    settle_origin_retry,
    stale_closed,
};

pub fn decideTool(state: State, epoch: usize, class: ToolClass) ToolDecision {
    if (class == .non_mcp) return .execute;
    return switch (state) {
        .open => .execute,
        .blocked => |token| if (epoch == token.origin_epoch)
            .settle_origin_retry
        else
            .stale_closed,
        .closed => .stale_closed,
    };
}

pub const StepDecision = enum {
    unchanged,
    consumed,
    stale_closed,
};

pub fn enterModelStep(
    state: *State,
    turn_id: u64,
    epoch: usize,
    runtime_generation: ?u64,
    action_generation: u64,
) StepDecision {
    const token = switch (state.*) {
        .open => return .unchanged,
        .closed => return .stale_closed,
        .blocked => |value| value,
    };
    if (turn_id != token.turn_id or
        epoch != token.expected_epoch or
        runtime_generation == null or
        runtime_generation.? != token.runtime_generation or
        action_generation != token.action_generation)
    {
        state.* = .closed;
        return .stale_closed;
    }
    state.* = .open;
    return .consumed;
}

pub fn actionGeneration(grants: []const types.PermissionGrant) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.project-mcp-retry-action.v1\x00");
    for (grants) |grant| {
        hash.update(grant.tool_name);
        hash.update("\x00");
        hash.update(grant.target_path);
        hash.update("\x00");
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .little);
}

pub fn renderRetryJson(
    alloc: Allocator,
    tool_name: []const u8,
    reason: Reason,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"project_mcp_retry_required\":{\"tool\":");
    try std.json.Stringify.value(tool_name, .{}, &out.writer);
    try out.writer.writeAll(",\"reason\":");
    try std.json.Stringify.value(@tagName(reason), .{}, &out.writer);
    try out.writer.writeAll(",\"transport_started\":false}}");
    return out.toOwnedSlice();
}

test "project MCP retry barrier blocks only MCP siblings and consumes once" {
    const token = Token{
        .turn_id = 7,
        .origin_epoch = 2,
        .expected_epoch = 3,
        .runtime_generation = 11,
        .action_generation = 13,
        .call_id = "call-1",
        .tool_name = "mcp_docs_query",
        .arguments_json = "{}",
        .server_name = "docs",
    };
    var state: State = .{ .blocked = token };
    try std.testing.expectEqual(
        ToolDecision.settle_origin_retry,
        decideTool(state, 2, .dynamic_mcp),
    );
    try std.testing.expectEqual(
        ToolDecision.execute,
        decideTool(state, 2, .non_mcp),
    );
    try std.testing.expectEqual(
        StepDecision.consumed,
        enterModelStep(&state, 7, 3, 11, 13),
    );
    try std.testing.expectEqual(ToolDecision.execute, decideTool(state, 3, .dynamic_mcp));
}

test "project MCP retry barrier closes on every authority mismatch" {
    const token = Token{
        .turn_id = 7,
        .origin_epoch = 2,
        .expected_epoch = 3,
        .runtime_generation = 11,
        .action_generation = 13,
        .call_id = "call-1",
        .tool_name = "mcp_docs_query",
        .arguments_json = "{}",
        .server_name = "docs",
    };
    const cases = [_]struct {
        turn_id: u64 = 7,
        epoch: usize = 3,
        runtime_generation: ?u64 = 11,
        action_generation: u64 = 13,
    }{
        .{ .turn_id = 8 },
        .{ .epoch = 4 },
        .{ .runtime_generation = null },
        .{ .runtime_generation = 12 },
        .{ .action_generation = 14 },
    };
    for (cases) |case| {
        var state: State = .{ .blocked = token };
        try std.testing.expectEqual(
            StepDecision.stale_closed,
            enterModelStep(
                &state,
                case.turn_id,
                case.epoch,
                case.runtime_generation,
                case.action_generation,
            ),
        );
        try std.testing.expectEqual(
            ToolDecision.stale_closed,
            decideTool(state, case.epoch, .dynamic_mcp),
        );
    }
}

test "project MCP retry result is typed and transport free" {
    const output = try renderRetryJson(
        std.testing.allocator,
        "mcp_docs_query",
        .origin_step_invalidated,
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "{\"project_mcp_retry_required\":{\"tool\":\"mcp_docs_query\",\"reason\":\"origin_step_invalidated\",\"transport_started\":false}}",
        output,
    );
}
