const std = @import("std");
const testing = std.testing;

pub const Id = struct {
    /// Date component: YYYYMMDD
    date: Date,
    /// 4-character hex hash of the item text
    hash: [4]u8,

    pub const Date = struct {
        year: u16,
        month: u8,
        day: u8,

        /// Format as YYYYMMDD
        pub fn format(self: Date, buf: *[8]u8) []const u8 {
            return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}", .{
                self.year, self.month, self.day,
            }) catch unreachable;
        }

        /// Format as YY-MM-DD for @done timestamps
        pub fn formatShort(self: Date, buf: *[8]u8) []const u8 {
            const short_year = @as(u8, @intCast(self.year % 100));
            return std.fmt.bufPrint(buf, "{d:0>2}-{d:0>2}-{d:0>2}", .{
                short_year, self.month, self.day,
            }) catch unreachable;
        }

        pub fn eql(a: Date, b: Date) bool {
            return a.year == b.year and a.month == b.month and a.day == b.day;
        }
    };

    /// Format as [#YYYYMMDD-XXXX]
    pub fn format(self: Id, buf: *[18]u8) []const u8 {
        var date_buf: [8]u8 = undefined;
        const date_str = self.date.format(&date_buf);
        return std.fmt.bufPrint(buf, "[#{s}-{s}]", .{ date_str, self.hash }) catch unreachable;
    }

    pub fn eql(a: Id, b: Id) bool {
        return a.date.eql(b.date) and std.mem.eql(u8, &a.hash, &b.hash);
    }
};

/// Generate a backlog item ID from the item text and date.
/// The hash is deterministic: same text + same date = same ID.
pub fn generateId(text: []const u8, date: Id.Date) Id {
    // Combine date string + text for hashing
    var date_buf: [8]u8 = undefined;
    const date_str = date.format(&date_buf);

    // Simple hash: FNV-1a over (date_str + text)
    var hasher = std.hash.Fnv1a_32.init();
    hasher.update(date_str);
    hasher.update(text);
    const hash_val = hasher.final();

    // Take lower 16 bits and format as 4-char hex
    const hex_val: u16 = @truncate(hash_val);
    var hash_buf: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&hash_buf, "{x:0>4}", .{hex_val}) catch unreachable;

    return Id{
        .date = date,
        .hash = hash_buf,
    };
}

/// Parse an ID string like [#20260809-a3f2], #20260809-a3f2, or 20260809-a3f2
pub fn parse(text: []const u8) ?Id {
    // Strip surrounding [# and ] if present
    const stripped_brackets = blk: {
        if (std.mem.startsWith(u8, text, "[#") and std.mem.endsWith(u8, text, "]")) {
            break :blk text[2 .. text.len - 1];
        }
        break :blk text;
    };

    // Strip leading # if present (without brackets)
    const stripped = if (std.mem.startsWith(u8, stripped_brackets, "#"))
        stripped_brackets[1..]
    else
        stripped_brackets;

    // Expect format: YYYYMMDD-XXXX
    if (stripped.len != 13) return null;
    if (stripped[8] != '-') return null;

    const date_part = stripped[0..8];
    const hash_part = stripped[9..13];

    // Parse date
    const year = std.fmt.parseInt(u16, date_part[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, date_part[4..6], 10) catch return null;
    const day = std.fmt.parseInt(u8, date_part[6..8], 10) catch return null;

    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    return Id{
        .date = .{ .year = year, .month = month, .day = day },
        .hash = hash_part[0..4].*,
    };
}

// ==================== TESTS ====================

test "generateId is deterministic" {
    const date = Id.Date{ .year = 2026, .month = 8, .day = 9 };
    const id1 = generateId("Implement YAML parser", date);
    const id2 = generateId("Implement YAML parser", date);
    try testing.expect(id1.eql(id2));
}

test "generateId produces different hashes for different text" {
    const date = Id.Date{ .year = 2026, .month = 8, .day = 9 };
    const id1 = generateId("Implement YAML parser", date);
    const id2 = generateId("Design CLI structure", date);
    try testing.expect(!id1.eql(id2));
}

test "generateId produces different hashes for different dates" {
    const date1 = Id.Date{ .year = 2026, .month = 8, .day = 9 };
    const date2 = Id.Date{ .year = 2026, .month = 8, .day = 10 };
    const id1 = generateId("Same text", date1);
    const id2 = generateId("Same text", date2);
    try testing.expect(!id1.eql(id2));
}

test "generateId format matches [#YYYYMMDD-XXXX]" {
    const date = Id.Date{ .year = 2026, .month = 8, .day = 9 };
    const id = generateId("test item", date);
    var buf: [18]u8 = undefined;
    const formatted = id.format(&buf);
    // Should start with [#
    try testing.expectEqualStrings("[#", formatted[0..2]);
    // Should end with ]
    try testing.expectEqual(@as(u8, ']'), formatted[formatted.len - 1]);
    // Should have - at position 11
    try testing.expectEqual(@as(u8, '-'), formatted[10]);
    // Total length: [ + # + 8 date + - + 4 hash + ] = 16
    try testing.expectEqual(@as(usize, 16), formatted.len);
}

test "Id.format produces correct output" {
    const id = Id{
        .date = .{ .year = 2026, .month = 8, .day = 9 },
        .hash = "a3f2".*,
    };
    var buf: [18]u8 = undefined;
    try testing.expectEqualStrings("[#20260809-a3f2]", id.format(&buf));
}

test "Date.format produces YYYYMMDD" {
    const date = Id.Date{ .year = 2026, .month = 1, .day = 5 };
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("20260105", date.format(&buf));
}

test "Date.formatShort produces YY-MM-DD" {
    const date = Id.Date{ .year = 2026, .month = 8, .day = 9 };
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("26-08-09", date.formatShort(&buf));
}

test "parse valid ID with brackets" {
    const id = parse("[#20260809-a3f2]").?;
    try testing.expectEqual(@as(u16, 2026), id.date.year);
    try testing.expectEqual(@as(u8, 8), id.date.month);
    try testing.expectEqual(@as(u8, 9), id.date.day);
    try testing.expectEqualStrings("a3f2", &id.hash);
}

test "parse valid ID without brackets" {
    const id = parse("20260809-a3f2").?;
    try testing.expectEqual(@as(u16, 2026), id.date.year);
    try testing.expectEqualStrings("a3f2", &id.hash);
}

test "parse returns null for invalid format" {
    try testing.expect(parse("invalid") == null);
    try testing.expect(parse("[#2026080]") == null);
    try testing.expect(parse("[#20260809]") == null);
    try testing.expect(parse("202608-abc") == null);
}

test "parse returns null for invalid date" {
    try testing.expect(parse("[#20261301-a3f2]") == null); // month 13
    try testing.expect(parse("[#20260832-a3f2]") == null); // day 32
}

test "roundtrip: generate then parse" {
    const date = Id.Date{ .year = 2026, .month = 8, .day = 9 };
    const original = generateId("backlog item text", date);
    var buf: [18]u8 = undefined;
    const formatted = original.format(&buf);
    const parsed = parse(formatted).?;
    try testing.expect(original.eql(parsed));
}
