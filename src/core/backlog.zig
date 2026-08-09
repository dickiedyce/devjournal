const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ids = @import("ids.zig");

pub const Priority = enum {
    high,
    medium,
    low,

    pub fn fromTag(tag: []const u8) ?Priority {
        if (std.mem.eql(u8, tag, "@high")) return .high;
        if (std.mem.eql(u8, tag, "@medium")) return .medium;
        if (std.mem.eql(u8, tag, "@low")) return .low;
        return null;
    }

    pub fn toTag(self: Priority) []const u8 {
        return switch (self) {
            .high => "@high",
            .medium => "@medium",
            .low => "@low",
        };
    }
};

pub const BacklogItem = struct {
    checked: bool,
    id: ?ids.Id,
    text: []const u8,
    priority: ?Priority,
    done_timestamp: ?[]const u8,
    /// The full original line (trimmed)
    raw_line: []const u8,
};

/// Parse all backlog items from file content.
/// Items are single lines matching: `- [ ] ...` or `- [x] ...`
/// Returns a list of parsed items. The caller provides an arena or manages memory.
pub fn parseItems(allocator: Allocator, content: []const u8) Allocator.Error![]BacklogItem {
    var items = std.ArrayListUnmanaged(BacklogItem).empty;
    errdefer items.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (parseItemLine(trimmed)) |item| {
            try items.append(allocator, item);
        }
    }

    return try items.toOwnedSlice(allocator);
}

/// Parse a single backlog line. Returns null if it's not a backlog item line.
pub fn parseItemLine(line: []const u8) ?BacklogItem {
    const trimmed = std.mem.trim(u8, line, " \t\r");

    // Must start with "- [ ]" or "- [x]" or "- [X]"
    if (trimmed.len < 6) return null;
    if (trimmed[0] != '-') return null;
    if (trimmed[1] != ' ') return null;
    if (trimmed[2] != '[') return null;

    const check_char = trimmed[3];
    if (check_char != ' ' and check_char != 'x' and check_char != 'X') return null;
    if (trimmed[4] != ']') return null;
    if (trimmed[5] != ' ') return null;

    const checked = check_char == 'x' or check_char == 'X';
    const rest = std.mem.trim(u8, trimmed[6..], " \t");

    // Try to extract ID: [#YYYYMMDD-XXXX]
    var item_id: ?ids.Id = null;
    var text_start: usize = 0;

    if (rest.len >= 18 and rest[0] == '[' and rest[1] == '#') {
        // Find closing ]
        if (std.mem.indexOfScalar(u8, rest, ']')) |close| {
            const id_str = rest[1..close]; // e.g. #20260809-a3f2
            // Strip the leading # for parsing
            if (ids.parse(id_str)) |parsed_id| {
                item_id = parsed_id;
                text_start = close + 1;
                // Skip space after ]
                if (text_start < rest.len and rest[text_start] == ' ') {
                    text_start += 1;
                }
            }
        }
    }

    const text_with_tags = if (text_start < rest.len) rest[text_start..] else rest;

    // Extract priority and done timestamp from end of text
    var priority: ?Priority = null;
    var done_ts: ?[]const u8 = null;
    var text_end = text_with_tags.len;

    // Scan backwards for tags
    var remaining = text_with_tags;
    while (remaining.len > 0) {
        // Check for @done (YY-MM-DD HH:mm) at end
        if (std.mem.lastIndexOfScalar(u8, remaining, '@')) |at_pos| {
            const tag_region = remaining[at_pos..];

            if (std.mem.startsWith(u8, tag_region, "@done")) {
                done_ts = tag_region;
                remaining = remaining[0..at_pos];
                text_end = at_pos;
                // Trim trailing space
                while (text_end > 0 and remaining[text_end - 1] == ' ') {
                    text_end -= 1;
                }
                continue;
            }

            if (Priority.fromTag(tag_region)) |p| {
                priority = p;
                remaining = remaining[0..at_pos];
                text_end = at_pos;
                while (text_end > 0 and remaining[text_end - 1] == ' ') {
                    text_end -= 1;
                }
                continue;
            }
        }
        break;
    }

    const text = std.mem.trim(u8, text_with_tags[0..text_end], " \t");

    return BacklogItem{
        .checked = checked,
        .id = item_id,
        .text = text,
        .priority = priority,
        .done_timestamp = done_ts,
        .raw_line = trimmed,
    };
}

/// Build a new backlog item line.
/// Returns a formatted string: `- [ ] [#YYYYMMDD-XXXX] text`
pub fn buildItemLine(
    allocator: Allocator,
    text: []const u8,
    date: ids.Id.Date,
) Allocator.Error![]const u8 {
    const id = ids.generateId(text, date);
    var id_buf: [18]u8 = undefined;
    const id_str = id.format(&id_buf);

    return std.fmt.allocPrint(allocator, "- [ ] {s} {s}", .{ id_str, text });
}

