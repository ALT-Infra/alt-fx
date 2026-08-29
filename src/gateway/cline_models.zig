const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const gateway_client = @import("client.zig");

const catalog_endpoint = "https://api.cline.bot/api/v1/ai/cline/recommended-models";
const plan_endpoint = "https://api.cline.bot/api/v1/users/me/plan";
const e2e_catalog_endpoint_env = "FX_E2E_CLINE_MODELS_URL";
const e2e_plan_endpoint_env = "FX_E2E_CLINE_PLAN_URL";
const max_catalog_bytes: usize = 2 * 1024 * 1024;
const max_models: usize = 4096;
const max_model_id_bytes: usize = 256;
const fetch_timeout_ms: i64 = 30_000;

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
    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });
    const body = fetchPublicBody(alloc, cancel_flag, deadline) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = catalogFetchFailure(err) };
    };
    defer alloc.free(body);
    const include_cline_pass = if (input.access.authorizationCredential()) |credential|
        fetchPlanEntitlement(alloc, credential, cancel_flag, deadline) catch false
    else
        false;
    const catalog = parseCatalog(alloc, body, include_cline_pass) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

fn catalogFetchFailure(err: anyerror) model_catalog.Failure {
    if (err == error.Cancelled) return .{ .category = .cancellation };
    if (err == error.ClineModelCatalogTooLarge or err == error.ClinePublicResponseTooLarge) {
        return .{ .category = .malformed_response };
    }
    return .{ .category = .transport, .retryable = true };
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
            .limited(max_catalog_bytes + 1),
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.ClinePublicResponseTooLarge,
            else => return err,
        };
        errdefer self.alloc.free(body);
        if (body.len > max_catalog_bytes) return error.ClinePublicResponseTooLarge;
        return .{ .status = response.head.status, .body = body };
    }
};

fn fetchPublicBody(
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) ![]u8 {
    const request_url = if (io_mod.getenv(e2e_catalog_endpoint_env)) |override| blk: {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EClineEndpoint;
        break :blk override;
    } else catalog_endpoint;
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
        return error.ClineModelsEndpointFailed;
    }
    return output.body;
}

fn parseCatalog(
    alloc: std.mem.Allocator,
    body: []const u8,
    include_cline_pass: bool,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidClineModelCatalog;

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    if (parsed.value.object.get("free")) |free| try appendTier(alloc, &catalog, free);
    if (include_cline_pass) if (parsed.value.object.get("clinePass")) |cline_pass| try appendTier(alloc, &catalog, cline_pass);
    if (catalog.items.len == 0) return error.InvalidClineModelCatalog;
    return catalog;
}

fn fetchPlanEntitlement(
    alloc: std.mem.Allocator,
    credential: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !bool {
    const request_url = if (io_mod.getenv(e2e_plan_endpoint_env)) |override| blk: {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EClineEndpoint;
        break :blk override;
    } else plan_endpoint;
    const authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{credential});
    defer alloc.free(authorization);
    var operation = PlanGetOperation{ .alloc = alloc, .url = request_url, .authorization = authorization };
    var output = try gateway_client.runBoundedHttpOperation(
        PlanGetOperation.Output,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
    defer output.deinit(alloc);
    if (output.status != .ok) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, output.body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    if (parsed.value.object.get("success")) |success| if (success != .bool or !success.bool) return false;
    const data = parsed.value.object.get("data") orelse return false;
    return data != .null;
}

const PlanGetOperation = struct {
    alloc: std.mem.Allocator,
    url: []const u8,
    authorization: []const u8,

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
                .authorization = .{ .override = self.authorization },
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .redirect_behavior = .unhandled,
        });
        defer request.deinit();
        try request.sendBodiless();
        if (request.connection) |connection| try connection.flush();
        var response = try request.receiveHead(&.{});
        var transfer: [16 * 1024]u8 = undefined;
        const body = try response.reader(&transfer).allocRemaining(self.alloc, .limited(64 * 1024));
        return .{ .status = response.head.status, .body = body };
    }
};

fn appendTier(
    alloc: std.mem.Allocator,
    catalog: *std.ArrayList(model_catalog.ModelCatalogEntry),
    tier: std.json.Value,
) !void {
    if (tier != .array) return error.InvalidClineModelCatalog;
    for (tier.array.items) |value| {
        if (value != .object) continue;
        const id = stringField(value.object, "id") orelse continue;
        if (!validModelId(id) or containsModel(catalog.items, id)) continue;
        if (catalog.items.len >= max_models) return error.ClineModelCatalogTooLarge;
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try catalog.append(alloc, .{
            .id = owned_id,
            .model_type = model_type,
            .has_tool_use = true,
        });
    }
}

fn validModelId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_model_id_bytes) return false;
    for (id) |byte| if (byte <= 0x20 or byte == 0x7f) return false;
    return true;
}

fn containsModel(entries: []const model_catalog.ModelCatalogEntry, id: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.id, id)) return true;
    return false;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

pub fn selectAvailableModel(model_ids: []const []u8, preferred: []const u8) ?[]const u8 {
    for (model_ids) |model| if (std.mem.eql(u8, model, preferred)) return model;
    const preferred_is_pass = isClinePassModel(preferred);
    for (model_ids) |model| if (isClinePassModel(model) == preferred_is_pass) return model;
    return if (model_ids.len > 0) model_ids[0] else null;
}

fn isClinePassModel(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "cline-pass/");
}

test "Cline catalog exposes live free and ClinePass tiers without frozen IDs" {
    const fixture =
        "{\"free\":[{\"id\":\"future/free-model\"},{\"id\":\"shared/model\"}]," ++
        "\"clinePass\":[{\"id\":\"cline-pass/future-model\"},{\"id\":\"shared/model\"}]}";
    var catalog = try parseCatalog(std.testing.allocator, fixture, true);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 3), catalog.items.len);
    try std.testing.expectEqualStrings("future/free-model", catalog.items[0].id);
    try std.testing.expectEqualStrings("cline-pass/future-model", catalog.items[2].id);
    for (catalog.items) |entry| try std.testing.expect(entry.has_tool_use);
}

test "Cline model fallback prefers the live feed order" {
    const ids = [_][]u8{ @constCast("free/new"), @constCast("cline-pass/new") };
    try std.testing.expectEqualStrings("cline-pass/new", selectAvailableModel(&ids, "cline-pass/new").?);
    try std.testing.expectEqualStrings("free/new", selectAvailableModel(&ids, "retired/model").?);
    try std.testing.expectEqualStrings("cline-pass/new", selectAvailableModel(&ids, "cline-pass/retired").?);
}

test "Cline catalog tolerates either requested tier being temporarily absent" {
    var free_only = try parseCatalog(std.testing.allocator, "{\"free\":[{\"id\":\"free/new\"}]}", false);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &free_only);
    try std.testing.expectEqual(@as(usize, 1), free_only.items.len);

    var pass_only = try parseCatalog(std.testing.allocator, "{\"clinePass\":[{\"id\":\"cline-pass/new\"}]}", true);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &pass_only);
    try std.testing.expectEqual(@as(usize, 1), pass_only.items.len);
}
