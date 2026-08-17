const std = @import("std");

const Allocator = std.mem.Allocator;

pub const schema_version: u8 = 1;
pub const max_rules: usize = 1024;
pub const max_identity_bytes: usize = 4096;
pub const max_display_identity_bytes: usize = 4096;

pub const RuleId = struct {
    value: u64,
};

pub const RuleKey = struct {
    pub const Kind = enum {
        command,
        file_mutation,
        structured_tool,
    };

    kind: Kind,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    canonical: []const u8,

    pub fn init(kind: Kind, canonical: []const u8) !RuleKey {
        if (canonical.len == 0 or canonical.len > max_identity_bytes) {
            return error.InvalidPermissionIdentity;
        }
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
        return .{
            .kind = kind,
            .digest = digest,
            .canonical = canonical,
        };
    }

    pub fn eql(a: RuleKey, b: RuleKey) bool {
        return a.kind == b.kind and
            std.mem.eql(u8, &a.digest, &b.digest) and
            std.mem.eql(u8, a.canonical, b.canonical);
    }
};

pub const Decision = enum {
    allow,
    deny,
};

pub const StateDecision = enum {
    allow,
    deny,
    unresolved,
};

pub const Rule = struct {
    id: RuleId,
    key: RuleKey,
    display_identity: []u8,
    decision: Decision,
    generation: u64,

    fn deinit(self: *Rule, alloc: Allocator) void {
        alloc.free(@constCast(self.key.canonical));
        alloc.free(self.display_identity);
        self.* = undefined;
    }
};

pub const State = struct {
    version: u8 = schema_version,
    next_generation: u64 = 1,
    rules: std.ArrayList(Rule) = .empty,

    pub fn deinit(self: *State, alloc: Allocator) void {
        for (self.rules.items) |*rule| rule.deinit(alloc);
        self.rules.deinit(alloc);
        self.* = .{};
    }
};

pub fn validate(state: State) !void {
    if (state.version != schema_version or
        state.next_generation == 0 or
        state.rules.items.len > max_rules)
    {
        return error.InvalidPermissionState;
    }
    for (state.rules.items, 0..) |rule, index| {
        if (rule.id.value == 0 or
            rule.generation == 0 or
            rule.id.value > rule.generation or
            rule.id.value >= state.next_generation or
            rule.generation >= state.next_generation or
            rule.key.canonical.len == 0 or
            rule.key.canonical.len > max_identity_bytes or
            rule.display_identity.len == 0 or
            rule.display_identity.len > max_display_identity_bytes)
        {
            return error.InvalidPermissionState;
        }
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(rule.key.canonical, &digest, .{});
        if (!std.mem.eql(u8, &digest, &rule.key.digest)) {
            return error.InvalidPermissionState;
        }
        for (state.rules.items[0..index]) |prior| {
            if (prior.id.value == rule.id.value or RuleKey.eql(prior.key, rule.key)) {
                return error.InvalidPermissionState;
            }
        }
    }
}

pub const SetEvent = struct {
    key: RuleKey,
    display_identity: []const u8,
    decision: Decision,
    expected_generation: ?u64,
};

pub const RevokeEvent = struct {
    id: RuleId,
    expected_generation: u64,
};

pub const ConfirmedRuleEvent = union(enum) {
    set: SetEvent,
    revoke: RevokeEvent,
};

pub const OwnedConfirmedRuleEvent = struct {
    event: ConfirmedRuleEvent,

    pub fn dupe(
        alloc: Allocator,
        event: ConfirmedRuleEvent,
    ) !OwnedConfirmedRuleEvent {
        return .{ .event = switch (event) {
            .revoke => |revoke| .{ .revoke = revoke },
            .set => |set| blk: {
                const canonical = try alloc.dupe(u8, set.key.canonical);
                errdefer alloc.free(canonical);
                const display_identity = try alloc.dupe(u8, set.display_identity);
                break :blk .{ .set = .{
                    .key = .{
                        .kind = set.key.kind,
                        .digest = set.key.digest,
                        .canonical = canonical,
                    },
                    .display_identity = display_identity,
                    .decision = set.decision,
                    .expected_generation = set.expected_generation,
                } };
            },
        } };
    }

    pub fn deinit(self: *OwnedConfirmedRuleEvent, alloc: Allocator) void {
        switch (self.event) {
            .revoke => {},
            .set => |set| {
                alloc.free(@constCast(set.key.canonical));
                alloc.free(@constCast(set.display_identity));
            },
        }
        self.* = undefined;
    }
};

