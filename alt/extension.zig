const std = @import("std");
const host = @import("fx_orchestration_host");
const runtime_mod = @import("runtime.zig");
const team_document = @import("domain/team_document.zig");
const AltRuntime = runtime_mod.Runtime(host);

pub fn descriptor() host.ExtensionDescriptor {
    return .{
        .id = "alt",
        .display_name = "ALT",
        .slash_command = "/alt",
        .summary = "enter or leave ALT Team orchestration",
        .usage = "/alt [on|off]",
    };
}

const Adapter = struct {
    team: team_document.Document,
    runtime: AltRuntime,

    fn dispatch(context: *anyopaque, event: host.HostEvent, sink: host.IntentSink) !void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        try self.runtime.dispatch(event, sink);
    }

    fn deinit(context: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.runtime.deinit();
        self.team.deinit();
        allocator.destroy(self);
    }
};

const vtable = host.Engine.VTable{
    .dispatch = Adapter.dispatch,
    .deinit = Adapter.deinit,
};

pub fn create(allocator: std.mem.Allocator) !host.Engine {
    var team = try team_document.engineering(allocator);
    errdefer team.deinit();
    const adapter = try allocator.create(Adapter);
    adapter.* = .{
        .team = team,
        .runtime = AltRuntime.init(allocator, team.value),
    };
    return .{ .context = adapter, .vtable = &vtable };
}

test "adapter admits only a unified catalog provider" {
    const Capture = struct {
        entered: bool = false,
        refused: bool = false,

        fn emit(context: *anyopaque, intent: host.Intent) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (intent) {
                .mode_entered => self.entered = true,
                .notice => |notice| self.refused = notice.tone == .failure,
                .trace => {},
                else => return error.UnexpectedIntent,
            }
        }
    };

    var engine = try create(std.testing.allocator);
    defer engine.deinit(std.testing.allocator);
    var capture = Capture{};
    const sink = host.IntentSink{ .context = &capture, .emit_fn = Capture.emit };

    const single_model = [_]host.ProviderDescriptor{.{
        .id = "codex",
        .display_name = "Codex",
        .catalog_scope = .provider_native,
    }};
    try engine.dispatch(.{ .enter = .{
        .conversation_id = "conversation",
        .workspace_path = "/workspace",
        .providers = &single_model,
    } }, sink);
    try std.testing.expect(!capture.entered);
    try std.testing.expect(capture.refused);

    const unified = [_]host.ProviderDescriptor{.{
        .id = "opencode",
        .display_name = "OpenCode",
        .catalog_scope = .unified,
    }};
    try engine.dispatch(.{ .enter = .{
        .conversation_id = "conversation",
        .workspace_path = "/workspace",
        .providers = &unified,
    } }, sink);
    try std.testing.expect(capture.entered);
}
