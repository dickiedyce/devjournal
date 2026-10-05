//! Core library for DevJournal.
//! Pure domain logic with no I/O dependencies.

pub const yaml = @import("core/yaml.zig");
pub const frontmatter = @import("core/frontmatter.zig");
pub const ids = @import("core/ids.zig");
pub const tz = @import("core/tz.zig");
pub const config = @import("core/config.zig");
pub const backlog = @import("core/backlog.zig");
pub const daily = @import("core/daily.zig");
pub const session = @import("core/session.zig");
pub const project = @import("core/project.zig");
pub const adr = @import("core/adr.zig");
pub const note = @import("core/note.zig");
pub const search = @import("core/search.zig");

test {
    // Pull in tests from every sub-module (lazy imports are not analyzed otherwise).
    std.testing.refAllDecls(@This());
    _ = yaml;
    _ = frontmatter;
    _ = ids;
    _ = tz;
    _ = config;
    _ = backlog;
    _ = daily;
    _ = session;
    _ = project;
    _ = adr;
    _ = note;
    _ = search;
}

const std = @import("std");
