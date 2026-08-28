const std = @import("std");
const builtin_mcp = @import("../../builtins/mcp.zig");
const config_runtime = @import("../config/config_runtime.zig");
const mcp_command_provider = @import("../mcp/command_provider.zig");
const mcp_menu_state = @import("../mcp/menu_state.zig");
const project_config = @import("../mcp/project_config.zig");

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn saveAdd(
            app: *App,
            generation: u64,
            transport: mcp_menu_state.AddTransport,
        ) !void {
            const form = app.mcp.menuView().add_form;
            var tokens: std.ArrayList([]const u8) = .empty;
            defer tokens.deinit(app.alloc);
            switch (transport) {
                .local => {
                    try tokens.appendSlice(app.alloc, &.{ form.name.items, form.target.items });
                    var arguments = std.mem.tokenizeAny(u8, form.arguments.items, " \t");
                    while (arguments.next()) |argument| try tokens.append(app.alloc, argument);
                },
                .http => try tokens.appendSlice(
                    app.alloc,
                    &.{ "--transport", "http", form.name.items, form.target.items },
                ),
            }
            const intent = try mcp_command_provider.parseAddIntent(tokens.items);
            var result = try builtin_mcp.addProfileServer(app.alloc, intent);
            defer result.deinit(app.alloc);
            try app.mcp.setMenuFeedback(app.alloc, "Saved MCP server; reconnecting…");
            app.mcp.returnMenuToServers();
            app.beginMcpMenuReload(generation) catch |err| {
                try app.mcp.recordMenuEffectFailure(app.alloc, generation, err);
            };
        }

        pub fn removeServer(app: *App, generation: u64) !void {
            const server_name = app.mcp.selectedMenuServerName() orelse
                return error.McpServerNotFound;
            var result = try builtin_mcp.removeProfileServer(app.alloc, server_name);
            defer result.deinit(app.alloc);
            if (!result.removed) return error.McpProfileServerNotFound;
            try app.mcp.setMenuFeedback(app.alloc, "Removed MCP server; reconnecting…");
            app.mcp.returnMenuToServers();
            app.beginMcpMenuReload(generation) catch |err| {
                try app.mcp.recordMenuEffectFailure(app.alloc, generation, err);
            };
        }

        pub fn applyTrustAction(
            app: *App,
            generation: u64,
            action: mcp_menu_state.Action,
        ) !void {
            const project_action: project_config.ProjectMcpAction = switch (action) {
                .trust_approve => .{
                    .approve = app.mcp.selectedMenuServerName() orelse return error.McpServerNotFound,
                },
                .trust_reject => .{
                    .reject = app.mcp.selectedMenuServerName() orelse return error.McpServerNotFound,
                },
                .trust_approve_all => .approve_all,
                .trust_reset => .reset,
                else => return error.McpMenuInvalidOperation,
            };
            var attempt = config_runtime.attemptProjectMcpMutation(
                app.alloc,
                app.workspace_root,
                project_action,
            );
            defer attempt.deinit(app.alloc);
            const outcome = switch (attempt) {
                .outcome => |value| value,
                .failure => |failure| return failure.err,
            };
            try app.mcp.setMenuFeedback(app.alloc, "Updated project MCP trust; reconnecting…");
            app.mcp.returnMenuToServers();
            switch (outcome) {
                .unchanged => {
                    app.mcp.menu = mcp_menu_state.reduce(
                        app.mcp.menu,
                        .{ .action_succeeded = generation },
                    ).state;
                },
                .committed => |committed| if (committed.authority_reduced)
                    app.beginMcpMenuAuthorityReduction(true, generation) catch |err| {
                        try app.mcp.recordMenuEffectFailure(app.alloc, generation, err);
                    }
                else
                    app.beginMcpMenuReload(generation) catch |err| {
                        try app.mcp.recordMenuEffectFailure(app.alloc, generation, err);
                    },
            }
        }
    };
}
