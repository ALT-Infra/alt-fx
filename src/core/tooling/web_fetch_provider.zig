const std = @import("std");
const session_usage = @import("../session/session_usage.zig");
const types = @import("../shared/types.zig");
const web_fetch_contract = @import("web_fetch_contract.zig");

const Allocator = std.mem.Allocator;

pub const Inputs = struct {
    api_key: []const u8,
    worker_model: []const u8,
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
};

pub const ExecuteFn = *const fn (
    ?*anyopaque,
    Allocator,
    Inputs,
    web_fetch_contract.Request,
) anyerror!web_fetch_contract.Response;

pub const Provider = struct {
    context: ?*anyopaque = null,
    execute_fn: ExecuteFn,

    pub fn execute(
        self: Provider,
        alloc: Allocator,
        inputs: Inputs,
        request: web_fetch_contract.Request,
    ) !web_fetch_contract.Response {
        return self.execute_fn(self.context, alloc, inputs, request);
    }
};
