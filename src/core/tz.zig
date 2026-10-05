//! Timezone support: TZif (RFC 8536) parsing and POSIX TZ rule evaluation.
//! Pure logic with no I/O -- callers supply file contents (e.g. /etc/localtime).
//! All offsets are seconds east of UTC (e.g. London BST = +3600).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// A local time type: UTC offset and DST flag.
pub const TtInfo = struct {
    /// Seconds east of UTC.
    utoff: i32,
    isdst: bool,
};

/// A recurring DST transition rule from a POSIX TZ string (e.g. "M3.2.0").
pub const TransitionRule = struct {
    pub const Kind = enum { month_week_day, julian, day_of_year };

    kind: Kind,
    /// julian: 1..365 (never counts Feb 29); day_of_year: 0..365 (counts Feb 29).
    day: u16 = 0,
    /// month_week_day: month 1..12.
    month: u8 = 0,
    /// month_week_day: week 1..5 (5 = last).
    week: u8 = 0,
    /// month_week_day: weekday 0..6 (0 = Sunday).
    weekday: u8 = 0,
    /// Seconds from local midnight at which the transition happens (default 02:00).
    time: i32 = 7200,
};

/// A parsed POSIX TZ string (e.g. "EST5EDT,M3.2.0,M11.1.0").
pub const PosixRule = struct {
    /// Seconds east of UTC for standard time.
    std_utoff: i32,
    /// Seconds east of UTC for DST (defaults to std + 1h when not given).
    dst_utoff: i32,
    /// DST start rule (null when the string has no DST part).
    start: ?TransitionRule,
    /// DST end rule.
    end: ?TransitionRule,

    /// Offset in effect at the given UTC instant.
    pub fn offsetAt(rule: PosixRule, epoch_secs: i64) i32 {
        const start = rule.start orelse return rule.std_utoff;
        const end = rule.end orelse return rule.std_utoff;
        const local_days = @divFloor(epoch_secs + rule.std_utoff, 86400);
        const year = yearFromEpochDays(local_days);
        const start_utc = ruleInstant(start, year) - rule.std_utoff;
        const end_utc = ruleInstant(end, year) - rule.dst_utoff;
        const in_dst = if (start_utc <= end_utc)
            (epoch_secs >= start_utc and epoch_secs < end_utc)
        else // southern hemisphere: DST wraps the year
            (epoch_secs >= start_utc or epoch_secs < end_utc);
        return if (in_dst) rule.dst_utoff else rule.std_utoff;
    }
};

/// A parsed TZif file: transition table plus an optional POSIX footer rule
/// that governs instants after the last transition.
pub const Tz = struct {
    allocator: Allocator,
    /// Sorted UTC transition instants.
    transitions: []i64,
    /// Time type index in effect after each transition.
    type_idx: []u8,
    types: []TtInfo,
    /// Footer rule (RFC 8536 section 3.3), used after the last transition.
    posix: ?PosixRule,

    /// Offset in effect at the given UTC instant.
    pub fn offsetAt(tz: Tz, epoch_secs: i64) i32 {
        if (tz.transitions.len == 0) {
            if (tz.posix) |p| return p.offsetAt(epoch_secs);
            return tz.defaultOffset();
        }
        if (epoch_secs < tz.transitions[0]) return tz.defaultOffset();
        // Binary search for the last transition at or before the instant.
        var lo: usize = 0;
        var hi: usize = tz.transitions.len - 1;
        while (lo < hi) {
            const mid = lo + (hi - lo + 1) / 2;
            if (tz.transitions[mid] <= epoch_secs) lo = mid else hi = mid - 1;
        }
        // The footer rule governs instants after the final transition.
        if (lo == tz.transitions.len - 1) {
            if (tz.posix) |p| return p.offsetAt(epoch_secs);
        }
        return tz.types[tz.type_idx[lo]].utoff;
    }

    fn defaultOffset(tz: Tz) i32 {
        for (tz.types) |t| {
            if (!t.isdst) return t.utoff;
        }
        return tz.types[0].utoff;
    }

    pub fn deinit(tz: *Tz) void {
        tz.allocator.free(tz.transitions);
        tz.allocator.free(tz.type_idx);
        tz.allocator.free(tz.types);
        tz.* = undefined;
    }
};

