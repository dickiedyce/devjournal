const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ids = @import("ids.zig");

/// A single entry in a daily note (timestamped line).
pub const Entry = struct {
    timestamp: []const u8, // "HH:MM"
    text: []const u8,
};

/// Format the daily note filename for a given date.
pub fn formatFilename(date: ids.Id.Date, buf: *[14]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}.md", .{
        date.year, date.month, date.day,
    }) catch unreachable;
}

/// Build an entry line for appending to a daily note.
/// Returns: `- HH:MM -- text\n`
pub fn buildEntry(allocator: Allocator, timestamp: []const u8, text: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "- {s} -- {s}\n", .{ timestamp, text });
}

/// Build a section header for a daily note.
/// Returns: `## Project -- topic\n`
pub fn buildSection(allocator: Allocator, project: []const u8, topic: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "## {s} -- {s}\n\n", .{ project, topic });
}

/// Build a session start block for a daily note.
/// Returns:
/// ```
/// ## Project -- topic
///
/// - Started: HH:MM
/// - Goal: description
/// ```
pub fn buildSessionStart(allocator: Allocator, project: []const u8, topic: []const u8, time: []const u8, goal: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\## {s} -- {s}
        \\
        \\- Started: {s}
        \\- Goal: {s}
        \\
    , .{ project, topic, time, goal });
}

/// Parse entries from daily note content.
/// Looks for lines matching: `- HH:MM -- text`
pub fn parseEntries(allocator: Allocator, content: []const u8) Allocator.Error![]Entry {
    var entries = std.ArrayListUnmanaged(Entry).empty;
    errdefer entries.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (parseEntryLine(line)) |entry| {
            try entries.append(allocator, entry);
        }
    }

    return try entries.toOwnedSlice(allocator);
}

/// Parse a single entry line. Returns null if not an entry.
pub fn parseEntryLine(line: []const u8) ?Entry {
    const trimmed = std.mem.trim(u8, line, " \t\r");

    // Must start with "- " and have "--" separator
    if (trimmed.len < 8) return null;
    if (trimmed[0] != '-' or trimmed[1] != ' ') return null;

    // Find the " -- " separator
    if (std.mem.indexOf(u8, trimmed, " -- ")) |sep_pos| {
        const timestamp = std.mem.trim(u8, trimmed[2..sep_pos], " \t");
        const text = trimmed[sep_pos + 4 ..];

        // Validate timestamp format: HH:MM
        if (timestamp.len != 5) return null;
        if (timestamp[2] != ':') return null;

        return Entry{
            .timestamp = timestamp,
            .text = text,
        };
    }

    return null;
}

// ==================== TESTS ====================

test "formatFilename produces YYYY-MM-DD.md" {
    var buf: [14]u8 = undefined;
    try testing.expectEqualStrings("2026-08-09.md", formatFilename(.{ .year = 2026, .month = 8, .day = 9 }, &buf));
    try testing.expectEqualStrings("2026-01-05.md", formatFilename(.{ .year = 2026, .month = 1, .day = 5 }, &buf));
}

test "buildEntry produces correct format" {
    const entry = try buildEntry(testing.allocator, "14:30", "Fixed the parser");
    defer testing.allocator.free(entry);
    try testing.expectEqualStrings("- 14:30 -- Fixed the parser\n", entry);
}

test "buildSection produces correct format" {
    const section = try buildSection(testing.allocator, "DevJournal", "YAML parser");
    defer testing.allocator.free(section);
    try testing.expectEqualStrings("## DevJournal -- YAML parser\n\n", section);
}

test "buildSessionStart produces correct format" {
    const block = try buildSessionStart(testing.allocator, "DevJournal", "Build backlog", "14:00", "Implement add/done commands");
    defer testing.allocator.free(block);
    const expected =
        \\## DevJournal -- Build backlog
        \\
        \\- Started: 14:00
        \\- Goal: Implement add/done commands
        \\
    ;
    try testing.expectEqualStrings(expected, block);
}

test "parseEntryLine with valid entry" {
    const entry = parseEntryLine("- 14:30 -- Fixed the parser").?;
    try testing.expectEqualStrings("14:30", entry.timestamp);
    try testing.expectEqualStrings("Fixed the parser", entry.text);
}

test "parseEntryLine returns null for non-entries" {
    try testing.expect(parseEntryLine("# Heading") == null);
    try testing.expect(parseEntryLine("- Started: 14:30") == null);
    try testing.expect(parseEntryLine("") == null);
    try testing.expect(parseEntryLine("- Goal: something") == null);
}

test "parseEntries from daily note content" {
    const content =
        \\---
        \\date: 2026-08-09
        \\---
        \\
        \\## DevJournal -- Build backlog
        \\
        \\- Started: 14:00
        \\- Goal: Implement add/done commands
        \\
        \\- 14:30 -- Parsed backlog items
        \\- 15:00 -- markDone working
        \\- 15:45 -- All tests passing
    ;
    const entries = try parseEntries(testing.allocator, content);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("14:30", entries[0].timestamp);
    try testing.expectEqualStrings("Parsed backlog items", entries[0].text);
    try testing.expectEqualStrings("15:45", entries[2].timestamp);
    try testing.expectEqualStrings("All tests passing", entries[2].text);
}

test "parseEntries returns empty for no entries" {
    const content = "# Just a heading\n\nSome text without entries.";
    const entries = try parseEntries(testing.allocator, content);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}
