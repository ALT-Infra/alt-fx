const std = @import("std");
const lexical_relevance = @import("../../core/shared/lexical_relevance.zig");
const result_store = @import("../../core/session/result_store.zig");
const capability_retrieval = @import("../../core/tooling/capability_retrieval.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_limits = @import("../../core/tooling/tool_result_limits.zig");
const skill_search = @import("../skills/skill_search.zig");

const Allocator = std.mem.Allocator;
const Input = struct {
    query: []u8,
    prepared: lexical_relevance.PreparedQuery,
    kind: capability_retrieval.Kind,
    server: ?[]u8,
    limit: usize,
    cursor: ?[]u8,

    fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.query);
        if (self.server) |server| alloc.free(server);
        if (self.cursor) |cursor| alloc.free(cursor);
        self.* = undefined;
    }

    fn request(self: *const Input) capability_retrieval.Request {
        return .{
            .query = &self.prepared,
            .kind = self.kind,
            .server = self.server,
            .limit = self.limit,
            .cursor = self.cursor,
        };
    }
};

const ProjectionCheck = union(enum) {
    valid,
    invalid,
    authentication_identity_changed,
};

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(ctx.allocator, "capability_search arguments must be valid JSON"),
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return failure(ctx.allocator, "capability_search arguments must be an object");
    }
    const query_value = parsed.value.object.get("query") orelse std.json.Value{ .string = "" };
    if (query_value != .string) {
        return failure(ctx.allocator, "capability_search field \"query\" must be a string");
    }
    if (query_value.string.len > lexical_relevance.max_query_bytes) {
        return failure(ctx.allocator, "capability_search query must not exceed 4096 bytes");
    }

    const kind = if (parsed.value.object.get("kind")) |value| kind: {
        if (value != .string) {
            return failure(ctx.allocator, "capability_search field \"kind\" must be all, skill, or mcp");
        }
        break :kind std.meta.stringToEnum(capability_retrieval.Kind, value.string) orelse
            return failure(ctx.allocator, "capability_search field \"kind\" must be all, skill, or mcp");
    } else capability_retrieval.Kind.all;
    const server_value = parsed.value.object.get("server");
    if (server_value) |value| {
        if (value != .string) {
            return failure(ctx.allocator, "capability_search field \"server\" must be a string");
        }
    }
    const cursor_value = parsed.value.object.get("cursor");
    if (cursor_value) |value| {
        if (value != .string) {
            return failure(ctx.allocator, "capability_search field \"cursor\" must be a string");
        }
    }
    const limit = if (parsed.value.object.get("limit")) |value| limit: {
        if (value != .integer or value.integer <= 0) {
            return failure(ctx.allocator, "capability_search field \"limit\" must be an integer from 1 to 20");
        }
        break :limit std.math.cast(usize, value.integer) orelse
            return failure(ctx.allocator, "capability_search field \"limit\" must be an integer from 1 to 20");
    } else capability_retrieval.default_limit;

    const query = try ctx.allocator.dupe(u8, query_value.string);
    errdefer ctx.allocator.free(query);
    const prepared = lexical_relevance.prepare(query) catch |err| switch (err) {
        error.QueryTooLong => unreachable,
        error.TooManyTokens => {
            const result = try failure(
                ctx.allocator,
                "capability_search query must not exceed 64 tokens",
            );
            ctx.allocator.free(query);
            return result;
        },
    };
    const server = if (server_value) |value|
        if (kind == .skill) null else try ctx.allocator.dupe(u8, value.string)
    else
        null;
    errdefer if (server) |owned| ctx.allocator.free(owned);
    const cursor = if (cursor_value) |value|
        if (std.mem.eql(u8, value.string, "first")) null else try ctx.allocator.dupe(u8, value.string)
    else
        null;
    errdefer if (cursor) |owned| ctx.allocator.free(owned);
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .query = query,
        .prepared = prepared,
        .kind = kind,
        .server = server,
        .limit = limit,
        .cursor = cursor,
    };
    input.request().validate() catch |err| {
        const message = try validationMessage(ctx.allocator, err);
        input.deinit(ctx.allocator);
        ctx.allocator.destroy(input);
        return .{ .failure = message };
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const server = args.get("server") orelse return null;
    if (server != .string or server.string.len == 0) return null;
    return .{
        .activity_kind = .read,
        .action_label = "Searching capabilities",
        .completed_action_label = "Searched capabilities",
        .label_arg_kind = .server,
        .label_arg_default = "MCP server",
    };
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const output_cap = @min(
        ctx.max_tool_result_bytes,
        result_store.large_result_threshold_bytes,
    );
    const request = input.request();
    const searches_skills = request.includes(.skill);
    const searches_mcp = request.includes(.mcp);
    const domain_cap = if (searches_skills and searches_mcp and output_cap > 512)
        (output_cap - 512) / 2
    else
        output_cap;
    const skill_output = if (searches_skills)
        skill_search.searchRequest(ctx, request, domain_cap) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCursor => try domainStateJson(ctx.allocator, .skill, "invalid_cursor", false),
            error.StaleCursor => try domainStateJson(ctx.allocator, .skill, "stale_cursor", true),
            else => return executionFailure(ctx.allocator, "skill", err),
        }
    else
        try ctx.allocator.dupe(
            u8,
            "{\"skills\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null}",
        );
    defer ctx.allocator.free(skill_output);

    var mcp_notice: ?[]u8 = null;
    defer if (mcp_notice) |notice| ctx.allocator.free(notice);
    const mcp_output = if (searches_mcp)
        try searchMcp(ctx, request, domain_cap, &mcp_notice)
    else
        try ctx.allocator.dupe(
            u8,
            "{\"tools\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null}",
        );
    defer ctx.allocator.free(mcp_output);
    if (mcp_notice) |notice| try tool_dispatch.reportContextNotice(ctx, notice);

    const combined = combineProjected(
        ctx.allocator,
        skill_output,
        mcp_output,
        output_cap,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return executionFailure(ctx.allocator, "combined", err),
    };
    return .{ .success = combined };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn failure(alloc: Allocator, message: []const u8) Allocator.Error!tool_dispatch.DecodeResult {
    return .{ .failure = try alloc.dupe(u8, message) };
}

