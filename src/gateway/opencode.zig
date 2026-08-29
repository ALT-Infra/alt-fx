const std = @import("std");
const chat_completions = @import("openai_chat_completions.zig");

const endpoint_zen = "https://opencode.ai/zen/v1/chat/completions";
const endpoint_go = "https://opencode.ai/zen/go/v1/chat/completions";
const go_model_prefix = "go/";

fn route(model: []const u8) chat_completions.Route {
    if (std.mem.startsWith(u8, model, go_model_prefix)) {
        return .{
            .endpoint = endpoint_go,
            .wire_model = model[go_model_prefix.len..],
        };
    }
    return .{ .endpoint = endpoint_zen, .wire_model = model };
}

const spec = chat_completions.Spec{
    .credential_source = .opencode_api_key,
    .alternate_credential_source = .opencode_anonymous,
    .allow_anonymous = true,
    .provider_name = "OpenCode",
    .e2e_endpoint_env = "FX_E2E_OPENCODE_CHAT_URL",
    .resolve_route = route,
    .non_retryable_limit_markers = &.{ "GoUsageLimitError", "FreeUsageLimitError" },
};

pub const agent_stream_provider = chat_completions.provider(&spec);

test "OpenCode routes Zen and Go without changing model identity in fx" {
    const zen = route("kimi-k3");
    try std.testing.expectEqualStrings(endpoint_zen, zen.endpoint);
    try std.testing.expectEqualStrings("kimi-k3", zen.wire_model);

    const go = route("go/kimi-k3");
    try std.testing.expectEqualStrings(endpoint_go, go.endpoint);
    try std.testing.expectEqualStrings("kimi-k3", go.wire_model);
    try std.testing.expectEqualStrings("", route("go/").wire_model);
}
