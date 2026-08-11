const std = @import("std");

pub const default_max_provider_attempts: usize = 10;
pub const max_retry_after_seconds: u64 = 30;

pub const FailureCause = enum {
    transport_interrupted,
    response_interrupted,
    provider_unavailable,
    rate_limited,
    system_resumed,
    authentication,
    request_limit_reached,
    content_filter,
};

pub const Delivery = enum {
    definitely_unsent,
    possibly_sent,
};

pub const OutputEvidence = enum {
    none,
    partial,
};

pub const ToolEvidence = enum {
    none,
    proven_unexecuted,
    confirmed,
    uncertain,
};

pub const AttemptState = struct {
    consumed: usize,
    limit: usize = default_max_provider_attempts,

    pub fn remaining(self: AttemptState) usize {
        return self.limit -| self.consumed;
    }
};

pub const Strategy = enum {
    retry_request,
    continue_response,
    regenerate_tool,
    continue_after_confirmed_tool,
    reconcile_tool,
    wait_for_connectivity,
    pause,
    stop,
};

pub const RequiredAction = enum {
    none,
    continue_later,
    inspect_uncertain_tool,
    change_request,
};

pub const Evidence = struct {
    cause: FailureCause,
    delivery: Delivery,
    attempts: AttemptState,
    output: OutputEvidence = .none,
    tool: ToolEvidence = .none,
    retry_after_seconds: ?u64 = null,
    cancelled: bool = false,
};

pub const Decision = struct {
    strategy: Strategy,
    delay_ns: u64 = 0,
    reserve_provider_attempt: bool = false,
    required_action: RequiredAction = .none,
};

/// Pure model-response policy. It describes the next effect but never sleeps,
/// sends, mutates stream state, or persists a checkpoint.
pub noinline fn decide(evidence: Evidence) Decision {
    if (evidence.cancelled) return .{ .strategy = .stop };

    switch (evidence.cause) {
        .content_filter => return .{
            .strategy = .stop,
            .required_action = .change_request,
        },
        .request_limit_reached => return .{
            .strategy = .pause,
            .required_action = .continue_later,
        },
        else => {},
    }

    if (evidence.attempts.remaining() == 0) {
        return .{
            .strategy = .pause,
            .required_action = if (evidence.tool == .uncertain)
                .inspect_uncertain_tool
            else
                .continue_later,
        };
    }

    if (evidence.cause == .system_resumed) {
        return .{ .strategy = .wait_for_connectivity };
    }

    if (evidence.retry_after_seconds) |seconds| {
        if (seconds > max_retry_after_seconds) {
            return .{
                .strategy = .pause,
                .required_action = .continue_later,
            };
        }
    }

    const strategy: Strategy = if (evidence.delivery == .definitely_unsent)
        .retry_request
    else switch (evidence.tool) {
        .proven_unexecuted => .regenerate_tool,
        .confirmed => .continue_after_confirmed_tool,
        .uncertain => .reconcile_tool,
        .none => if (evidence.output == .partial)
            .continue_response
        else
            .retry_request,
    };
    const delay_ns = if (evidence.retry_after_seconds) |seconds|
        std.math.mul(u64, seconds, std.time.ns_per_s) catch max_retry_after_seconds * std.time.ns_per_s
    else
        retryDelayNs(evidence.attempts.consumed);
    return .{
        .strategy = strategy,
        .delay_ns = delay_ns,
        .reserve_provider_attempt = true,
    };
}

/// Delay before the next provider request after `consumed` attempts: 250 ms,
/// 1 s, then exponential growth capped at 30 s.
pub fn retryDelayNs(consumed: usize) u64 {
    if (consumed == 0) return 0;
    if (consumed == 1) return 250 * std.time.ns_per_ms;

    var seconds: u64 = 1;
    var attempt: usize = 2;
    while (attempt < consumed and seconds < max_retry_after_seconds) : (attempt += 1) {
        seconds = @min(seconds * 2, max_retry_after_seconds);
    }
    return seconds * std.time.ns_per_s;
}

/// Fast is an optimization, not a recovery requirement. A replay-safe
/// provider outage may fall back to the canonical route without changing the
/// semantic request budget.
pub fn shouldDisableFastRoute(
    fast_mode: bool,
    cause: FailureCause,
    replay_safe: bool,
) bool {
    return fast_mode and cause == .provider_unavailable and replay_safe;
}

