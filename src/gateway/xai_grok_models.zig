const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const max_catalog_models: usize = 128;
const max_model_id_bytes: usize = 256;
const max_catalog_bytes: usize = 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;
const default_models_endpoint = "https://api.x.ai/v1/language-models";
const e2e_models_endpoint_env = "FX_E2E_XAI_GROK_MODELS_URL";
const grok_4_6_reasoning_efforts = [_]types.ReasoningEffort{
    types.ReasoningEffort.literal("xhigh"),
    types.ReasoningEffort.literal("high"),
    types.ReasoningEffort.literal("medium"),
    types.ReasoningEffort.literal("low"),
};
const grok_4_5_reasoning_efforts = [_]types.ReasoningEffort{
    types.ReasoningEffort.literal("high"),
    types.ReasoningEffort.literal("medium"),
    types.ReasoningEffort.literal("low"),
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
    if (input.access.credentialSource() != .grok_subscription) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    const credential = input.access.authorizationCredential() orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    const request_url = modelsUrl(alloc) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(request_url);

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    var operation = FetchOperation{
        .alloc = alloc,
        .url = request_url,
        .credential = credential,
    };
    var response = gateway_client.runBoundedHttpOperation(
        FetchResponse,
        alloc,
        cancel_flag,
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(fetch_timeout_ms),
        }),
        &operation,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{
            .category = if (err == error.Cancelled) .cancellation else .transport,
            .retryable = err != error.Cancelled,
        } };
    };
    defer response.deinit(alloc);
    if (response.status != .ok) {
        return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    }
    const catalog = parseCatalog(alloc, response.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *FetchResponse, alloc: std.mem.Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

const FetchOperation = struct {
    alloc: std.mem.Allocator,
    url: []const u8,
    credential: []const u8,

    pub fn run(self: *@This()) !FetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const auth_header = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.credential});
        defer secret.zeroAndFree(self.alloc, auth_header);
        const body_buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer secret.zeroAndFree(self.alloc, body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .authorization = .{ .override = auth_header },
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = &.{
                .{ .name = "accept", .value = "application/json" },
            },
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.GrokModelCatalogTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        try validateCatalogBodySize(body.len);
        return .{
            .status = result.status,
            .body = try self.alloc.dupe(u8, body),
        };
    }
};

fn modelsUrl(alloc: std.mem.Allocator) ![]u8 {
    const base = io_mod.getenv(e2e_models_endpoint_env) orelse default_models_endpoint;
    if (io_mod.getenv(e2e_models_endpoint_env) != null and !gateway_client.isLoopbackHttpUrl(base)) {
        return error.InvalidE2EGrokModelsEndpoint;
    }
    return alloc.dupe(u8, base);
}

fn parseCatalog(
    alloc: std.mem.Allocator,
    json_text: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGrokModelCatalog;
    const models_value = parsed.value.object.get("models") orelse
        return error.InvalidGrokModelCatalog;
    if (models_value != .array) {
        return error.InvalidGrokModelCatalog;
    }
    try validateCatalogModelCount(models_value.array.items.len);

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (models_value.array.items) |value| {
        if (value != .object) return error.InvalidGrokModelCatalog;
        const object = value.object;
        if (!try stringArrayContains(object, "output_modalities", "text")) continue;
        const raw_id = try requiredString(object, "id");
        try validateModelId(raw_id);
        const id = try alloc.dupe(u8, raw_id);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        var reasoning_efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer reasoning_efforts.deinit(alloc);
        try appendKnownReasoningEfforts(alloc, &reasoning_efforts, raw_id);
        const has_vision = try stringArrayContains(object, "input_modalities", "image");

        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .has_tool_use = true,
            .has_reasoning = reasoning_efforts.items.len > 0,
            .reasoning_efforts = reasoning_efforts,
            .has_vision = has_vision,
            .has_file_input = has_vision,
            .has_implicit_caching = true,
        });
    }
    return catalog;
}

fn appendKnownReasoningEfforts(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(types.ReasoningEffort),
    model_id: []const u8,
) !void {
    const efforts = if (std.mem.eql(u8, model_id, "grok-4.6"))
        &grok_4_6_reasoning_efforts
    else if (std.mem.eql(u8, model_id, "grok-4.5"))
        &grok_4_5_reasoning_efforts
    else
        return;
    try out.appendSlice(alloc, efforts);
}