pub const ApplyResult = union(enum) {
    applied: State,
    stale,
    full,
    invalid,

    pub fn takeApplied(self: *ApplyResult) ?State {
        return switch (self.*) {
            .applied => |state| blk: {
                self.* = .invalid;
                break :blk state;
            },
            else => null,
        };
    }
};

pub const ApplyStatus = enum {
    applied,
    stale,
    full,
    invalid,
};

pub fn apply(
    alloc: Allocator,
    state: State,
    event: ConfirmedRuleEvent,
) !ApplyResult {
    validate(state) catch return .invalid;
    return switch (event) {
        .set => |set| applySet(alloc, state, set),
        .revoke => |revoke| applyRevoke(alloc, state, revoke),
    };
}

fn applySet(alloc: Allocator, state: State, event: SetEvent) !ApplyResult {
    if (state.version != schema_version or
        state.next_generation == 0 or
        event.display_identity.len == 0 or
        event.display_identity.len > max_display_identity_bytes or
        event.key.canonical.len == 0 or
        event.key.canonical.len > max_identity_bytes)
    {
        return .invalid;
    }
    const next_generation = std.math.add(u64, state.next_generation, 1) catch
        return .invalid;

    if (keyIndex(state, event.key)) |index| {
        if (event.expected_generation != state.rules.items[index].generation) {
            return .stale;
        }
        const display_identity = try alloc.dupe(u8, event.display_identity);
        errdefer alloc.free(display_identity);
        var next = try cloneState(alloc, state);
        errdefer next.deinit(alloc);
        alloc.free(next.rules.items[index].display_identity);
        next.rules.items[index].display_identity = display_identity;
        next.rules.items[index].decision = event.decision;
        next.rules.items[index].generation = state.next_generation;
        next.next_generation = next_generation;
        return .{ .applied = next };
    }
    if (event.expected_generation != null) return .stale;
    if (state.rules.items.len >= max_rules) return .full;

    var next = try cloneState(alloc, state);
    errdefer next.deinit(alloc);
    const canonical = try alloc.dupe(u8, event.key.canonical);
    errdefer alloc.free(canonical);
    const display_identity = try alloc.dupe(u8, event.display_identity);
    errdefer alloc.free(display_identity);
    try next.rules.append(alloc, .{
        .id = .{ .value = state.next_generation },
        .key = .{
            .kind = event.key.kind,
            .digest = event.key.digest,
            .canonical = canonical,
        },
        .display_identity = display_identity,
        .decision = event.decision,
        .generation = state.next_generation,
    });
    next.next_generation = next_generation;
    return .{ .applied = next };
}

fn cloneState(alloc: Allocator, state: State) !State {
    var copy: State = .{
        .version = state.version,
        .next_generation = state.next_generation,
    };
    errdefer copy.deinit(alloc);
    try copy.rules.ensureTotalCapacity(alloc, state.rules.items.len);
    for (state.rules.items) |rule| {
        try appendRuleCopy(alloc, &copy, rule);
    }
    return copy;
}

pub fn dupe(alloc: Allocator, state: State) !State {
    try validate(state);
    return cloneState(alloc, state);
}

fn appendRuleCopy(alloc: Allocator, state: *State, rule: Rule) !void {
    const canonical = try alloc.dupe(u8, rule.key.canonical);
    errdefer alloc.free(canonical);
    const display_identity = try alloc.dupe(u8, rule.display_identity);
    errdefer alloc.free(display_identity);
    try state.rules.append(alloc, .{
        .id = rule.id,
        .key = .{
            .kind = rule.key.kind,
            .digest = rule.key.digest,
            .canonical = canonical,
        },
        .display_identity = display_identity,
        .decision = rule.decision,
        .generation = rule.generation,
    });
}

