const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const endpoint = "https://models.dev/api.json";
const max_response_bytes: usize = 32 * 1024 * 1024;

pub const ReasoningMetadata = struct {
    has_reasoning: bool = false,
    efforts: std.ArrayList(types.ReasoningEffort) = .empty,

    pub fn deinit(self: *ReasoningMetadata, alloc: std.mem.Allocator) void {
        self.efforts.deinit(alloc);
        self.* = .{};
    }
};

pub fn parseReasoningFields(
    alloc: std.mem.Allocator,
    has_reasoning: bool,
    options: ?std.json.Value,
) !ReasoningMetadata {
    var metadata = ReasoningMetadata{ .has_reasoning = has_reasoning };
    errdefer metadata.deinit(alloc);

    const value = options orelse return metadata;
    if (value != .array) return metadata;
    for (value.array.items) |option| {
        if (option != .object) continue;
        const option_type = option.object.get("type") orelse continue;
        if (option_type != .string) continue;
        if (std.mem.eql(u8, option_type.string, "toggle") or
            std.mem.eql(u8, option_type.string, "budget_tokens"))
        {
            metadata.has_reasoning = true;
            continue;
        }
        if (!std.mem.eql(u8, option_type.string, "effort")) continue;
        metadata.has_reasoning = true;
        const values = option.object.get("values") orelse continue;
        if (values != .array) continue;
        for (values.array.items) |raw| {
            if (metadata.efforts.items.len >= types.ReasoningEffort.max_options) break;
            if (raw != .string) continue;
            const effort = types.ReasoningEffort.parse(raw.string) orelse continue;
            if (effort.isDefault() or containsEffort(metadata.efforts.items, effort)) continue;
            try metadata.efforts.append(alloc, effort);
        }
    }
    return metadata;
}