/// Build a new backlog item line with priority.
pub fn buildItemLineWithPriority(
    allocator: Allocator,
    text: []const u8,
    date: ids.Id.Date,
    priority: Priority,
) Allocator.Error![]const u8 {
    const id = ids.generateId(text, date);
    var id_buf: [18]u8 = undefined;
    const id_str = id.format(&id_buf);

    return std.fmt.allocPrint(allocator, "- [ ] {s} {s} {s}", .{ id_str, text, priority.toTag() });
}

/// Mark a backlog item as done in the content string.
/// Finds the line containing the given ID (or text substring) and replaces it
/// with a checked version including the done timestamp.
/// Returns a new string with the modification applied.
/// The caller must free the returned string.
pub fn markDone(
    allocator: Allocator,
    content: []const u8,
    id_str: []const u8,
    timestamp: []const u8,
) (Allocator.Error || error{ItemNotFound})![]const u8 {
    // Try to parse as ID first
    const target_id = ids.parse(id_str);

    // Find the line and replace it
    var result = std.ArrayListUnmanaged(u8).empty;
    errdefer result.deinit(allocator);

    var found = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) {
            result.append(allocator, '\n') catch return error.OutOfMemory;
        }
        first = false;

        if (!found) {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (parseItemLine(trimmed)) |item| {
                const matches = blk: {
                    if (item.id != null and target_id != null) {
                        break :blk item.id.?.eql(target_id.?);
                    }
                    // Fall back to substring match on the ID string
                    if (std.mem.indexOf(u8, trimmed, id_str) != null) {
                        break :blk true;
                    }
                    break :blk false;
                };

                if (matches and !item.checked) {
                    // Replace this line
                    found = true;
                    const new_line = std.fmt.allocPrint(allocator, "- [x] {s} @done ({s})", .{
                        if (item.id) |id| blk: {
                            var id_buf: [18]u8 = undefined;
                            break :blk id.format(&id_buf);
                        } else "",
                        timestamp,
                    }) catch return error.OutOfMemory;
                    defer allocator.free(new_line);

                    // Rebuild the line with original text + priority + done
                    var rebuilt = std.ArrayListUnmanaged(u8).empty;
                    defer rebuilt.deinit(allocator);
                    rebuilt.appendSlice(allocator, "- [x] ") catch return error.OutOfMemory;
                    if (item.id) |id| {
                        var id_buf2: [18]u8 = undefined;
                        const fid = id.format(&id_buf2);
                        rebuilt.appendSlice(allocator, fid) catch return error.OutOfMemory;
                        rebuilt.append(allocator, ' ') catch return error.OutOfMemory;
                    }
                    rebuilt.appendSlice(allocator, item.text) catch return error.OutOfMemory;
                    if (item.priority) |p| {
                        rebuilt.append(allocator, ' ') catch return error.OutOfMemory;
                        rebuilt.appendSlice(allocator, p.toTag()) catch return error.OutOfMemory;
                    }
                    rebuilt.append(allocator, ' ') catch return error.OutOfMemory;
                    rebuilt.appendSlice(allocator, "@done (") catch return error.OutOfMemory;
                    rebuilt.appendSlice(allocator, timestamp) catch return error.OutOfMemory;
                    rebuilt.append(allocator, ')') catch return error.OutOfMemory;

                    result.appendSlice(allocator, rebuilt.items) catch return error.OutOfMemory;
                    continue;
                }
            }
        }

        // Copy line as-is
        result.appendSlice(allocator, line) catch return error.OutOfMemory;
    }

    if (!found) return error.ItemNotFound;
    return try result.toOwnedSlice(allocator);
}

// ==================== TESTS ====================

test "parseItemLine with ID and priority" {
    const line = "- [ ] [#20260809-a3f2] Implement YAML parser @high";
    const item = parseItemLine(line).?;
    try testing.expect(!item.checked);
    try testing.expect(item.id != null);
    try testing.expectEqualStrings("Implement YAML parser", item.text);
    try testing.expect(item.priority.? == .high);
    try testing.expect(item.done_timestamp == null);
}

test "parseItemLine done item with timestamp" {
    const line = "- [x] [#20260808-d4e9] Write ADR @done (26-08-09 14:30)";
    const item = parseItemLine(line).?;
    try testing.expect(item.checked);
    try testing.expect(item.id != null);
    try testing.expectEqualStrings("Write ADR", item.text);
    try testing.expectEqualStrings("@done (26-08-09 14:30)", item.done_timestamp.?);
}

test "parseItemLine item without ID" {
    const line = "- [ ] Some task without ID";
    const item = parseItemLine(line).?;
    try testing.expect(!item.checked);
    try testing.expect(item.id == null);
    try testing.expectEqualStrings("Some task without ID", item.text);
}

test "parseItemLine returns null for non-item lines" {
    try testing.expect(parseItemLine("# Heading") == null);
    try testing.expect(parseItemLine("") == null);
    try testing.expect(parseItemLine("Some text") == null);
    try testing.expect(parseItemLine("## Archive") == null);
}

