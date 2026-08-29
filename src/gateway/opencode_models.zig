const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const max_models_per_surface: usize = 4096;
const max_model_id_bytes: usize = 256;
const max_catalog_bytes: usize = 1024 * 1024;
// models.dev publishes one aggregate for every provider. Keep a generous
// runaway-response guard so unrelated catalog growth cannot silently strand
// newly published OpenCode models.
const max_protocol_metadata_bytes: usize = 32 * 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;
const zen_models_endpoint = "https://opencode.ai/zen/v1/models";
const go_models_endpoint = "https://opencode.ai/zen/go/v1/models";
const protocol_metadata_endpoint = "https://models.dev/api.json";
const e2e_zen_models_endpoint_env = "FX_E2E_OPENCODE_ZEN_MODELS_URL";
const e2e_go_models_endpoint_env = "FX_E2E_OPENCODE_GO_MODELS_URL";
const e2e_protocol_metadata_endpoint_env = "FX_E2E_OPENCODE_PROTOCOL_METADATA_URL";
const go_model_prefix = "go/";
const openai_compatible_sdk = "@ai-sdk/openai-compatible";

const ProtocolOverride = struct {
    npm: ?[]const u8 = null,
};

const ProtocolModel = struct {
    provider: ?ProtocolOverride = null,
    cost: ?struct {
        input: f64,
        output: f64,
    } = null,
};

const ProtocolProvider = struct {
    npm: []const u8,
    models: std.json.ArrayHashMap(ProtocolModel),
};

const ProtocolMetadata = struct {
    opencode: ProtocolProvider,
    @"opencode-go": ProtocolProvider,
};

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    return switch (model_catalog.fetchWithPublicFallback(model_catalog_provider, alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    })) {
        .loaded => |loaded| blk: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :blk .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failure| .{ .failure = failure },
    };
}

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    const authenticated = input.access.credentialSource() == .opencode_api_key;
    if (input.access.credentialSource() != null and !authenticated) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });

    const zen_body = fetchPublicBody(alloc, zen_models_endpoint, e2e_zen_models_endpoint_env, max_catalog_bytes, cancel_flag, deadline) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = catalogFetchFailure(err) };
    };
    defer alloc.free(zen_body);
    const go_body = fetchPublicBody(alloc, go_models_endpoint, e2e_go_models_endpoint_env, max_catalog_bytes, cancel_flag, deadline) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = catalogFetchFailure(err) };
    };
    defer alloc.free(go_body);
    const protocol_metadata_body = fetchPublicBody(
        alloc,
        protocol_metadata_endpoint,
        e2e_protocol_metadata_endpoint_env,
        max_protocol_metadata_bytes,
        cancel_flag,
        deadline,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = catalogFetchFailure(err) };
    };
    defer alloc.free(protocol_metadata_body);

    const catalog = parseCatalog(alloc, zen_body, go_body, protocol_metadata_body, authenticated) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

fn catalogFetchFailure(err: anyerror) model_catalog.Failure {
    if (err == error.Cancelled) return .{ .category = .cancellation };
    if (err == error.OpenCodeModelCatalogTooLarge or err == error.OpenCodePublicResponseTooLarge) {
        return .{ .category = .malformed_response };
    }
    return .{ .category = .transport, .retryable = true };
}

const ModelsGetOperation = struct {
    alloc: std.mem.Allocator,
    url: []const u8,
    max_body_bytes: usize,

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
            .limited(self.max_body_bytes + 1),
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.OpenCodePublicResponseTooLarge,
            else => return err,
        };
        errdefer self.alloc.free(body);
        if (body.len > self.max_body_bytes) return error.OpenCodePublicResponseTooLarge;
        return .{ .status = response.head.status, .body = body };
    }
};

