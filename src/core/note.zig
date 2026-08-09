const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Build a generic note with optional frontmatter.
pub fn build(
    allocator: Allocator,
    title: []const u8,
    tags: ?[]const []const u8,
    date: ?[]const u8,
    body: []const u8,
) Allocator.Error![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    // Frontmatter
    try buf.appendSlice(allocator, "---\n");
    try buf.print(allocator, "title: \"{s}\"\n", .{title});
    if (date) |d| {
        try buf.print(allocator, "date: {s}\n", .{d});
    }
    if (tags) |t| {
        try buf.appendSlice(allocator, "tags:\n");
        for (t) |tag| {
            try buf.print(allocator, "  - {s}\n", .{tag});
        }
    }
    try buf.appendSlice(allocator, "---\n\n");
    try buf.print(allocator, "# {s}\n\n{s}\n", .{ title, body });

    return try buf.toOwnedSlice(allocator);
}

/// Parse a note title from frontmatter content (raw, not full document).
pub fn parseTitleFromFrontmatter(frontmatter_raw: []const u8) ?[]const u8 {
    // Look for: title: "value" or title: value
    var lines = std.mem.splitScalar(u8, frontmatter_raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "title:")) {
            const val = std.mem.trim(u8, trimmed[6..], " \t");
            // Strip quotes
            if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
                return val[1 .. val.len - 1];
            }
            return val;
        }
    }
    return null;
}

/// Parse a note title from a full markdown document with frontmatter.
pub fn parseTitle(content: []const u8) ?[]const u8 {
    const frontmatter = @import("frontmatter.zig");
    const ext = frontmatter.extract(content) orelse return null;
    return parseTitleFromFrontmatter(ext.frontmatter_raw);
}

// ==================== TESTS ====================

test "build note with tags and date" {
    const tags = [_][]const u8{ "til", "zig" };
    const note = try build(testing.allocator, "TIL -- Zig ArrayList", &tags, "2026-08-09", "In Zig 0.16.0, ArrayList is the unmanaged version.");
    defer testing.allocator.free(note);

    try testing.expect(std.mem.indexOf(u8, note, "title: \"TIL -- Zig ArrayList\"") != null);
    try testing.expect(std.mem.indexOf(u8, note, "date: 2026-08-09") != null);
    try testing.expect(std.mem.indexOf(u8, note, "  - til") != null);
    try testing.expect(std.mem.indexOf(u8, note, "  - zig") != null);
    try testing.expect(std.mem.indexOf(u8, note, "# TIL -- Zig ArrayList") != null);
    try testing.expect(std.mem.indexOf(u8, note, "unmanaged version") != null);
}

test "build note without tags" {
    const note = try build(testing.allocator, "Simple Note", null, null, "Just some text.");
    defer testing.allocator.free(note);
    try testing.expect(std.mem.indexOf(u8, note, "title: \"Simple Note\"") != null);
    try testing.expect(std.mem.indexOf(u8, note, "tags:") == null);
}

test "parseTitle from content" {
    const content =
        \\---
        \\title: "My Note"
        \\tags:
        \\  - test
        \\---
        \\
        \\Body here.
    ;
    const title = parseTitle(content);
    try testing.expect(title != null);
    try testing.expectEqualStrings("My Note", title.?);
}

test "parseTitle returns null for no frontmatter" {
    try testing.expect(parseTitle("# Just a heading") == null);
}
