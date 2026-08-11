const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const settings_catalog = @import("../../core/config/settings_catalog.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const AppearanceMenuProjection = render_input.AppearanceMenuProjection;

pub const row_count: u16 = 11;
const option_label_column: usize = 16;

pub noinline fn composeAppearanceMenuRow(
    alloc: Allocator,
    projection: AppearanceMenuProjection,
    row_index: u16,
    visible_rows: u16,
    width: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    if (width == 0 or row_index >= visible_rows) return empty;
    return switch (menuRowAt(projection, row_index, visible_rows)) {
        .empty => empty,
        .header => composeStyledRow(alloc, "Appearance · Choose one", width, ui_render.selected_completion_style),
        .input_heading => composeStyledRow(alloc, settings_catalog.AppearanceSection.input_style.label(), width, ui_render.dim_style),
        .presentation_heading => composeStyledRow(alloc, settings_catalog.AppearanceSection.presentation.label(), width, ui_render.dim_style),
        .choice => |choice_index| composeChoiceRow(alloc, projection, choice_index, width),
    };
}

const MenuRow = union(enum) {
    empty,
    header,
    input_heading,
    presentation_heading,
    choice: usize,
};

fn menuRowAt(projection: AppearanceMenuProjection, row_index: u16, visible_rows: u16) MenuRow {
    if (visible_rows >= 7) return groupedMenuRowAt(row_index, @min(visible_rows, row_count) - 7);
    if (visible_rows == 6) {
        return switch (row_index) {
            0 => .input_heading,
            1 => .{ .choice = 0 },
            2 => .{ .choice = 1 },
            3 => .presentation_heading,
            4 => .{ .choice = 2 },
            5 => .{ .choice = 3 },
            else => .empty,
        };
    }
    if (visible_rows >= 4) {
        if (visible_rows == 5 and row_index == 0) return .header;
        const choice_index: usize = @intCast(row_index - @intFromBool(visible_rows == 5));
        return if (choice_index < settings_catalog.appearanceChoiceCount())
            .{ .choice = choice_index }
        else
            .empty;
    }

    const selected = projection.selected_index % settings_catalog.appearanceChoiceCount();
    const section_start: usize = if (selected < 2) 0 else 2;
    if (visible_rows == 3) {
        return switch (row_index) {
            0 => if (section_start == 0) .input_heading else .presentation_heading,
            1 => .{ .choice = section_start },
            2 => .{ .choice = section_start + 1 },
            else => .empty,
        };
    }
    if (visible_rows == 2) {
        return .{ .choice = section_start + @as(usize, row_index) };
    }
    if (visible_rows == 1 and row_index == 0) return .{ .choice = selected };
    return .empty;
}

fn groupedMenuRowAt(row_index: u16, gap_count: u16) MenuRow {
    var row: u16 = 0;
    if (takeMenuRow(row_index, &row, .header)) |menu_row| return menu_row;
    if (gap_count >= 2) {
        if (takeMenuRow(row_index, &row, .empty)) |menu_row| return menu_row;
    }
    if (takeMenuRow(row_index, &row, .input_heading)) |menu_row| return menu_row;
    if (gap_count >= 4) {
        if (takeMenuRow(row_index, &row, .empty)) |menu_row| return menu_row;
    }
    if (takeMenuRow(row_index, &row, .{ .choice = 0 })) |menu_row| return menu_row;
    if (takeMenuRow(row_index, &row, .{ .choice = 1 })) |menu_row| return menu_row;
    if (gap_count >= 1) {
        if (takeMenuRow(row_index, &row, .empty)) |menu_row| return menu_row;
    }
    if (takeMenuRow(row_index, &row, .presentation_heading)) |menu_row| return menu_row;
    if (gap_count >= 3) {
        if (takeMenuRow(row_index, &row, .empty)) |menu_row| return menu_row;
    }
    if (takeMenuRow(row_index, &row, .{ .choice = 2 })) |menu_row| return menu_row;
    return if (row_index == row) .{ .choice = 3 } else .empty;
}

fn takeMenuRow(target: u16, row_index: *u16, menu_row: MenuRow) ?MenuRow {
    defer row_index.* += 1;
    return if (target == row_index.*) menu_row else null;
}

fn composeStyledRow(
    alloc: Allocator,
    text: []const u8,
    width: u16,
    style: []const u8,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, style);
    try row_text.appendSingleLineEllipsized(alloc, &row, text, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeChoiceRow(
    alloc: Allocator,
    projection: AppearanceMenuProjection,
    choice_index: usize,
    width: u16,
) !std.ArrayList(u8) {
    const choice = settings_catalog.appearanceChoiceAt(choice_index) orelse return .empty;
    const selected = choice_index == projection.selected_index % settings_catalog.appearanceChoiceCount();
    const current = choice.isCurrent(projection.snapshot);
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);

    try row.appendSlice(alloc, if (selected) ui_render.system_notice_label_style else ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, if (selected) "❯ " else "  ", width);
    var label_buf: [64]u8 = undefined;
    const label = if (current)
        std.fmt.bufPrint(&label_buf, "{s} ✓", .{choice.label}) catch choice.label
    else
        choice.label;
    const prefix_used = display_width.visibleWidthIgnoringAnsi(row.items);
    try row_text.appendSingleLineEllipsized(alloc, &row, label, @as(usize, width) -| prefix_used);
    try row.appendSlice(alloc, ui_render.reset_style);

    const used = display_width.visibleWidthIgnoringAnsi(row.items);
    const total_width: usize = width;
    if (used >= total_width or total_width < option_label_column + 8) return row;
    const description_col = @max(option_label_column, used + 2);
    try row.appendNTimes(alloc, ' ', description_col - used);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, choice.description, total_width - description_col);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

test "appearance menu renders grouped current choices and selection" {
    const projection: AppearanceMenuProjection = .{
        .active = true,
        .selected_index = 0,
        .snapshot = .{ .input_appearance = "tint", .maxxing_mode = "minimal" },
    };

    var header = try composeAppearanceMenuRow(std.testing.allocator, projection, 0, row_count, 80);
    defer header.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, header.items, "Appearance · Choose one") != null);

    var input_gap = try composeAppearanceMenuRow(std.testing.allocator, projection, 3, row_count, 80);
    defer input_gap.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), input_gap.items.len);

    var selected = try composeAppearanceMenuRow(std.testing.allocator, projection, 4, row_count, 80);
    defer selected.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, selected.items, "❯ Lines") != null);

    var tint = try composeAppearanceMenuRow(std.testing.allocator, projection, 5, row_count, 80);
    defer tint.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, tint.items, "Tint ✓") != null);

    var presentation_gap = try composeAppearanceMenuRow(std.testing.allocator, projection, 8, row_count, 80);
    defer presentation_gap.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), presentation_gap.items.len);

    var minimal = try composeAppearanceMenuRow(std.testing.allocator, projection, 10, row_count, 80);
    defer minimal.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, minimal.items, "Minimal ✓") != null);
}

