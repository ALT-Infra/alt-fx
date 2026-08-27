const std = @import("std");

const gateway_client = @import("../gateway/client.zig");
const io_mod = @import("../core/shared/io.zig");
const web_search_contract = @import("../core/tooling/web_search_contract.zig");
const web_search_policy = @import("../core/tooling/web_search_policy.zig");
const web_search_provider = @import("../core/tooling/web_search_provider.zig");

const Allocator = std.mem.Allocator;
const default_search_url = "https://api.parallel.ai/v1/search";
const e2e_search_url_env = "FX_E2E_PARALLEL_SEARCH_URL";
const max_response_bytes: usize = 2 * 1024 * 1024;
const backend_id = web_search_contract.SearchBackendId{ .value = "parallel_direct_search" };
const backend_order = [_]web_search_contract.SearchBackendId{backend_id};
const backend_policies = [_]web_search_policy.BackendPolicy{.{
    .id = backend_id,
    .features = .{
        .max_uses = .best_effort,
        .allowed_domains = .pass_through,
        .blocked_domains = .pass_through,
        .ordered_sources = true,
        .usage = true,
        .terminal_incomplete = true,
        .timeout = true,
        .cancellation = true,
        .result_bounds = .pass_through,
    },
}};

pub const default_web_search_policy = web_search_policy.WebSearchPolicy{
    .preferred_backends = &backend_order,
    .backend_policies = &backend_policies,
};

pub const default_web_search_provider = web_search_provider.Provider{
    .policy = default_web_search_policy,
    .preferred_backends_fn = preferredBackends,
    .execute_fn = executeProvider,
};

fn preferredBackends(_: ?*anyopaque) !?[]const web_search_contract.SearchBackendId {
    return &backend_order;
}

fn executeProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    inputs: web_search_provider.Inputs,
    request: web_search_contract.ProviderRequest,
    on_progress: ?web_search_contract.ProgressFn,
    progress_ctx: ?*anyopaque,
) !web_search_contract.ProviderResponse {
    if (!request.backend.eql(backend_id)) return error.InvalidWebSearchBackend;
    if (inputs.api_key.len == 0) return error.MissingParallelApiKey;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    const payload = try buildPayload(alloc, inputs.worker_model, request);
    defer alloc.free(payload);
    const url = try searchUrl();
    var operation = SearchOperation{
        .alloc = alloc,
        .url = url,
        .api_key = inputs.api_key,
        .payload = payload,
    };
    var http = try gateway_client.runBoundedHttpOperation(
        HttpResult,
        alloc,
        request.cancel_flag,
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(request.timeout_ms),
        }),
        &operation,
    );
    defer http.deinit(alloc);
    try statusError(http.status);

    var response = try parseResponse(alloc, http.body, request.max_results);
    errdefer response.deinit(alloc);
    if (on_progress) |progress| {
        const count = if (response.content.len == 1 and response.content[0] == .search)
            response.content[0].search.content.len
        else
            0;
        progress(progress_ctx orelse return error.MissingProgressContext, .{
            .results_received = .{ .query = request.query, .result_count = count },
        });
    }
    return response;
}

fn searchUrl() ![]const u8 {
    const override = io_mod.getenv(e2e_search_url_env) orelse return default_search_url;
    if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EParallelSearchUrl;
    return override;
}