fn fetchPublicBody(
    alloc: std.mem.Allocator,
    default_url: []const u8,
    e2e_url_env: []const u8,
    max_body_bytes: usize,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) ![]u8 {
    const request_url = if (io_mod.getenv(e2e_url_env)) |override| blk: {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EOpenCodeEndpoint;
        break :blk override;
    } else default_url;
    var operation = ModelsGetOperation{
        .alloc = alloc,
        .url = request_url,
        .max_body_bytes = max_body_bytes,
    };
    var output = try gateway_client.runBoundedHttpOperation(
        ModelsGetOperation.Output,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
    if (output.status != .ok) {
        output.deinit(alloc);
        return error.OpenCodeModelsEndpointFailed;
    }
    return output.body;
}

fn parseCatalog(
    alloc: std.mem.Allocator,
    zen_json: []const u8,
    go_json: []const u8,
    protocol_metadata_json: []const u8,
    authenticated: bool,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var protocol_metadata = try std.json.parseFromSlice(
        ProtocolMetadata,
        alloc,
        protocol_metadata_json,
        .{ .ignore_unknown_fields = true },
    );
    defer protocol_metadata.deinit();
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    try appendSurface(alloc, &catalog, zen_json, "", protocol_metadata.value.opencode, !authenticated);
    if (authenticated) {
        try appendSurface(alloc, &catalog, go_json, go_model_prefix, protocol_metadata.value.@"opencode-go", false);
    }
    if (catalog.items.len == 0) return error.InvalidOpenCodeModelCatalog;
    for (catalog.items, 0..) |entry, index| {
        if (!std.mem.endsWith(u8, entry.id, "-free")) continue;
        if (index > 0) std.mem.swap(model_catalog.ModelCatalogEntry, &catalog.items[0], &catalog.items[index]);
        break;
    }
    return catalog;
}

fn appendSurface(
    alloc: std.mem.Allocator,
    catalog: *std.ArrayList(model_catalog.ModelCatalogEntry),
    body: []const u8,
    id_prefix: []const u8,
    protocol_provider: ProtocolProvider,
    free_only: bool,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenCodeModelCatalog;
    const data = parsed.value.object.get("data") orelse return error.InvalidOpenCodeModelCatalog;
    if (data != .array) return error.InvalidOpenCodeModelCatalog;
    for (data.array.items) |value| {
        if (value != .object) continue;
        const raw_id = stringField(value.object, "id") orelse continue;
        if (raw_id.len == 0 or raw_id.len > max_model_id_bytes) continue;
        if (!supportsChatCompletions(protocol_provider, raw_id)) continue;
        if (free_only and !availableWithoutKey(protocol_provider, raw_id)) continue;
        if (findDuplicate(catalog.items, id_prefix, raw_id)) continue;
        if (catalog.items.len >= max_models_per_surface * 2) return error.OpenCodeModelCatalogTooLarge;
        const id = try std.fmt.allocPrint(alloc, "{s}{s}", .{ id_prefix, raw_id });
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .has_tool_use = true,
        });
    }
}

fn availableWithoutKey(provider: ProtocolProvider, model_id: []const u8) bool {
    if (provider.models.map.get(model_id)) |model| {
        if (model.cost) |cost| return cost.input == 0 and cost.output == 0;
    }
    // OpenCode marks newly launched free models in their live IDs before the
    // richer models.dev record necessarily catches up.
    return std.mem.endsWith(u8, model_id, "-free");
}

fn supportsChatCompletions(provider: ProtocolProvider, model_id: []const u8) bool {
    const npm = if (provider.models.map.get(model_id)) |model|
        if (model.provider) |model_provider|
            model_provider.npm orelse provider.npm
        else
            provider.npm
    else
        // A live model can precede its detailed metadata. Provider defaults are
        // authoritative for entries without a per-model transport override.
        provider.npm;
    return std.mem.eql(u8, npm, openai_compatible_sdk);
}

fn isFreeModel(model: []const u8) bool {
    return std.mem.endsWith(u8, model, "-free");
}

fn isGoModel(model: []const u8) bool {
    return std.mem.startsWith(u8, model, go_model_prefix);
}

