const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const yaml = @import("yaml.zig");

/// Build an overview.md file content from project metadata.
pub fn buildOverview(
    allocator: Allocator,
    project_name: []const u8,
    description: ?[]const u8,
    repo: ?[]const u8,
    tech: ?[]const []const u8,
    status: []const u8,
) Allocator.Error![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.print(allocator, "---\nproject: {s}\nstatus: {s}\n", .{ project_name, status });
    if (repo) |r| {
        try buf.print(allocator, "repo: {s}\n", .{r});
    }
    if (tech) |t| {
        try buf.appendSlice(allocator, "tech:\n");
        for (t) |item| {
            try buf.print(allocator, "  - {s}\n", .{item});
        }
    }
    try buf.print(allocator, "tags:\n  - project-overview\n---\n\n", .{});
    try buf.print(allocator, "# {s}\n\n", .{project_name});
    if (description) |d| {
        try buf.print(allocator, "{s}\n", .{d});
    }

    return try buf.toOwnedSlice(allocator);
}

/// Parse project info from overview.md content.
pub const ProjectInfo = struct {
    name: []const u8,
    status: []const u8,
    repo: ?[]const u8,
    tech: ?[][]const u8,
    description: ?[]const u8,
    allocator: Allocator,

    pub fn deinit(self: *const ProjectInfo) void {
        self.allocator.free(self.name);
        self.allocator.free(self.status);
        if (self.repo) |r| self.allocator.free(r);
        if (self.tech) |t| {
            for (t) |item| self.allocator.free(item);
            self.allocator.free(t);
        }
        if (self.description) |d| self.allocator.free(d);
    }
};

pub fn parseOverview(allocator: Allocator, content: []const u8) !?ProjectInfo {
    const fm = @import("frontmatter.zig");
    const ext = fm.extract(content) orelse return null;
    const parsed = try yaml.parse(allocator, ext.frontmatter_raw);
    defer parsed.deinit();

    // Copy strings out of the parsed result before deinit frees them
    const name = try allocator.dupe(u8, parsed.getString("project") orelse "unknown");
    errdefer allocator.free(name);
    const status = try allocator.dupe(u8, parsed.getString("status") orelse "unknown");
    errdefer allocator.free(status);

    const repo: ?[]const u8 = if (parsed.getString("repo")) |r| try allocator.dupe(u8, r) else null;
    errdefer if (repo) |r| allocator.free(r);

    var tech_list: ?[][]const u8 = null;
    if (parsed.getList("tech")) |t| {
        var copied = try allocator.alloc([]const u8, t.len);
        for (t, 0..) |item, i| {
            copied[i] = try allocator.dupe(u8, item);
        }
        tech_list = copied;
    }

    const body_copy: ?[]const u8 = if (ext.body.len > 0) try allocator.dupe(u8, ext.body) else null;

    return ProjectInfo{
        .name = name,
        .status = status,
        .repo = repo,
        .tech = tech_list,
        .description = body_copy,
        .allocator = allocator,
    };
}

// ==================== TESTS ====================

test "buildOverview minimal" {
    const note = try buildOverview(testing.allocator, "DevJournal", null, null, null, "active");
    defer testing.allocator.free(note);

    try testing.expect(std.mem.indexOf(u8, note, "project: DevJournal") != null);
    try testing.expect(std.mem.indexOf(u8, note, "status: active") != null);
    try testing.expect(std.mem.indexOf(u8, note, "# DevJournal") != null);
    try testing.expect(std.mem.indexOf(u8, note, "- project-overview") != null);
}

test "buildOverview with all fields" {
    const tech = [_][]const u8{ "Zig", "Shell" };
    const note = try buildOverview(
        testing.allocator,
        "DevJournal",
        "CLI tool for coding journals",
        "dd/DevJournal",
        &tech,
        "active",
    );
    defer testing.allocator.free(note);

    try testing.expect(std.mem.indexOf(u8, note, "repo: dd/DevJournal") != null);
    try testing.expect(std.mem.indexOf(u8, note, "  - Zig") != null);
    try testing.expect(std.mem.indexOf(u8, note, "  - Shell") != null);
    try testing.expect(std.mem.indexOf(u8, note, "CLI tool for coding journals") != null);
}

