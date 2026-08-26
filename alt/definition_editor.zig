const std = @import("std");
const host = @import("fx_orchestration_host");
const team_document = @import("domain/team_document.zig");

const Allocator = std.mem.Allocator;
const ObjectMap = std.json.ObjectMap;

const RoleKind = enum { peer, specialist };
const RoleRef = union(enum) {
    primary,
    peer: usize,
    specialist: usize,
};
const TextField = enum { team_name, team_id, role_id, model, definition };
const Screen = union(enum) {
    overview,
    provider,
    members: RoleKind,
    role: RoleRef,
    relationships,
    relationship_targets: RoleRef,
    text: struct { field: TextField, role: ?RoleRef, previous: PreviousScreen },
    delete_role: RoleRef,
};
const PreviousScreen = union(enum) { overview, role: RoleRef };

pub const Editor = struct {
    arena: std.heap.ArenaAllocator,
    root: std.json.Value,
    screen: Screen = .overview,
    selected: usize = 0,
    rows: [128]host.DefinitionEditorRow = undefined,
    row_count: usize = 0,
    detail_buffers: [128][256]u8 = undefined,
    title_buffer: [256]u8 = undefined,
    error_buffer: [256]u8 = undefined,
    error_len: usize = 0,
    identity_locked: bool = false,

    pub fn init(alloc: Allocator, source: []const u8) !Editor {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const value = try std.json.parseFromSliceLeaky(
            std.json.Value,
            arena.allocator(),
            source,
            .{},
        );
        if (value != .object) return error.InvalidTeamDocument;
        return .{ .arena = arena, .root = value };
    }

    pub fn lockIdentity(self: *Editor) void {
        self.identity_locked = true;
    }

    pub fn deinit(self: *Editor) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn projection(self: *Editor) host.DefinitionEditorProjection {
        self.row_count = 0;
        const title = switch (self.screen) {
            .overview => "Team",
            .provider => "Model provider",
            .members => |kind| if (kind == .peer) "Peers" else "Specialists",
            .role => |role| self.roleTitle(role),
            .relationships => "Relationships",
            .relationship_targets => |role| self.relationshipTitle(role),
            .text => |field| textFieldTitle(field.field),
            .delete_role => "Remove role?",
        };
        const accepts_text = self.screen == .text;
        switch (self.screen) {
            .overview => self.projectOverview(),
            .provider => self.projectProvider(),
            .members => |kind| self.projectMembers(kind),
            .role => |role| self.projectRole(role),
            .relationships => self.projectRelationships(),
            .relationship_targets => |role| self.projectRelationshipTargets(role),
            .text => |field| self.projectText(field.field),
            .delete_role => |role| self.projectDelete(role),
        }
        self.clampSelection();
        for (self.rows[0..self.row_count], 0..) |*row, index| row.selected = index == self.selected;
        return .{
            .active = true,
            .title = title,
            .subtitle = self.subtitle(),
            .rows = self.rows[0..self.row_count],
            .error_message = self.error_buffer[0..self.error_len],
            .accepts_text = accepts_text,
            .hint = if (accepts_text)
                "Enter Apply  ·  Esc Cancel"
            else if (self.screen == .relationship_targets)
                "↑↓ Navigate  ·  Enter Toggle  ·  Esc Done"
            else
                "↑↓ Navigate  ·  Enter Select  ·  Esc Back",
        };
    }

    pub fn move(self: *Editor, delta: i32) bool {
        if (self.screen == .text) return false;
        _ = self.projection();
        if (self.row_count == 0) return false;
        var next: i32 = @as(i32, @intCast(self.selected)) + delta;
        if (next < 0) next = @as(i32, @intCast(self.row_count)) - 1;
        if (next >= @as(i32, @intCast(self.row_count))) next = 0;
        self.selected = @intCast(next);
        return true;
    }

    pub fn submit(self: *Editor, alloc: Allocator, input: []const u8) !host.DefinitionEditorOutcome {
        self.clearError();
        return switch (self.screen) {
            .overview => self.submitOverview(alloc),
            .provider => self.submitProvider(),
            .members => |kind| self.submitMembers(kind),
            .role => |role| self.submitRole(role),
            .relationships => self.submitRelationships(),
            .relationship_targets => |role| self.submitRelationshipTarget(role),
            .text => |field| self.submitText(field, input),
            .delete_role => |role| self.submitDeleteRole(role),
        };
    }

    pub fn back(self: *Editor) host.DefinitionEditorOutcome {
        self.clearError();
        switch (self.screen) {
            .overview => return .exit,
            .provider, .members, .relationships => self.screen = .overview,
            .role => |role| self.screen = switch (role) {
                .primary => .overview,
                .peer => .{ .members = .peer },
                .specialist => .{ .members = .specialist },
            },
            .relationship_targets => self.screen = .relationships,
            .text => |field| self.screen = previousScreen(field.previous),
            .delete_role => |role| self.screen = .{ .role = role },
        }
        self.selected = 0;
        return .{ .replace_input = "" };
    }

    fn submitOverview(self: *Editor, alloc: Allocator) !host.DefinitionEditorOutcome {
        switch (self.selected) {
            0 => return self.beginText(.team_name, null, .overview, self.teamString("name")),
            1 => if (self.identity_locked) {
                self.setError("A revision keeps its Team ID. Create a new Team to use another ID.");
                return .redraw;
            } else return self.beginText(.team_id, null, .overview, self.teamString("id")),
            2 => self.screen = .provider,
            3 => self.screen = .{ .role = .primary },
            4 => self.screen = .{ .members = .peer },
            5 => self.screen = .{ .members = .specialist },
            6 => self.screen = .relationships,
            7 => {
                const source = self.serialize(alloc) catch |err| {
                    self.setErrorName("Team could not be saved", err);
                    return .redraw;
                };
                errdefer alloc.free(source);
                var parsed = team_document.Document.parse(alloc, source) catch |err| {
                    alloc.free(source);
                    self.setError(teamValidationMessage(err));
                    return .redraw;
                };
                parsed.deinit();
                return .{ .save = source };
            },
            else => return .redraw,
        }
        self.selected = 0;
        return .{ .replace_input = "" };
    }

    fn submitProvider(self: *Editor) !host.DefinitionEditorOutcome {
        const provider = if (self.selected == 0) "opencode" else "vercel";
        try self.setTeamString("provider_id", provider);
        self.screen = .overview;
        self.selected = 2;
        return .{ .replace_input = "" };
    }

    fn submitMembers(self: *Editor, kind: RoleKind) !host.DefinitionEditorOutcome {
        const count = self.roleArray(kind).items.len;
        if (self.selected < count) {
            self.screen = .{ .role = if (kind == .peer)
                .{ .peer = self.selected }
            else
                .{ .specialist = self.selected } };
            self.selected = 0;
            return .{ .replace_input = "" };
        }
        if (self.selected == count) {
            const role = try self.addRole(kind);
            self.screen = .{ .role = role };
            self.selected = 0;
            return .{ .replace_input = "" };
        }
        self.screen = .overview;
        self.selected = if (kind == .peer) 4 else 5;
        return .{ .replace_input = "" };
    }

    fn submitRole(self: *Editor, role: RoleRef) !host.DefinitionEditorOutcome {
        switch (self.selected) {
            0 => return self.beginText(.role_id, role, .{ .role = role }, self.roleString(role, "id")),
            1 => return self.beginText(.model, role, .{ .role = role }, self.modelDisplay(role)),
            2 => return self.beginText(.definition, role, .{ .role = role }, self.roleString(role, "definition")),
            3 => {
                self.screen = .{ .relationship_targets = role };
                self.selected = 0;
            },
            4 => {
                if (role == .primary) {
                    self.screen = .overview;
                    self.selected = 3;
                } else {
                    self.screen = .{ .delete_role = role };
                    self.selected = 1;
                }
            },
            else => {},
        }
        return .{ .replace_input = "" };
    }

    fn submitRelationships(self: *Editor) host.DefinitionEditorOutcome {
        const agent_count = 1 + self.roleArray(.peer).items.len;
        if (self.selected < agent_count) {
            self.screen = .{ .relationship_targets = if (self.selected == 0)
                .primary
            else
                .{ .peer = self.selected - 1 } };
            self.selected = 0;
        } else {
            self.screen = .overview;
            self.selected = 6;
        }
        return .{ .replace_input = "" };
    }

    fn submitRelationshipTarget(self: *Editor, role: RoleRef) !host.DefinitionEditorOutcome {
        const peer_count = self.roleArray(.peer).items.len;
        var row: usize = 0;
        if (role != .primary) {
            if (row == self.selected) {
                try self.togglePeerEdge(role, .primary);
                return .redraw;
            }
            row += 1;
        }
        var peer_index: usize = 0;
        while (peer_index < peer_count) : (peer_index += 1) {
            const target: RoleRef = .{ .peer = peer_index };
            if (sameRole(role, target)) continue;
            if (row == self.selected) {
                try self.togglePeerEdge(role, target);
                return .redraw;
            }
            row += 1;
        }
        const specialists = self.roleArray(.specialist).items;
        for (specialists, 0..) |_, specialist_index| {
            if (row == self.selected) {
                try self.toggleSpecialist(role, specialist_index);
                return .redraw;
            }
            row += 1;
        }
        self.screen = .relationships;
        self.selected = 0;
        return .{ .replace_input = "" };
    }

    fn submitText(
        self: *Editor,
        field: @FieldType(Screen, "text"),
        input_raw: []const u8,
    ) !host.DefinitionEditorOutcome {
        const input = std.mem.trim(u8, input_raw, " \t\r\n");
        if (input.len == 0) {
            self.setError("This field cannot be empty.");
            return .redraw;
        }
        switch (field.field) {
            .team_name => try self.setTeamString("name", input),
            .team_id => {
                if (!validIdentifier(input)) {
                    self.setError("Team IDs use lowercase letters, digits, and single hyphens.");
                    return .redraw;
                }
                try self.setTeamString("id", input);
            },
            .role_id => {
                if (!validIdentifier(input)) {
                    self.setError("Role IDs use lowercase letters, digits, and single hyphens.");
                    return .redraw;
                }
                if (self.roleIdInUse(field.role.?, input)) {
                    self.setError("Every primary, peer, and specialist needs a distinct ID.");
                    return .redraw;
                }
                try self.renameRole(field.role.?, input);
            },
            .model => self.setRoleModel(field.role.?, input) catch |err| {
                self.setError(switch (err) {
                    error.InvalidModelId => if (std.mem.eql(u8, self.teamString("provider_id"), "opencode"))
                        "Use model or go/model for OpenCode."
                    else
                        "Gateway models use provider/model IDs.",
                    error.DuplicateCatalogModel => "Every Team role must use a distinct model.",
                    else => "That model could not be applied.",
                });
                return .redraw;
            },
            .definition => try self.setRoleString(field.role.?, "definition", input),
        }
        self.screen = previousScreen(field.previous);
        self.selected = switch (field.field) {
            .team_name => 0,
            .team_id => 1,
            .role_id => 0,
            .model => 1,
            .definition => 2,
        };
        return .{ .replace_input = "" };
    }

    fn submitDeleteRole(self: *Editor, role: RoleRef) !host.DefinitionEditorOutcome {
        if (self.selected == 0) {
            const kind: RoleKind = switch (role) {
                .peer => .peer,
                .specialist => .specialist,
                .primary => return .redraw,
            };
            try self.removeRole(role);
            self.screen = .{ .members = kind };
            self.selected = 0;
        } else {
            self.screen = .{ .role = role };
            self.selected = 4;
        }
        return .{ .replace_input = "" };
    }

    fn projectOverview(self: *Editor) void {
        self.addRow("Name", self.teamString("name"), false, false);
        self.addRow(if (self.identity_locked) "ID · fixed" else "ID", self.teamString("id"), false, false);
        self.addRow("Provider", providerLabel(self.teamString("provider_id")), false, false);
        self.addRow("Primary", self.roleString(.primary, "id"), false, false);
        self.addCountRow("Peers", self.roleArray(.peer).items.len);
        self.addCountRow("Specialists", self.roleArray(.specialist).items.len);
        self.addRow("Relationships", "peer access and specialist authority", false, false);
        self.addRow("Save & start", "new ALT conversation", false, false);
    }

    fn projectProvider(self: *Editor) void {
        const current = self.teamString("provider_id");
        self.addRow("OpenCode", "Zen and Go", std.mem.eql(u8, current, "opencode"), false);
        self.addRow("Vercel AI Gateway", "unified model catalog", std.mem.eql(u8, current, "vercel"), false);
    }

    fn projectMembers(self: *Editor, kind: RoleKind) void {
        for (self.roleArray(kind).items, 0..) |_, index| {
            const role: RoleRef = if (kind == .peer) .{ .peer = index } else .{ .specialist = index };
            self.addRow(self.roleString(role, "id"), self.modelDisplay(role), false, false);
        }
        self.addRow(if (kind == .peer) "+ Add peer" else "+ Add specialist", "", false, false);
        self.addRow("Back", "", false, false);
    }

    fn projectRole(self: *Editor, role: RoleRef) void {
        self.addRow("ID", self.roleString(role, "id"), false, false);
        self.addRow("Model", self.modelDisplay(role), false, false);
        self.addRow("Instructions", self.roleString(role, "definition"), false, false);
        self.addRow("Relationships", "consultation and specialist access", false, false);
        self.addRow(if (role == .primary) "Back" else "Remove role", "", false, role != .primary);
    }

    fn projectRelationships(self: *Editor) void {
        self.addRow(self.roleString(.primary, "id"), "primary", false, false);
        for (self.roleArray(.peer).items, 0..) |_, index| {
            const role: RoleRef = .{ .peer = index };
            self.addRow(self.roleString(role, "id"), "peer", false, false);
        }
        self.addRow("Done", "", false, false);
    }

    fn projectRelationshipTargets(self: *Editor, role: RoleRef) void {
        if (role != .primary) {
            self.addRow(
                self.roleString(.primary, "id"),
                "primary",
                self.hasPeerEdge(role, .primary),
                false,
            );
        }
        for (self.roleArray(.peer).items, 0..) |_, index| {
            const target: RoleRef = .{ .peer = index };
            if (sameRole(role, target)) continue;
            self.addRow(
                self.roleString(target, "id"),
                "peer",
                self.hasPeerEdge(role, target),
                false,
            );
        }
        for (self.roleArray(.specialist).items, 0..) |_, index| {
            const target: RoleRef = .{ .specialist = index };
            self.addRow(
                self.roleString(target, "id"),
                "specialist",
                self.hasSpecialist(role, index),
                false,
            );
        }
        self.addRow("Done", "", false, false);
    }

    fn projectText(self: *Editor, field: TextField) void {
        const detail = switch (field) {
            .model => if (std.mem.eql(u8, self.teamString("provider_id"), "opencode"))
                "Use an fx model ID such as kimi-k3 or go/kimi-k3."
            else
                "Use a Gateway model ID such as anthropic/claude-sonnet-4.",
            .definition => "Describe this role's expertise, judgment, and responsibilities.",
            .team_id, .role_id => "Lowercase letters, digits, and single hyphens.",
            .team_name => "A concise display name for this Team.",
        };
        self.addRow(detail, "", false, false);
    }

    fn projectDelete(self: *Editor, role: RoleRef) void {
        self.addRow("Remove", self.roleString(role, "id"), false, true);
        self.addRow("Cancel", "", false, false);
    }

    fn subtitle(self: *Editor) []const u8 {
        return switch (self.screen) {
            .overview => "Configure a primary plus at least one peer or specialist.",
            .provider => "ALT accepts only unified multi-model providers.",
            .members => "Every role must use a distinct catalog model.",
            .role => "Model and instructions are pinned in this Team revision.",
            .relationships => "Choose each context-bearing agent to configure its access.",
            .relationship_targets => "Checked peers are consultable; checked specialists are callable.",
            .text => "",
            .delete_role => "References and the role's model are removed together.",
        };
    }

    fn beginText(
        self: *Editor,
        field: TextField,
        role: ?RoleRef,
        previous: PreviousScreen,
        current: []const u8,
    ) host.DefinitionEditorOutcome {
        self.screen = .{ .text = .{ .field = field, .role = role, .previous = previous } };
        self.selected = 0;
        return .{ .replace_input = current };
    }

    fn rootObject(self: *Editor) *ObjectMap {
        return &self.root.object;
    }

    fn teamString(self: *Editor, key: []const u8) []const u8 {
        const value = self.rootObject().get(key) orelse return "";
        return if (value == .string) value.string else "";
    }

    fn setTeamString(self: *Editor, key: []const u8, value: []const u8) !void {
        try self.rootObject().put(
            self.arena.allocator(),
            try self.arena.allocator().dupe(u8, key),
            .{ .string = try self.arena.allocator().dupe(u8, value) },
        );
    }

    fn roleArray(self: *Editor, kind: RoleKind) *std.json.Array {
        const key = if (kind == .peer) "peers" else "specialists";
        return &self.rootObject().getPtr(key).?.array;
    }

    fn roleObject(self: *Editor, role: RoleRef) *ObjectMap {
        return switch (role) {
            .primary => &self.rootObject().getPtr("primary").?.object,
            .peer => |index| &self.roleArray(.peer).items[index].object,
            .specialist => |index| &self.roleArray(.specialist).items[index].object,
        };
    }

    fn roleString(self: *Editor, role: RoleRef, key: []const u8) []const u8 {
        const value = self.roleObject(role).get(key) orelse return "";
        return if (value == .string) value.string else "";
    }

    fn setRoleString(self: *Editor, role: RoleRef, key: []const u8, value: []const u8) !void {
        try self.roleObject(role).put(
            self.arena.allocator(),
            try self.arena.allocator().dupe(u8, key),
            .{ .string = try self.arena.allocator().dupe(u8, value) },
        );
    }

    fn models(self: *Editor) *std.json.Array {
        return &self.rootObject().getPtr("models").?.array;
    }

    fn modelObject(self: *Editor, role: RoleRef) ?*ObjectMap {
        const model_id = self.roleString(role, "model_id");
        for (self.models().items) |*value| {
            const id = value.object.get("id") orelse continue;
            if (id == .string and std.mem.eql(u8, id.string, model_id)) return &value.object;
        }
        return null;
    }

    fn modelDisplay(self: *Editor, role: RoleRef) []const u8 {
        const model = self.modelObject(role) orelse return "Choose model";
        const route_value = model.get("route") orelse return "Choose model";
        const name_value = model.get("name") orelse return "Choose model";
        if (route_value != .string or name_value != .string) return "Choose model";
        const slot = self.row_count % self.detail_buffers.len;
        if (std.mem.eql(u8, self.teamString("provider_id"), "opencode") and
            std.mem.eql(u8, route_value.string, "zen"))
        {
            return std.fmt.bufPrint(
                &self.detail_buffers[slot],
                "{s}",
                .{name_value.string},
            ) catch "Choose model";
        }
        return std.fmt.bufPrint(
            &self.detail_buffers[slot],
            "{s}/{s}",
            .{ route_value.string, name_value.string },
        ) catch "Choose model";
    }

    fn setRoleModel(self: *Editor, role: RoleRef, input: []const u8) !void {
        const provider = self.teamString("provider_id");
        var route: []const u8 = undefined;
        var name: []const u8 = undefined;
        if (std.mem.eql(u8, provider, "opencode")) {
            if (std.mem.startsWith(u8, input, "go/")) {
                route = "go";
                name = input[3..];
            } else {
                route = "zen";
                name = input;
            }
        } else {
            const split = std.mem.indexOfScalar(u8, input, '/') orelse
                return error.InvalidModelId;
            route = input[0..split];
            name = input[split + 1 ..];
        }
        if (route.len == 0 or name.len == 0) return error.InvalidModelId;
        const current = self.modelObject(role) orelse return error.UnknownModel;
        for (self.models().items) |*value| {
            if (&value.object == current) continue;
            const other_route = value.object.get("route") orelse continue;
            const other_name = value.object.get("name") orelse continue;
            if (other_route == .string and other_name == .string and
                std.ascii.eqlIgnoreCase(other_route.string, route) and
                std.mem.eql(u8, other_name.string, name))
            {
                return error.DuplicateCatalogModel;
            }
        }
        try current.put(self.arena.allocator(), "route", .{ .string = try self.arena.allocator().dupe(u8, route) });
        try current.put(self.arena.allocator(), "name", .{ .string = try self.arena.allocator().dupe(u8, name) });
    }

    fn roleIdInUse(self: *Editor, role: RoleRef, id: []const u8) bool {
        if (!sameRole(role, .primary) and std.mem.eql(u8, self.roleString(.primary, "id"), id)) return true;
        for (self.roleArray(.peer).items, 0..) |_, index| {
            const candidate: RoleRef = .{ .peer = index };
            if (!sameRole(role, candidate) and std.mem.eql(u8, self.roleString(candidate, "id"), id)) return true;
        }
        for (self.roleArray(.specialist).items, 0..) |_, index| {
            const candidate: RoleRef = .{ .specialist = index };
            if (!sameRole(role, candidate) and std.mem.eql(u8, self.roleString(candidate, "id"), id)) return true;
        }
        return false;
    }

    fn renameRole(self: *Editor, role: RoleRef, new_id: []const u8) !void {
        const old_id = self.roleString(role, "id");
        const owned = try self.arena.allocator().dupe(u8, new_id);
        for ([_][]const u8{ "peers", "specialists" }) |key| {
            if (self.rootObject().getPtr("primary").?.object.getPtr(key)) |value| {
                replaceArrayString(&value.array, old_id, owned);
            }
            for (self.roleArray(.peer).items) |*peer| {
                if (peer.object.getPtr(key)) |value| replaceArrayString(&value.array, old_id, owned);
            }
        }
        try self.roleObject(role).put(self.arena.allocator(), "id", .{ .string = owned });
    }

    fn addRole(self: *Editor, kind: RoleKind) !RoleRef {
        const index = self.roleArray(kind).items.len;
        const prefix = if (kind == .peer) "peer" else "specialist";
        const id = try std.fmt.allocPrint(self.arena.allocator(), "{s}-{d}", .{ prefix, index + 1 });
        const model_id = try std.fmt.allocPrint(self.arena.allocator(), "{s}-model-{d}", .{ prefix, index + 1 });
        var model: ObjectMap = .empty;
        try model.put(self.arena.allocator(), "id", .{ .string = model_id });
        try model.put(self.arena.allocator(), "route", .{ .string = try self.arena.allocator().dupe(u8, "") });
        try model.put(self.arena.allocator(), "name", .{ .string = try self.arena.allocator().dupe(u8, "") });
        try self.models().append(.{ .object = model });

        var object: ObjectMap = .empty;
        try object.put(self.arena.allocator(), "id", .{ .string = id });
        try object.put(self.arena.allocator(), "model_id", .{ .string = model_id });
        try object.put(self.arena.allocator(), "definition", .{ .string = try self.arena.allocator().dupe(u8, "Describe this role.") });
        if (kind == .peer) {
            try object.put(self.arena.allocator(), "peers", .{ .array = std.json.Array.init(self.arena.allocator()) });
            try object.put(self.arena.allocator(), "specialists", .{ .array = std.json.Array.init(self.arena.allocator()) });
        }
        try self.roleArray(kind).append(.{ .object = object });
        const role: RoleRef = if (kind == .peer) .{ .peer = index } else .{ .specialist = index };
        if (kind == .peer) try self.setPeerEdge(.primary, role, true) else try self.setSpecialist(.primary, index, true);
        return role;
    }

    fn removeRole(self: *Editor, role: RoleRef) !void {
        const id = self.roleString(role, "id");
        const model_id = self.roleString(role, "model_id");
        self.removeReferences(id);
        var model_index: usize = 0;
        while (model_index < self.models().items.len) : (model_index += 1) {
            const value = self.models().items[model_index].object.get("id") orelse continue;
            if (value == .string and std.mem.eql(u8, value.string, model_id)) {
                _ = self.models().orderedRemove(model_index);
                break;
            }
        }
        switch (role) {
            .peer => |index| _ = self.roleArray(.peer).orderedRemove(index),
            .specialist => |index| _ = self.roleArray(.specialist).orderedRemove(index),
            .primary => return error.CannotRemovePrimary,
        }
    }

    fn removeReferences(self: *Editor, id: []const u8) void {
        for ([_][]const u8{ "peers", "specialists" }) |key| {
            if (self.rootObject().getPtr("primary").?.object.getPtr(key)) |value| removeArrayString(&value.array, id);
            for (self.roleArray(.peer).items) |*peer| {
                if (peer.object.getPtr(key)) |value| removeArrayString(&value.array, id);
            }
        }
    }

    fn hasPeerEdge(self: *Editor, left: RoleRef, right: RoleRef) bool {
        return arrayContains(self.agentArray(left, "peers"), self.roleString(right, "id")) or
            arrayContains(self.agentArray(right, "peers"), self.roleString(left, "id"));
    }

    fn togglePeerEdge(self: *Editor, left: RoleRef, right: RoleRef) !void {
        try self.setPeerEdge(left, right, !self.hasPeerEdge(left, right));
    }

    fn setPeerEdge(self: *Editor, left: RoleRef, right: RoleRef, enabled: bool) !void {
        const left_id = self.roleString(left, "id");
        const right_id = self.roleString(right, "id");
        removeArrayString(self.agentArray(left, "peers"), right_id);
        removeArrayString(self.agentArray(right, "peers"), left_id);
        if (enabled) try self.agentArray(left, "peers").append(.{
            .string = try self.arena.allocator().dupe(u8, right_id),
        });
    }

    fn hasSpecialist(self: *Editor, role: RoleRef, index: usize) bool {
        return arrayContains(self.agentArray(role, "specialists"), self.roleString(.{ .specialist = index }, "id"));
    }

    fn toggleSpecialist(self: *Editor, role: RoleRef, index: usize) !void {
        try self.setSpecialist(role, index, !self.hasSpecialist(role, index));
    }

    fn setSpecialist(self: *Editor, role: RoleRef, index: usize, enabled: bool) !void {
        const id = self.roleString(.{ .specialist = index }, "id");
        const values = self.agentArray(role, "specialists");
        removeArrayString(values, id);
        if (enabled) try values.append(.{
            .string = try self.arena.allocator().dupe(u8, id),
        });
    }

    fn agentArray(self: *Editor, role: RoleRef, key: []const u8) *std.json.Array {
        const object = self.roleObject(role);
        if (object.getPtr(key)) |value| return &value.array;
        object.put(self.arena.allocator(), key, .{
            .array = std.json.Array.init(self.arena.allocator()),
        }) catch unreachable;
        return &object.getPtr(key).?.array;
    }

    fn serialize(self: *Editor, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try std.json.Stringify.value(self.root, .{ .whitespace = .indent_2 }, &out.writer);
        return out.toOwnedSlice();
    }

    fn addRow(self: *Editor, label: []const u8, detail: []const u8, marked: bool, destructive: bool) void {
        if (self.row_count >= self.rows.len) return;
        self.rows[self.row_count] = .{
            .label = label,
            .detail = detail,
            .marked = marked,
            .destructive = destructive,
        };
        self.row_count += 1;
    }

    fn addCountRow(self: *Editor, label: []const u8, count: usize) void {
        const slot = self.row_count % self.detail_buffers.len;
        const detail = std.fmt.bufPrint(&self.detail_buffers[slot], "{d}", .{count}) catch "";
        self.addRow(label, detail, false, false);
    }

    fn clampSelection(self: *Editor) void {
        if (self.row_count == 0) self.selected = 0 else self.selected %= self.row_count;
    }

    fn roleTitle(self: *Editor, role: RoleRef) []const u8 {
        return std.fmt.bufPrint(
            &self.title_buffer,
            "{s} · {s}",
            .{ switch (role) {
                .primary => "Primary",
                .peer => "Peer",
                .specialist => "Specialist",
            }, self.roleString(role, "id") },
        ) catch "Role";
    }

    fn relationshipTitle(self: *Editor, role: RoleRef) []const u8 {
        return std.fmt.bufPrint(
            &self.title_buffer,
            "Relationships · {s}",
            .{self.roleString(role, "id")},
        ) catch "Relationships";
    }

    fn setError(self: *Editor, message: []const u8) void {
        const len = @min(message.len, self.error_buffer.len);
        @memcpy(self.error_buffer[0..len], message[0..len]);
        self.error_len = len;
    }

    fn setErrorName(self: *Editor, prefix: []const u8, err: anyerror) void {
        const message = std.fmt.bufPrint(
            &self.error_buffer,
            "{s}: {s}",
            .{ prefix, @errorName(err) },
        ) catch prefix;
        self.error_len = message.len;
    }

    fn clearError(self: *Editor) void {
        self.error_len = 0;
    }
};