pub const ContinuationProbeOutcome = enum {
    may_extend,
    cannot_extend,
    budget_exhausted,
};

pub const ContinuationProbe = struct {
    outcome: ContinuationProbeOutcome,
    comparisons: usize,
};

/// Determines whether more incoming bytes could extend the overlap while
/// performing no more than `comparison_budget` byte comparisons.
pub fn probeContinuationExtension(
    existing: []const u8,
    incoming: []const u8,
    comparison_budget: usize,
) ContinuationProbe {
    if (incoming.len >= existing.len) return .{
        .outcome = .cannot_extend,
        .comparisons = 0,
    };

    const candidate_count = existing.len - incoming.len;
    var comparisons: usize = 0;
    var start: usize = 0;
    while (start < candidate_count) : (start += 1) {
        var matched = true;
        for (incoming, 0..) |byte, offset| {
            if (comparisons == comparison_budget) return .{
                .outcome = .budget_exhausted,
                .comparisons = comparisons,
            };
            comparisons += 1;
            if (existing[start + offset] != byte) {
                matched = false;
                break;
            }
        }
        if (matched) return .{
            .outcome = .may_extend,
            .comparisons = comparisons,
        };
    }
    return .{
        .outcome = .cannot_extend,
        .comparisons = comparisons,
    };
}

/// Returns only the longest byte-exact suffix/prefix overlap in linear time.
/// This deliberately avoids fuzzy or semantic matching, which could delete
/// legitimate output.
pub fn exactContinuationOverlap(
    alloc: std.mem.Allocator,
    existing: []const u8,
    incoming: []const u8,
) !usize {
    if (existing.len == 0 or incoming.len == 0) return 0;

    const prefix = try alloc.alloc(usize, incoming.len);
    defer alloc.free(prefix);
    prefix[0] = 0;

    var matched: usize = 0;
    var incoming_idx: usize = 1;
    while (incoming_idx < incoming.len) : (incoming_idx += 1) {
        while (matched > 0 and incoming[incoming_idx] != incoming[matched]) {
            matched = prefix[matched - 1];
        }
        if (incoming[incoming_idx] == incoming[matched]) matched += 1;
        prefix[incoming_idx] = matched;
    }

    matched = 0;
    for (existing) |byte| {
        while (matched > 0 and
            (matched == incoming.len or incoming[matched] != byte))
        {
            matched = prefix[matched - 1];
        }
        if (incoming[matched] == byte) matched += 1;
    }
    return matched;
}

test "model response recovery policy is deterministic and bounded" {
    const base = Evidence{
        .cause = .transport_interrupted,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 1 },
    };
    const first = decide(base);
    try std.testing.expectEqual(first, decide(base));
    try std.testing.expectEqual(Strategy.retry_request, first.strategy);
    try std.testing.expect(first.reserve_provider_attempt);
    try std.testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), first.delay_ns);

    var partial = base;
    partial.output = .partial;
    try std.testing.expectEqual(Strategy.continue_response, decide(partial).strategy);

    var unexecuted = partial;
    unexecuted.tool = .proven_unexecuted;
    try std.testing.expectEqual(Strategy.regenerate_tool, decide(unexecuted).strategy);

    var uncertain = partial;
    uncertain.tool = .uncertain;
    try std.testing.expectEqual(Strategy.reconcile_tool, decide(uncertain).strategy);

    var definitely_unsent = uncertain;
    definitely_unsent.delivery = .definitely_unsent;
    try std.testing.expectEqual(Strategy.retry_request, decide(definitely_unsent).strategy);

    var exhausted = base;
    exhausted.attempts.consumed = exhausted.attempts.limit;
    const paused = decide(exhausted);
    try std.testing.expectEqual(Strategy.pause, paused.strategy);
    try std.testing.expect(!paused.reserve_provider_attempt);

    var request_limit = base;
    request_limit.cause = .request_limit_reached;
    const request_limit_pause = decide(request_limit);
    try std.testing.expectEqual(Strategy.pause, request_limit_pause.strategy);
    try std.testing.expect(!request_limit_pause.reserve_provider_attempt);
}

