const std = @import("std");
const host = @import("fx_orchestration_host");
const runtime_mod = @import("runtime.zig");
const team_document = @import("domain/team_document.zig");
const definition_editor = @import("definition_editor.zig");
const AltRuntime = runtime_mod.Runtime(host);

pub const DefinitionEditor = definition_editor.Editor;

pub fn descriptor() host.ExtensionDescriptor {
    return .{
        .id = "alt",
        .display_name = "ALT",
        .slash_command = "/alt",
        .summary = "resume ALT or manage Teams",
        .usage = "/alt [off|teams|new]",
        .definition_kind = "team",
        .definition_collection = "teams",
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

pub fn inspectDefinition(
    allocator: std.mem.Allocator,
    definition_source: []const u8,
) !host.DefinitionMetadata {
    var team = try team_document.Document.parse(allocator, definition_source);
    defer team.deinit();
    const id = try allocator.dupe(u8, team.value.id);
    errdefer allocator.free(id);
    return .{
        .id = id,
        .revision = team.value.revision,
        .digest = team.value.digest,
        .name = try allocator.dupe(u8, team.value.name),
    };
}

pub fn newDefinitionTemplate(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8,
        \\{
        \\  "schema": 2,
        \\  "id": "my-team",
        \\  "revision": 1,
        \\  "name": "My Team",
        \\  "provider_id": "opencode",
        \\  "models": [
        \\    { "id": "primary-model", "route": "zen", "name": "kimi-k3" },
        \\    { "id": "peer-model", "route": "go", "name": "kimi-k3" }
        \\  ],
        \\  "primary": {
        \\    "id": "primary",
        \\    "model_id": "primary-model",
        \\    "definition": "Own the user's request and its final answer.",
        \\    "peers": ["peer"]
        \\  },
        \\  "peers": [
        \\    {
        \\      "id": "peer",
        \\      "model_id": "peer-model",
        \\      "definition": "Contribute an independent perspective when consulted."
        \\    }
        \\  ],
        \\  "specialists": []
        \\}
    );
}

pub fn nextDefinitionRevision(
    allocator: std.mem.Allocator,
    source: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTeamDocument;
    const revision = parsed.value.object.get("revision") orelse
        return error.InvalidTeamDocument;
    if (revision != .integer or revision.integer <= 0 or revision.integer >= std.math.maxInt(u32)) {
        return error.InvalidTeamRevision;
    }
    try parsed.value.object.put(
        parsed.arena.allocator(),
        "revision",
        .{ .integer = revision.integer + 1 },
    );

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &out.writer);
    const result = try out.toOwnedSlice();
    errdefer allocator.free(result);
    var verified = try team_document.Document.parse(allocator, result);
    verified.deinit();
    return result;
}

pub fn create(allocator: std.mem.Allocator, options: host.CreateOptions) !host.Engine {
    var team = try team_document.Document.parse(allocator, options.definition_source);
    errdefer team.deinit();
    const adapter = try allocator.create(Adapter);
    adapter.* = .{
        .team = team,
        .runtime = AltRuntime.init(allocator, team.value),
    };
    return .{ .context = adapter, .vtable = &vtable };
}

test "adapter admits only a unified catalog provider" {
    const test_definition =
        "{\"schema\":2,\"id\":\"test-team\",\"revision\":1,\"name\":\"Test Team\",\"provider_id\":\"opencode\",\"models\":[" ++
        "{\"id\":\"primary-model\",\"route\":\"zen\",\"name\":\"primary\"}," ++
        "{\"id\":\"peer-model\",\"route\":\"zen\",\"name\":\"peer\"}]," ++
        "\"primary\":{\"id\":\"primary\",\"model_id\":\"primary-model\",\"definition\":\"Own the result.\",\"peers\":[\"peer\"]}," ++
        "\"peers\":[{\"id\":\"peer\",\"model_id\":\"peer-model\",\"definition\":\"Contribute.\"}],\"specialists\":[]}";
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

    var engine = try create(std.testing.allocator, .{
        .definition_source = test_definition,
    });
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

test "Team editor template starts valid and revisions remain valid" {
    const alloc = std.testing.allocator;
    const template = try newDefinitionTemplate(alloc);
    defer alloc.free(template);
    var initial = try team_document.Document.parse(alloc, template);
    defer initial.deinit();
    try std.testing.expectEqual(@as(u32, 1), initial.value.revision);

    const revised = try nextDefinitionRevision(alloc, template);
    defer alloc.free(revised);
    var next = try team_document.Document.parse(alloc, revised);
    defer next.deinit();
    try std.testing.expectEqual(@as(u32, 2), next.value.revision);
    try std.testing.expectEqualStrings(initial.value.id, next.value.id);
}