fn applyRevoke(
    alloc: Allocator,
    state: State,
    event: RevokeEvent,
) !ApplyResult {
    const index = idIndex(state, event.id) orelse return .stale;
    if (state.rules.items[index].generation != event.expected_generation) {
        return .stale;
    }
    const next_generation = std.math.add(u64, state.next_generation, 1) catch
        return .invalid;
    var next = try cloneState(alloc, state);
    errdefer next.deinit(alloc);
    var removed = next.rules.orderedRemove(index);
    removed.deinit(alloc);
    next.next_generation = next_generation;
    return .{ .applied = next };
}

fn keyIndex(state: State, key: RuleKey) ?usize {
    for (state.rules.items, 0..) |rule, index| {
        if (RuleKey.eql(rule.key, key)) return index;
    }
    return null;
}

fn idIndex(state: State, id: RuleId) ?usize {
    for (state.rules.items, 0..) |rule, index| {
        if (rule.id.value == id.value) return index;
    }
    return null;
}

pub fn ruleForId(state: State, id: RuleId) ?*const Rule {
    for (state.rules.items) |*rule| {
        if (rule.id.value == id.value) return rule;
    }
    return null;
}

pub fn ruleForKey(state: State, key: RuleKey) ?*const Rule {
    const index = keyIndex(state, key) orelse return null;
    return &state.rules.items[index];
}

pub fn decide(state: State, key: RuleKey) StateDecision {
    const index = keyIndex(state, key) orelse return .unresolved;
    return switch (state.rules.items[index].decision) {
        .allow => .allow,
        .deny => .deny,
    };
}

pub fn projectForChild(
    alloc: Allocator,
    state: State,
    delegated_allow_keys: []const RuleKey,
) !State {
    var projected: State = .{
        .version = state.version,
        .next_generation = state.next_generation,
    };
    errdefer projected.deinit(alloc);
    try projected.rules.ensureTotalCapacity(alloc, state.rules.items.len);
    for (state.rules.items) |rule| {
        if (rule.decision == .allow and
            !containsKey(delegated_allow_keys, rule.key))
        {
            continue;
        }
        try appendRuleCopy(alloc, &projected, rule);
    }
    return projected;
}

fn containsKey(keys: []const RuleKey, candidate: RuleKey) bool {
    for (keys) |key| {
        if (RuleKey.eql(key, candidate)) return true;
    }
    return false;
}

test "rule insertion creates a stable nonzero id" {
    const alloc = std.testing.allocator;
    var original: State = .{};
    defer original.deinit(alloc);

    const key = try RuleKey.init(.command, "command\x00git status");
    var result = try apply(alloc, original, .{ .set = .{
        .key = key,
        .display_identity = "git status in /workspace",
        .decision = .deny,
        .expected_generation = null,
    } });
    var next = result.takeApplied() orelse return error.TestExpectedAppliedState;
    defer next.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), original.rules.items.len);
    try std.testing.expectEqual(@as(usize, 1), next.rules.items.len);
    try std.testing.expect(next.rules.items[0].id.value != 0);
    try std.testing.expectEqual(next.rules.items[0].id, ruleForId(next, next.rules.items[0].id).?.id);
}

test "rule replacement preserves id and prior state" {
    const alloc = std.testing.allocator;
    var empty: State = .{};
    defer empty.deinit(alloc);
    const key = try RuleKey.init(.command, "command\x00git status");

    var inserted_result = try apply(alloc, empty, .{ .set = .{
        .key = key,
        .display_identity = "git status in /workspace",
        .decision = .allow,
        .expected_generation = null,
    } });
    var inserted = inserted_result.takeApplied() orelse
        return error.TestExpectedAppliedState;
    defer inserted.deinit(alloc);
    const original_id = inserted.rules.items[0].id;
    const original_generation = inserted.rules.items[0].generation;

    var replaced_result = try apply(alloc, inserted, .{ .set = .{
        .key = key,
        .display_identity = "git status in /workspace",
        .decision = .deny,
        .expected_generation = original_generation,
    } });
    var replaced = replaced_result.takeApplied() orelse
        return error.TestExpectedAppliedState;
    defer replaced.deinit(alloc);

    try std.testing.expectEqual(Decision.allow, inserted.rules.items[0].decision);
    try std.testing.expectEqual(Decision.deny, replaced.rules.items[0].decision);
    try std.testing.expectEqual(original_id, replaced.rules.items[0].id);
    try std.testing.expect(replaced.rules.items[0].generation > original_generation);
}

