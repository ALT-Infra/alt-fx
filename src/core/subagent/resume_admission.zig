const std = @import("std");
const io_mod = @import("../shared/io.zig");
const session = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_log = @import("../session/session_log.zig");
const session_store = @import("../session/session_store.zig");
const control_store = @import("control_store.zig");
const domain = @import("domain.zig");
const manager_mod = @import("manager.zig");

const Allocator = std.mem.Allocator;

/// Resumes a session for a user-authored prompt while preserving the canonical
/// one-off child lifecycle. Internal child execution uses the mode-neutral
/// session store directly.
pub fn resumeForExternalPrompt(
    store: session_store.Store,
    alloc: Allocator,
    target: session_store.ResumeTarget,
    workspace_root: []const u8,
    options: session_store.ResumeOptions,
) !session_store.LoadedWritableSession {
    switch (target) {
        .id => |session_id| try ensureExternalPromptAllowed(
            store,
            alloc,
            session_id,
            true,
        ),
        .last => {},
    }

    var loaded = try store.resumeTargetForWrite(
        alloc,
        target,
        workspace_root,
        options,
    );
    errdefer loaded.deinit(alloc);
    try ensureExternalPromptAllowed(store, alloc, loaded.active_id, false);
    try installExternalPromptAuthority(store, alloc, &loaded);
    return loaded;
}

pub fn admitResumeViewForExternalPrompt(
    store: session_store.Store,
    alloc: Allocator,
    target: session_store.ResumeTarget,
) !?session_store.ResumeViewAdmission {
    var admission = (try store.admitResumeView(alloc, target)) orelse return null;
    errdefer admission.deinit(alloc);
    try ensureExternalPromptAllowed(store, alloc, admission.sessionId(), true);
    return admission;
}

pub fn resumeAdmittedForExternalPrompt(
    store: session_store.Store,
    alloc: Allocator,
    admission: *session_store.ResumeViewAdmission,
    session_id: []const u8,
    workspace_root: []const u8,
    options: session_store.ResumeOptions,
) !session_store.LoadedWritableSession {
    try ensureExternalPromptAllowed(store, alloc, session_id, true);
    var loaded = try store.resumeAdmittedForWrite(
        alloc,
        admission,
        session_id,
        workspace_root,
        options,
    );
    errdefer loaded.deinit(alloc);
    try ensureExternalPromptAllowed(store, alloc, loaded.active_id, false);
    try installExternalPromptAuthority(store, alloc, &loaded);
    return loaded;
}

fn installExternalPromptAuthority(
    store: session_store.Store,
    alloc: Allocator,
    loaded: *session_store.LoadedWritableSession,
) !void {
    var capability = try store.openSubagentControlCapabilityReadOnly(
        alloc,
        loaded.active_id,
        .{},
    );
    defer capability.deinit();
    const controls = control_store.Store{
        .capability = &capability,
        .expected_child_id = loaded.active_id,
    };
    var record = try controls.loadOptional(alloc);
    defer if (record) |*value| value.deinit(alloc);
    const child = record orelse return;
    if (child.mode == .one_off) return error.OneOffSessionNotResumable;

    loaded.external_prompt_origin = .persistent_child;
    const latest = if (child.queue.len > 0)
        child.queue[child.queue.len - 1]
    else
        return;
    if (!latest.root_user_evidence_complete or latest.root_user_messages.len == 0) {
        return;
    }
    const messages = try alloc.alloc([]u8, latest.root_user_messages.len);
    var initialized: usize = 0;
    errdefer {
        for (messages[0..initialized]) |message| alloc.free(message);
        alloc.free(messages);
    }
    for (latest.root_user_messages) |message| {
        messages[initialized] = try alloc.dupe(u8, message);
        initialized += 1;
    }
    loaded.external_root_user_messages = messages;
    loaded.external_root_user_evidence_complete = true;
}