fn validationMessage(
    alloc: Allocator,
    err: capability_retrieval.ValidationError,
) Allocator.Error![]u8 {
    const message = switch (err) {
        error.QueryOrServerRequired => "capability_search requires a non-empty query or an exact MCP server",
        error.InvalidLimit => "capability_search field \"limit\" must be an integer from 1 to 20",
        error.InvalidServer => "capability_search field \"server\" must not be empty",
        error.ServerRequiresMcp => "capability_search cannot combine kind=skill with an MCP server",
        error.CursorRequiresDomain => "capability_search cursor continuation requires kind=skill or kind=mcp",
        error.InvalidCursor => "capability_search field \"cursor\" is invalid",
    };
    return alloc.dupe(u8, message);
}
fn executionFailure(
    alloc: Allocator,
    domain: []const u8,
    err: anyerror,
) Allocator.Error!tool_dispatch.ToolResult {
    return .{ .failure = try std.fmt.allocPrint(
        alloc,
        "capability_search {s} search failed: {s}",
        .{ domain, @errorName(err) },
    ) };
}

fn searchMcp(
    ctx: tool_dispatch.DispatchContext,
    request: capability_retrieval.Request,
    max_bytes: usize,
    notice_out: *?[]u8,
) tool_dispatch.DispatchError![]u8 {
    const runtime_context = ctx.mcp_ctx orelse
        return ctx.allocator.dupe(u8, "{\"tools\":[],\"count\":0,\"state\":\"unavailable\"}");
    const search_tools = ctx.mcp_search_tools orelse
        return ctx.allocator.dupe(u8, "{\"tools\":[],\"count\":0,\"state\":\"unavailable\"}");
    var limits = ctx.context_limits;
    if (max_bytes < limits.mcp_search_result_bytes.effectiveBytes()) {
        limits.mcp_search_result_bytes.value = .{ .bytes = max_bytes };
    }
    var result = search_tools(
        runtime_context,
        ctx.allocator,
        request,
        ctx.mcp_permission_rules,
        limits,
        ctx.mcp_access,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCursor => return domainStateJson(ctx.allocator, .mcp, "invalid_cursor", false),
        error.StaleCursor => return domainStateJson(ctx.allocator, .mcp, "stale_cursor", true),
        else => return std.fmt.allocPrint(
            ctx.allocator,
            "{{\"tools\":[],\"count\":0,\"error\":\"{s}\"}}",
            .{@errorName(err)},
        ),
    };
    notice_out.* = result.notice;
    result.notice = null;
    return result.model_output;
}

