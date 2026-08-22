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
    tenant: ?[]const u8,
    secret: []const u8,
) Identity {
    var hash = Sha256.init(.{});
    hash.update("fx-credential-authority-v1\x00");
    hash.update(@tagName(source));
    hash.update("\x00");
    if (account_id) |account| {
        hash.update("account\x00");
        hash.update(account);
    } else {
        hash.update("credential\x00");
        hash.update(secret);
        if (tenant) |value| {
            hash.update("\x00tenant\x00");
            hash.update(value);
        }
    }
    var bytes: [Sha256.digest_length]u8 = undefined;
    hash.final(&bytes);
    return .{ .bytes = bytes };
}

test "credential authority prefers stable account identity and never stores the secret" {
    const first = derive(.chatgpt_subscription, "acct_1", null, "token-a");
    const refreshed = derive(.chatgpt_subscription, "acct_1", null, "token-b");
    const other = derive(.chatgpt_subscription, "acct_2", null, "token-a");
    try std.testing.expect(first.eql(refreshed));
    try std.testing.expect(!first.eql(other));

    const key_a = derive(.ai_gateway_api_key, null, null, "secret-a");
    const key_b = derive(.ai_gateway_api_key, null, null, "secret-b");
    try std.testing.expect(!key_a.eql(key_b));
    try std.testing.expect(@sizeOf(Identity) == 32);
    _ = types.CredentialSource;
}
