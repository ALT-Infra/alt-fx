const std = @import("std");
const types = @import("../shared/types.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Identity = struct {
    bytes: [Sha256.digest_length]u8,

    pub fn eql(self: Identity, other: Identity) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

pub fn derive(
    source: types.CredentialSource,
    account_id: ?[]const u8,
) ?Identity {
    const account = account_id orelse return null;
    if (account.len == 0) return null;
    var hash = Sha256.init(.{});
    hash.update("fx-credential-authority-v1\x00");
    hash.update(@tagName(source));
    hash.update("\x00account\x00");
    hash.update(account);
    var bytes: [Sha256.digest_length]u8 = undefined;
    hash.final(&bytes);
    return .{ .bytes = bytes };
}

test "credential authority uses only stable account identity" {
    const first = derive(.chatgpt_subscription, "acct_1").?;
    const refreshed = derive(.chatgpt_subscription, "acct_1").?;
    const other = derive(.chatgpt_subscription, "acct_2").?;
    try std.testing.expect(first.eql(refreshed));
    try std.testing.expect(!first.eql(other));
    try std.testing.expect(derive(.ai_gateway_api_key, null) == null);
    try std.testing.expect(@sizeOf(Identity) == 32);
    _ = types.CredentialSource;
}
