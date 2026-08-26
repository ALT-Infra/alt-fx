const std = @import("std");
const revision_store = @import("revision_store.zig");

const Allocator = std.mem.Allocator;

pub const Stage = enum {
    library,
    actions,
    editor,
    delete_confirmation,
};

pub const EditorMode = union(enum) {
    create,
    revise: struct {
        id: []u8,
        previous_revision: u32,
    },

    fn deinit(self: *EditorMode, alloc: Allocator) void {
        switch (self.*) {
            .create => {},
            .revise => |value| alloc.free(value.id),
        }
        self.* = .create;
    }
};

pub const LibraryChoice = union(enum) {
    create,
    definition: usize,
};

pub const Action = enum {
    start,
    edit,
    delete,
    back,
};

pub const State = struct {
    active: bool = false,
    stage: Stage = .library,
    library: revision_store.Library = .{},
    selected: usize = 0,
    window_start: usize = 0,
    active_definition_index: ?usize = null,
    editor_mode: EditorMode = .create,
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,
    error_buf: [256]u8 = undefined,
    error_len: usize = 0,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.library.deinit(alloc);
        self.editor_mode.deinit(alloc);
        self.* = .{};
    }

    pub fn open(self: *State, alloc: Allocator, library: revision_store.Library) void {
        self.deinit(alloc);
        self.active = true;
        self.library = library;
    }

    pub fn close(self: *State, alloc: Allocator) void {
        self.deinit(alloc);
    }

    pub fn query(self: *const State) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn errorMessage(self: *const State) []const u8 {
        return self.error_buf[0..self.error_len];
    }

    pub fn setError(self: *State, message: []const u8) void {
        const len = @min(message.len, self.error_buf.len);
        @memcpy(self.error_buf[0..len], message[0..len]);
        self.error_len = len;
    }

    pub fn clearError(self: *State) void {
        self.error_len = 0;
    }

    pub fn setQuery(self: *State, value: []const u8) void {
        if (!self.active or self.stage != .library) return;
        const len = @min(value.len, self.query_buf.len);
        if (len > 0) @memcpy(self.query_buf[0..len], value[0..len]);
        self.query_len = len;
        self.selected = 0;
        self.window_start = 0;
    }

    pub fn filteredDefinitionCount(self: *const State) usize {
        var count: usize = 0;
        for (self.library.items.items) |item| {
            if (matches(item, self.query())) count += 1;
        }
        return count;
    }

    pub fn definitionAt(self: *const State, display_index: usize) ?*const revision_store.Summary {
        var found: usize = 0;
        for (self.library.items.items) |*item| {
            if (!matches(item.*, self.query())) continue;
            if (found == display_index) return item;
            found += 1;
        }
        return null;
    }

    pub fn definitionIndexAt(self: *const State, display_index: usize) ?usize {
        var found: usize = 0;
        for (self.library.items.items, 0..) |item, index| {
            if (!matches(item, self.query())) continue;
            if (found == display_index) return index;
            found += 1;
        }
        return null;
    }

    pub fn activeDefinition(self: *const State) ?*const revision_store.Summary {
        const index = self.active_definition_index orelse return null;
        if (index >= self.library.items.items.len) return null;
        return &self.library.items.items[index];
    }

    pub fn navigationItemCount(self: *const State) usize {
        if (!self.active) return 0;
        return switch (self.stage) {
            .library => self.filteredDefinitionCount() + 1,
            .actions => 4,
            .delete_confirmation => 2,
            .editor => 0,
        };
    }

    pub fn move(self: *State, delta: i32, visible_items: u16) bool {
        const count = self.navigationItemCount();
        if (count == 0) return false;
        const current: i32 = @intCast(self.selected % count);
        var next = current + delta;
        if (next < 0) next = @as(i32, @intCast(count)) - 1;
        if (next >= @as(i32, @intCast(count))) next = 0;
        self.selected = @intCast(next);
        self.window_start = updateWindowStart(
            self.window_start,
            count,
            self.selected,
            @max(visible_items, 1),
        );
        return true;
    }

    pub fn selectLibrary(self: *State) ?LibraryChoice {
        if (!self.active or self.stage != .library) return null;
        if (self.selected == 0) return .create;
        const index = self.definitionIndexAt(self.selected - 1) orelse return null;
        self.active_definition_index = index;
        self.stage = .actions;
        self.selected = 0;
        self.window_start = 0;
        self.query_len = 0;
        self.clearError();
        return .{ .definition = index };
    }

    pub fn selectedAction(self: *const State) ?Action {
        if (!self.active or self.stage != .actions) return null;
        return @enumFromInt(self.selected % 4);
    }

    pub fn enterCreateEditor(self: *State, alloc: Allocator) void {
        self.editor_mode.deinit(alloc);
        self.editor_mode = .create;
        self.stage = .editor;
        self.selected = 0;
        self.clearError();
    }

    pub fn enterReviseEditor(self: *State, alloc: Allocator) !void {
        const definition = self.activeDefinition() orelse return error.DefinitionNotSelected;
        self.editor_mode.deinit(alloc);
        self.editor_mode = .{ .revise = .{
            .id = try alloc.dupe(u8, definition.id),
            .previous_revision = definition.latest_revision,
        } };
        self.stage = .editor;
        self.selected = 0;
        self.clearError();
    }

    pub fn enterDeleteConfirmation(self: *State) void {
        self.stage = .delete_confirmation;
        self.selected = 1;
        self.window_start = 0;
        self.clearError();
    }

    pub fn confirmDeleteSelected(self: *const State) bool {
        return self.active and self.stage == .delete_confirmation and self.selected == 0;
    }

    pub fn back(self: *State) bool {
        if (!self.active) return false;
        switch (self.stage) {
            .library => return false,
            .actions, .editor => self.stage = .library,
            .delete_confirmation => self.stage = .actions,
        }
        self.selected = 0;
        self.window_start = 0;
        self.query_len = 0;
        self.clearError();
        return true;
    }
};

