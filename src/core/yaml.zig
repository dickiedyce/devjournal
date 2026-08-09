const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    list: []const []const u8,
    boolean: bool,
    null_value: void,
};

pub const ParseResult = struct {
    entries: []const Entry,
    allocator: Allocator,

    pub const Entry = struct {
        key: []const u8,
        value: Value,
    };

    pub fn get(self: *const ParseResult, key: []const u8) ?Value {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return entry.value;
            }
        }
        return null;
    }

    pub fn getString(self: *const ParseResult, key: []const u8) ?[]const u8 {
        if (self.get(key)) |v| {
            return switch (v) {
                .string => |s| s,
                else => null,
            };
        }
        return null;
    }

    pub fn getList(self: *const ParseResult, key: []const u8) ?[]const []const u8 {
        if (self.get(key)) |v| {
            return switch (v) {
                .list => |l| l,
                else => null,
            };
        }
        return null;
    }

    pub fn getBool(self: *const ParseResult, key: []const u8) ?bool {
        if (self.get(key)) |v| {
            return switch (v) {
                .boolean => |b| b,
                else => null,
            };
        }
        return null;
    }

    pub fn deinit(self: *const ParseResult) void {
        for (self.entries) |entry| {
            if (entry.value == .list) {
                self.allocator.free(entry.value.list);
            }
        }
        self.allocator.free(self.entries);
    }
};

pub const ParseError = error{
    OutOfMemory,
    InvalidYaml,
};

/// Parse a YAML subset string. Handles:
/// - Scalar strings: key: value
/// - Lists: key:\n  - item\n  - item
/// - Booleans: true/false
/// - Nulls: null, ~
/// - Quoted strings: "hello world" or 'hello world'
/// Lines starting with # are comments and are skipped.
/// Empty lines are skipped.
pub fn parse(allocator: Allocator, input: []const u8) ParseError!ParseResult {
    var entries = std.ArrayListUnmanaged(ParseResult.Entry).empty;
    errdefer {
        for (entries.items) |entry| {
            if (entry.value == .list) {
                allocator.free(entry.value.list);
            }
        }
        entries.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Check if this is a list item (starts with -)
        // List items are handled when we encounter them under a key

        // Parse key: value
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
            const key = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
            const rest = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t");

            if (key.len == 0) return error.InvalidYaml;

            if (rest.len == 0) {
                // Could be a list that follows on subsequent lines
                // Look ahead for list items
                var list_items = std.ArrayListUnmanaged([]const u8).empty;
                errdefer list_items.deinit(allocator);

                // We need to peek at remaining lines
                var remaining = lines;
                while (remaining.next()) |next_line| {
                    const next_trimmed = std.mem.trim(u8, next_line, " \t\r");
                    if (next_trimmed.len == 0) continue;
                    if (next_trimmed[0] == '#') continue;

                    if (next_trimmed.len >= 2 and next_trimmed[0] == '-' and next_trimmed[1] == ' ') {
                        const item_text = std.mem.trim(u8, next_trimmed[2..], " \t");
                        const cleaned = stripQuotes(item_text);
                        try list_items.append(allocator, cleaned);
                        // Advance the outer iterator
                        _ = lines.next();
                    } else {
                        // Not a list item, stop
                        break;
                    }
                }

                if (list_items.items.len > 0) {
                    const list_slice = try list_items.toOwnedSlice(allocator);
                    try entries.append(allocator, .{
                        .key = key,
                        .value = .{ .list = list_slice },
                    });
                } else {
                    // Empty value, treat as null
                    try entries.append(allocator, .{
                        .key = key,
                        .value = .null_value,
                    });
                }
            } else {
                const value = parseScalar(rest);
                try entries.append(allocator, .{
                    .key = key,
                    .value = value,
                });
            }
        }
    }

    return ParseResult{
        .entries = try entries.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn parseScalar(text: []const u8) Value {
    // Check boolean
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "True") or std.mem.eql(u8, text, "TRUE")) {
        return .{ .boolean = true };
    }
    if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "False") or std.mem.eql(u8, text, "FALSE")) {
        return .{ .boolean = false };
    }
    // Check null
    if (std.mem.eql(u8, text, "null") or std.mem.eql(u8, text, "Null") or std.mem.eql(u8, text, "NULL") or std.mem.eql(u8, text, "~")) {
        return .null_value;
    }
    // Otherwise it's a string (possibly quoted)
    return .{ .string = stripQuotes(text) };
}

