const std = @import("std");
const types = @import("../shared/types.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Identity = struct {
    bytes: [Sha256.digest_length]u8,

    pub fn eql(self: Identity, other: Identity) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

pub const EphemeralVerifier = struct {
    bytes: [Sha256.digest_length]u8,

    pub fn eql(self: EphemeralVerifier, other: EphemeralVerifier) bool {
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

pub fn deriveEphemeralVerifier(
    source: types.CredentialSource,
    account_id: ?[]const u8,
    tenant: ?[]const u8,
    secret: []const u8,
) EphemeralVerifier {
    var hash = Sha256.init(.{});
    hash.update("fx-ephemeral-credential-verifier-v1\x00source\x00");
    hash.update(@tagName(source));
    if (account_id) |account| {
        hash.update("\x00account\x00");
        hash.update(account);
    }
    if (tenant) |value| {
        hash.update("\x00tenant\x00");
        hash.update(value);
    }
    hash.update("\x00secret\x00");
    hash.update(secret);
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

test "ephemeral verifier changes with secret and never shares the durable type" {
    const first = deriveEphemeralVerifier(.ai_gateway_api_key, null, "team_1", "secret-a");
    const same = deriveEphemeralVerifier(.ai_gateway_api_key, null, "team_1", "secret-a");
    const changed = deriveEphemeralVerifier(.ai_gateway_api_key, null, "team_1", "secret-b");
    try std.testing.expect(first.eql(same));
    try std.testing.expect(!first.eql(changed));
    try std.testing.expect(EphemeralVerifier != Identity);
}