/// Parse a POSIX TZ string into a rule. Returns error.InvalidPosixTz when the
/// string is not valid.
pub fn parsePosixRule(text: []const u8) !PosixRule {
    var pos: usize = 0;
    const std_name = try parseName(text, pos);
    pos = std_name.end;
    const std_off = try parseOffset(text, pos);
    pos = std_off.end;

    var dst_utoff = std_off.utoff + 3600;
    var start: ?TransitionRule = null;
    var end: ?TransitionRule = null;

    if (pos < text.len) {
        const dst_name = try parseName(text, pos);
        pos = dst_name.end;
        if (pos < text.len and (text[pos] == '+' or text[pos] == '-' or std.ascii.isDigit(text[pos]))) {
            const d = try parseOffset(text, pos);
            pos = d.end;
            dst_utoff = d.utoff;
        }
        if (pos < text.len) {
            if (text[pos] != ',') return error.InvalidPosixTz;
            pos += 1;
            const s = try parseRule(text, pos);
            pos = s.end;
            start = s.rule;
            if (pos >= text.len or text[pos] != ',') return error.InvalidPosixTz;
            pos += 1;
            const e = try parseRule(text, pos);
            pos = e.end;
            end = e.rule;
        }
    }
    if (pos != text.len) return error.InvalidPosixTz;
    return .{ .std_utoff = std_off.utoff, .dst_utoff = dst_utoff, .start = start, .end = end };
}

/// Parse a TZif file (RFC 8536) into a Tz. Caller must call deinit().
pub fn parse(allocator: Allocator, data: []const u8) !Tz {
    var pos: usize = 0;
    var counts = try readHeader(data, &pos);
    const wide = data[4] >= '2';
    if (wide) {
        pos += counts.v1BlockSize();
        counts = try readHeader(data, &pos);
    }
    const timecnt = counts.timecnt;
    const typecnt = counts.typecnt;
    if (typecnt == 0) return error.InvalidTzif;

    const transitions = try allocator.alloc(i64, timecnt);
    errdefer allocator.free(transitions);
    for (transitions) |*t| {
        t.* = if (wide) readI64(data, &pos) else @as(i64, readI32(data, &pos));
    }

    const type_idx = try allocator.alloc(u8, timecnt);
    errdefer allocator.free(type_idx);
    for (type_idx) |*idx| {
        if (pos >= data.len) return error.InvalidTzif;
        idx.* = data[pos];
        if (idx.* >= typecnt) return error.InvalidTzif;
        pos += 1;
    }

    const types = try allocator.alloc(TtInfo, typecnt);
    errdefer allocator.free(types);
    for (types) |*t| {
        if (pos + 6 > data.len) return error.InvalidTzif;
        t.* = .{ .utoff = readI32(data, &pos), .isdst = data[pos] != 0 };
        pos += 2; // isdst + abbrind
    }
    // Skip the chars, leap-second, isstd and isut blocks.
    pos += counts.charcnt + counts.leapcnt * 8 + counts.isstdcnt + counts.isutcnt;
    if (pos > data.len) return error.InvalidTzif;

    // Footer: optional POSIX TZ string, newline-delimited (v2+ only).
    var posix: ?PosixRule = null;
    if (wide and pos < data.len) {
        var footer = data[pos..];
        if (footer.len > 0 and footer[0] == '\n') footer = footer[1..];
        if (footer.len > 0 and footer[footer.len - 1] == '\n') footer = footer[0 .. footer.len - 1];
        if (footer.len > 0) posix = parsePosixRule(footer) catch null;
    }

    return .{
        .allocator = allocator,
        .transitions = transitions,
        .type_idx = type_idx,
        .types = types,
        .posix = posix,
    };
}

const Counts = struct {
    isutcnt: u32,
    isstdcnt: u32,
    leapcnt: u32,
    timecnt: u32,
    typecnt: u32,
    charcnt: u32,

    fn v1BlockSize(c: Counts) usize {
        return c.timecnt * 4 + c.timecnt + c.typecnt * 6 + c.charcnt + c.leapcnt * 8 + c.isstdcnt + c.isutcnt;
    }
};