fn textFieldTitle(field: TextField) []const u8 {
    return switch (field) {
        .team_name => "Team name",
        .team_id => "Team ID",
        .role_id => "Role ID",
        .model => "Model",
        .definition => "Role instructions",
    };
}

fn previousScreen(previous: PreviousScreen) Screen {
    return switch (previous) {
        .overview => .overview,
        .role => |role| .{ .role = role },
    };
}

fn providerLabel(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "opencode")) return "OpenCode";
    if (std.mem.eql(u8, provider, "vercel")) return "Vercel AI Gateway";
    return provider;
}

fn validIdentifier(value: []const u8) bool {
    if (value.len == 0 or value[0] < 'a' or value[0] > 'z') return false;
    var previous_hyphen = false;
    for (value) |byte| {
        const alphanumeric = (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9');
        if (alphanumeric) {
            previous_hyphen = false;
        } else if (byte == '-' and !previous_hyphen) {
            previous_hyphen = true;
        } else {
            return false;
        }
    }
    return !previous_hyphen;
}

fn teamValidationMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCollaborator => "Add at least one peer or specialist before starting ALT.",
        error.UnreachablePeer => "Connect every peer to the primary through Relationships.",
        error.UnreachableSpecialist => "Give at least one primary or peer access to every specialist.",
        error.DuplicateCatalogModel, error.DuplicateModelOwner => "Every Team role must use a distinct model.",
        error.EmptyModel => "Choose a model for every Team role.",
        error.InvalidIdentifier => "Team and role IDs use lowercase letters, digits, and single hyphens.",
        error.DuplicateAssignment => "Every primary, peer, and specialist needs a distinct ID.",
        error.UnsupportedProvider => "Choose OpenCode or Vercel AI Gateway.",
        else => "This Team is incomplete. Review every role, model, and relationship.",
    };
}

