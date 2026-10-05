const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const yaml = @import("yaml.zig");

/// Result of extracting frontmatter from a markdown document.
pub const Extraction = struct {
    /// The raw frontmatter text between the --- delimiters (trimmed).
    frontmatter_raw: []const u8,
    /// The body content after the closing ---.
    body: []const u8,
};

/// Extract frontmatter from a markdown string.
/// Frontmatter is the YAML block between the first `---` and the next `---`.
/// Returns null if no frontmatter is found.
pub fn extract(input: []const u8) ?Extraction {
    if (input.len < 3) return null;
    if (!std.mem.startsWith(u8, std.mem.trimStart(u8, input, " \t\r\n"), "---")) return null;

    // Find start of frontmatter content (after first ---)
    const after_first = if (std.mem.indexOfScalar(u8, input, '-')) |pos|
        pos + 3
    else
        return null;

    // Skip to next line after opening ---
    const content_start = if (std.mem.indexOfScalar(u8, input[after_first..], '\n')) |nl|
        after_first + nl + 1
    else
        return null;

    // Find closing ---
    const remaining = input[content_start..];
    if (std.mem.indexOf(u8, remaining, "\n---")) |close_pos| {
        const fm_raw = std.mem.trim(u8, remaining[0..close_pos], " \t\r\n");
        const body_start = content_start + close_pos + 4; // skip \n---
        const body_rest = input[body_start..];
        // Skip leading newlines after closing ---
        const body = std.mem.trimStart(u8, body_rest, "\r\n");

        return Extraction{
            .frontmatter_raw = fm_raw,
            .body = body,
        };
    }

    return null;
}

/// Parse the YAML frontmatter from a markdown string.
pub fn parseFrontmatter(allocator: Allocator, input: []const u8) !?yaml.ParseResult {
    const ext = extract(input) orelse return null;
    return try yaml.parse(allocator, ext.frontmatter_raw);
}

/// Build a markdown string with the given frontmatter and body.
/// If frontmatter_text is empty, returns just the body.
/// Caller owns the returned memory.
pub fn build(allocator: Allocator, frontmatter_text: ?[]const u8, body: []const u8) Allocator.Error![]const u8 {
    if (frontmatter_text) |fm| {
        if (fm.len > 0) {
            return allocator.print("---\n{s}\n---\n\n{s}", .{ fm, body });
        }
    }
    return try allocator.dupe(u8, body);
}

// ==================== TESTS ====================

test "extract frontmatter from simple document" {
    const input =
        \\---
        \\name: DevJournal
        \\status: active
        \\---
        \\
        \\# Hello
        \\
        \\Some content here.
    ;
    const ext = extract(input).?;
    try testing.expectEqualStrings("name: DevJournal\nstatus: active", ext.frontmatter_raw);
    try testing.expectEqualStrings("# Hello\n\nSome content here.", ext.body);
}

test "extract returns null for no frontmatter" {
    const input = "# Just a heading\n\nSome content.";
    try testing.expect(extract(input) == null);
}

test "extract returns null for empty input" {
    try testing.expect(extract("") == null);
}

test "extract handles frontmatter with no body" {
    const input =
        \\---
        \\name: test
        \\---
    ;
    const ext = extract(input).?;
    try testing.expectEqualStrings("name: test", ext.frontmatter_raw);
    try testing.expectEqualStrings("", ext.body);
}

test "extract handles leading whitespace before ---" {
    const input =
        \\   
        \\---
        \\title: Hello
        \\---
        \\Body text
    ;
    const ext = extract(input).?;
    try testing.expectEqualStrings("title: Hello", ext.frontmatter_raw);
    try testing.expectEqualStrings("Body text", ext.body);
}

test "parseFrontmatter returns parsed YAML" {
    const input =
        \\---
        \\project: DevJournal
        \\status: active
        \\tech:
        \\  - Zig
        \\  - Shell
        \\---
        \\
        \\# Content
    ;
    const result = (try parseFrontmatter(testing.allocator, input)).?;
    defer result.deinit();
    try testing.expectEqualStrings("DevJournal", result.getString("project").?);
    try testing.expectEqualStrings("active", result.getString("status").?);
    const tech = result.getList("tech").?;
    try testing.expectEqual(@as(usize, 2), tech.len);
}

test "parseFrontmatter returns null for no frontmatter" {
    const input = "# No frontmatter here";
    try testing.expect((try parseFrontmatter(testing.allocator, input)) == null);
}

test "build document with frontmatter" {
    const result = try build(testing.allocator, "name: test\nstatus: active", "# Hello\n\nContent");
    defer testing.allocator.free(result);
    const expected = "---\nname: test\nstatus: active\n---\n\n# Hello\n\nContent";
    try testing.expectEqualStrings(expected, result);
}

test "build document without frontmatter" {
    const result = try build(testing.allocator, null, "# Just content");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("# Just content", result);
}