pub fn selectAvailableModel(model_ids: []const []u8, preferred: []const u8) ?[]const u8 {
    for (model_ids) |model| if (std.mem.eql(u8, model, preferred)) return model;

    const preferred_is_free = isFreeModel(preferred);
    const preferred_is_go = isGoModel(preferred);
    if (preferred_is_free) {
        for (model_ids) |model| {
            if (isGoModel(model) == preferred_is_go and isFreeModel(model)) return model;
        }
    }
    for (model_ids) |model| {
        if (isGoModel(model) == preferred_is_go) return model;
    }
    return if (model_ids.len > 0) model_ids[0] else null;
}

/// Rejects an exact full-id repeat within or across surfaces. The same model
/// name on both surfaces is not a duplicate: zen and go are distinct routes.
fn findDuplicate(entries: []const model_catalog.ModelCatalogEntry, id_prefix: []const u8, raw_id: []const u8) bool {
    for (entries) |entry| {
        if (entry.id.len != id_prefix.len + raw_id.len) continue;
        if (!std.mem.startsWith(u8, entry.id, id_prefix)) continue;
        if (!std.mem.eql(u8, entry.id[id_prefix.len..], raw_id)) continue;
        return true;
    }
    return false;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

const compatible_protocol_metadata = "{\"opencode\":{\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{}},\"opencode-go\":{\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{}}}";

test "parseCatalog merges both surfaces and keeps same-name models as distinct routes" {
    const zen = "{\"object\":\"list\",\"data\":[{\"id\":\"kimi-k3\",\"object\":\"model\"},{\"id\":\"glm-5\",\"object\":\"model\"},{\"id\":\"gpt-5.6-sol\",\"object\":\"model\"}]}";
    const go = "{\"object\":\"list\",\"data\":[{\"id\":\"kimi-k3\",\"object\":\"model\"},{\"id\":\"kimi-k3\",\"object\":\"model\"},{\"id\":\"deepseek-v4-flash\",\"object\":\"model\"},{\"id\":\"minimax-m3\",\"object\":\"model\"}]}";
    const protocols = "{\"opencode\":{\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{\"gpt-5.6-sol\":{\"provider\":{\"npm\":\"@ai-sdk/openai\"}}}},\"opencode-go\":{\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{\"minimax-m3\":{\"provider\":{\"npm\":\"@ai-sdk/anthropic\"}}}}}";
    var catalog = try parseCatalog(std.testing.allocator, zen, go, protocols, true);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 4), catalog.items.len);
    try std.testing.expectEqualStrings("kimi-k3", catalog.items[0].id);
    try std.testing.expectEqualStrings("glm-5", catalog.items[1].id);
    try std.testing.expectEqualStrings("go/kimi-k3", catalog.items[2].id);
    try std.testing.expectEqualStrings("go/deepseek-v4-flash", catalog.items[3].id);
    for (catalog.items) |entry| {
        try std.testing.expectEqualStrings("language", entry.model_type);
        try std.testing.expect(entry.has_tool_use);
    }
}

test "parseCatalog hides live models that require unsupported OpenCode protocols" {
    const unsupported_zen = "{\"data\":[{\"id\":\"gpt-5.6-sol\"},{\"id\":\"claude-opus-5\"}]}";
    const unsupported_go = "{\"data\":[{\"id\":\"grok-4.5\"},{\"id\":\"minimax-m3\"}]}";
    const protocols = "{\"opencode\":{\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{\"gpt-5.6-sol\":{\"provider\":{\"npm\":\"@ai-sdk/openai\"}},\"claude-opus-5\":{\"provider\":{\"npm\":\"@ai-sdk/anthropic\"}}}},\"opencode-go\":{\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{\"grok-4.5\":{\"provider\":{\"npm\":\"@ai-sdk/openai\"}},\"minimax-m3\":{\"provider\":{\"npm\":\"@ai-sdk/anthropic\"}}}}}";
    try std.testing.expectError(
        error.InvalidOpenCodeModelCatalog,
        parseCatalog(std.testing.allocator, unsupported_zen, unsupported_go, protocols, true),
    );
}

