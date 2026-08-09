const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ids = @import("ids.zig");

pub const Adr = struct {
    number: u32,
    title: []const u8,
    status: []const u8,
    date: ids.Id.Date,
    deciders: ?[]const []const u8,
    context: []const u8,
    decision: []const u8,
    consequences: ?[]const u8,
};

/// Build an ADR markdown document.
pub fn build(
    allocator: Allocator,
    number: u32,
    title: []const u8,
    status: []const u8,
    date: ids.Id.Date,
    deciders: ?[]const []const u8,
    context: []const u8,
    decision: []const u8,
    consequences: ?[]const u8,
) Allocator.Error![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    // Frontmatter
    var date_buf: [10]u8 = undefined;
    const date_str = formatDate(&date_buf, date);

    try buf.print(allocator, "---\nadr: {d}\ntitle: \"{s}\"\ndate: {s}\nstatus: {s}\n", .{
        number, title, date_str, status,
    });
    if (deciders) |d| {
        try buf.appendSlice(allocator, "deciders:\n");
        for (d) |person| {
            try buf.print(allocator, "  - {s}\n", .{person});
        }
    }
    try buf.appendSlice(allocator, "tags:\n  - adr\n---\n\n");

    // Body
    try buf.print(allocator, "# ADR-{d}: {s}\n\n", .{ number, title });
    try buf.print(allocator, "## Status\n\n{s}\n\n", .{status});
    try buf.print(allocator, "## Context\n\n{s}\n\n", .{context});
    try buf.print(allocator, "## Decision\n\n{s}\n\n", .{decision});
    if (consequences) |c| {
        try buf.print(allocator, "## Consequences\n\n{s}\n", .{c});
    }

    return try buf.toOwnedSlice(allocator);
}

/// Format an ADR filename: ADR-001.md
pub fn formatFilename(number: u32, buf: *[12]u8) []const u8 {
    return std.fmt.bufPrint(buf, "ADR-{d:0>3}.md", .{number}) catch unreachable;
}

/// Parse an ADR number from a filename like "ADR-001.md"
pub fn parseFilenameNumber(filename: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, filename, "ADR-")) return null;
    const rest = filename[4..];
    // Find the .md extension
    if (std.mem.indexOfScalar(u8, rest, '.')) |dot_pos| {
        return std.fmt.parseInt(u32, rest[0..dot_pos], 10) catch null;
    }
    return null;
}

fn formatDate(buf: *[10]u8, date: ids.Id.Date) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        date.year, date.month, date.day,
    }) catch unreachable;
}

/// Given a list of filenames (e.g. from a directory listing), find the highest
/// ADR number and return the next one. Returns 1 if no ADRs exist.
/// Only considers filenames matching ADR-NNN.md pattern.
pub fn nextNumber(filenames: []const []const u8) u32 {
    var max_num: u32 = 0;
    for (filenames) |fname| {
        if (parseFilenameNumber(fname)) |num| {
            if (num > max_num) max_num = num;
        }
    }
    return max_num + 1;
}

// ==================== TESTS ====================

test "build ADR document" {
    const adr = try build(
        testing.allocator,
        1,
        "Use Zig for CLI tool",
        "accepted",
        .{ .year = 2026, .month = 8, .day = 9 },
        null,
        "Need a compiled language for cross-platform CLI.",
        "Use Zig for its cross-compilation and zero dependencies.",
        null,
    );
    defer testing.allocator.free(adr);

    try testing.expect(std.mem.indexOf(u8, adr, "adr: 1") != null);
    try testing.expect(std.mem.indexOf(u8, adr, "title: \"Use Zig for CLI tool\"") != null);
    try testing.expect(std.mem.indexOf(u8, adr, "date: 2026-08-09") != null);
    try testing.expect(std.mem.indexOf(u8, adr, "status: accepted") != null);
    try testing.expect(std.mem.indexOf(u8, adr, "- adr") != null);
    try testing.expect(std.mem.indexOf(u8, adr, "# ADR-1: Use Zig for CLI tool") != null);
    try testing.expect(std.mem.indexOf(u8, adr, "## Context") != null);
    try testing.expect(std.mem.indexOf(u8, adr, "## Decision") != null);
}

test "build ADR with deciders and consequences" {
    const deciders = [_][]const u8{ "Alice", "Bob" };
    const adr = try build(
        testing.allocator,
        42,
        "Use TOML for config",
        "proposed",
        .{ .year = 2026, .month = 8, .day = 9 },
        &deciders,
        "Need a simple config format.",
        "Use TOML.",
        "Users must learn TOML syntax.",
    );
    defer testing.allocator.free(adr);

    try testing.expect(std.mem.indexOf(u8, adr, "  - Alice") != null);
    try testing.expect(std.mem.indexOf(u8, adr, "  - Bob") != null);
    try testing.expect(std.mem.indexOf(u8, adr, "## Consequences") != null);
    try testing.expect(std.mem.indexOf(u8, adr, "Users must learn TOML syntax.") != null);
}

test "formatFilename produces ADR-NNN.md" {
    var buf: [12]u8 = undefined;
    try testing.expectEqualStrings("ADR-001.md", formatFilename(1, &buf));
    try testing.expectEqualStrings("ADR-042.md", formatFilename(42, &buf));
    try testing.expectEqualStrings("ADR-999.md", formatFilename(999, &buf));
}

test "parseFilenameNumber extracts number" {
    try testing.expectEqual(@as(?u32, 1), parseFilenameNumber("ADR-001.md"));
    try testing.expectEqual(@as(?u32, 42), parseFilenameNumber("ADR-042.md"));
    try testing.expect(parseFilenameNumber("overview.md") == null);
    try testing.expect(parseFilenameNumber("ADR-.md") == null);
}

test "build ADR then verify frontmatter parseable" {
    const adr = try build(
        testing.allocator,
        5,
        "Test ADR",
        "accepted",
        .{ .year = 2026, .month = 8, .day = 9 },
        null,
        "Some context.",
        "Some decision.",
        null,
    );
    defer testing.allocator.free(adr);

    const frontmatter = @import("frontmatter.zig");
    const parsed = (try frontmatter.parseFrontmatter(testing.allocator, adr)).?;
    defer parsed.deinit();
    try testing.expectEqualStrings("accepted", parsed.getString("status").?);
}

test "nextNumber returns 1 when no ADRs exist" {
    const filenames = [_][]const u8{ "overview.md", "backlog.md" };
    try testing.expectEqual(@as(u32, 1), nextNumber(&filenames));
}

test "nextNumber returns 1 for empty list" {
    try testing.expectEqual(@as(u32, 1), nextNumber(&.{}));
}

test "nextNumber returns next after highest" {
    const filenames = [_][]const u8{ "ADR-001.md", "ADR-005.md", "ADR-003.md" };
    try testing.expectEqual(@as(u32, 6), nextNumber(&filenames));
}

test "nextNumber ignores non-ADR files" {
    const filenames = [_][]const u8{ "ADR-001.md", "overview.md", "ADR-010.md", "notes.md" };
    try testing.expectEqual(@as(u32, 11), nextNumber(&filenames));
}

test "nextNumber handles malformed ADR filenames" {
    const filenames = [_][]const u8{ "ADR-.md", "ADR-abc.md", "ADR-002.md" };
    try testing.expectEqual(@as(u32, 3), nextNumber(&filenames));
}