fn stripQuotes(text: []const u8) []const u8 {
    if (text.len >= 2) {
        if ((text[0] == '"' and text[text.len - 1] == '"') or
            (text[0] == '\'' and text[text.len - 1] == '\''))
        {
            return text[1 .. text.len - 1];
        }
    }
    return text;
}

// ==================== TESTS ====================

test "parse empty input" {
    const result = try parse(testing.allocator, "");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.entries.len);
}

test "parse single scalar string" {
    const result = try parse(testing.allocator, "name: DevJournal");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.entries.len);
    try testing.expectEqualStrings("name", result.entries[0].key);
    try testing.expectEqualStrings("DevJournal", result.entries[0].value.string);
}

test "parse multiple scalars" {
    const input =
        \\name: DevJournal
        \\status: active
        \\version: 1.0
    ;
    const result = try parse(testing.allocator, input);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.entries.len);
    try testing.expectEqualStrings("name", result.entries[0].key);
    try testing.expectEqualStrings("DevJournal", result.entries[0].value.string);
    try testing.expectEqualStrings("status", result.entries[1].key);
    try testing.expectEqualStrings("active", result.entries[1].value.string);
}

test "parse list" {
    const input =
        \\tech:
        \\  - Zig
        \\  - Shell
        \\  - Markdown
    ;
    const result = try parse(testing.allocator, input);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.entries.len);
    const list = result.getList("tech").?;
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("Zig", list[0]);
    try testing.expectEqualStrings("Shell", list[1]);
    try testing.expectEqualStrings("Markdown", list[2]);
}

test "parse booleans" {
    const input =
        \\enabled: true
        \\debug: false
    ;
    const result = try parse(testing.allocator, input);
    defer result.deinit();
    try testing.expect(result.getBool("enabled").? == true);
    try testing.expect(result.getBool("debug").? == false);
}

test "parse null values" {
    const input =
        \\value: null
        \\other: ~
    ;
    const result = try parse(testing.allocator, input);
    defer result.deinit();
    try testing.expect(result.get("value").? == .null_value);
    try testing.expect(result.get("other").? == .null_value);
}

test "parse quoted strings" {
    const input =
        \\title: "Hello World"
        \\desc: 'Single quoted'
    ;
    const result = try parse(testing.allocator, input);
    defer result.deinit();
    try testing.expectEqualStrings("Hello World", result.getString("title").?);
    try testing.expectEqualStrings("Single quoted", result.getString("desc").?);
}

test "parse comments and blank lines" {
    const input =
        \\# This is a comment
        \\name: test
        \\
        \\# Another comment
        \\status: active
    ;
    const result = try parse(testing.allocator, input);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.entries.len);
    try testing.expectEqualStrings("test", result.getString("name").?);
}

test "parse mixed scalars and lists" {
    const input =
        \\project: DevJournal
        \\status: active
        \\tech:
        \\  - Zig
        \\  - Shell
        \\repo: dd/DevJournal
    ;
    const result = try parse(testing.allocator, input);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 4), result.entries.len);
    try testing.expectEqualStrings("DevJournal", result.getString("project").?);
    try testing.expectEqualStrings("active", result.getString("status").?);
    const tech = result.getList("tech").?;
    try testing.expectEqual(@as(usize, 2), tech.len);
    try testing.expectEqualStrings("dd/DevJournal", result.getString("repo").?);
}

test "get returns null for missing key" {
    const result = try parse(testing.allocator, "name: test");
    defer result.deinit();
    try testing.expect(result.get("missing") == null);
    try testing.expect(result.getString("missing") == null);
}

test "parse key with empty value is null" {
    const result = try parse(testing.allocator, "empty:");
    defer result.deinit();
    try testing.expect(result.get("empty").? == .null_value);
}
