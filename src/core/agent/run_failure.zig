const std = @import("std");

pub const Kind = enum {
    interrupted,
    authentication,
    forbidden,
    invalid_request,
    request_too_large,
    rate_limited,
    provider_unavailable,
    provider_error,
    runtime,
};

pub const Snapshot = struct {
    kind: Kind,
    http_status: ?u16 = null,
    message: []const u8,
};

pub fn kindForHttpStatus(status: std.http.Status) Kind {
    return switch (status) {
        .unauthorized => .authentication,
        .forbidden => .forbidden,
        .bad_request, .not_found, .method_not_allowed, .not_acceptable, .unprocessable_entity => .invalid_request,
        .payload_too_large => .request_too_large,
        .too_many_requests => .rate_limited,
        .bad_gateway, .service_unavailable, .gateway_timeout => .provider_unavailable,
        else => .provider_error,
    };
}

test "HTTP statuses map to stable orchestration failure kinds" {
    try std.testing.expectEqual(Kind.authentication, kindForHttpStatus(.unauthorized));
    try std.testing.expectEqual(Kind.rate_limited, kindForHttpStatus(.too_many_requests));
    try std.testing.expectEqual(Kind.provider_unavailable, kindForHttpStatus(.service_unavailable));
    try std.testing.expectEqual(Kind.invalid_request, kindForHttpStatus(.bad_request));
}