const ModelsGetOperation = struct {
    alloc: std.mem.Allocator,
    url: []const u8,

    const Output = struct {
        status: std.http.Status,
        body: []u8,

        pub fn deinit(self: *Output, alloc: std.mem.Allocator) void {
            alloc.free(self.body);
        }
    };

    pub fn run(self: *@This()) !Output {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const uri = try std.Uri.parse(self.url);
        var request = try client.request(.GET, uri, .{
            .headers = .{
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .redirect_behavior = .unhandled,
        });
        defer request.deinit();
        try request.sendBodiless();
        if (request.connection) |connection| try connection.flush();
        var response = try request.receiveHead(&.{});
        var transfer_buffer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        const body = reader.allocRemaining(
            self.alloc,
            .limited(max_response_bytes + 1),
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.ModelsDevResponseTooLarge,
            else => return err,
        };
        errdefer self.alloc.free(body);
        if (body.len > max_response_bytes) return error.ModelsDevResponseTooLarge;
        return .{ .status = response.head.status, .body = body };
    }
};

/// Fetches the shared models.dev aggregate. The caller owns the returned body.
pub fn fetchBody(
    alloc: std.mem.Allocator,
    e2e_endpoint_env: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) ![]u8 {
    const request_url = if (io_mod.getenv(e2e_endpoint_env)) |override| blk: {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EModelsDevEndpoint;
        break :blk override;
    } else endpoint;
    var operation = ModelsGetOperation{ .alloc = alloc, .url = request_url };
    var output = try gateway_client.runBoundedHttpOperation(
        ModelsGetOperation.Output,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
    if (output.status != .ok) {
        output.deinit(alloc);
        return error.ModelsDevEndpointFailed;
    }
    return output.body;
}

pub fn providerModels(root: std.json.Value, provider_id: []const u8) ?std.json.ObjectMap {
    if (root != .object) return null;
    const provider = root.object.get(provider_id) orelse return null;
    if (provider != .object) return null;
    const models = provider.object.get("models") orelse return null;
    return if (models == .object) models.object else null;
}

pub fn findExactOrUniqueSlugModel(models: std.json.ObjectMap, model_id: []const u8) ?std.json.Value {
    if (models.get(model_id)) |model| return model;

    const wanted_slug = modelSlug(model_id);
    var found: ?std.json.Value = null;
    var iterator = models.iterator();
    while (iterator.next()) |entry| {
        if (!std.mem.eql(u8, modelSlug(entry.key_ptr.*), wanted_slug)) continue;
        if (found != null) return null;
        found = entry.value_ptr.*;
    }
    return found;
}

pub fn parseReasoningMetadata(
    alloc: std.mem.Allocator,
    model: ?std.json.Value,
) !ReasoningMetadata {
    const value = model orelse return .{};
    if (value != .object) return .{};
    var has_reasoning = false;
    if (value.object.get("reasoning")) |reasoning| {
        has_reasoning = reasoning == .bool and reasoning.bool;
    }
    return parseReasoningFields(alloc, has_reasoning, value.object.get("reasoning_options"));
}

fn containsEffort(efforts: []const types.ReasoningEffort, wanted: types.ReasoningEffort) bool {
    for (efforts) |effort| if (effort.eql(wanted)) return true;
    return false;
}

fn modelSlug(model_id: []const u8) []const u8 {
    const separator = std.mem.findScalarLast(u8, model_id, '/') orelse return model_id;
    return model_id[separator + 1 ..];
}

test "models.dev reasoning metadata preserves explicit source efforts only" {
    const fixture =
        \\{"reasoning":true,"reasoning_options":[
        \\  {"type":"toggle","values":["invented"]},
        \\  {"type":"budget_tokens","min":1,"max":2048},
        \\  {"type":"effort","values":["none","low","default","bad value","high","low"]}
        \\]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture, .{});
    defer parsed.deinit();
    var metadata = try parseReasoningMetadata(std.testing.allocator, parsed.value);
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expect(metadata.has_reasoning);
    try std.testing.expectEqual(@as(usize, 3), metadata.efforts.items.len);
    try std.testing.expectEqualStrings("none", metadata.efforts.items[0].label());
    try std.testing.expectEqualStrings("low", metadata.efforts.items[1].label());
    try std.testing.expectEqualStrings("high", metadata.efforts.items[2].label());
}

test "models.dev reasoning metadata bounds source effort values" {
    const fixture =
        \\{"reasoning_options":[{"type":"effort","values":[
        \\  "one","two","three","four","five","six","seven","eight",
        \\  "nine","ten","eleven","twelve","thirteen","fourteen","fifteen","sixteen","seventeen"
        \\]}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture, .{});
    defer parsed.deinit();
    var metadata = try parseReasoningMetadata(std.testing.allocator, parsed.value);
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqual(types.ReasoningEffort.max_options, metadata.efforts.items.len);
    try std.testing.expectEqualStrings("one", metadata.efforts.items[0].label());
    try std.testing.expectEqualStrings("sixteen", metadata.efforts.items[15].label());
}

test "models.dev model lookup prefers exact ids and requires a unique slug" {
    const fixture =
        \\{"openrouter":{"models":{
        \\  "cline-pass/exact":{"reasoning":true},
        \\  "vendor/unique":{"reasoning_options":[{"type":"effort","values":["high"]}]},
        \\  "first/collision":{"reasoning":true},
        \\  "second/collision":{"reasoning":true}
        \\}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture, .{});
    defer parsed.deinit();
    const models = providerModels(parsed.value, "openrouter").?;

    try std.testing.expect(findExactOrUniqueSlugModel(models, "cline-pass/exact") != null);
    try std.testing.expect(findExactOrUniqueSlugModel(models, "cline-free/unique") != null);
    try std.testing.expect(findExactOrUniqueSlugModel(models, "cline-free/collision") == null);
    try std.testing.expect(findExactOrUniqueSlugModel(models, "cline-free/missing") == null);
}
