pub const Row = struct {
    label: []const u8,
    detail: []const u8 = "",
    selected: bool = false,
    marked: bool = false,
    destructive: bool = false,
};

pub const Projection = struct {
    active: bool = false,
    title: []const u8 = "",
    subtitle: []const u8 = "",
    rows: []const Row = &.{},
    error_message: []const u8 = "",
    accepts_text: bool = false,
    hint: []const u8 = "↑↓ Navigate  ·  Enter Select  ·  Esc Back",
};

pub const Outcome = union(enum) {
    redraw,
    replace_input: []const u8,
    choose_model: []const u8,
    save: []u8,
    exit,
};