fn readHeader(data: []const u8, pos: *usize) !Counts {
    if (pos.* + 44 > data.len) return error.InvalidTzif;
    const hdr = data[pos.*..];
    if (!std.mem.eql(u8, hdr[0..4], "TZif")) return error.InvalidTzif;
    const counts = Counts{
        .isutcnt = std.mem.readInt(u32, hdr[20..24], .big),
        .isstdcnt = std.mem.readInt(u32, hdr[24..28], .big),
        .leapcnt = std.mem.readInt(u32, hdr[28..32], .big),
        .timecnt = std.mem.readInt(u32, hdr[32..36], .big),
        .typecnt = std.mem.readInt(u32, hdr[36..40], .big),
        .charcnt = std.mem.readInt(u32, hdr[40..44], .big),
    };
    pos.* += 44;
    return counts;
}

fn readI32(data: []const u8, pos: *usize) i32 {
    const v = std.mem.readInt(u32, data[pos.*..][0..4], .big);
    pos.* += 4;
    return @bitCast(v);
}

fn readI64(data: []const u8, pos: *usize) i64 {
    const v = std.mem.readInt(u64, data[pos.*..][0..8], .big);
    pos.* += 8;
    return @bitCast(v);
}

fn parseName(text: []const u8, pos: usize) !struct { end: usize } {
    if (pos >= text.len) return error.InvalidPosixTz;
    if (text[pos] == '<') {
        const close = std.mem.indexOfScalarPos(u8, text, pos + 1, '>') orelse return error.InvalidPosixTz;
        if (close < pos + 2) return error.InvalidPosixTz;
        return .{ .end = close + 1 };
    }
    var end = pos;
    while (end < text.len and std.ascii.isAlphabetic(text[end])) : (end += 1) {}
    if (end - pos < 3) return error.InvalidPosixTz;
    return .{ .end = end };
}

/// POSIX offsets are "time to add to local to get UTC" (west positive),
/// so the returned utoff is seconds east of UTC (negated).
fn parseOffset(text: []const u8, pos: usize) !struct { utoff: i32, end: usize } {
    var i = pos;
    var sign: i32 = 1;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) {
        if (text[i] == '-') sign = -1;
        i += 1;
    }
    const parts = try parseTimeParts(text, i);
    return .{ .utoff = -sign * parts.secs, .end = parts.end };
}

fn parseRule(text: []const u8, pos: usize) !struct { rule: TransitionRule, end: usize } {
    var rule: TransitionRule = undefined;
    var i = pos;
    if (i >= text.len) return error.InvalidPosixTz;
    if (text[i] == 'M') {
        i += 1;
        const m = try parseNum(text, &i, 2);
        if (m < 1 or m > 12 or i >= text.len or text[i] != '.') return error.InvalidPosixTz;
        i += 1;
        const w = try parseNum(text, &i, 1);
        if (w < 1 or w > 5 or i >= text.len or text[i] != '.') return error.InvalidPosixTz;
        i += 1;
        const d = try parseNum(text, &i, 1);
        if (d > 6) return error.InvalidPosixTz;
        rule = .{ .kind = .month_week_day, .month = @intCast(m), .week = @intCast(w), .weekday = @intCast(d) };
    } else if (text[i] == 'J') {
        i += 1;
        const n = try parseNum(text, &i, 3);
        if (n < 1 or n > 365) return error.InvalidPosixTz;
        rule = .{ .kind = .julian, .day = @intCast(n) };
    } else {
        const n = try parseNum(text, &i, 3);
        if (n > 365) return error.InvalidPosixTz;
        rule = .{ .kind = .day_of_year, .day = @intCast(n) };
    }
    if (i < text.len and text[i] == '/') {
        i += 1;
        var sign: i32 = 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) {
            if (text[i] == '-') sign = -1;
            i += 1;
        }
        const parts = try parseTimeParts(text, i);
        rule.time = sign * parts.secs;
        i = parts.end;
    }
    return .{ .rule = rule, .end = i };
}