test "parseItemLine item with medium priority" {
    const line = "- [ ] [#20260809-b7c1] Design CLI structure @medium";
    const item = parseItemLine(line).?;
    try testing.expect(item.priority.? == .medium);
}

test "parseItemLine item with no priority" {
    const line = "- [ ] [#20260809-c8d3] Write tests";
    const item = parseItemLine(line).?;
    try testing.expect(item.priority == null);
    try testing.expectEqualStrings("Write tests", item.text);
}

test "parseItems from full backlog content" {
    const content =
        \\# Backlog
        \\
        \\- [ ] [#20260809-a3f2] Task one @high
        \\- [ ] [#20260809-b7c1] Task two
        \\- [x] [#20260808-d4e9] Done task @done (26-08-09 14:30)
        \\
        \\## Archive
        \\
        \\- [x] [#20260801-abcd] Archived task @done (26-08-01 10:00)
    ;
    const items = try parseItems(testing.allocator, content);
    defer testing.allocator.free(items);
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expect(!items[0].checked);
    try testing.expect(!items[1].checked);
    try testing.expect(items[2].checked);
    try testing.expect(items[3].checked);
}

test "buildItemLine produces correct format" {
    const date = ids.Id.Date{ .year = 2026, .month = 8, .day = 9 };
    const line = try buildItemLine(testing.allocator, "Implement YAML parser", date);
    defer testing.allocator.free(line);

    // Should start with "- [ ] [#20260809-"
    try testing.expect(std.mem.startsWith(u8, line, "- [ ] [#20260809-"));
    // Should contain the text
    try testing.expect(std.mem.indexOf(u8, line, "Implement YAML parser") != null);
    // Should end with the text (no trailing tags)
    try testing.expect(std.mem.endsWith(u8, line, "Implement YAML parser"));
}

test "buildItemLineWithPriority adds tag" {
    const date = ids.Id.Date{ .year = 2026, .month = 8, .day = 9 };
    const line = try buildItemLineWithPriority(testing.allocator, "Urgent task", date, .high);
    defer testing.allocator.free(line);
    try testing.expect(std.mem.endsWith(u8, line, "@high"));
    try testing.expect(std.mem.indexOf(u8, line, "Urgent task") != null);
}

test "markDone by ID string" {
    // Build content with actually-generated IDs so they match
    const id1 = ids.generateId("Implement YAML parser", .{ .year = 2026, .month = 8, .day = 9 });
    var id1_buf: [18]u8 = undefined;
    const id1_str = id1.format(&id1_buf);

    const id2 = ids.generateId("Design CLI", .{ .year = 2026, .month = 8, .day = 9 });
    var id2_buf: [18]u8 = undefined;
    const id2_str = id2.format(&id2_buf);

    const content = try std.fmt.allocPrint(testing.allocator,
        \\# Backlog
        \\
        \\- [ ] {s} Implement YAML parser @high
        \\- [ ] {s} Design CLI
    , .{ id1_str, id2_str });
    defer testing.allocator.free(content);

    const result = try markDone(testing.allocator, content, id1_str, "26-08-09 16:00");
    defer testing.allocator.free(result);

    // The item should now be checked
    try testing.expect(std.mem.indexOf(u8, result, "- [x]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "@done (26-08-09 16:00)") != null);
    // The other item should remain unchanged
    try testing.expect(std.mem.indexOf(u8, result, "Design CLI") != null);
    try testing.expect(std.mem.indexOf(u8, result, "- [ ]") != null);
}

test "markDone preserves priority" {
    const id = ids.generateId("Task", .{ .year = 2026, .month = 8, .day = 9 });
    var id_buf: [18]u8 = undefined;
    const id_str = id.format(&id_buf);

    const content = try std.fmt.allocPrint(testing.allocator, "- [ ] {s} Task @high\n- [ ] other", .{id_str});
    defer testing.allocator.free(content);

    const result = try markDone(testing.allocator, content, id_str, "26-08-09 16:00");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "@high") != null);
    try testing.expect(std.mem.indexOf(u8, result, "@done") != null);
}

test "markDone returns error for missing item" {
    const content = "- [ ] [#20260809-a3f2] Task";
    try testing.expectError(error.ItemNotFound, markDone(testing.allocator, content, "[#99999999-xxxx]", "26-08-09 16:00"));
}

test "markDone returns error for already-done item" {
    const content = "- [x] [#20260809-a3f2] Task @done (26-08-09 10:00)";
    const id = ids.generateId("Task", .{ .year = 2026, .month = 8, .day = 9 });
    var id_buf: [18]u8 = undefined;
    const id_formatted = id.format(&id_buf);
    try testing.expectError(error.ItemNotFound, markDone(testing.allocator, content, id_formatted, "26-08-09 16:00"));
}
