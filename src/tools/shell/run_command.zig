const std = @import("std");
const server_detection = @import("../../core/background/server_detection.zig");
const io_mod = @import("../../core/shared/io.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const workspace_access = @import("../../core/workspace/workspace_access.zig");

const Allocator = std.mem.Allocator;

/// Typed input for the core run_command tool.
pub const Input = struct {
    command: []u8,
    cwd: ?[]u8 = null,
    background: bool = false,

    /// Frees owned command and optional cwd strings.
    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.command);
        if (self.cwd) |cwd| alloc.free(cwd);
        self.* = .{ .command = &.{} };
    }
};

/// Decodes run_command JSON into an owned Input released by ToolInput.deinit.
pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "run_command arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "run_command arguments must be an object") };
    }

    const command_value = parsed.value.object.get("command") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "run_command requires string field \"command\"") };
    };
    if (command_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "run_command field \"command\" must be a string") };
    }

    const cwd_raw: ?[]const u8 = if (parsed.value.object.get("cwd")) |cwd_value| blk: {
        if (cwd_value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "run_command field \"cwd\" must be a string") };
        }
        break :blk cwd_value.string;
    } else null;

    var run_in_background = false;
    if (parsed.value.object.get("background")) |background_value| {
        if (background_value != .bool) {
            return .{ .failure = try ctx.allocator.dupe(u8, "run_command field \"background\" must be a bool") };
        }
        run_in_background = background_value.bool;
    }

    const command = try ctx.allocator.dupe(u8, command_value.string);
    errdefer ctx.allocator.free(command);
    const cwd: ?[]u8 = if (cwd_raw) |raw| try ctx.allocator.dupe(u8, raw) else null;
    errdefer if (cwd) |owned| ctx.allocator.free(owned);
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .command = command,
        .cwd = cwd,
        .background = run_in_background,
    };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

/// Leaves the active run_command public contract to the runtime.
pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

/// Resolves the command cwd using the same rule as the runner and permission target.
pub fn resolveCwd(arena: Allocator, scope: workspace_access.AccessScope, input: *const Input) ![]const u8 {
    const cwd_input = input.cwd orelse return arena.dupe(u8, scope.primary_directory);
    if (std.mem.eql(u8, cwd_input, ".")) return arena.dupe(u8, scope.primary_directory);
    return pathing.resolveWorkspaceOrExternalPath(arena, scope.primary_directory, cwd_input);
}

/// Delegates validated input to the Core-owned command execution backend.
pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const backend = ctx.run_command_backend orelse return .{
        .failure = try ctx.allocator.dupe(u8, "run_command execution backend is unavailable\n"),
    };
    const input = erased.as(Input);
    const cwd = resolveCwd(
        ctx.allocator,
        ctx.access_scope orelse workspace_access.AccessScope.primaryOnly(ctx.workspace_root),
        input,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to resolve command cwd: {s}", .{@errorName(err)}) };
    };
    defer ctx.allocator.free(@constCast(cwd));
    return backend.execute(ctx, .{
        .command = input.command,
        .resolved_cwd = cwd,
        .background = input.background,
        .expects_url = server_detection.isLikelyServerCommand(input.command),
    });
}

/// Reports that run_command may mutate process or filesystem state.
pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

/// Reports that run_command is not intrinsically irreversible.
pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

fn stackInput(input: *Input) tool_dispatch.ToolInput {
    return .{ .ptr = input, .deinit_fn = noopInputDeinit };
}

fn validateStackInput(alloc: Allocator, input: *Input) !?[]u8 {
    return validate(.{ .allocator = alloc }, stackInput(input));
}

fn decodeInput(args_json: []const u8) !tool_dispatch.ToolInput {
    const decoded = try decode(.{ .allocator = std.testing.allocator }, args_json);
    return switch (decoded) {
        .input => |input| input,
        .failure => |body| {
            defer std.testing.allocator.free(body);
            return error.TestUnexpectedDecodeFailure;
        },
    };
}

fn expectDecodeFailure(args_json: []const u8, expected: []const u8) !void {
    const decoded = try decode(.{ .allocator = std.testing.allocator }, args_json);
    switch (decoded) {
        .input => |input| {
            input.deinit(std.testing.allocator);
            return error.TestExpectedDecodeFailure;
        },
        .failure => |body| {
            defer std.testing.allocator.free(body);
            try std.testing.expectEqualStrings(expected, body);
        },
    }
}

test "decode accepts active fields and ignores unknown keys" {
    const erased = try decodeInput("{\"command\":\"echo ok\",\"cwd\":\"src\",\"background\":true,\"timeout_ms\":500,\"extra\":1}");
    defer erased.deinit(std.testing.allocator);
    const input = erased.as(Input);
    try std.testing.expectEqualStrings("echo ok", input.command);
    try std.testing.expectEqualStrings("src", input.cwd.?);
    try std.testing.expect(input.background);
}

