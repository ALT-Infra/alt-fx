const std = @import("std");

const Allocator = std.mem.Allocator;

pub const GitHubIssueContext = struct {
    version: []const u8,
    git_commit: []const u8,
    os_family: []const u8,
    arch: []const u8,
    build_mode: []const u8,
};

const github_issue_url = "https://github.com/vercel-labs/fx/issues/new";
const github_issue_template = "fx-report.yml";

/// Returns an owned GitHub issue-form URL containing only bounded build and
/// platform metadata. Prompts, paths, command output, and environment values
/// are deliberately excluded so the user decides what diagnostic data to add.
pub fn buildGitHubIssueUrl(alloc: Allocator, context: GitHubIssueContext) ![]u8 {
    var diagnostics: std.Io.Writer.Allocating = .init(alloc);
    defer diagnostics.deinit();
    try diagnostics.writer.print(
        "fx version: {s} ({s})\nplatform: {s}/{s}\nbuild: {s}\nsource: /feedback",
        .{
            context.version,
            context.git_commit,
            context.os_family,
            context.arch,
            context.build_mode,
        },
    );

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{s}?template={s}&diagnostics=", .{
        github_issue_url,
        github_issue_template,
    });
    try percentEncode(&out.writer, diagnostics.written());
    return out.toOwnedSlice();
}

fn percentEncode(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or
            byte == '.' or byte == '~')
        {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

test "GitHub issue URL pre-fills only encoded build metadata" {
    const url = try buildGitHubIssueUrl(std.testing.allocator, .{
        .version = "0.4.0 dev",
        .git_commit = "abc123",
        .os_family = "macos",
        .arch = "aarch64",
        .build_mode = "Debug",
    });
    defer std.testing.allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://github.com/vercel-labs/fx/issues/new?template=fx-report.yml&diagnostics=" ++
            "fx%20version%3A%200.4.0%20dev%20%28abc123%29%0A" ++
            "platform%3A%20macos%2Faarch64%0A" ++
            "build%3A%20Debug%0A" ++
            "source%3A%20%2Ffeedback",
        url,
    );
    try std.testing.expect(std.mem.find(u8, url, "prompt") == null);
    try std.testing.expect(std.mem.find(u8, url, "workspace") == null);
}