fn domainStateJson(
    alloc: Allocator,
    domain: capability_retrieval.Domain,
    state: []const u8,
    retryable: bool,
) Allocator.Error![]u8 {
    const cursor_action = if (std.mem.eql(u8, state, "invalid_cursor"))
        ",\"cursor_action\":\"Set cursor to the exact literal first for the initial page. For continuation, copy the exact non-null next_cursors value returned by the prior page; never invent, transform, or wildcard a cursor.\""
    else
        "";
    return std.fmt.allocPrint(
        alloc,
        "{{\"{s}\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null,\"state\":\"{s}\",\"retryable\":{s}{s}}}",
        .{
            if (domain == .skill) "skills" else "tools",
            state,
            if (retryable) "true" else "false",
            cursor_action,
        },
    );
}

fn combineProjected(
    alloc: Allocator,
    skill_output: []const u8,
    mcp_output: []const u8,
    max_bytes: usize,
) ![]u8 {
    var skills_parsed = try std.json.parseFromSlice(std.json.Value, alloc, skill_output, .{});
    defer skills_parsed.deinit();
    var mcp_parsed = try std.json.parseFromSlice(std.json.Value, alloc, mcp_output, .{});
    defer mcp_parsed.deinit();
    if (skills_parsed.value != .object or mcp_parsed.value != .object) {
        return error.InvalidCapabilitySearchResult;
    }
    const skills_value = skills_parsed.value.object.get("skills") orelse
        return error.InvalidCapabilitySearchResult;
    const mcp_tools_value = mcp_parsed.value.object.get("tools") orelse
        return error.InvalidCapabilitySearchResult;
    if (skills_value != .array or mcp_tools_value != .array) {
        return error.InvalidCapabilitySearchResult;
    }

    const skill_items = skills_value.array.items;
    const mcp_items = mcp_tools_value.array.items;
    const skill_count = skill_items.len;
    const mcp_count = mcp_items.len;
    var include_authentication = mcp_parsed.value.object.get("authentication_required") != null;

    while (true) {
        const raw = renderCombined(
            alloc,
            skill_items[0..skill_count],
            mcp_items[0..mcp_count],
            skillMoreAvailable(skills_parsed.value) or skill_count < skill_items.len,
            mcpMoreAvailable(mcp_parsed.value) or mcp_count < mcp_items.len,
            objectNonNegativeCount(skills_parsed.value, "total_matches"),
            objectNonNegativeCount(mcp_parsed.value, "total_matches"),
            skills_parsed.value.object.get("next_cursor"),
            mcp_parsed.value.object.get("next_cursor"),
            skills_parsed.value.object.get("state"),
            skills_parsed.value.object.get("cursor_action"),
            if (include_authentication)
                mcp_parsed.value.object.get("authentication_required")
            else
                null,
            mcp_parsed.value.object.get("state"),
            mcp_parsed.value.object.get("cursor_action"),
            mcp_parsed.value.object.get("error"),
            mcp_parsed.value.object.get("context_limit"),
        ) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        defer alloc.free(raw);

        const projected = @constCast(try tool_result_limits.prepareModelOutput(
            alloc,
            "capability_search",
            raw,
            max_bytes,
        ));
        errdefer alloc.free(projected);
        const check = try checkProjection(
            alloc,
            projected,
            skill_items[0..skill_count],
            mcp_items[0..mcp_count],
            if (include_authentication)
                mcp_parsed.value.object.get("authentication_required")
            else
                null,
        );
        switch (check) {
            .valid => {
                const second = try tool_result_limits.prepareModelOutput(
                    alloc,
                    "capability_search",
                    projected,
                    max_bytes,
                );
                defer alloc.free(@constCast(second));
                if (std.mem.eql(u8, projected, second)) return projected;
                alloc.free(projected);
                return error.CapabilitySearchResultLimitTooSmall;
            },
            .authentication_identity_changed => include_authentication = false,
            .invalid,
            => {
                alloc.free(projected);
                return error.CapabilitySearchResultLimitTooSmall;
            },
        }
        alloc.free(projected);
    }
}