test "stale events and generation exhaustion leave state unchanged" {
    const alloc = std.testing.allocator;
    var empty: State = .{};
    defer empty.deinit(alloc);
    const key = try RuleKey.init(.command, "command\x00git status");
    var inserted_result = try apply(alloc, empty, .{ .set = .{
        .key = key,
        .display_identity = "git status",
        .decision = .deny,
        .expected_generation = null,
    } });
    var inserted = inserted_result.takeApplied() orelse
        return error.TestExpectedAppliedState;
    defer inserted.deinit(alloc);
    const stored = inserted.rules.items[0];

    const stale_set = try apply(alloc, inserted, .{ .set = .{
        .key = key,
        .display_identity = "git status replacement",
        .decision = .allow,
        .expected_generation = stored.generation + 1,
    } });
    try std.testing.expectEqual(
        std.meta.Tag(ApplyResult).stale,
        std.meta.activeTag(stale_set),
    );
    const stale_revoke = try apply(alloc, inserted, .{ .revoke = .{
        .id = stored.id,
        .expected_generation = stored.generation + 1,
    } });
    try std.testing.expectEqual(
        std.meta.Tag(ApplyResult).stale,
        std.meta.activeTag(stale_revoke),
    );
    try std.testing.expectEqual(Decision.deny, inserted.rules.items[0].decision);
    try std.testing.expectEqual(stored.generation, inserted.rules.items[0].generation);

    var exhausted: State = .{ .next_generation = std.math.maxInt(u64) };
    defer exhausted.deinit(alloc);
    const exhausted_result = try apply(alloc, exhausted, .{ .set = .{
        .key = key,
        .display_identity = "git status",
        .decision = .allow,
        .expected_generation = null,
    } });
    try std.testing.expectEqual(
        std.meta.Tag(ApplyResult).invalid,
        std.meta.activeTag(exhausted_result),
    );
    try std.testing.expectEqual(@as(usize, 0), exhausted.rules.items.len);
}

test "rule revocation uses stored id after identity changes" {
    const alloc = std.testing.allocator;
    var empty: State = .{};
    defer empty.deinit(alloc);
    const original_key = try RuleKey.init(.file_mutation, "file\x00old-preimage");

    var inserted_result = try apply(alloc, empty, .{ .set = .{
        .key = original_key,
        .display_identity = "write_file report.md with old preimage",
        .decision = .deny,
        .expected_generation = null,
    } });
    var inserted = inserted_result.takeApplied() orelse
        return error.TestExpectedAppliedState;
    defer inserted.deinit(alloc);
    const stored = inserted.rules.items[0];

    const changed_key = try RuleKey.init(.file_mutation, "file\x00new-preimage");
    try std.testing.expect(!RuleKey.eql(stored.key, changed_key));

    var revoked_result = try apply(alloc, inserted, .{ .revoke = .{
        .id = stored.id,
        .expected_generation = stored.generation,
    } });
    var revoked = revoked_result.takeApplied() orelse
        return error.TestExpectedAppliedState;
    defer revoked.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), revoked.rules.items.len);
    try std.testing.expect(ruleForId(revoked, stored.id) == null);
}

test "decision matches only the exact canonical key" {
    const alloc = std.testing.allocator;
    var empty: State = .{};
    defer empty.deinit(alloc);
    const exact = try RuleKey.init(.command, "command\x00/workspace\x00git status");
    var result = try apply(alloc, empty, .{ .set = .{
        .key = exact,
        .display_identity = "git status in /workspace",
        .decision = .allow,
        .expected_generation = null,
    } });
    var state = result.takeApplied() orelse return error.TestExpectedAppliedState;
    defer state.deinit(alloc);

    const neighbor = try RuleKey.init(.command, "command\x00/workspace\x00git status --short");
    try std.testing.expectEqual(StateDecision.allow, decide(state, exact));
    try std.testing.expectEqual(StateDecision.unresolved, decide(state, neighbor));
}