/// Retains a committed, externally authored prompt for a resumed persistent
/// child. Missing historical evidence cannot be repaired by a newer prompt:
/// the complete bit remains false until a canonical queue record supplies the
/// full root-user lane on a later resume.
pub fn retainExternalRootUserTurn(
    alloc: Allocator,
    loaded: *session_store.LoadedWritableSession,
    turn: session.HistoryTurn,
) !void {
    if (loaded.external_prompt_origin != .persistent_child or
        !loaded.external_root_user_evidence_complete)
    {
        return;
    }
    const prompt = switch (turn) {
        .assistant => |entry| entry.user.text,
        .background_command => |entry| entry.user.text,
        .interrupted => |entry| entry.user.text,
        .compacted_summary => return,
    };
    if (!rootUserEvidenceCanAppend(loaded.external_root_user_messages, prompt)) {
        clearExternalRootUserEvidence(alloc, loaded);
        return;
    }

    const next = try alloc.alloc([]u8, loaded.external_root_user_messages.len + 1);
    errdefer alloc.free(next);
    @memcpy(
        next[0..loaded.external_root_user_messages.len],
        loaded.external_root_user_messages,
    );
    next[next.len - 1] = try alloc.dupe(u8, prompt);
    if (loaded.external_root_user_messages.len > 0) {
        alloc.free(loaded.external_root_user_messages);
    }
    loaded.external_root_user_messages = next;
}

fn rootUserEvidenceCanAppend(
    retained: []const []const u8,
    prompt: []const u8,
) bool {
    if (prompt.len == 0) return false;
    var total_bytes: usize = prompt.len;
    for (retained) |message| {
        if (message.len == 0) return false;
        total_bytes = std.math.add(usize, total_bytes, message.len) catch return false;
        if (total_bytes > domain.max_root_user_evidence_bytes) return false;
    }
    return total_bytes <= domain.max_root_user_evidence_bytes;
}

fn clearExternalRootUserEvidence(
    alloc: Allocator,
    loaded: *session_store.LoadedWritableSession,
) void {
    for (loaded.external_root_user_messages) |message| alloc.free(message);
    if (loaded.external_root_user_messages.len > 0) {
        alloc.free(loaded.external_root_user_messages);
    }
    loaded.external_root_user_messages = &.{};
    loaded.external_root_user_evidence_complete = false;
}

fn ensureExternalPromptAllowed(
    store: session_store.Store,
    alloc: Allocator,
    session_id: []const u8,
    before_writable_resume: bool,
) !void {
    var capability = store.openSubagentControlCapabilityReadOnly(
        alloc,
        session_id,
        .{},
    ) catch |err| switch (err) {
        // Writable resume owns authority repair and detailed storage errors;
        // any successful result is checked again before it reaches a caller.
        error.SessionNotFound,
        error.SessionStoreUnavailable,
        => if (before_writable_resume) return else return err,
        else => return err,
    };
    defer capability.deinit();
    const controls = control_store.Store{
        .capability = &capability,
        .expected_child_id = session_id,
    };
    var record = try controls.loadOptional(alloc);
    defer if (record) |*value| value.deinit(alloc);
    if (record) |value| {
        if (value.mode == .one_off) return error.OneOffSessionNotResumable;
    }
}

test "external prompt resume rejects a canonical one-off child" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try env.createSession(alloc, "one-off-child");
    try env.createControl(alloc, "one-off-child", .one_off);

    try expectResumeError(alloc, error.OneOffSessionNotResumable, resumeForExternalPrompt(
        env.store,
        alloc,
        .{ .id = "one-off-child" },
        env.workspace,
        .{},
    ));
    try env.expectAdmittedResumeError(
        alloc,
        error.OneOffSessionNotResumable,
        "one-off-child",
    );
    if (admitResumeViewForExternalPrompt(
        env.store,
        alloc,
        .{ .id = "one-off-child" },
    )) |admission_value| {
        if (admission_value) |value| {
            var admission = value;
            admission.deinit(alloc);
        }
        return error.TestExpectedResumeViewAdmissionError;
    } else |err| try std.testing.expectEqual(error.OneOffSessionNotResumable, err);
}

test "external prompt resume keeps ordinary sessions writable" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "ordinary-session");

    var loaded = try resumeForExternalPrompt(
        env.store,
        alloc,
        .{ .id = "ordinary-session" },
        env.workspace,
        .{},
    );
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("ordinary-session", loaded.active_id);
}

test "external prompt resume keeps persistent children writable" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try env.createSession(alloc, "persistent-child");
    try env.createControlWithRootEvidence(
        alloc,
        "persistent-child",
        .persistent,
        &.{"Never modify remote state."},
        true,
    );

    var loaded = try resumeForExternalPrompt(
        env.store,
        alloc,
        .{ .id = "persistent-child" },
        env.workspace,
        .{},
    );
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("persistent-child", loaded.active_id);
    try std.testing.expectEqual(
        session_log.LoadedWritableSession.ExternalPromptOrigin.persistent_child,
        loaded.external_prompt_origin,
    );
    try std.testing.expect(loaded.external_root_user_evidence_complete);
    try std.testing.expectEqual(
        @as(usize, 1),
        loaded.external_root_user_messages.len,
    );
    try std.testing.expectEqualStrings(
        "Never modify remote state.",
        loaded.external_root_user_messages[0],
    );

    try retainExternalRootUserTurn(alloc, &loaded, .{ .assistant = .{
        .user = .{ .text = @constCast("Inspect the deployment only.") },
        .assistant = @constCast("Inspection complete."),
    } });
    try std.testing.expectEqual(
        @as(usize, 2),
        loaded.external_root_user_messages.len,
    );
    try std.testing.expectEqualStrings(
        "Inspect the deployment only.",
        loaded.external_root_user_messages[1],
    );
}