fn sameRole(left: RoleRef, right: RoleRef) bool {
    return switch (left) {
        .primary => right == .primary,
        .peer => |index| switch (right) {
            .peer => |other| index == other,
            else => false,
        },
        .specialist => |index| switch (right) {
            .specialist => |other| index == other,
            else => false,
        },
    };
}

fn arrayContains(values: *const std.json.Array, expected: []const u8) bool {
    for (values.items) |value| {
        if (value == .string and std.mem.eql(u8, value.string, expected)) return true;
    }
    return false;
}

fn removeArrayString(values: *std.json.Array, expected: []const u8) void {
    var index: usize = 0;
    while (index < values.items.len) {
        const value = values.items[index];
        if (value == .string and std.mem.eql(u8, value.string, expected)) {
            _ = values.orderedRemove(index);
        } else {
            index += 1;
        }
    }
}

fn replaceArrayString(values: *std.json.Array, expected: []const u8, replacement: []const u8) void {
    for (values.items) |*value| {
        if (value.* == .string and std.mem.eql(u8, value.string, expected)) {
            value.* = .{ .string = replacement };
        }
    }
}

test "guided Team editor revises without exposing JSON" {
    const alloc = std.testing.allocator;
    const source =
        "{\"schema\":2,\"id\":\"my-team\",\"revision\":1,\"name\":\"My Team\",\"provider_id\":\"opencode\",\"models\":[" ++
        "{\"id\":\"primary-model\",\"route\":\"zen\",\"name\":\"kimi-k3\"}," ++
        "{\"id\":\"peer-model\",\"route\":\"go\",\"name\":\"kimi-k3\"}]," ++
        "\"primary\":{\"id\":\"primary\",\"model_id\":\"primary-model\",\"definition\":\"Own the result.\",\"peers\":[\"peer\"]}," ++
        "\"peers\":[{\"id\":\"peer\",\"model_id\":\"peer-model\",\"definition\":\"Contribute.\"}],\"specialists\":[]}";
    var editor = try Editor.init(alloc, source);
    defer editor.deinit();
    const projection = editor.projection();
    try std.testing.expectEqualStrings("Team", projection.title);
    try std.testing.expectEqualStrings("Name", projection.rows[0].label);
    try std.testing.expect(std.mem.find(u8, projection.rows[0].label, "{") == null);
    editor.selected = 7;
    const outcome = try editor.submit(alloc, "");
    switch (outcome) {
        .save => |saved| {
            defer alloc.free(saved);
            var parsed = try team_document.Document.parse(alloc, saved);
            defer parsed.deinit();
            try std.testing.expect(parsed.value.peers.len + parsed.value.specialists.len > 0);
        },
        else => return error.ExpectedSavedTeam,
    }
}