fn parseNum(text: []const u8, pos: *usize, max_digits: usize) !i64 {
    const start = pos.*;
    while (pos.* < text.len and std.ascii.isDigit(text[pos.*]) and pos.* - start < max_digits) : (pos.* += 1) {}
    if (pos.* == start) return error.InvalidPosixTz;
    return std.fmt.parseInt(i64, text[start..pos.*], 10);
}

fn parseTimeParts(text: []const u8, pos: usize) !struct { secs: i32, end: usize } {
    var i = pos;
    const h = try parseNum(text, &i, 2);
    var total = h * 3600;
    if (i < text.len and text[i] == ':') {
        i += 1;
        const m = try parseNum(text, &i, 2);
        total += m * 60;
        if (i < text.len and text[i] == ':') {
            i += 1;
            total += try parseNum(text, &i, 2);
        }
    }
    return .{ .secs = @intCast(total), .end = i };
}

fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i64, month: u8) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => unreachable,
    };
}

/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
fn daysFromCivil(year: i64, month: u8, day: i64) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const shift: i64 = if (m > 2) -3 else 9;
    const doy = @divFloor(153 * (m + shift) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn yearFromEpochDays(days: i64) i64 {
    var year: i64 = 1970 + @divFloor(days, 365);
    while (daysFromCivil(year, 1, 1) > days) year -= 1;
    while (daysFromCivil(year + 1, 1, 1) <= days) year += 1;
    return year;
}

/// Naive "UTC" seconds for a rule's wall-clock transition in the given year.
/// Callers subtract the pre-transition offset to get the real UTC instant.
fn ruleInstant(rule: TransitionRule, year: i64) i64 {
    const day: i64 = switch (rule.kind) {
        .month_week_day => blk: {
            const first = daysFromCivil(year, rule.month, 1);
            const first_wd = @mod(first + 4, 7); // 0 = Sunday
            const first_match = 1 + @mod(@as(i64, rule.weekday) - first_wd + 7, 7);
            var dom = first_match + (@as(i64, rule.week) - 1) * 7;
            if (dom > daysInMonth(year, rule.month)) dom -= 7; // week 5 = last
            break :blk daysFromCivil(year, rule.month, dom);
        },
        .julian => blk: {
            const n: i64 = rule.day;
            const doy = if (isLeapYear(year) and n >= 60) n + 1 else n; // skip Feb 29
            break :blk daysFromCivil(year, 1, 1) + doy - 1;
        },
        .day_of_year => daysFromCivil(year, 1, 1) + @as(i64, rule.day),
    };
    return day * 86400 + rule.time;
}

// ==================== TESTS ====================

// Ground-truth UTC instants (verified with `date -u`):
const jan_1_2026: i64 = 1767225600; // 2026-01-01 00:00:00Z
const mar_1_0200_2026: i64 = 1772330400; // 2026-03-01 02:00:00Z
const us_spring_minus1: i64 = 1772953199; // 2026-03-08 06:59:59Z (still EST)
const us_spring: i64 = 1772953200; // 2026-03-08 07:00:00Z (EDT begins)
const uk_spring_minus1: i64 = 1774745999; // 2026-03-29 00:59:59Z (still GMT)
const uk_spring: i64 = 1774746000; // 2026-03-29 01:00:00Z (BST begins)
const jul_1_2026: i64 = 1782864000; // 2026-07-01 00:00:00Z
const oct_27_0100_2026: i64 = 1793062800; // 2026-10-27 01:00:00Z
const uk_fall_minus1: i64 = 1792889999; // 2026-10-25 00:59:59Z (still BST)
const uk_fall: i64 = 1792890000; // 2026-10-25 01:00:00Z (GMT returns)
const us_fall_minus1: i64 = 1793512799; // 2026-11-01 05:59:59Z (still EDT)
const us_fall: i64 = 1793512800; // 2026-11-01 06:00:00Z (EST returns)
const dec_31_2026: i64 = 1798758000; // 2026-12-31 23:00:00Z
const jan_1_2010: i64 = 1262304000; // 2010-01-01 00:00:00Z
const us_fall_2010: i64 = 1289109600; // 2010-11-07 06:00:00Z
const au_spring: i64 = 1791043200; // 2026-10-03 16:00:00Z (first Sun Oct, 02:00 AEST)

test "parsePosixRule UK with explicit transition times" {
    const rule = try parsePosixRule("GMT0BST,M3.5.0/1,M10.5.0/2");
    try testing.expectEqual(@as(i32, 0), rule.std_utoff);
    try testing.expectEqual(@as(i32, 3600), rule.dst_utoff);
    try testing.expectEqual(TransitionRule.Kind.month_week_day, rule.start.?.kind);
    try testing.expectEqual(@as(u8, 3), rule.start.?.month);
    try testing.expectEqual(@as(u8, 5), rule.start.?.week);
    try testing.expectEqual(@as(u8, 0), rule.start.?.weekday);
    try testing.expectEqual(@as(i32, 3600), rule.start.?.time);
    try testing.expectEqual(@as(u8, 10), rule.end.?.month);
    try testing.expectEqual(@as(i32, 7200), rule.end.?.time);
}

test "parsePosixRule US with default transition times" {
    const rule = try parsePosixRule("EST5EDT,M3.2.0,M11.1.0");
    try testing.expectEqual(@as(i32, -18000), rule.std_utoff);
    try testing.expectEqual(@as(i32, -14400), rule.dst_utoff); // default: +1h
    try testing.expectEqual(@as(i32, 7200), rule.start.?.time); // default 02:00
    try testing.expectEqual(@as(i32, 7200), rule.end.?.time);
}

test "parsePosixRule without DST" {
    const rule = try parsePosixRule("EST5");
    try testing.expectEqual(@as(i32, -18000), rule.std_utoff);
    try testing.expect(rule.start == null);
    try testing.expect(rule.end == null);
}

test "parsePosixRule southern hemisphere with bracket names" {
    const rule = try parsePosixRule("AEST-10AEDT,M10.1.0,M4.1.0/3");
    try testing.expectEqual(@as(i32, 36000), rule.std_utoff); // UTC+10
    try testing.expectEqual(@as(i32, 39600), rule.dst_utoff); // UTC+11
    try testing.expectEqual(@as(u8, 10), rule.start.?.month);
    try testing.expectEqual(@as(i32, 10800), rule.end.?.time); // /3 = 03:00
}

test "parsePosixRule Julian and day-of-year forms" {
    const julian = try parsePosixRule("STD0DST,J60,J300");
    try testing.expectEqual(TransitionRule.Kind.julian, julian.start.?.kind);
    try testing.expectEqual(@as(u16, 60), julian.start.?.day);
    try testing.expectEqual(TransitionRule.Kind.julian, julian.end.?.kind);
    try testing.expectEqual(@as(u16, 300), julian.end.?.day);

    const doy = try parsePosixRule("STD0DST,59,300");
    try testing.expectEqual(TransitionRule.Kind.day_of_year, doy.start.?.kind);
    try testing.expectEqual(@as(u16, 59), doy.start.?.day);
}

test "parsePosixRule rejects garbage" {
    try testing.expectError(error.InvalidPosixTz, parsePosixRule(""));
    try testing.expectError(error.InvalidPosixTz, parsePosixRule("AB"));
    try testing.expectError(error.InvalidPosixTz, parsePosixRule("EST5EDT,M3.2.0")); // missing end rule
    try testing.expectError(error.InvalidPosixTz, parsePosixRule("EST5EDT,M13.2.0,M11.1.0")); // bad month
    try testing.expectError(error.InvalidPosixTz, parsePosixRule("EST5EDT,M3.2.9,M11.1.0")); // bad weekday
}

test "posixRule offsetAt US transitions in 2026" {
    const rule = try parsePosixRule("EST5EDT,M3.2.0,M11.1.0");
    try testing.expectEqual(@as(i32, -18000), rule.offsetAt(jan_1_2026));
    try testing.expectEqual(@as(i32, -18000), rule.offsetAt(us_spring_minus1));
    try testing.expectEqual(@as(i32, -14400), rule.offsetAt(us_spring));
    try testing.expectEqual(@as(i32, -14400), rule.offsetAt(jul_1_2026));
    try testing.expectEqual(@as(i32, -14400), rule.offsetAt(us_fall_minus1));
    try testing.expectEqual(@as(i32, -18000), rule.offsetAt(us_fall));
    try testing.expectEqual(@as(i32, -18000), rule.offsetAt(dec_31_2026));
}

test "posixRule offsetAt UK transitions in 2026" {
    const rule = try parsePosixRule("GMT0BST,M3.5.0/1,M10.5.0/2");
    try testing.expectEqual(@as(i32, 0), rule.offsetAt(jan_1_2026));
    try testing.expectEqual(@as(i32, 0), rule.offsetAt(uk_spring_minus1));
    try testing.expectEqual(@as(i32, 3600), rule.offsetAt(uk_spring));
    try testing.expectEqual(@as(i32, 3600), rule.offsetAt(jul_1_2026));
    try testing.expectEqual(@as(i32, 3600), rule.offsetAt(uk_fall_minus1));
    try testing.expectEqual(@as(i32, 0), rule.offsetAt(uk_fall));
}

test "posixRule offsetAt southern hemisphere wraps the year" {
    const rule = try parsePosixRule("AEST-10AEDT,M10.1.0,M4.1.0/3");
    // January is DST (started Oct 2025, ends Apr 2026)
    try testing.expectEqual(@as(i32, 39600), rule.offsetAt(jan_1_2026));
    // July is standard time
    try testing.expectEqual(@as(i32, 36000), rule.offsetAt(jul_1_2026));
    // DST began 2026-10-04 16:00:00Z
    try testing.expectEqual(@as(i32, 36000), rule.offsetAt(au_spring - 1));
    try testing.expectEqual(@as(i32, 39600), rule.offsetAt(au_spring));
}

test "posixRule offsetAt Julian day rules" {
    // J60 = Mar 1 (always), J300 = Oct 27 in 2026; times default to 02:00 local.
    const rule = try parsePosixRule("STD0DST,J60,J300");
    try testing.expectEqual(@as(i32, 0), rule.offsetAt(mar_1_0200_2026 - 1));
    try testing.expectEqual(@as(i32, 3600), rule.offsetAt(mar_1_0200_2026));
    try testing.expectEqual(@as(i32, 3600), rule.offsetAt(oct_27_0100_2026 - 1));
    try testing.expectEqual(@as(i32, 0), rule.offsetAt(oct_27_0100_2026));
}

/// Serialize a synthetic TZif file (test fixture builder).
fn buildTzif(
    allocator: Allocator,
    version: u8,
    transitions: []const i64,
    type_idx: []const u8,
    types: []const TtInfo,
    footer: ?[]const u8,
) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    const timecnt: u32 = @intCast(transitions.len);
    const typecnt: u32 = @intCast(types.len);

    const writeHeader = struct {
        fn go(b: *std.ArrayList(u8), a: Allocator, v: u8, tc: u32, ty: u32) !void {
            try b.appendSlice(a, "TZif");
            try b.append(a, v);
            try b.appendNTimes(a, 0, 15);
            const counts: [6]u32 = .{ 0, 0, 0, tc, ty, 1 }; // isutcnt, isstdcnt, leapcnt, timecnt, typecnt, charcnt
            for (counts) |c| {
                var w: [4]u8 = undefined;
                std.mem.writeInt(u32, &w, c, .big);
                try b.appendSlice(a, &w);
            }
        }
    }.go;

    const writeRest = struct {
        fn go(b: *std.ArrayList(u8), a: Allocator, idx: []const u8, ty: []const TtInfo) !void {
            try b.appendSlice(a, idx);
            for (ty) |t| {
                var w: [4]u8 = undefined;
                std.mem.writeInt(u32, &w, @bitCast(t.utoff), .big);
                try b.appendSlice(a, &w);
                try b.append(a, @intFromBool(t.isdst));
                try b.append(a, 0); // abbrind -> single shared char
            }
            try b.append(a, 0); // charcnt bytes: "\0"
        }
    }.go;

    try writeHeader(&buf, allocator, if (version >= '2') '2' else version, timecnt, typecnt);
    for (transitions) |t| {
        var w: [4]u8 = undefined;
        std.mem.writeInt(u32, &w, @bitCast(@as(i32, @intCast(t))), .big);
        try buf.appendSlice(allocator, &w);
    }
    try writeRest(&buf, allocator, type_idx, types);

    if (version >= '2') {
        try writeHeader(&buf, allocator, version, timecnt, typecnt);
        for (transitions) |t| {
            var w: [8]u8 = undefined;
            std.mem.writeInt(u64, &w, @bitCast(t), .big);
            try buf.appendSlice(allocator, &w);
        }
        try writeRest(&buf, allocator, type_idx, types);
        try buf.append(allocator, '\n');
        try buf.appendSlice(allocator, footer orelse "");
        try buf.append(allocator, '\n');
    }

    return try buf.toOwnedSlice(allocator);
}