fn matches(summary: revision_store.Summary, query_raw: []const u8) bool {
    const query = std.mem.trim(u8, query_raw, " \t\r\n");
    if (query.len == 0) return true;
    return containsIgnoreCase(summary.name, query) or containsIgnoreCase(summary.id, query);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn updateWindowStart(
    current: usize,
    count: usize,
    selected: usize,
    visible: usize,
) usize {
    if (count <= visible) return 0;
    var start = @min(current, count - visible);
    if (selected < start) start = selected;
    if (selected >= start + visible) start = selected - visible + 1;
    return start;
}

test "definition manager requires a real Team and preserves edit intent" {
    const alloc = std.testing.allocator;
    var state = State{};
    defer state.deinit(alloc);
    var library = revision_store.Library{};
    try library.items.append(alloc, .{
        .id = try alloc.dupe(u8, "engineering"),
        .name = try alloc.dupe(u8, "Engineering"),
        .latest_revision = 3,
        .latest_digest = [_]u8{'0'} ** 64,
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .deleted = false,
    });
    state.open(alloc, library);
    try std.testing.expectEqual(@as(usize, 2), state.navigationItemCount());
    _ = state.move(1, 4);
    const choice = state.selectLibrary().?;
    switch (choice) {
        .definition => {},
        .create => return error.ExpectedDefinitionChoice,
    }
    try std.testing.expectEqual(Action.start, state.selectedAction().?);
    try state.enterReviseEditor(alloc);
    switch (state.editor_mode) {
        .revise => |edit| {
            try std.testing.expectEqualStrings("engineering", edit.id);
            try std.testing.expectEqual(@as(u32, 3), edit.previous_revision);
        },
        .create => return error.ExpectedRevisionEditor,
    }
}