fn buildPayload(alloc: Allocator, client_model: []const u8, request: web_search_contract.ProviderRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"objective\":");
    try std.json.Stringify.value(request.query, .{}, &out.writer);
    try out.writer.writeAll(",\"search_queries\":[");
    const queries = request.search_queries orelse &.{request.query};
    for (queries, 0..) |query, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(query, .{}, &out.writer);
    }
    try out.writer.writeAll("],\"mode\":");
    try std.json.Stringify.value(@tagName(request.mode orelse .fast), .{}, &out.writer);
    try out.writer.print(",\"max_chars_total\":{d}", .{request.max_output_chars});
    if (client_model.len > 0) {
        try out.writer.writeAll(",\"client_model\":");
        try std.json.Stringify.value(client_model, .{}, &out.writer);
    }
    if (request.session_id) |session_id| {
        if (session_id.len > 0 and session_id.len <= 1000) {
            try out.writer.writeAll(",\"session_id\":");
            try std.json.Stringify.value(session_id, .{}, &out.writer);
        }
    }
    if (hasValues(request.allowed_domains) or hasValues(request.blocked_domains)) {
        try out.writer.print(",\"advanced_settings\":{{\"max_results\":{d},\"source_policy\":{{", .{request.max_results});
        if (hasValues(request.allowed_domains)) {
            try writeStrings(&out.writer, "include_domains", request.allowed_domains.?);
        } else {
            try writeStrings(&out.writer, "exclude_domains", request.blocked_domains.?);
        }
        try out.writer.writeAll("}}");
    } else {
        try out.writer.print(",\"advanced_settings\":{{\"max_results\":{d}", .{request.max_results});
        try out.writer.writeByte('}');
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn writeStrings(writer: *std.Io.Writer, name: []const u8, values: []const []const u8) !void {
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(":[");
    for (values, 0..) |value, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(value, .{}, writer);
    }
    try writer.writeByte(']');
}

const HttpResult = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *HttpResult, alloc: Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

const SearchOperation = struct {
    alloc: Allocator,
    url: []const u8,
    api_key: []const u8,
    payload: []const u8,

    pub fn run(self: *@This()) !HttpResult {
        const uri = try std.Uri.parse(self.url);
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const extra_headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "accept", .value = "application/json" },
        };
        var request = try client.request(.POST, uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = &extra_headers,
            .redirect_behavior = .unhandled,
        });
        defer request.deinit();
        request.transfer_encoding = .{ .content_length = self.payload.len };
        var send_buffer: [8192]u8 = undefined;
        var body_writer = try request.sendBodyUnflushed(&send_buffer);
        try body_writer.writer.writeAll(self.payload);
        try body_writer.end();
        if (request.connection) |connection| try connection.flush();
        var response = try request.receiveHead(&.{});
        var transfer_buffer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        const body = reader.allocRemaining(self.alloc, .limited(max_response_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.ParallelSearchResponseTooLarge,
            else => return err,
        };
        return .{ .status = response.head.status, .body = body };
    }
};

fn statusError(status: std.http.Status) !void {
    return switch (status) {
        .ok => {},
        .unauthorized, .forbidden => error.InvalidParallelApiKey,
        .payment_required => error.ParallelPaymentRequired,
        .too_many_requests => error.ParallelRateLimited,
        else => error.ParallelSearchRequestFailed,
    };
}

fn parseResponse(alloc: Allocator, body: []const u8, max_results: u8) !web_search_contract.ProviderResponse {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidParallelSearchResponse;
    const search_id_value = parsed.value.object.get("search_id") orelse return error.InvalidParallelSearchResponse;
    if (search_id_value != .string) return error.InvalidParallelSearchResponse;
    const results_value = parsed.value.object.get("results") orelse return error.InvalidParallelSearchResponse;
    if (results_value != .array) return error.InvalidParallelSearchResponse;

    var sources: std.ArrayList(web_search_contract.Source) = .empty;
    errdefer deinitSources(alloc, &sources);
    for (results_value.array.items) |value| {
        if (sources.items.len >= max_results) break;
        if (try decodeSource(alloc, value)) |source| try sources.append(alloc, source);
    }
    const owned_sources = try sources.toOwnedSlice(alloc);
    errdefer {
        for (owned_sources) |source| source.deinit(alloc);
        if (owned_sources.len > 0) alloc.free(owned_sources);
    }
    const items = try alloc.alloc(web_search_contract.ResultItem, 1);
    items[0] = .{ .search = .{
        .tool_use_id = try alloc.dupe(u8, search_id_value.string),
        .content = owned_sources,
    } };
    return .{
        .content = items,
        .stop_reason = try alloc.dupe(u8, "complete"),
        .usage = .{ .web_search_requests = 1 },
    };
}