test "retry after and cancellation override automatic recovery" {
    const base = Evidence{
        .cause = .rate_limited,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 3 },
    };

    var bounded = base;
    bounded.retry_after_seconds = 30;
    const wait = decide(bounded);
    try std.testing.expectEqual(Strategy.retry_request, wait.strategy);
    try std.testing.expectEqual(@as(u64, 30 * std.time.ns_per_s), wait.delay_ns);

    var over_cap = base;
    over_cap.retry_after_seconds = 31;
    const paused = decide(over_cap);
    try std.testing.expectEqual(Strategy.pause, paused.strategy);
    try std.testing.expect(!paused.reserve_provider_attempt);

    var cancelled = base;
    cancelled.cancelled = true;
    try std.testing.expectEqual(Strategy.stop, decide(cancelled).strategy);
}

test "retry schedule uses the approved cap" {
    const expected = [_]u64{
        0,
        250 * std.time.ns_per_ms,
        1 * std.time.ns_per_s,
        2 * std.time.ns_per_s,
        4 * std.time.ns_per_s,
        8 * std.time.ns_per_s,
        16 * std.time.ns_per_s,
        30 * std.time.ns_per_s,
        30 * std.time.ns_per_s,
    };
    for (expected, 0..) |delay, consumed| {
        try std.testing.expectEqual(delay, retryDelayNs(consumed));
    }
}

test "system resume is gateway evidence but agent policy owns connectivity action" {
    const waiting = decide(.{
        .cause = .system_resumed,
        .delivery = .definitely_unsent,
        .attempts = .{ .consumed = 4 },
    });
    try std.testing.expectEqual(Strategy.wait_for_connectivity, waiting.strategy);
    try std.testing.expect(!waiting.reserve_provider_attempt);

    const exhausted = decide(.{
        .cause = .system_resumed,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 10 },
    });
    try std.testing.expectEqual(Strategy.pause, exhausted.strategy);
}

test "fast fallback is limited to replay safe provider outages" {
    try std.testing.expect(shouldDisableFastRoute(true, .provider_unavailable, true));
    try std.testing.expect(!shouldDisableFastRoute(false, .provider_unavailable, true));
    try std.testing.expect(!shouldDisableFastRoute(true, .provider_unavailable, false));
    try std.testing.expect(!shouldDisableFastRoute(true, .rate_limited, true));
    try std.testing.expect(!shouldDisableFastRoute(true, .transport_interrupted, true));
}

test "continuation overlap removes exact repetition only" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        existing: []const u8,
        incoming: []const u8,
        expected: usize,
    }{
        .{ .existing = "", .incoming = "next", .expected = 0 },
        .{ .existing = "hello", .incoming = " world", .expected = 0 },
        .{ .existing = "hello world", .incoming = "world again", .expected = 5 },
        .{ .existing = "abcabc", .incoming = "abcX", .expected = 3 },
        .{ .existing = "same", .incoming = "same", .expected = 4 },
        .{ .existing = "caf\xc3\xa9", .incoming = "\xc3\xa9 noir", .expected = 2 },
        .{ .existing = "almost", .incoming = "Almost", .expected = 0 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            try exactContinuationOverlap(alloc, case.existing, case.incoming),
        );
    }
}

test "continuation overlap remains exact for a long repetitive no-match boundary" {
    const alloc = std.testing.allocator;
    const boundary_len = 32 * 1024;
    const existing = try alloc.alloc(u8, boundary_len);
    defer alloc.free(existing);
    const incoming = try alloc.alloc(u8, boundary_len);
    defer alloc.free(incoming);
    @memset(existing, 'a');
    @memset(incoming, 'a');
    existing[existing.len - 1] = 'b';

    try std.testing.expectEqual(
        @as(usize, 0),
        try exactContinuationOverlap(alloc, existing, incoming),
    );
}

test "continuation extension probe never exceeds its comparison budget" {
    const alloc = std.testing.allocator;
    const boundary_len = 4096;
    const existing = try alloc.alloc(u8, boundary_len);
    defer alloc.free(existing);
    const incoming = try alloc.alloc(u8, boundary_len - 1);
    defer alloc.free(incoming);
    @memset(existing, 'a');
    @memset(incoming, 'a');
    existing[existing.len - 1] = 'b';

    const possible = probeContinuationExtension(existing, incoming, incoming.len);
    try std.testing.expectEqual(ContinuationProbeOutcome.may_extend, possible.outcome);
    try std.testing.expectEqual(incoming.len, possible.comparisons);

    const exhausted = probeContinuationExtension(existing, incoming, 1);
    try std.testing.expectEqual(ContinuationProbeOutcome.budget_exhausted, exhausted.outcome);
    try std.testing.expectEqual(@as(usize, 1), exhausted.comparisons);
}