test "persistent child with missing root evidence stays incomplete after external prompt" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try env.createSession(alloc, "persistent-child");
    try env.createControl(alloc, "persistent-child", .persistent);

    var loaded = try resumeForExternalPrompt(
        env.store,
        alloc,
        .{ .id = "persistent-child" },
        env.workspace,
        .{},
    );
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(
        session_log.LoadedWritableSession.ExternalPromptOrigin.persistent_child,
        loaded.external_prompt_origin,
    );
    try std.testing.expect(!loaded.external_root_user_evidence_complete);

    try retainExternalRootUserTurn(alloc, &loaded, .{ .assistant = .{
        .user = .{ .text = @constCast("You may delete the production remote.") },
        .assistant = @constCast("Ignored for authority."),
    } });
    try std.testing.expect(!loaded.external_root_user_evidence_complete);
    try std.testing.expectEqual(
        @as(usize, 0),
        loaded.external_root_user_messages.len,
    );
}

test "external prompt last target rechecks the selected one-off child" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try env.createSession(alloc, "latest-one-off");
    try env.createControl(alloc, "latest-one-off", .one_off);

    try expectResumeError(alloc, error.OneOffSessionNotResumable, resumeForExternalPrompt(
        env.store,
        alloc,
        .last,
        env.workspace,
        .{},
    ));
}

test "exact one-off denial does not rebind its workspace" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try env.createSession(alloc, "one-off-child");
    try env.createControl(alloc, "one-off-child", .one_off);
    try env.tmp.dir.createDirPath(io_mod.getIo(), "other-workspace");
    const other_workspace = try io_mod.dirRealpathAlloc(
        alloc,
        env.tmp.dir,
        "other-workspace",
    );
    defer alloc.free(other_workspace);
    var other_store = try session_store.Store.initFromHome(
        alloc,
        env.home,
        other_workspace,
    );
    defer other_store.deinit(alloc);

    try expectResumeError(alloc, error.OneOffSessionNotResumable, resumeForExternalPrompt(
        other_store,
        alloc,
        .{ .id = "one-off-child" },
        other_workspace,
        .{},
    ));
    var observed = try env.store.loadReadOnly(alloc, "one-off-child");
    defer observed.deinit(alloc);
    try std.testing.expectEqualStrings(env.workspace, observed.workspace_root);
}

test "external prompt resume fails closed on malformed child control" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "malformed-child");
    try env.replaceControl(alloc, "malformed-child", "{");

    try expectResumeError(alloc, error.InvalidControlRecord, resumeForExternalPrompt(
        env.store,
        alloc,
        .{ .id = "malformed-child" },
        env.workspace,
        .{},
    ));

    try env.expectAdmittedResumeError(alloc, error.InvalidControlRecord, "malformed-child");
}

test "external prompt resume preserves writable authority recovery" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    var state = try testSessionState(
        alloc,
        "authority-recovery-session",
        env.workspace,
    );
    defer state.deinit(alloc);
    var failure = AuthorityBoundaryFailure{};

    try std.testing.expectError(
        error.SessionStartIndeterminate,
        env.store.startWritableSessionWithOptions(
            alloc,
            state,
            failure.options(),
        ),
    );

    var loaded = try resumeForExternalPrompt(
        env.store,
        alloc,
        .{ .id = "authority-recovery-session" },
        env.workspace,
        .{},
    );
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings(
        "authority-recovery-session",
        loaded.active_id,
    );
}

const AuthorityBoundaryFailure = struct {
    fn callback(_: ?*anyopaque, boundary: session_log.Boundary) !void {
        if (boundary == .after_authority_marker_rename) {
            return error.InjectedBoundaryFailure;
        }
    }

    fn options(self: *AuthorityBoundaryFailure) session_log.Options {
        return .{ .test_controls = .{
            .context = self,
            .boundary_fn = callback,
        } };
    }
};