fn renderCombined(
    alloc: Allocator,
    skills: []const std.json.Value,
    mcp_tools: []const std.json.Value,
    skills_more_available: bool,
    mcp_more_available: bool,
    skill_total_matches: usize,
    mcp_total_matches: usize,
    skill_next_cursor: ?std.json.Value,
    mcp_next_cursor: ?std.json.Value,
    skill_state: ?std.json.Value,
    skill_cursor_action: ?std.json.Value,
    authentication_required: ?std.json.Value,
    mcp_state: ?std.json.Value,
    mcp_cursor_action: ?std.json.Value,
    mcp_error: ?std.json.Value,
    mcp_context_limit: ?std.json.Value,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"skills\":[");
    for (skills, 0..) |value, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    try out.writer.writeAll("],\"mcp_tools\":[");
    for (mcp_tools, 0..) |value, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    try out.writer.print(
        "],\"counts\":{{\"skills\":{d},\"mcp_tools\":{d}}},\"total_matches\":{{\"skills\":{d},\"mcp_tools\":{d}}},\"more_available\":{{\"skills\":{s},\"mcp_tools\":{s}}},\"next_cursors\":{{\"skills\":",
        .{
            skills.len,
            mcp_tools.len,
            skill_total_matches,
            mcp_total_matches,
            if (skills_more_available) "true" else "false",
            if (mcp_more_available) "true" else "false",
        },
    );
    try std.json.Stringify.value(skill_next_cursor orelse .null, .{}, &out.writer);
    try out.writer.writeAll(",\"mcp_tools\":");
    try std.json.Stringify.value(mcp_next_cursor orelse .null, .{}, &out.writer);
    try out.writer.writeByte('}');
    if (skill_state) |value| {
        try out.writer.writeAll(",\"skill_state\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    if (skill_cursor_action) |value| {
        try out.writer.writeAll(",\"skill_cursor_action\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    if (authentication_required) |value| {
        try out.writer.writeAll(",\"authentication_required\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    if (mcp_state) |value| {
        try out.writer.writeAll(",\"mcp_state\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    if (mcp_cursor_action) |value| {
        try out.writer.writeAll(",\"mcp_cursor_action\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    if (mcp_error) |value| {
        try out.writer.writeAll(",\"mcp_error\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    if (mcp_context_limit) |value| {
        try out.writer.writeAll(",\"mcp_context_limit\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn checkProjection(
    alloc: Allocator,
    projected: []const u8,
    skills: []const std.json.Value,
    mcp_tools: []const std.json.Value,
    authentication_required: ?std.json.Value,
) !ProjectionCheck {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, projected, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .invalid,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .invalid;
    const projected_skills = parsed.value.object.get("skills") orelse return .invalid;
    const projected_mcp = parsed.value.object.get("mcp_tools") orelse return .invalid;
    if (projected_skills != .array or projected_mcp != .array or
        projected_skills.array.items.len != skills.len or
        projected_mcp.array.items.len != mcp_tools.len)
    {
        return .invalid;
    }

    for (projected_skills.array.items, skills) |projected_skill, skill| {
        if (!objectStringFieldsEqual(projected_skill, skill, "name", "location")) {
            return .invalid;
        }
    }
    for (projected_mcp.array.items, mcp_tools) |projected_tool, tool| {
        if (!objectStringFieldsEqual(projected_tool, tool, "name", "server")) {
            return .invalid;
        }
    }
    if (authentication_required) |expected| {
        const projected_auth = parsed.value.object.get("authentication_required") orelse
            return .authentication_identity_changed;
        if (!objectStringFieldEqual(projected_auth, expected, "server")) {
            return .authentication_identity_changed;
        }
    }
    return .valid;
}

fn objectStringFieldsEqual(
    actual: std.json.Value,
    expected: std.json.Value,
    first: []const u8,
    second: []const u8,
) bool {
    return objectStringFieldEqual(actual, expected, first) and
        objectStringFieldEqual(actual, expected, second);
}

fn objectStringFieldEqual(
    actual: std.json.Value,
    expected: std.json.Value,
    field: []const u8,
) bool {
    if (actual != .object or expected != .object) return false;
    const actual_value = actual.object.get(field) orelse return false;
    const expected_value = expected.object.get(field) orelse return false;
    return actual_value == .string and expected_value == .string and
        std.mem.eql(u8, actual_value.string, expected_value.string);
}

fn skillMoreAvailable(value: std.json.Value) bool {
    const candidate = value.object.get("more_available") orelse return false;
    return candidate == .bool and candidate.bool;
}

fn mcpMoreAvailable(value: std.json.Value) bool {
    const candidate = value.object.get("more_available") orelse return false;
    return candidate == .bool and candidate.bool;
}

fn objectNonNegativeCount(value: std.json.Value, field: []const u8) usize {
    const candidate = value.object.get(field) orelse return 0;
    if (candidate != .integer or candidate.integer < 0) return 0;
    return std.math.cast(usize, candidate.integer) orelse 0;
}

test "capability search decoder owns one bounded prepared query" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"query\":\"send an email\"}");
    switch (decoded) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const value = input.as(Input);
            try std.testing.expectEqualStrings("send an email", value.prepared.raw);
            try std.testing.expectEqual(@as(usize, 3), value.prepared.token_count);
        },
    }
}

test "capability search decoder accepts scoped inventory and rejects ambiguous continuation" {
    const alloc = std.testing.allocator;
    const decoded = try decode(
        .{ .allocator = alloc },
        "{\"kind\":\"mcp\",\"server\":\"datadog\",\"limit\":20,\"cursor\":\"first\"}",
    );
    switch (decoded) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const value = input.as(Input);
            try std.testing.expectEqualStrings("", value.query);
            try std.testing.expectEqual(capability_retrieval.Kind.mcp, value.kind);
            try std.testing.expectEqualStrings("datadog", value.server.?);
            try std.testing.expectEqual(@as(usize, 20), value.limit);
            try std.testing.expect(value.cursor == null);
        },
    }

    const skill_scoped = try decode(
        .{ .allocator = alloc },
        "{\"query\":\"review monitoring names\",\"kind\":\"skill\",\"server\":\"datadog\",\"cursor\":\"first\"}",
    );
    switch (skill_scoped) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const value = input.as(Input);
            try std.testing.expectEqual(capability_retrieval.Kind.skill, value.kind);
            try std.testing.expect(value.server == null);
            try std.testing.expect(value.cursor == null);
        },
    }

    const rejected = try decode(
        .{ .allocator = alloc },
        "{\"query\":\"monitor\",\"cursor\":\"c1:m:1:1:1\"}",
    );
    switch (rejected) {
        .failure => |message| {
            defer alloc.free(message);
            try std.testing.expect(std.mem.find(u8, message, "requires kind=skill or kind=mcp") != null);
        },
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
    }
}

