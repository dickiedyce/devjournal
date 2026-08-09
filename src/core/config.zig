const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    /// Path to the journal folder (relative to .devjournal.toml location, or absolute)
    journal_path: []const u8,
    /// Project metadata (optional, seeded into overview.md on init)
    project_meta: ?ProjectMeta,

    pub const ProjectMeta = struct {
        description: ?[]const u8 = null,
        repo: ?[]const u8 = null,
        tech: ?[]const []const u8 = null,
        status: ?[]const u8 = null,
    };

    pub fn deinit(self: *const Config, allocator: Allocator) void {
        allocator.free(self.journal_path);
        if (self.project_meta) |meta| {
            if (meta.description) |d| allocator.free(d);
            if (meta.repo) |r| allocator.free(r);
            if (meta.tech) |t| {
                for (t) |item| allocator.free(item);
                allocator.free(t);
            }
            if (meta.status) |s| allocator.free(s);
        }
    }
};

pub const ParseError = error{
    MissingJournalPath,
    InvalidToml,
    OutOfMemory,
};

/// Parse a .devjournal.toml string into a Config.
/// Only supports the subset we need:
///   journal = "path"
///   [project_meta]
///   description = "..."
///   repo = "owner/repo"
///   tech = ["a", "b"]
///   status = "active"
pub fn parse(allocator: Allocator, input: []const u8) ParseError!Config {
    var journal_path: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var repo: ?[]const u8 = null;
    var status: ?[]const u8 = null;
    var tech_items = std.ArrayListUnmanaged([]const u8).empty;

    errdefer {
        if (journal_path) |p| allocator.free(p);
        if (description) |d| allocator.free(d);
        if (repo) |r| allocator.free(r);
        if (status) |s| allocator.free(s);
        for (tech_items.items) |item| allocator.free(item);
        tech_items.deinit(allocator);
    }

    var in_project_meta = false;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Section header
        if (trimmed[0] == '[') {
            if (std.mem.eql(u8, trimmed, "[project_meta]")) {
                in_project_meta = true;
            } else {
                in_project_meta = false;
            }
            continue;
        }

        // Key = value
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const val_raw = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            if (!in_project_meta) {
                if (std.mem.eql(u8, key, "journal")) {
                    journal_path = try allocator.dupe(u8, parseTomlString(val_raw));
                }
            } else {
                if (std.mem.eql(u8, key, "description")) {
                    description = try allocator.dupe(u8, parseTomlString(val_raw));
                } else if (std.mem.eql(u8, key, "repo")) {
                    repo = try allocator.dupe(u8, parseTomlString(val_raw));
                } else if (std.mem.eql(u8, key, "status")) {
                    status = try allocator.dupe(u8, parseTomlString(val_raw));
                } else if (std.mem.eql(u8, key, "tech")) {
                    try parseTomlStringArray(allocator, &tech_items, val_raw);
                }
            }
        }
    }

    const path = journal_path orelse return error.MissingJournalPath;

    const meta = if (description != null or repo != null or status != null or tech_items.items.len > 0)
        Config.ProjectMeta{
            .description = description,
            .repo = repo,
            .tech = if (tech_items.items.len > 0) try tech_items.toOwnedSlice(allocator) else null,
            .status = status,
        }
    else
        null;

    return Config{
        .journal_path = path,
        .project_meta = meta,
    };
}

/// Strip quotes from a TOML string value.
fn parseTomlString(val: []const u8) []const u8 {
    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
        return val[1 .. val.len - 1];
    }
    if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'') {
        return val[1 .. val.len - 1];
    }
    return val;
}

/// Parse a TOML inline array of strings: ["a", "b", "c"]
fn parseTomlStringArray(allocator: Allocator, list: *std.ArrayListUnmanaged([]const u8), val: []const u8) !void {
    // Strip [ and ]
    const inner = std.mem.trim(u8, val, " []");
    if (inner.len == 0) return;

    var items = std.mem.splitScalar(u8, inner, ',');
    while (items.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t");
        if (trimmed.len > 0) {
            try list.append(allocator, try allocator.dupe(u8, parseTomlString(trimmed)));
        }
    }
}

