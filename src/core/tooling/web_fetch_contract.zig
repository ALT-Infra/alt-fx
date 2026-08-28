const std = @import("std");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const ContentMode = enum {
    focused,
    full,
};

pub const Request = struct {
    url: []const u8,
    objective: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    turn_id: ?u64 = null,
    timeout_ms: u32 = 30_000,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

/// Provider output owned by the caller.
pub const Response = struct {
    final_url: []u8,
    title: ?[]u8 = null,
    publish_date: ?[]u8 = null,
    content: []u8,
    mode: ContentMode,
    session_id: ?[]u8 = null,
    usage: ?types.ToolUsage = null,

    pub fn deinit(self: *Response, alloc: Allocator) void {
        alloc.free(self.final_url);
        if (self.title) |title| alloc.free(title);
        if (self.publish_date) |publish_date| alloc.free(publish_date);
        alloc.free(self.content);
        if (self.session_id) |session_id| alloc.free(session_id);
        self.* = undefined;
    }
};