test "new live OpenCode models inherit dynamic provider protocol defaults" {
    const zen = "{\"data\":[{\"id\":\"future-zen-model\"}]}";
    const go = "{\"data\":[{\"id\":\"glm-5.3-flash\"},{\"id\":\"future-go-model\"}]}";
    var catalog = try parseCatalog(std.testing.allocator, zen, go, compatible_protocol_metadata, true);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 3), catalog.items.len);
    try std.testing.expectEqualStrings("future-zen-model", catalog.items[0].id);
    try std.testing.expectEqualStrings("go/glm-5.3-flash", catalog.items[1].id);
    try std.testing.expectEqualStrings("go/future-go-model", catalog.items[2].id);
}

test "stale OpenCode selection stays on its surface and free tier" {
    var ids = [_][]u8{
        @constCast("deepseek-v4-pro"),
        @constCast("x-preview-f-free"),
        @constCast("go/glm-5.3"),
        @constCast("go/ox-alpha-free"),
    };
    try std.testing.expectEqualStrings("x-preview-f-free", selectAvailableModel(&ids, "deepseek-v4-flash-free").?);
    try std.testing.expectEqualStrings("go/ox-alpha-free", selectAvailableModel(&ids, "go/retired-free").?);
    try std.testing.expectEqualStrings("go/glm-5.3", selectAvailableModel(&ids, "go/retired-paid").?);
    try std.testing.expectEqualStrings("deepseek-v4-pro", selectAvailableModel(&ids, "retired-paid").?);
}

test "OpenCode catalog puts explicit free models first" {
    const zen = "{\"data\":[{\"id\":\"deepseek-v4-pro\"},{\"id\":\"x-preview-f-free\"}]}";
    const go = "{\"data\":[{\"id\":\"glm-5.3\"},{\"id\":\"ox-alpha-free\"}]}";
    var catalog = try parseCatalog(std.testing.allocator, zen, go, compatible_protocol_metadata, true);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqualStrings("x-preview-f-free", catalog.items[0].id);
    try std.testing.expectEqualStrings("deepseek-v4-pro", catalog.items[1].id);
    try std.testing.expectEqualStrings("go/glm-5.3", catalog.items[2].id);
    try std.testing.expectEqualStrings("go/ox-alpha-free", catalog.items[3].id);
}

test "parseCatalog rejects empty or malformed catalogs" {
    try std.testing.expectError(error.InvalidOpenCodeModelCatalog, parseCatalog(std.testing.allocator, "{}", "{}", compatible_protocol_metadata, true));
    try std.testing.expectError(error.InvalidOpenCodeModelCatalog, parseCatalog(std.testing.allocator, "{\"data\":[]}", "{\"data\":[]}", compatible_protocol_metadata, true));
    try std.testing.expectError(error.MissingField, parseCatalog(std.testing.allocator, "{\"data\":[]}", "{\"data\":[]}", "{}", true));
}

test "anonymous OpenCode catalog exposes only free Zen chat-completions models" {
    const zen = "{\"data\":[{\"id\":\"paid-model\"},{\"id\":\"future-model-free\"},{\"id\":\"big-pickle\"}]}";
    const go = "{\"data\":[{\"id\":\"go-model-free\"}]}";
    const protocols = "{\"opencode\":{\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{\"big-pickle\":{\"cost\":{\"input\":0,\"output\":0}},\"paid-model\":{\"cost\":{\"input\":1,\"output\":2}}}},\"opencode-go\":{\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{}}}";
    var catalog = try parseCatalog(std.testing.allocator, zen, go, protocols, false);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("future-model-free", catalog.items[0].id);
    try std.testing.expectEqualStrings("big-pickle", catalog.items[1].id);
}