fn decodeSource(alloc: Allocator, value: std.json.Value) !?web_search_contract.Source {
    if (value != .object) return null;
    const url_value = value.object.get("url") orelse return null;
    if (url_value != .string or !isSafeCitationUrl(url_value.string)) return null;
    const title_value = value.object.get("title");
    const title = if (title_value != null and title_value.? == .string) title_value.?.string else url_value.string;
    const owned_title = try alloc.dupe(u8, title);
    errdefer alloc.free(owned_title);
    const owned_url = try alloc.dupe(u8, url_value.string);
    errdefer alloc.free(owned_url);
    const excerpt = try joinedExcerpts(alloc, value.object.get("excerpts"));
    errdefer if (excerpt) |text| alloc.free(text);
    const publish_date = date: {
        const date_value = value.object.get("publish_date") orelse break :date null;
        if (date_value != .string) break :date null;
        break :date try alloc.dupe(u8, date_value.string);
    };
    return .{
        .title = owned_title,
        .url = owned_url,
        .excerpt = excerpt,
        .publish_date = publish_date,
    };
}

fn joinedExcerpts(alloc: Allocator, maybe_value: ?std.json.Value) !?[]u8 {
    const value = maybe_value orelse return null;
    if (value != .array or value.array.items.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var wrote = false;
    for (value.array.items) |item| {
        if (item != .string or item.string.len == 0) continue;
        if (wrote) try out.writer.writeAll("\n\n");
        try out.writer.writeAll(item.string);
        wrote = true;
    }
    if (!wrote) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
}

fn isSafeCitationUrl(url: []const u8) bool {
    const authority_start = if (std.mem.startsWith(u8, url, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, url, "http://"))
        "http://".len
    else
        return false;
    const remainder = url[authority_start..];
    if (remainder.len == 0 or std.mem.findScalar(u8, remainder, '@') != null) return false;
    for (remainder) |char| if (char < 0x20 or char == 0x7f or std.ascii.isWhitespace(char)) return false;
    return true;
}

fn hasValues(values: ?[]const []const u8) bool {
    return if (values) |items| items.len > 0 else false;
}

fn deinitSources(alloc: Allocator, sources: *std.ArrayList(web_search_contract.Source)) void {
    for (sources.items) |source| source.deinit(alloc);
    sources.deinit(alloc);
}

test "Parallel payload uses fast default and preserves optimization context" {
    var cancelled = std.atomic.Value(bool).init(false);
    const payload = try buildPayload(std.testing.allocator, "go/kimi-k3", .{
        .backend = backend_id,
        .query = "Find the current Zig release",
        .search_queries = &.{ "Zig current release", "Zig downloads latest", "Zig release notes" },
        .allowed_domains = &.{"ziglang.org"},
        .session_id = "session-1",
        .cancel_flag = &cancelled,
    });
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.find(u8, payload, "\"mode\":\"fast\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"client_model\":\"go/kimi-k3\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"session_id\":\"session-1\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"include_domains\":[\"ziglang.org\"]") != null);
}

test "Parallel response retains dense excerpts and source metadata" {
    const body =
        "{\"search_id\":\"search_1\",\"results\":[{" ++
        "\"url\":\"https://ziglang.org/download/\",\"title\":\"Download Zig\"," ++
        "\"publish_date\":\"2026-08-20\",\"excerpts\":[\"First fact.\",\"Second fact.\"]}]," ++
        "\"warnings\":null,\"usage\":[{\"name\":\"sku_search\",\"count\":1}]}";
    var response = try parseResponse(std.testing.allocator, body, 10);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), response.content.len);
    const source = response.content[0].search.content[0];
    try std.testing.expectEqualStrings("Download Zig", source.title);
    try std.testing.expectEqualStrings("2026-08-20", source.publish_date.?);
    try std.testing.expectEqualStrings("First fact.\n\nSecond fact.", source.excerpt.?);
    try std.testing.expectEqual(@as(u32, 1), response.usage.?.web_search_requests);
}

test "Parallel HTTP status failures remain actionable" {
    try std.testing.expectError(error.InvalidParallelApiKey, statusError(.unauthorized));
    try std.testing.expectError(error.ParallelPaymentRequired, statusError(.payment_required));
    try std.testing.expectError(error.ParallelRateLimited, statusError(.too_many_requests));
}