test "parse TZif v2 and offsetAt from the transition table" {
    const transitions = [_]i64{ us_spring, us_fall };
    const idx = [_]u8{ 1, 0 };
    const types = [_]TtInfo{
        .{ .utoff = -18000, .isdst = false },
        .{ .utoff = -14400, .isdst = true },
    };
    const data = try buildTzif(testing.allocator, '2', &transitions, &idx, &types, null);
    defer testing.allocator.free(data);

    var tz = try parse(testing.allocator, data);
    defer tz.deinit();

    // Before the first transition: first non-DST type.
    try testing.expectEqual(@as(i32, -18000), tz.offsetAt(jan_1_2026));
    try testing.expectEqual(@as(i32, -18000), tz.offsetAt(us_spring_minus1));
    try testing.expectEqual(@as(i32, -14400), tz.offsetAt(us_spring));
    try testing.expectEqual(@as(i32, -14400), tz.offsetAt(jul_1_2026));
    try testing.expectEqual(@as(i32, -18000), tz.offsetAt(us_fall));
    try testing.expectEqual(@as(i32, -18000), tz.offsetAt(dec_31_2026));
}

test "parse TZif v2 with footer rule after last transition" {
    // Table ends in 2010; the footer rule must govern later instants.
    const transitions = [_]i64{ jan_1_2010, us_fall_2010 };
    const idx = [_]u8{ 1, 0 };
    const types = [_]TtInfo{
        .{ .utoff = -18000, .isdst = false },
        .{ .utoff = -14400, .isdst = true },
    };
    const data = try buildTzif(testing.allocator, '2', &transitions, &idx, &types, "EST5EDT,M3.2.0,M11.1.0");
    defer testing.allocator.free(data);

    var tz = try parse(testing.allocator, data);
    defer tz.deinit();

    // From the table (before last transition):
    try testing.expectEqual(@as(i32, -14400), tz.offsetAt(jan_1_2010 + 1));
    // From the footer rule (after last transition):
    try testing.expectEqual(@as(i32, -14400), tz.offsetAt(jul_1_2026)); // EDT
    try testing.expectEqual(@as(i32, -18000), tz.offsetAt(jan_1_2026)); // EST
}

