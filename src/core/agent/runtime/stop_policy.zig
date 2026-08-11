const std = @import("std");
const types = @import("../../shared/types.zig");
const debug_trace = @import("../../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const ToolCall = types.ToolCall;

const NonLiveBackgroundContext = struct {
    command: []const u8,
    log_path: []const u8,
    state: []const u8,
};

pub fn blockedNonLiveBackgroundRestart(arena: Allocator, messages: []const ChatMessage, call: ToolCall, prompt: []const u8) !?[]const u8 {
    const command = backgroundCommandStartCommand(arena, call) orelse return null;
    if (promptExplicitlyRequestsBackgroundStart(prompt)) return null;

    const context = findNonLiveBackgroundContextForCommand(messages, command) orelse return null;
    debug_trace.logf("background", "blocked restart of non-live background command state={s} log={s}", .{ context.state, context.log_path });
    const output: []const u8 = try std.fmt.allocPrint(
        arena,
        "Blocked restarting non-live background command from history. Runtime context says command={s}; log={s}; state={s}. Answer from that state unless the user explicitly asks to start it again.",
        .{ context.command, context.log_path, context.state },
    );
    return output;
}

fn backgroundCommandStartCommand(arena: Allocator, call: ToolCall) ?[]const u8 {
    if (!std.mem.eql(u8, call.name, "run_command")) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, arena, call.arguments_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const background = parsed.value.object.get("background") orelse return null;
    if (background != .bool or !background.bool) return null;

    const command = parsed.value.object.get("command") orelse return null;
    if (command != .string) return null;
    return command.string;
}

fn findNonLiveBackgroundContextForCommand(messages: []const ChatMessage, command: []const u8) ?NonLiveBackgroundContext {
    for (messages) |message_item| {
        if (message_item.role != .system) continue;
        const content = message_item.content orelse continue;
        if (std.mem.find(u8, content, "previous background command history includes command(s) that are no longer live") == null) continue;

        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, content, search_start, "- command=")) |prefix_index| {
            const command_start = prefix_index + "- command=".len;
            const log_marker = std.mem.indexOfPos(u8, content, command_start, "; log=") orelse break;
            const log_start = log_marker + "; log=".len;
            const state_marker = std.mem.indexOfPos(u8, content, log_start, "; state=") orelse break;
            const state_start = state_marker + "; state=".len;
            const line_end = std.mem.indexOfScalarPos(u8, content, state_start, '\n') orelse content.len;

            const context_command = std.mem.trim(u8, content[command_start..log_marker], " \t\r\n");
            if (std.mem.eql(u8, context_command, std.mem.trim(u8, command, " \t\r\n"))) {
                return .{
                    .command = context_command,
                    .log_path = std.mem.trim(u8, content[log_start..state_marker], " \t\r\n"),
                    .state = std.mem.trim(u8, content[state_start..line_end], " \t\r\n"),
                };
            }
            search_start = line_end;
        }
    }
    return null;
}

fn promptExplicitlyRequestsBackgroundStart(prompt: []const u8) bool {
    if (containsPhraseIgnoreCase(prompt, "do not run")) return false;
    if (containsPhraseIgnoreCase(prompt, "do not restart")) return false;
    if (containsPhraseIgnoreCase(prompt, "do not start")) return false;
    if (containsPhraseIgnoreCase(prompt, "don't run")) return false;
    if (containsPhraseIgnoreCase(prompt, "don't restart")) return false;
    if (containsPhraseIgnoreCase(prompt, "don't start")) return false;
    if (containsPhraseIgnoreCase(prompt, "without running")) return false;
    if (containsPhraseIgnoreCase(prompt, "without restarting")) return false;
    if (containsPhraseIgnoreCase(prompt, "without starting")) return false;

    return containsWordIgnoreCase(prompt, "restart") or
        containsPhraseIgnoreCase(prompt, "start it") or
        containsPhraseIgnoreCase(prompt, "start the") or
        containsPhraseIgnoreCase(prompt, "start this") or
        containsPhraseIgnoreCase(prompt, "run it") or
        containsPhraseIgnoreCase(prompt, "run the") or
        containsPhraseIgnoreCase(prompt, "run this") or
        containsPhraseIgnoreCase(prompt, "launch it") or
        containsPhraseIgnoreCase(prompt, "launch the") or
        containsPhraseIgnoreCase(prompt, "launch this");
}

fn containsPhraseIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn containsWordIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) continue;
        const before_ok = i == 0 or !isAsciiWordByte(haystack[i - 1]);
        const after_index = i + needle.len;
        const after_ok = after_index == haystack.len or !isAsciiWordByte(haystack[after_index]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn isAsciiWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn toolCall(id: []const u8, name: []const u8, args: []const u8) ToolCall {
    return .{ .id = id, .name = name, .arguments_json = args };
}

test "blockedNonLiveBackgroundRestart matches terminal runtime context" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const command = "while true; do echo labs7; sleep 1; done";
    var messages: std.ArrayList(ChatMessage) = .empty;
    try messages.append(arena, .{
        .role = .system,
        .content = "Runtime context: previous background command history includes command(s) that are no longer live. Treat these as terminal historical records, not running tasks.\n" ++
            "- command=while true; do echo labs7; sleep 1; done; log=/tmp/labs7.log; state=dead\n" ++
            "For any listed command, answer liveness questions from this state; do not assume it is still running, do not reuse it as a running background command, and do not call run_command to restart the same command unless the user explicitly asks to start it again.",
    });
    const call = toolCall("call_restart", "run_command", "{\"command\":\"while true; do echo labs7; sleep 1; done\",\"background\":true}");

    const blocked = (try blockedNonLiveBackgroundRestart(arena, messages.items, call, "is it still running? do not run or restart it")) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.find(u8, blocked, command) != null);
    try std.testing.expect(std.mem.find(u8, blocked, "state=dead") != null);

    try std.testing.expect(try blockedNonLiveBackgroundRestart(arena, messages.items, call, "please restart it") == null);
    const foreground = toolCall("call_foreground", "run_command", "{\"command\":\"while true; do echo labs7; sleep 1; done\",\"background\":false}");
    try std.testing.expect(try blockedNonLiveBackgroundRestart(arena, messages.items, foreground, "is it still running?") == null);
}
