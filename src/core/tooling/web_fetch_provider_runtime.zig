const std = @import("std");
const io_mod = @import("../shared/io.zig");
const session_usage = @import("../session/session_usage.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const web_fetch_contract = @import("web_fetch_contract.zig");
const web_fetch_provider = @import("web_fetch_provider.zig");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    provider: ?web_fetch_provider.Provider = null,
};

const OwnedInputs = struct {
    api_key: []u8,
    worker_model: []u8,
    usage: ?*session_usage.Usage,
    usage_allocator: Allocator,

    fn deinit(self: *OwnedInputs, alloc: Allocator) void {
        alloc.free(self.api_key);
        alloc.free(self.worker_model);
        self.* = undefined;
    }

    fn borrowed(self: *const OwnedInputs) web_fetch_provider.Inputs {
        return .{
            .api_key = self.api_key,
            .worker_model = self.worker_model,
            .usage = self.usage,
            .usage_allocator = self.usage_allocator,
        };
    }
};

pub const Runtime = struct {
    provider: ?web_fetch_provider.Provider,
    api_key: []const u8 = "",
    worker_model: []const u8 = "",
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
    config_mutex: std.Io.Mutex = .init,
    fallback_cancel_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(config: Config) Runtime {
        return .{ .provider = config.provider };
    }

    pub fn deinit(_: *Runtime) void {}

    pub fn configure(self: *Runtime, inputs: web_fetch_provider.Inputs) void {
        self.config_mutex.lockUncancelable(io_mod.getIo());
        defer self.config_mutex.unlock(io_mod.getIo());
        self.api_key = inputs.api_key;
        self.worker_model = inputs.worker_model;
        self.usage = inputs.usage;
        self.usage_allocator = inputs.usage_allocator;
    }

    pub fn dispatchBackend(self: *Runtime) tool_dispatch.WebFetchBackend {
        return .{ .ctx = @ptrCast(self), .execute_fn = executeForDispatch };
    }

    fn inputsSnapshot(self: *Runtime, alloc: Allocator) !OwnedInputs {
        self.config_mutex.lockUncancelable(io_mod.getIo());
        defer self.config_mutex.unlock(io_mod.getIo());
        const api_key = try alloc.dupe(u8, self.api_key);
        errdefer alloc.free(api_key);
        return .{
            .api_key = api_key,
            .worker_model = try alloc.dupe(u8, self.worker_model),
            .usage = self.usage,
            .usage_allocator = self.usage_allocator,
        };
    }

    fn executeForDispatch(
        raw_ctx: *anyopaque,
        ctx: tool_dispatch.DispatchContext,
        input: web_fetch_contract.Request,
    ) anyerror!web_fetch_contract.Response {
        const self: *Runtime = @ptrCast(@alignCast(raw_ctx));
        var inputs = try self.inputsSnapshot(ctx.allocator);
        defer inputs.deinit(ctx.allocator);
        const provider = self.provider orelse return error.MissingWebFetchProvider;
        var request = input;
        request.session_id = ctx.web_research_session_id;
        request.turn_id = if (ctx.output_chunk_lifecycle_id) |id| id.turn_id else null;
        request.cancel_flag = ctx.cancel_flag orelse &self.fallback_cancel_flag;
        return provider.execute(ctx.allocator, inputs.borrowed(), request);
    }
};