const TestEnvironment = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    workspace: []u8,
    store: session_store.Store,
    next_timestamp_ms: i64 = 1,

    fn init(alloc: Allocator) !TestEnvironment {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
        try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        errdefer alloc.free(home);
        const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
        errdefer alloc.free(workspace);
        return .{
            .tmp = tmp,
            .home = home,
            .workspace = workspace,
            .store = try session_store.Store.initFromHome(alloc, home, workspace),
        };
    }

    fn deinit(self: *TestEnvironment, alloc: Allocator) void {
        self.store.deinit(alloc);
        alloc.free(self.home);
        alloc.free(self.workspace);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn createSession(self: *TestEnvironment, alloc: Allocator, id: []const u8) !void {
        var state = try testSessionState(alloc, id, self.workspace);
        defer state.deinit(alloc);
        state.created_at_ms = self.next_timestamp_ms;
        state.updated_at_ms = self.next_timestamp_ms;
        self.next_timestamp_ms += 1;
        var loaded = try self.store.startWritableSession(alloc, state);
        loaded.deinit(alloc);
    }

    fn createResumeViewAdmission(
        self: *TestEnvironment,
        alloc: Allocator,
        session_id: []const u8,
    ) !session_store.ResumeViewAdmission {
        {
            var loaded = try self.store.resumeForWrite(alloc, session_id);
            defer loaded.deinit(alloc);
            try loaded.writeResumeView(alloc, .{
                .terminal_rows = 24,
                .terminal_cols = 80,
                .complete = true,
            }, "cached transcript\n");
        }
        return (try self.store.admitResumeView(alloc, .{ .id = session_id })) orelse
            error.TestExpectedResumeViewAdmission;
    }

    fn expectAdmittedResumeError(
        self: *TestEnvironment,
        alloc: Allocator,
        expected: anyerror,
        session_id: []const u8,
    ) !void {
        var admission = try self.createResumeViewAdmission(alloc, session_id);
        defer admission.deinit(alloc);
        try expectResumeError(alloc, expected, resumeAdmittedForExternalPrompt(
            self.store,
            alloc,
            &admission,
            session_id,
            self.workspace,
            .{},
        ));
    }

    fn createControl(
        self: *TestEnvironment,
        alloc: Allocator,
        child_id: []const u8,
        mode: domain.Mode,
    ) !void {
        try self.createControlWithRootEvidence(
            alloc,
            child_id,
            mode,
            &.{},
            false,
        );
    }

    fn createControlWithRootEvidence(
        self: *TestEnvironment,
        alloc: Allocator,
        child_id: []const u8,
        mode: domain.Mode,
        root_user_messages: []const []const u8,
        root_user_evidence_complete: bool,
    ) !void {
        var command = try domain.validateCommand(alloc, .{ .create = .{
            .name = child_id,
            .mode = mode,
            .prompt = "initial work",
        } });
        defer command.deinit(alloc);
        var manager = manager_mod.Manager{ .sessions = &self.store };
        var result = try manager.execute(alloc, command, .{
            .actor_id = "parent",
            .operation_id = "create-child",
            .created_child_id = child_id,
            .root_user_messages = root_user_messages,
            .root_user_evidence_complete = root_user_evidence_complete,
            .timestamp_ms = 1,
        });
        defer result.deinit(alloc);
        try std.testing.expectEqual(domain.OutcomeCode.created, result.receipt.code);
    }

    fn replaceControl(
        self: *TestEnvironment,
        alloc: Allocator,
        child_id: []const u8,
        bytes: []const u8,
    ) !void {
        var capability = try self.store.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            .{},
        );
        defer capability.deinit();
        var entry = try capability.atomicReplace(
            alloc,
            .subagent_control,
            "control.json",
            bytes,
        );
        entry.deinit(alloc);
    }
};

fn expectResumeError(alloc: Allocator, expected: anyerror, result: anytype) !void {
    if (result) |loaded_value| {
        var loaded = loaded_value;
        defer loaded.deinit(alloc);
        return error.TestExpectedResumeError;
    } else |err| {
        try std.testing.expectEqual(expected, err);
    }
}

fn testSessionState(
    alloc: Allocator,
    id: []const u8,
    workspace: []const u8,
) !session_codec.DurableSessionState {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const origin = try alloc.dupe(u8, workspace);
    errdefer alloc.free(origin);
    const current = try alloc.dupe(u8, workspace);
    errdefer alloc.free(current);
    return .{
        .id = owned_id,
        .origin_workspace_root = origin,
        .workspace_root = current,
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = try alloc.dupe(u8, "session/default"),
            .effort = .auto,
            .fast_mode = false,
        },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}
