const std = @import("std");
const chat_completions = @import("openai_chat_completions.zig");

const endpoint = "https://api.cline.bot/api/v1/chat/completions";

fn route(model: []const u8) chat_completions.Route {
    return .{ .endpoint = endpoint, .wire_model = model };
}

fn isAsciiAlphanumeric(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte);
}

fn containsBoundedIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len > value.len) return false;
    var index: usize = 0;
    while (index + needle.len <= value.len) : (index += 1) {
        if (!std.ascii.eqlIgnoreCase(value[index .. index + needle.len], needle)) continue;
        if (index > 0 and isAsciiAlphanumeric(value[index - 1])) continue;
        const end = index + needle.len;
        if (end < value.len and isAsciiAlphanumeric(value[end])) continue;
        return true;
    }
    return false;
}

fn usesMaxCompletionTokens(model: []const u8) bool {
    return containsBoundedIgnoreCase(model, "o1") or
        containsBoundedIgnoreCase(model, "o3") or
        containsBoundedIgnoreCase(model, "o4") or
        containsBoundedIgnoreCase(model, "gpt-5") or
        containsBoundedIgnoreCase(model, "gpt5");
}

const spec = chat_completions.Spec{
    .credential_source = .cline_api_key,
    .alternate_credential_source = .cline_account,
    .provider_name = "Cline",
    .e2e_endpoint_env = "FX_E2E_CLINE_CHAT_URL",
    .resolve_route = route,
    .uses_max_completion_tokens = usesMaxCompletionTokens,
};

pub const agent_stream_provider = chat_completions.provider(&spec);

test "Cline keeps free and ClinePass model IDs intact on one endpoint" {
    inline for (.{ "z-ai/glm-5.3-flash", "cline-pass/kimi-k3" }) |model| {
        const resolved = route(model);
        try std.testing.expectEqualStrings(endpoint, resolved.endpoint);
        try std.testing.expectEqualStrings(model, resolved.wire_model);
    }
}

test "Cline mirrors its reasoning-era completion-token field rule" {
    inline for (.{ "openai/gpt-5.4", "openai/gpt5-mini", "openai/o3-mini", "O4" }) |model| {
        try std.testing.expect(usesMaxCompletionTokens(model));
    }
    inline for (.{ "anthropic/claude-sonnet-4.6", "openai/gpt-4o", "yolo1", "foo-gpt-50" }) |model| {
        try std.testing.expect(!usesMaxCompletionTokens(model));
    }
}

test "Cline request emits the completion-token field selected by its model rule" {
    const types = @import("../core/shared/types.zig");
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hello" }};

    const reasoning_body = try chat_completions.buildRequest(std.testing.allocator, .{
        .model = "openai/gpt-5.4",
        .messages = &messages,
        .tool_choice = .none,
        .max_output_tokens = 8192,
        .provider_options = .{},
    }, &spec);
    defer std.testing.allocator.free(reasoning_body);
    try std.testing.expect(std.mem.find(u8, reasoning_body, "\"max_completion_tokens\":8192") != null);
    try std.testing.expect(std.mem.find(u8, reasoning_body, "\"max_tokens\":") == null);

    const ordinary_body = try chat_completions.buildRequest(std.testing.allocator, .{
        .model = "anthropic/claude-sonnet-4.6",
        .messages = &messages,
        .tool_choice = .none,
        .max_output_tokens = 8192,
        .provider_options = .{},
    }, &spec);
    defer std.testing.allocator.free(ordinary_body);
    try std.testing.expect(std.mem.find(u8, ordinary_body, "\"max_tokens\":8192") != null);
    try std.testing.expect(std.mem.find(u8, ordinary_body, "\"max_completion_tokens\":") == null);
}