test "capability search projects actionable invalid cursor recovery" {
    const alloc = std.testing.allocator;
    const skills = "{\"skills\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null}";
    const mcp = try domainStateJson(alloc, .mcp, "invalid_cursor", false);
    defer alloc.free(mcp);
    const output = try combineProjected(alloc, skills, mcp, 4096);
    defer alloc.free(output);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "invalid_cursor",
        parsed.value.object.get("mcp_state").?.string,
    );
    const action = parsed.value.object.get("mcp_cursor_action").?.string;
    try std.testing.expect(std.mem.find(u8, action, "exact literal first") != null);
    try std.testing.expect(std.mem.find(u8, action, "never invent") != null);
}

test "capability search presents exact server scope when query is empty" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"mcp\",\"server\":\"clerk\",\"query\":\"\"}",
        .{},
    );
    defer parsed.deinit();
    const resolved = presentation(parsed.value.object).?;
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.server, resolved.label_arg_kind);
    try std.testing.expectEqualStrings("clerk", tool_dispatch.presentationLabelValue(resolved, parsed.value.object).?);
}

test "capability search combines independently paged domains" {
    const alloc = std.testing.allocator;
    const skills =
        "{\"skills\":[{\"name\":\"mail-helper\",\"description\":\"Send email\",\"location\":\"/skills/mail-helper\"}],\"count\":1,\"total_matches\":2,\"more_available\":true,\"next_cursor\":\"c1:s:1:1:1\"}";
    const mcp =
        "{\"tools\":[{\"name\":\"mcp_mail_send\",\"server\":\"mail\",\"description\":\"Send email\"}],\"count\":1,\"total_matches\":3,\"more_available\":true,\"next_cursor\":\"c1:m:1:1:1\",\"authentication_required\":{\"server\":\"TOKEN=runtime-auth-secret\",\"message\":\"authenticate\"}}";
    const output = try combineProjected(alloc, skills, mcp, 4096);
    defer alloc.free(output);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, output, .{});
    defer parsed.deinit();
    const skill_items = parsed.value.object.get("skills").?.array.items;
    const mcp_items = parsed.value.object.get("mcp_tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), skill_items.len);
    try std.testing.expectEqualStrings("mail-helper", skill_items[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(usize, 1), mcp_items.len);
    try std.testing.expectEqualStrings("mcp_mail_send", mcp_items[0].object.get("name").?.string);
    try std.testing.expect(parsed.value.object.get("more_available").?.object.get("skills").?.bool);
    try std.testing.expect(parsed.value.object.get("more_available").?.object.get("mcp_tools").?.bool);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("total_matches").?.object.get("skills").?.integer);
    try std.testing.expectEqualStrings(
        "c1:m:1:1:1",
        parsed.value.object.get("next_cursors").?.object.get("mcp_tools").?.string,
    );
    try std.testing.expect(parsed.value.object.get("authentication_required") == null);
}

test "capability search combined projection releases every allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            const skills =
                "{\"skills\":[{\"name\":\"mail-helper\",\"description\":\"Send email\",\"location\":\"/skills/mail-helper\"}],\"count\":1,\"total_matches\":1,\"more_available\":false,\"next_cursor\":null}";
            const mcp =
                "{\"tools\":[{\"name\":\"mcp_mail_send\",\"server\":\"mail\",\"description\":\"Send email\"}],\"count\":1,\"total_matches\":1,\"more_available\":false,\"next_cursor\":null}";
            const output = try combineProjected(alloc, skills, mcp, 1024);
            alloc.free(output);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
