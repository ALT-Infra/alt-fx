const std = @import("std");
const js_host_workspace = @import("../../core/hosts/js_host_workspace.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const run_command = @import("run_command.zig");

const Allocator = std.mem.Allocator;

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return failure(ctx.allocator, "browser run_command arguments must be valid JSON");
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return failure(ctx.allocator, "browser run_command arguments must be an object");
    }
    const command_value = parsed.value.object.get("command") orelse {
        return failure(ctx.allocator, "browser run_command requires string field \"command\"");
    };
    if (command_value != .string) {
        return failure(ctx.allocator, "browser run_command field \"command\" must be a string");
    }
    if (parsed.value.object.count() != 1) {
        return failure(ctx.allocator, "browser run_command accepts only the \"command\" field");
    }
    if (command_value.string.len > js_host_workspace.max_command_bytes) {
        return failure(ctx.allocator, "browser run_command field \"command\" exceeds 65536 bytes");
    }

    const command = try ctx.allocator.dupe(u8, command_value.string);
    errdefer ctx.allocator.free(command);
    const input = try ctx.allocator.create(run_command.Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .command = command };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn failure(alloc: Allocator, message: []const u8) Allocator.Error!tool_dispatch.DecodeResult {
    return .{ .failure = try alloc.dupe(u8, message) };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *run_command.Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}