test "child projection preserves denies and filters undelegated allows" {
    const alloc = std.testing.allocator;
    var empty: State = .{};
    defer empty.deinit(alloc);
    const denied_key = try RuleKey.init(.command, "command\x00denied");
    const allowed_key = try RuleKey.init(.structured_tool, "tool\x00allowed");

    var denied_result = try apply(alloc, empty, .{ .set = .{
        .key = denied_key,
        .display_identity = "denied command",
        .decision = .deny,
        .expected_generation = null,
    } });
    var with_deny = denied_result.takeApplied() orelse return error.TestExpectedAppliedState;
    defer with_deny.deinit(alloc);
    var allowed_result = try apply(alloc, with_deny, .{ .set = .{
        .key = allowed_key,
        .display_identity = "allowed tool",
        .decision = .allow,
        .expected_generation = null,
    } });
    var parent = allowed_result.takeApplied() orelse return error.TestExpectedAppliedState;
    defer parent.deinit(alloc);

    var without_allow = try projectForChild(alloc, parent, &.{});
    defer without_allow.deinit(alloc);
    try std.testing.expectEqual(StateDecision.deny, decide(without_allow, denied_key));
    try std.testing.expectEqual(StateDecision.unresolved, decide(without_allow, allowed_key));

    var with_allow = try projectForChild(alloc, parent, &.{allowed_key});
    defer with_allow.deinit(alloc);
    try std.testing.expectEqual(StateDecision.deny, decide(with_allow, denied_key));
    try std.testing.expectEqual(StateDecision.allow, decide(with_allow, allowed_key));
    try std.testing.expectEqual(@as(usize, 2), parent.rules.items.len);
}

test "state validation rejects duplicate rule ids" {
    const alloc = std.testing.allocator;
    var empty: State = .{};
    defer empty.deinit(alloc);
    const first_key = try RuleKey.init(.command, "command\x00first");
    const second_key = try RuleKey.init(.command, "command\x00second");

    var first_result = try apply(alloc, empty, .{ .set = .{
        .key = first_key,
        .display_identity = "first",
        .decision = .deny,
        .expected_generation = null,
    } });
    var first = first_result.takeApplied() orelse return error.TestExpectedAppliedState;
    defer first.deinit(alloc);
    var second_result = try apply(alloc, first, .{ .set = .{
        .key = second_key,
        .display_identity = "second",
        .decision = .allow,
        .expected_generation = null,
    } });
    var invalid = second_result.takeApplied() orelse return error.TestExpectedAppliedState;
    defer invalid.deinit(alloc);
    invalid.rules.items[1].id = invalid.rules.items[0].id;

    try std.testing.expectError(error.InvalidPermissionState, validate(invalid));
}

test "capacity rejects insertion while preserving replacement" {
    const alloc = std.testing.allocator;
    var state: State = .{ .next_generation = max_rules + 1 };
    defer state.deinit(alloc);
    try state.rules.ensureTotalCapacity(alloc, max_rules);
    for (0..max_rules) |index| {
        const canonical = try std.fmt.allocPrint(alloc, "command-{d}", .{index});
        const key = try RuleKey.init(.command, canonical);
        state.rules.appendAssumeCapacity(.{
            .id = .{ .value = @intCast(index + 1) },
            .key = key,
            .display_identity = try std.fmt.allocPrint(alloc, "command {d}", .{index}),
            .decision = .deny,
            .generation = @intCast(index + 1),
        });
    }
    try validate(state);

    const new_key = try RuleKey.init(.command, "new-command");
    const full = try apply(alloc, state, .{ .set = .{
        .key = new_key,
        .display_identity = "new command",
        .decision = .allow,
        .expected_generation = null,
    } });
    try std.testing.expectEqual(std.meta.Tag(ApplyResult).full, std.meta.activeTag(full));

    const existing = state.rules.items[0];
    var replaced_result = try apply(alloc, state, .{ .set = .{
        .key = existing.key,
        .display_identity = "replacement",
        .decision = .allow,
        .expected_generation = existing.generation,
    } });
    var replaced = replaced_result.takeApplied() orelse
        return error.TestExpectedAppliedState;
    defer replaced.deinit(alloc);
    try std.testing.expectEqual(@as(usize, max_rules), replaced.rules.items.len);
    try std.testing.expectEqual(existing.id, replaced.rules.items[0].id);
    try std.testing.expectEqual(Decision.allow, replaced.rules.items[0].decision);
}