test "appearance menu rows remain single-line and width safe" {
    const projection: AppearanceMenuProjection = .{ .active = true };
    for ([_]u16{ 1, 4, 18 }) |width| {
        var row = try composeAppearanceMenuRow(std.testing.allocator, projection, 4, row_count, width);
        defer row.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.findScalar(u8, row.items, '\n') == null);
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= width);
    }
}

test "appearance menu keeps actionable choices visible as rows compact" {
    const full_projection: AppearanceMenuProjection = .{
        .active = true,
        .selected_index = 0,
        .snapshot = .{ .input_appearance = "lines", .maxxing_mode = "normal" },
    };
    try expectMenuContains(full_projection, 9, "Lines");
    try expectMenuContains(full_projection, 9, "Tint");
    try expectMenuContains(full_projection, 9, "Normal");
    try expectMenuContains(full_projection, 9, "Minimal");

    const selected_section: AppearanceMenuProjection = .{
        .active = true,
        .selected_index = 2,
        .snapshot = full_projection.snapshot,
    };
    try expectMenuContains(selected_section, 3, "Normal");
    try expectMenuContains(selected_section, 3, "Minimal");
}

fn expectMenuContains(
    projection: AppearanceMenuProjection,
    visible_rows: u16,
    expected: []const u8,
) !void {
    var row_index: u16 = 0;
    while (row_index < visible_rows) : (row_index += 1) {
        var row = try composeAppearanceMenuRow(
            std.testing.allocator,
            projection,
            row_index,
            visible_rows,
            60,
        );
        defer row.deinit(std.testing.allocator);
        if (std.mem.find(u8, row.items, expected) != null) return;
    }
    return error.TestExpectedText;
}
