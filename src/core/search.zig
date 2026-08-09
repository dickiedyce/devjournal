const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// A search result: a matching line with its location.
pub const Match = struct {
    file: []const u8,
    line_number: usize,
    line: []const u8,
    match_start: usize,
};

/// Search content for a query string. Returns all matching lines.
/// Uses case-insensitive substring matching.
pub fn searchContent(
    allocator: Allocator,
    content: []const u8,
    query: []const u8,
    filename: []const u8,
) Allocator.Error![]Match {
    if (query.len == 0) return try allocator.alloc(Match, 0);

    var matches = std.ArrayListUnmanaged(Match).empty;
    errdefer matches.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 1;
    while (lines.next()) |line| {
        if (indexOfIgnoreCase(line, query)) |pos| {
            try matches.append(allocator, .{
                .file = filename,
                .line_number = line_num,
                .line = line,
                .match_start = pos,
            });
        }
        line_num += 1;
    }

    return try matches.toOwnedSlice(allocator);
}

/// Case-insensitive substring search. Returns the index of the first match.
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    if (needle.len == 0) return 0;

    const end = haystack.len - needle.len + 1;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        var matched = true;
        for (needle, 0..) |nc, j| {
            if (toLower(haystack[i + j]) != toLower(nc)) {
                matched = false;
                break;
            }
        }
        if (matched) return i;
    }
    return null;
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

// ==================== TESTS ====================

test "searchContent finds matching lines" {
    const content =
        \\# Backlog
        \\
        \\- [ ] [#20260809-a3f2] Implement YAML parser
        \\- [ ] [#20260809-b7c1] Design CLI structure
    ;
    const results = try searchContent(testing.allocator, content, "YAML", "backlog.md");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqual(@as(usize, 3), results[0].line_number);
    try testing.expect(std.mem.indexOf(u8, results[0].line, "YAML") != null);
}

test "searchContent case insensitive" {
    const content = "Hello World\nhello zig\nHELLO AGAIN\n";
    const results = try searchContent(testing.allocator, content, "hello", "test.md");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 3), results.len);
}

test "searchContent returns empty for no match" {
    const content = "nothing here\n";
    const results = try searchContent(testing.allocator, content, "xyz", "test.md");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "searchContent returns empty for empty query" {
    const content = "something\n";
    const results = try searchContent(testing.allocator, content, "", "test.md");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "searchContent finds multiple matches" {
    const content =
        \\fix the parser
        \\parser is done
        \\nothing here
        \\parser tests pass
    ;
    const results = try searchContent(testing.allocator, content, "parser", "daily.md");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expectEqual(@as(usize, 1), results[0].line_number);
    try testing.expectEqual(@as(usize, 2), results[1].line_number);
    try testing.expectEqual(@as(usize, 4), results[2].line_number);
}

test "indexOfIgnoreCase basic" {
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("Hello", "hello"));
    try testing.expectEqual(@as(?usize, 3), indexOfIgnoreCase("say Hello", "hello"));
    try testing.expect(indexOfIgnoreCase("world", "hello") == null);
}
