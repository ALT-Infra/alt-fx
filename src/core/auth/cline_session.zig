const std = @import("std");
const api_key_session = @import("api_key_session.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const spec = api_key_session.StoreSpec{
    .auth_file_name = profile_paths.cline_auth_file_name,
    .mutation_lock_file_name = "cline-auth.lock",
    .provider_name = "Cline",
};

pub const Session = api_key_session.Session;
pub const DeleteOutcome = api_key_session.DeleteOutcome;
pub const validApiKey = api_key_session.validApiKey;

pub fn load(alloc: std.mem.Allocator) !?Session {
    return api_key_session.load(alloc, spec);
}

pub fn saveNewSession(alloc: std.mem.Allocator, session: Session) !void {
    return api_key_session.saveNewSession(alloc, session, spec);
}

pub fn logout() !DeleteOutcome {
    return api_key_session.logout(spec);
}