fn stringArrayContains(
    object: std.json.ObjectMap,
    key: []const u8,
    expected: []const u8,
) !bool {
    const value = object.get(key) orelse return false;
    if (value != .array or value.array.items.len > 32) return error.InvalidGrokModelCatalog;
    for (value.array.items) |entry| {
        if (entry != .string) return error.InvalidGrokModelCatalog;
        if (std.mem.eql(u8, entry.string, expected)) return true;
    }
    return false;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidGrokModelCatalog;
    if (value != .string or value.string.len == 0) return error.InvalidGrokModelCatalog;
    return value.string;
}

fn validateModelId(id: []const u8) !void {
    if (id.len == 0 or id.len > max_model_id_bytes) return error.InvalidGrokModelCatalog;
    for (id) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidGrokModelCatalog;
    }
}

fn validateCatalogBodySize(size: usize) !void {
    if (size > max_catalog_bytes) return error.GrokModelCatalogTooLarge;
}

fn validateCatalogModelCount(count: usize) !void {
    if (count > max_catalog_models) return error.InvalidGrokModelCatalog;
}

test "Grok catalog parser keeps text models and live modalities" {
    const alloc = std.testing.allocator;
    const json =
        \\{"models":[
        \\  {"id":"grok-4.20","object":"model","input_modalities":["text","image"],"output_modalities":["text"]},
        \\  {"id":"grok-4.6","object":"model","input_modalities":["text","image"],"output_modalities":["text"]},
        \\  {"id":"grok-4.5","object":"model","input_modalities":["text","image"],"output_modalities":["text"]},
        \\  {"id":"grok-image","object":"model","input_modalities":["text"],"output_modalities":["image"]}
        \\]}
    ;
    var catalog = try parseCatalog(alloc, json);
    defer model_catalog.freeModelCatalog(alloc, &catalog);

    try std.testing.expectEqual(@as(usize, 3), catalog.items.len);
    const model = catalog.items[0];
    try std.testing.expectEqualStrings("grok-4.20", model.id);
    try std.testing.expect(model.has_tool_use);
    try std.testing.expect(!model.has_reasoning);
    try std.testing.expectEqual(@as(usize, 0), model.reasoning_efforts.items.len);
    try std.testing.expect(!model.supports_fast_mode);
    try std.testing.expect(model.has_vision);
    try std.testing.expect(model.has_file_input);
    try std.testing.expectEqual(@as(u32, 0), model.context_window);
    const grok_4_6 = catalog.items[1];
    try std.testing.expectEqualStrings("grok-4.6", grok_4_6.id);
    try std.testing.expect(grok_4_6.has_reasoning);
    try std.testing.expectEqual(@as(usize, 4), grok_4_6.reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("xhigh", grok_4_6.reasoning_efforts.items[0].label());
    try std.testing.expectEqualStrings("low", grok_4_6.reasoning_efforts.items[3].label());
    const grok_4_5 = catalog.items[2];
    try std.testing.expectEqualStrings("grok-4.5", grok_4_5.id);
    try std.testing.expectEqual(@as(usize, 3), grok_4_5.reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("high", grok_4_5.reasoning_efforts.items[0].label());
}

test "Grok catalog URL is the live-validated direct endpoint" {
    const url = try modelsUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(default_models_endpoint, url);
}

test "Grok model ids enforce the exact provider-local bound" {
    var accepted: [max_model_id_bytes]u8 = @splat('a');
    try validateModelId(&accepted);
    var rejected: [max_model_id_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.InvalidGrokModelCatalog, validateModelId(&rejected));
}

test "Grok catalog resource limits accept exact values and reject one beyond" {
    try validateCatalogBodySize(max_catalog_bytes);
    try std.testing.expectError(
        error.GrokModelCatalogTooLarge,
        validateCatalogBodySize(max_catalog_bytes + 1),
    );
    try validateCatalogModelCount(max_catalog_models);
    try std.testing.expectError(
        error.InvalidGrokModelCatalog,
        validateCatalogModelCount(max_catalog_models + 1),
    );
}