test "parseOverview from content" {
    const content =
        \\---
        \\project: DevJournal
        \\status: active
        \\repo: dd/DevJournal
        \\tech:
        \\  - Zig
        \\  - Shell
        \\tags:
        \\  - project-overview
        \\---
        \\
        \\# DevJournal
        \\
        \\CLI tool for coding journals.
    ;
    var info = (try parseOverview(testing.allocator, content)).?;
    defer info.deinit();
    try testing.expectEqualStrings("DevJournal", info.name);
    try testing.expectEqualStrings("active", info.status);
    try testing.expectEqualStrings("dd/DevJournal", info.repo.?);
    const tech = info.tech.?;
    try testing.expectEqual(@as(usize, 2), tech.len);
    try testing.expectEqualStrings("Zig", tech[0]);
}

test "parseOverview returns null for no frontmatter" {
    const content = "# Just a heading";
    try testing.expect((try parseOverview(testing.allocator, content)) == null);
}

test "roundtrip: build then parse" {
    const tech = [_][]const u8{ "Zig", "Shell" };
    const built = try buildOverview(
        testing.allocator,
        "DevJournal",
        "A tool",
        "dd/DevJournal",
        &tech,
        "active",
    );
    defer testing.allocator.free(built);

    var info = (try parseOverview(testing.allocator, built)).?;
    defer info.deinit();
    try testing.expectEqualStrings("DevJournal", info.name);
    try testing.expectEqualStrings("active", info.status);
    try testing.expectEqualStrings("dd/DevJournal", info.repo.?);
    const parsed_tech = info.tech.?;
    try testing.expectEqual(@as(usize, 2), parsed_tech.len);
    try testing.expectEqualStrings("Zig", parsed_tech[0]);
    try testing.expectEqualStrings("Shell", parsed_tech[1]);
}

/// Summary of project activity.
pub const ProjectSummary = struct {
    session_count: usize,
    total_entries: usize,
    sessions: []const SessionActivity,

    pub const SessionActivity = struct {
        date: []const u8,
        topic: []const u8,
        entry_count: usize,
    };
};

/// Build a project summary from session filenames and their entry counts.
/// Filenames should be session-formatted: "YYYY-MM-DD Topic.md"
/// Each entry_count corresponds to the number of daily entries for that session.
pub fn buildSummary(
    allocator: Allocator,
    session_dates: []const []const u8,
    session_topics: []const []const u8,
    session_entry_counts: []const usize,
) Allocator.Error!ProjectSummary {
    var total: usize = 0;
    for (session_entry_counts) |c| total += c;

    var activities = std.ArrayListUnmanaged(ProjectSummary.SessionActivity).empty;
    errdefer activities.deinit(allocator);

    for (session_dates, session_topics, session_entry_counts) |date, topic, count| {
        try activities.append(allocator, .{
            .date = date,
            .topic = topic,
            .entry_count = count,
        });
    }

    return ProjectSummary{
        .session_count = session_dates.len,
        .total_entries = total,
        .sessions = try activities.toOwnedSlice(allocator),
    };
}

test "buildSummary aggregates session data" {
    const dates = [_][]const u8{ "2026-08-08", "2026-08-09" };
    const topics = [_][]const u8{ "Setup", "Build backlog" };
    const counts = [_]usize{ 3, 5 };

    const summary = try buildSummary(testing.allocator, &dates, &topics, &counts);
    defer testing.allocator.free(summary.sessions);

    try testing.expectEqual(@as(usize, 2), summary.session_count);
    try testing.expectEqual(@as(usize, 8), summary.total_entries);
    try testing.expectEqualStrings("Setup", summary.sessions[0].topic);
    try testing.expectEqualStrings("Build backlog", summary.sessions[1].topic);
    try testing.expectEqual(@as(usize, 5), summary.sessions[1].entry_count);
}
