const std = @import("std");

pub const Profile = enum {
    clean,
    user,
};

/// Captured-command startup semantics bound into permission admission.
///
/// The shell path is part of explicit native profiles so execution cannot
/// silently switch environments after permission has been granted.
pub const Environment = union(enum) {
    legacy,
    clean: []const u8,
    user: []const u8,
    workspace_clean,

    pub fn eql(self: Environment, other: Environment) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .legacy, .workspace_clean => true,
            .clean => |path| std.mem.eql(u8, path, other.clean),
            .user => |path| std.mem.eql(u8, path, other.user),
        };
    }

    pub fn requiresShellRoute(self: Environment) bool {
        return std.meta.activeTag(self) == .user;
    }
};

pub const Host = enum {
    native,
    workspace_clean,
};

test "command environment equality includes explicit shell identity" {
    try std.testing.expect((Environment{ .legacy = {} }).eql(.legacy));
    try std.testing.expect((Environment{ .workspace_clean = {} }).eql(.workspace_clean));
    try std.testing.expect((Environment{ .clean = "/bin/zsh" }).eql(.{ .clean = "/bin/zsh" }));
    try std.testing.expect(!(Environment{ .clean = "/bin/zsh" }).eql(.{ .clean = "/bin/bash" }));
    try std.testing.expect(!(Environment{ .clean = "/bin/zsh" }).eql(.{ .user = "/bin/zsh" }));
}

test "only explicit user startup forbids the direct route" {
    try std.testing.expect(!(Environment{ .legacy = {} }).requiresShellRoute());
    try std.testing.expect(!(Environment{ .clean = "/bin/zsh" }).requiresShellRoute());
    try std.testing.expect((Environment{ .user = "/bin/zsh" }).requiresShellRoute());
    try std.testing.expect(!(Environment{ .workspace_clean = {} }).requiresShellRoute());
}