test "parse TZif version 0 (32-bit only)" {
    const transitions = [_]i64{ us_spring, us_fall };
    const idx = [_]u8{ 1, 0 };
    const types = [_]TtInfo{
        .{ .utoff = -18000, .isdst = false },
        .{ .utoff = -14400, .isdst = true },
    };
    const data = try buildTzif(testing.allocator, 0, &transitions, &idx, &types, null);
    defer testing.allocator.free(data);

    var tz = try parse(testing.allocator, data);
    defer tz.deinit();

    try testing.expect(tz.posix == null);
    try testing.expectEqual(@as(i32, -14400), tz.offsetAt(jul_1_2026));
    try testing.expectEqual(@as(i32, -18000), tz.offsetAt(dec_31_2026));
}

test "parse TZif rejects garbage" {
    try testing.expectError(error.InvalidTzif, parse(testing.allocator, ""));
    try testing.expectError(error.InvalidTzif, parse(testing.allocator, "NOTZ"));
    const bad_type_idx = try buildTzif(testing.allocator, 0, &[_]i64{us_spring}, &[_]u8{9}, &[_]TtInfo{.{ .utoff = 0, .isdst = false }}, null);
    defer testing.allocator.free(bad_type_idx);
    try testing.expectError(error.InvalidTzif, parse(testing.allocator, bad_type_idx));
}
