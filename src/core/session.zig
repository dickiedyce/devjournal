const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ids = @import("ids.zig");

/// Build a session note from daily entries.
/// Produces markdown with frontmatter and sections.
pub fn buildSessionNote(
    allocator: Allocator,
    project: []const u8,
    topic: []const u8,
    date: ids.Id.Date,
    entries: []const []const u8,
) Allocator.Error![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    var date_buf: [10]u8 = undefined;
    const date_str = formatDate(&date_buf, date);

    try buf.print(allocator, "---\nproject: {s}\ndate: {s}\ntags:\n  - session\n---\n\n", .{ project, date_str });
    try buf.print(allocator, "# {s}\n\n", .{topic});
    try buf.print(allocator, "## Goals\n\n", .{});
    if (entries.len == 0) {
        try buf.appendSlice(allocator, "- (no entries recorded)\n");
    }
    try buf.print(allocator, "\n## Work Log\n\n", .{});
    for (entries) |entry| {
        try buf.print(allocator, "- {s}\n", .{entry});
    }
    try buf.print(allocator, "\n## Outcomes\n\n", .{});
    try buf.print(allocator, "- Session completed with {d} entries\n", .{entries.len});

    return try buf.toOwnedSlice(allocator);
}

/// Build the session note filename.
pub fn formatFilename(date: ids.Id.Date, topic: []const u8, buf: *[128]u8) []const u8 {
    var date_buf: [10]u8 = undefined;
    const date_str = formatDate(&date_buf, date);
    return std.fmt.bufPrint(buf, "{s} {s}.md", .{ date_str, topic }) catch unreachable;
}

fn formatDate(buf: *[10]u8, date: ids.Id.Date) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        date.year, date.month, date.day,
    }) catch unreachable;
}

// ==================== TESTS ====================

test "formatFilename produces correct filename" {
    var buf: [128]u8 = undefined;
    const name = formatFilename(.{ .year = 2026, .month = 8, .day = 9 }, "Implement YAML parser", &buf);
    try testing.expectEqualStrings("2026-08-09 Implement YAML parser.md", name);
}

test "buildSessionNote with entries" {
    const entries = [_][]const u8{
        "14:30 -- Parsed backlog items",
        "15:00 -- markDone working",
    };
    const note = try buildSessionNote(
        testing.allocator,
        "DevJournal",
        "Build backlog",
        .{ .year = 2026, .month = 8, .day = 9 },
        &entries,
    );
    defer testing.allocator.free(note);

    // Should have frontmatter
    try testing.expect(std.mem.indexOf(u8, note, "---") != null);
    try testing.expect(std.mem.indexOf(u8, note, "project: DevJournal") != null);
    try testing.expect(std.mem.indexOf(u8, note, "date: 2026-08-09") != null);
    try testing.expect(std.mem.indexOf(u8, note, "- session") != null);

    // Should have topic as heading
    try testing.expect(std.mem.indexOf(u8, note, "# Build backlog") != null);

    // Should have entries in work log
    try testing.expect(std.mem.indexOf(u8, note, "Parsed backlog items") != null);
    try testing.expect(std.mem.indexOf(u8, note, "markDone working") != null);

    // Should have outcomes
    try testing.expect(std.mem.indexOf(u8, note, "2 entries") != null);
}

test "buildSessionNote with no entries" {
    const note = try buildSessionNote(
        testing.allocator,
        "DevJournal",
        "Empty session",
        .{ .year = 2026, .month = 8, .day = 9 },
        &.{},
    );
    defer testing.allocator.free(note);
    try testing.expect(std.mem.indexOf(u8, note, "(no entries recorded)") != null);
    try testing.expect(std.mem.indexOf(u8, note, "0 entries") != null);
}
