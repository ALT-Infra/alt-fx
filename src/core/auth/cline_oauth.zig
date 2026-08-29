const std = @import("std");
const cline_account_session = @import("cline_account_session.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const login_flow = @import("login_flow.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;
const client_id = "client_01K3A541FN8TA3EPPHTD2325AR";
const workos_issuer = "https://api.workos.com";
const device_url = workos_issuer ++ "/user_management/authorize/device";
const token_url = workos_issuer ++ "/user_management/authenticate";
const register_url = "https://api.cline.bot/api/v1/auth/register";
const refresh_url = "https://api.cline.bot/api/v1/auth/refresh";
const e2e_device_url_env = "FX_E2E_CLINE_DEVICE_AUTH_URL";
const e2e_token_url_env = "FX_E2E_CLINE_DEVICE_TOKEN_URL";
const e2e_register_url_env = "FX_E2E_CLINE_REGISTER_URL";
const e2e_refresh_url_env = "FX_E2E_CLINE_REFRESH_URL";

pub const RefreshMode = enum { if_needed, force, stored };

pub const Access = struct {
    access_token: []u8,
    account_id: []u8,
    refresh_after_ms: i64,

    pub fn deinit(self: *Access, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        alloc.free(self.account_id);
        self.* = undefined;
    }
};

const LoginContext = struct {
    transport: oauth_transport.Provider,
};

pub fn startSignIn(
    runtime: *login_flow.SignInRuntime,
    alloc: Allocator,
    transport: oauth_transport.Provider,
) !bool {
    if (comptime host_target.is_wasm) return error.ClineOAuthUnavailable;
    const context = try alloc.create(LoginContext);
    errdefer alloc.destroy(context);
    context.* = .{ .transport = transport };
    var prepared = try prepareSignIn(alloc, transport);
    errdefer prepared.deinit(alloc);
    return runtime.startPrepared(alloc, prepared, .{
        .ctx = context,
        .deinit_ctx = deinitContext,
        .oauth_transport = transport,
        .poll = .{ .poll_device_token = pollWorkosDeviceToken },
        .complete = completeSignIn,
        .save = saveSignIn,
    });
}

/// WorkOS's device token response does not match the generic OAuth contract
/// that the default poller assumes, so Cline's flow polls with the WorkOS
/// parser instead (see pollWorkosDeviceTokenBounded).
fn pollWorkosDeviceToken(
    _: ?*anyopaque,
    alloc: Allocator,
    transport: oauth_transport.Provider,
    metadata: oauth.Metadata,
    device_client_id: []const u8,
    device_code: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !oauth.PollResult {
    return oauth.pollWorkosDeviceTokenBounded(
        alloc,
        transport,
        metadata,
        device_client_id,
        device_code,
        cancel_flag,
        deadline,
    );
}

fn deinitContext(raw: ?*anyopaque, alloc: Allocator) void {
    alloc.destroy(@as(*LoginContext, @ptrCast(@alignCast(raw.?))));
}

fn prepareSignIn(alloc: Allocator, transport: oauth_transport.Provider) !login_flow.PreparedLogin {
    const configured_device = try configuredEndpoint(alloc, e2e_device_url_env, device_url);
    defer alloc.free(configured_device);
    const configured_token = try configuredEndpoint(alloc, e2e_token_url_env, token_url);
    errdefer alloc.free(configured_token);
    var response = try transport.execute(alloc, .{
        .method = .post_form,
        .url = configured_device,
        .payload = "client_id=" ++ client_id,
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) return error.ClineDeviceAuthorizationFailed;
    var device = try oauth.parseDeviceAuthorization(alloc, response.body);
    errdefer device.deinit(alloc);
    const owned_issuer = try alloc.dupe(u8, workos_issuer);
    errdefer alloc.free(owned_issuer);
    const owned_device_endpoint = try alloc.dupe(u8, configured_device);
    errdefer alloc.free(owned_device_endpoint);
    const owned_client_id = try alloc.dupe(u8, client_id);
    errdefer alloc.free(owned_client_id);
    return .{
        .metadata = .{
            .issuer = owned_issuer,
            .device_authorization_endpoint = owned_device_endpoint,
            .token_endpoint = configured_token,
        },
        .device = device,
        .client_id = owned_client_id,
    };
}

fn completeSignIn(
    raw: ?*anyopaque,
    alloc: Allocator,
    _: []const u8,
    _: []const u8,
    token: *oauth.TokenSet,
) !login_flow.SignInCompletion {
    const context: *LoginContext = @ptrCast(@alignCast(raw.?));
    const workos_refresh = token.refresh_token orelse return error.ClineRefreshTokenMissing;
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try payload.writer.writeAll("{\"accessToken\":");
    try std.json.Stringify.value(token.access_token, .{}, &payload.writer);
    try payload.writer.writeAll(",\"refreshToken\":");
    try std.json.Stringify.value(workos_refresh, .{}, &payload.writer);
    try payload.writer.writeByte('}');
    const endpoint = try configuredEndpoint(alloc, e2e_register_url_env, register_url);
    defer alloc.free(endpoint);
    var response = try context.transport.execute(alloc, .{
        .method = .post_json,
        .url = endpoint,
        .payload = payload.written(),
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) return error.ClineTokenRegistrationFailed;
    return .{ .cline = try parseClineSession(alloc, response.body, null) };
}

fn saveSignIn(_: ?*anyopaque, alloc: Allocator, completion: login_flow.SignInCompletion) !void {
    const session = switch (completion) {
        .cline => |session| session,
        else => return error.InvalidSignInCompletion,
    };
    try cline_account_session.saveNewSession(alloc, session);
}

pub fn sourceExists(alloc: Allocator) !bool {
    var session = (try cline_account_session.load(alloc)) orelse return false;
    defer session.deinit(alloc);
    return true;
}

pub fn loadAccess(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    mode: RefreshMode,
) !?Access {
    if (mode == .stored) {
        var session = (try cline_account_session.load(alloc)) orelse return null;
        defer session.deinit(alloc);
        return takeAccess(&session);
    }
    var mutation = (try cline_account_session.beginExistingMutation()) orelse return null;
    defer mutation.deinit();
    var session = (try mutation.load(alloc)) orelse return null;
    defer session.deinit(alloc);
    if (mode == .force or session.expired(io_mod.milliTimestamp())) {
        try refreshSession(alloc, transport, &mutation, &session);
    }
    return takeAccess(&session);
}

fn takeAccess(session: *cline_account_session.Session) Access {
    const token = session.access_token;
    session.access_token = &.{};
    const account = session.account_id;
    session.account_id = &.{};
    return .{
        .access_token = token,
        .account_id = account,
        .refresh_after_ms = cline_account_session.refreshDeadlineMs(session.expires_at_ms),
    };
}

fn refreshSession(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    mutation: *cline_account_session.Mutation,
    session: *cline_account_session.Session,
) !void {
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try payload.writer.writeAll("{\"refreshToken\":");
    try std.json.Stringify.value(session.refresh_token, .{}, &payload.writer);
    try payload.writer.writeAll(",\"grantType\":\"refresh_token\"}");
    const endpoint = try configuredEndpoint(alloc, e2e_refresh_url_env, refresh_url);
    defer alloc.free(endpoint);
    var response = try transport.execute(alloc, .{
        .method = .post_json,
        .url = endpoint,
        .payload = payload.written(),
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) return error.ClineTokenRefreshFailed;
    var replacement = try parseClineSession(alloc, response.body, session);
    errdefer replacement.deinit(alloc);
    if (!std.mem.eql(u8, replacement.account_id, session.account_id)) return error.ClineAccountChanged;
    try mutation.save(alloc, replacement);
    session.deinit(alloc);
    session.* = replacement;
    replacement.access_token = &.{};
    replacement.refresh_token = &.{};
    replacement.account_id = &.{};
}

fn parseClineSession(
    alloc: Allocator,
    bytes: []const u8,
    fallback: ?*const cline_account_session.Session,
) !cline_account_session.Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidClineOAuthResponse;
    const success = parsed.value.object.get("success") orelse return error.InvalidClineOAuthResponse;
    if (success != .bool or !success.bool) return error.InvalidClineOAuthResponse;
    const data = parsed.value.object.get("data") orelse return error.InvalidClineOAuthResponse;
    if (data != .object) return error.InvalidClineOAuthResponse;
    const token_type = try borrowedRequiredString(data.object, "tokenType");
    if (!std.ascii.eqlIgnoreCase(token_type, "Bearer")) return error.InvalidClineOAuthResponse;
    const access = try requiredString(alloc, data.object, "accessToken");
    errdefer secret.zeroAndFree(alloc, access);
    const refresh = if (data.object.get("refreshToken")) |value| blk: {
        if (value != .string or value.string.len == 0) return error.InvalidClineOAuthResponse;
        break :blk try alloc.dupe(u8, value.string);
    } else if (fallback) |old|
        try alloc.dupe(u8, old.refresh_token)
    else
        return error.ClineRefreshTokenMissing;
    errdefer secret.zeroAndFree(alloc, refresh);
    const expires_text = try borrowedRequiredString(data.object, "expiresAt");
    const user_info = data.object.get("userInfo") orelse return error.InvalidClineOAuthResponse;
    if (user_info != .object) return error.InvalidClineOAuthResponse;
    const account = if (user_info.object.get("clineUserId")) |value| blk: {
        if (value == .string and value.string.len > 0) break :blk try alloc.dupe(u8, value.string);
        if (fallback) |old| break :blk try alloc.dupe(u8, old.account_id);
        return error.InvalidClineOAuthResponse;
    } else if (fallback) |old|
        try alloc.dupe(u8, old.account_id)
    else
        return error.InvalidClineOAuthResponse;
    errdefer alloc.free(account);
    return .{
        .access_token = access,
        .refresh_token = refresh,
        .expires_at_ms = try parseUtcTimestampMs(expires_text),
        .account_id = account,
    };
}

fn parseUtcTimestampMs(value: []const u8) !i64 {
    if (value.len < 20 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':' or value[value.len - 1] != 'Z') {
        return error.InvalidClineOAuthResponse;
    }
    const year = try std.fmt.parseInt(u16, value[0..4], 10);
    const month = try std.fmt.parseInt(u8, value[5..7], 10);
    const day = try std.fmt.parseInt(u8, value[8..10], 10);
    const hour = try std.fmt.parseInt(u8, value[11..13], 10);
    const minute = try std.fmt.parseInt(u8, value[14..16], 10);
    const second = try std.fmt.parseInt(u8, value[17..19], 10);
    if (year < 1970 or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59) return error.InvalidClineOAuthResponse;
    const month_enum: std.time.epoch.Month = @enumFromInt(month);
    if (day < 1 or day > std.time.epoch.getDaysInMonth(year, month_enum)) return error.InvalidClineOAuthResponse;
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += std.time.epoch.getDaysInYear(y);
    var m: u8 = 1;
    while (m < month) : (m += 1) days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
    days += day - 1;
    var millis: i64 = (days * std.time.s_per_day + @as(i64, hour) * std.time.s_per_hour + @as(i64, minute) * std.time.s_per_min + second) * std.time.ms_per_s;
    if (value.len > 20) {
        if (value[19] != '.') return error.InvalidClineOAuthResponse;
        const fraction = value[20 .. value.len - 1];
        if (fraction.len == 0 or fraction.len > 9) return error.InvalidClineOAuthResponse;
        var nanos = try std.fmt.parseInt(u32, fraction, 10);
        var digits = fraction.len;
        while (digits < 9) : (digits += 1) nanos *= 10;
        millis += nanos / std.time.ns_per_ms;
    }
    return millis;
}

fn requiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    return alloc.dupe(u8, try borrowedRequiredString(object, key));
}

fn borrowedRequiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidClineOAuthResponse;
    if (value != .string or value.string.len == 0) return error.InvalidClineOAuthResponse;
    return value.string;
}

fn configuredEndpoint(alloc: Allocator, env: []const u8, default: []const u8) ![]u8 {
    const candidate = io_mod.getenv(env) orelse default;
    if (io_mod.getenv(env) != null) {
        const uri = std.Uri.parse(candidate) catch return error.InvalidE2EClineEndpoint;
        const host_component = uri.host orelse return error.InvalidE2EClineEndpoint;
        var buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const name = host_component.toRaw(&buf) catch return error.InvalidE2EClineEndpoint;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or uri.port == null or
            !(std.mem.eql(u8, name, "127.0.0.1") or std.ascii.eqlIgnoreCase(name, "localhost") or std.mem.eql(u8, name, "[::1]")))
        {
            return error.InvalidE2EClineEndpoint;
        }
    }
    return alloc.dupe(u8, candidate);
}

pub fn logout() !cline_account_session.DeleteOutcome {
    var mutation = (try cline_account_session.beginExistingMutation()) orelse return .missing;
    defer mutation.deinit();
    return mutation.delete();
}

pub fn runLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
) !void {
    var runtime: login_flow.SignInRuntime = .{};
    defer runtime.deinit(alloc);
    if (!try startSignIn(&runtime, alloc, transport)) return error.ClineLoginBusy;
    const snapshot = runtime.snapshot();
    const url = snapshot.verification_uri_complete orelse snapshot.verification_uri;
    try writeStdout("Open this URL to sign in with Cline:\n");
    try writeStdout(url);
    try writeStdout("\nCode: ");
    try writeStdout(snapshot.user_code);
    try writeStdout("\n\nWaiting for browser authorization...\n");
    if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) _ = url_opener.open(alloc, url) catch false;
    while (true) {
        switch (runtime.pollTransition(alloc)) {
            .none => try io_mod.getIo().sleep(.fromMilliseconds(50), .awake),
            .succeeded => |completion| {
                var owned = completion;
                defer owned.deinit(alloc);
                return;
            },
            .failed => |err| return err,
            .cancelled => return error.Cancelled,
        }
    }
}

fn writeStdout(value: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), value);
}

test "Cline timestamps preserve milliseconds" {
    try std.testing.expectEqual(@as(i64, 1_893_456_000_123), try parseUtcTimestampMs("2030-01-01T00:00:00.123Z"));
}

test "Cline registration envelope becomes a refreshable account session" {
    const fixture =
        "{\"success\":true,\"data\":{\"accessToken\":\"cline-access\",\"refreshToken\":\"cline-refresh\",\"tokenType\":\"Bearer\",\"expiresAt\":\"2030-01-01T00:00:00.123Z\",\"userInfo\":{\"clineUserId\":\"user_123\"}}}";
    var session = try parseClineSession(std.testing.allocator, fixture, null);
    defer session.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("cline-access", session.access_token);
    try std.testing.expectEqualStrings("cline-refresh", session.refresh_token);
    try std.testing.expectEqualStrings("user_123", session.account_id);
    try std.testing.expectEqual(@as(i64, 1_893_456_000_123), session.expires_at_ms);
}
