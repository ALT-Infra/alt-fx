const std = @import("std");
const team_mod = @import("team.zig");

const WireTeam = struct {
    schema: u16,
    id: []const u8,
    revision: u32,
    name: []const u8,
    provider_id: []const u8,
    models: []const team_mod.Model,
    primary: team_mod.Agent,
    peers: []const team_mod.Agent = &.{},
    specialists: []const team_mod.Specialist = &.{},
};

pub const Document = struct {
    parsed: std.json.Parsed(WireTeam),
    value: team_mod.Team,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Document {
        var parsed = try std.json.parseFromSlice(
            WireTeam,
            allocator,
            source,
            .{ .ignore_unknown_fields = false },
        );
        errdefer parsed.deinit();

        var digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source, &digest_bytes, .{});
        const digest = std.fmt.bytesToHex(digest_bytes, .lower);
        const wire = parsed.value;
        const value = team_mod.Team{
            .schema = wire.schema,
            .id = wire.id,
            .revision = wire.revision,
            .digest = digest,
            .name = wire.name,
            .provider_id = wire.provider_id,
            .models = wire.models,
            .primary = wire.primary,
            .peers = wire.peers,
            .specialists = wire.specialists,
        };
        try value.validate();
        return .{ .parsed = parsed, .value = value };
    }

    pub fn deinit(self: *Document) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub fn engineering(allocator: std.mem.Allocator) !Document {
    return Document.parse(allocator, @embedFile("../teams/engineering.json"));
}

test "embedded engineering Team is a validated immutable revision" {
    var document = try engineering(std.testing.allocator);
    defer document.deinit();

    try std.testing.expectEqual(@as(u16, 2), document.value.schema);
    try std.testing.expectEqualStrings("engineering", document.value.id);
    try std.testing.expectEqual(@as(u32, 6), document.value.revision);
    try std.testing.expectEqualStrings("opencode", document.value.provider_id);
    try std.testing.expect(document.value.arePeers("engineering", "coding"));
    try std.testing.expect(document.value.canUseSpecialist(
        "coding",
        "visual-inspector",
    ));
}

test "Team parser rejects unknown configuration fields" {
    try std.testing.expectError(
        error.UnknownField,
        Document.parse(
            std.testing.allocator,
            "{\"schema\":2,\"id\":\"x\",\"revision\":1,\"name\":\"X\",\"provider_id\":\"opencode\",\"models\":[],\"primary\":{\"id\":\"x\",\"model_id\":\"x\",\"definition\":\"x\"},\"surprise\":true}",
        ),
    );
}