test "decode frees valid cwd when background has invalid type" {
    try expectDecodeFailure(
        "{\"command\":\"echo ok\",\"cwd\":\"src\",\"background\":\"yes\"}",
        "run_command field \"background\" must be a bool",
    );
}

test "decode ignores unsigned timeout_ms type" {
    const erased = try decodeInput("{\"command\":\"echo ok\",\"cwd\":\"src\",\"timeout_ms\":\"1000\"}");
    defer erased.deinit(std.testing.allocator);
    const input = erased.as(Input);
    try std.testing.expectEqualStrings("echo ok", input.command);
    try std.testing.expectEqualStrings("src", input.cwd.?);
}

test "validation preserves command bytes without public trimming" {
    var empty = Input{ .command = try std.testing.allocator.dupe(u8, "") };
    defer empty.deinit(std.testing.allocator);
    try std.testing.expect((try validateStackInput(std.testing.allocator, &empty)) == null);
    try std.testing.expectEqualStrings("", empty.command);

    var whitespace_input = Input{ .command = try std.testing.allocator.dupe(u8, " \t\n ") };
    defer whitespace_input.deinit(std.testing.allocator);
    try std.testing.expect((try validateStackInput(std.testing.allocator, &whitespace_input)) == null);
    try std.testing.expectEqualStrings(" \t\n ", whitespace_input.command);
}

test "cwd resolution handles default and non default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/src");
    const workspace = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace");
    defer std.testing.allocator.free(workspace);
    const expected = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace/src");
    defer std.testing.allocator.free(expected);

    var default_input = Input{ .command = try std.testing.allocator.dupe(u8, "echo") };
    defer default_input.deinit(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const scope = workspace_access.AccessScope.primaryOnly(workspace);
    try std.testing.expectEqualStrings(workspace, try resolveCwd(arena_state.allocator(), scope, &default_input));

    var src_input = Input{
        .command = try std.testing.allocator.dupe(u8, "echo"),
        .cwd = try std.testing.allocator.dupe(u8, "src"),
    };
    defer src_input.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, try resolveCwd(arena_state.allocator(), scope, &src_input));
}

test "cwd resolution accepts external absolute and workspace escape paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "shared");
    const workspace = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace");
    defer std.testing.allocator.free(workspace);
    const shared = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "shared");
    defer std.testing.allocator.free(shared);
    const entries = [_]workspace_access.Entry{.{
        .path = @constCast(shared),
        .saved = true,
        .command_line = false,
        .available = true,
        .active = true,
    }};
    const scope = workspace_access.AccessScope{
        .primary_directory = workspace,
        .additional_directories = &entries,
    };
    var input = Input{
        .command = try std.testing.allocator.dupe(u8, "pwd"),
        .cwd = try std.testing.allocator.dupe(u8, shared),
    };
    defer input.deinit(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectEqualStrings(shared, try resolveCwd(arena_state.allocator(), scope, &input));
    try std.testing.expectEqualStrings(
        shared,
        try resolveCwd(arena_state.allocator(), workspace_access.AccessScope.primaryOnly(workspace), &input),
    );

    var relative_input = Input{
        .command = try std.testing.allocator.dupe(u8, "pwd"),
        .cwd = try std.testing.allocator.dupe(u8, "../shared"),
    };
    defer relative_input.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        shared,
        try resolveCwd(arena_state.allocator(), workspace_access.AccessScope.primaryOnly(workspace), &relative_input),
    );
}

const FakeBackend = struct {
    called: bool = false,
    command: []const u8 = "",
    expects_url: bool = false,

    fn execute(
        maybe_ctx: ?*anyopaque,
        ctx: tool_dispatch.DispatchContext,
        request: tool_dispatch.RunCommandRequest,
    ) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
        const raw_ctx = maybe_ctx orelse unreachable;
        const self: *FakeBackend = @ptrCast(@alignCast(raw_ctx));
        self.called = true;
        self.command = request.command;
        self.expects_url = request.expects_url;
        return .{ .success = try ctx.allocator.dupe(u8, "backend result") };
    }
};

test "registered callback delegates typed input to core backend" {
    const erased = try decodeInput("{\"command\":\"npm run dev\"}");
    defer erased.deinit(std.testing.allocator);
    var backend = FakeBackend{};

    var result = try call(.{
        .allocator = std.testing.allocator,
        .run_command_backend = .{
            .ctx = &backend,
            .execute_fn = FakeBackend.execute,
        },
    }, erased);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(backend.called);
    try std.testing.expectEqualStrings("npm run dev", backend.command);
    try std.testing.expect(backend.expects_url);
    try std.testing.expectEqualStrings("backend result", result.success);
}

test "registered callback fails when core backend is unavailable" {
    const erased = try decodeInput("{\"command\":\"printf unavailable\"}");
    defer erased.deinit(std.testing.allocator);
    var result = try call(.{ .allocator = std.testing.allocator }, erased);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "run_command execution backend is unavailable\n",
        result.failure,
    );
}