// ==================== TESTS ====================

test "parse minimal config" {
    const input = "journal = \"../vault/journal\"";
    const config = try parse(testing.allocator, input);
    defer config.deinit(testing.allocator);
    try testing.expectEqualStrings("../vault/journal", config.journal_path);
    try testing.expect(config.project_meta == null);
}

test "parse config with project_meta" {
    const input =
        \\journal = "/path/to/journal"
        \\
        \\[project_meta]
        \\description = "CLI tool for coding journals"
        \\repo = "dd/DevJournal"
        \\tech = ["Zig", "Shell"]
        \\status = "active"
    ;
    const config = try parse(testing.allocator, input);
    defer config.deinit(testing.allocator);
    try testing.expectEqualStrings("/path/to/journal", config.journal_path);
    const meta = config.project_meta.?;
    try testing.expectEqualStrings("CLI tool for coding journals", meta.description.?);
    try testing.expectEqualStrings("dd/DevJournal", meta.repo.?);
    try testing.expectEqualStrings("active", meta.status.?);
    const tech = meta.tech.?;
    try testing.expectEqual(@as(usize, 2), tech.len);
    try testing.expectEqualStrings("Zig", tech[0]);
    try testing.expectEqualStrings("Shell", tech[1]);
}

test "parse config with single quotes" {
    const input = "journal = '../vault/journal'";
    const config = try parse(testing.allocator, input);
    defer config.deinit(testing.allocator);
    try testing.expectEqualStrings("../vault/journal", config.journal_path);
}

test "parse config with comments" {
    const input =
        \\# This is a config file
        \\journal = "/journal"
        \\
        \\# Metadata section
        \\[project_meta]
        \\description = "Test"
    ;
    const config = try parse(testing.allocator, input);
    defer config.deinit(testing.allocator);
    try testing.expectEqualStrings("/journal", config.journal_path);
    try testing.expectEqualStrings("Test", config.project_meta.?.description.?);
}

test "parse fails without journal" {
    const input = "[project_meta]\ndescription = \"test\"";
    try testing.expectError(error.MissingJournalPath, parse(testing.allocator, input));
}

test "parse empty input fails" {
    try testing.expectError(error.MissingJournalPath, parse(testing.allocator, ""));
}

test "serialize config to TOML string" {
    const config = Config{
        .journal_path = "../vault/journal",
        .project_meta = Config.ProjectMeta{
            .description = "A tool",
            .repo = "owner/repo",
            .tech = null,
            .status = "active",
        },
    };

    const result = try serialize(testing.allocator, config);
    defer testing.allocator.free(result);

    const expected =
        \\journal = "../vault/journal"
        \\
        \\[project_meta]
        \\description = "A tool"
        \\repo = "owner/repo"
        \\status = "active"
        \\
    ;
    try testing.expectEqualStrings(expected, result);
}

/// Serialize a Config to TOML format. Caller owns the returned memory.
pub fn serialize(allocator: Allocator, config: Config) Allocator.Error![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.print(allocator, "journal = \"{s}\"\n", .{config.journal_path});
    if (config.project_meta) |meta| {
        try buf.appendSlice(allocator, "\n[project_meta]\n");
        if (meta.description) |d| try buf.print(allocator, "description = \"{s}\"\n", .{d});
        if (meta.repo) |r| try buf.print(allocator, "repo = \"{s}\"\n", .{r});
        if (meta.tech) |tech| {
            try buf.appendSlice(allocator, "tech = [");
            for (tech, 0..) |item, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.print(allocator, "\"{s}\"", .{item});
            }
            try buf.appendSlice(allocator, "]\n");
        }
        if (meta.status) |s| try buf.print(allocator, "status = \"{s}\"\n", .{s});
    }

    return try buf.toOwnedSlice(allocator);
}
