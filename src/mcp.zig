const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Parsed JSON-RPC request fields.
pub const Request = struct {
    id: ?i64,
    method: []const u8,
    /// Raw params JSON string (caller extracts fields)
    params_raw: ?[]const u8,
};

/// Parse a JSON-RPC request from a line of text.
/// Returns a Request with the id, method, and raw params JSON.
pub fn parseRequest(allocator: Allocator, line: []const u8) !Request {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value;
    const obj = root.object;

    const id: ?i64 = if (obj.get("id")) |v| switch (v) {
        .integer => |i| @intCast(i),
        else => null,
    } else null;

    const method = if (obj.get("method")) |v| v.string else "";

    // For params, we re-serialize just that field to a string
    var params_raw: ?[]const u8 = null;
    if (obj.get("params")) |p| {
        params_raw = try serializeValue(allocator, p);
    }

    return Request{
        .id = id,
        .method = method,
        .params_raw = params_raw,
    };
}

/// Serialize a std.json.Value to a JSON string. Caller owns memory.
pub fn serializeValue(allocator: Allocator, val: std.json.Value) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try serializeValueInner(allocator, &buf, val);
    return try buf.toOwnedSlice(allocator);
}

fn serializeValueInner(allocator: Allocator, buf: *std.ArrayList(u8), val: std.json.Value) !void {
    switch (val) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| try buf.print(allocator, "{d}", .{i}),
        .float => |f| try buf.print(allocator, "{d}", .{f}),
        .string => |s| {
            try buf.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    '\n' => try buf.appendSlice(allocator, "\\n"),
                    '\r' => try buf.appendSlice(allocator, "\\r"),
                    '\t' => try buf.appendSlice(allocator, "\\t"),
                    else => try buf.append(allocator, c),
                }
            }
            try buf.append(allocator, '"');
        },
        .number_string => |s| try buf.appendSlice(allocator, s),
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buf.append(allocator, ',');
                try serializeValueInner(allocator, buf, item);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            var iter = obj.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try buf.print(allocator, "\"{s}\":", .{entry.key_ptr.*});
                try serializeValueInner(allocator, buf, entry.value_ptr.*);
            }
            try buf.append(allocator, '}');
        },
    }
}

/// Build a JSON-RPC success response string.
pub fn buildResponse(allocator: Allocator, id: ?i64, result_json: []const u8) ![]const u8 {
    if (id) |i| {
        return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ i, result_json });
    }
    return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":{s}}}", .{result_json});
}

/// Build a JSON-RPC error response string.
pub fn buildErrorResponse(allocator: Allocator, id: ?i64, code: i32, message: []const u8) ![]const u8 {
    if (id) |i| {
        return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ i, code, message });
    }
    return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ code, message });
}

/// Build a tools/call result with text content.
pub fn buildToolResultText(allocator: Allocator, text: []const u8, is_error: bool) ![]const u8 {
    if (is_error) {
        return std.fmt.allocPrint(allocator, "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"isError\":true}}", .{text});
    }
    return std.fmt.allocPrint(allocator, "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}", .{text});
}

/// Build a tools/list result JSON string.
pub fn buildToolsList(allocator: Allocator, tools: []const Tool) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"tools\":[");
    for (tools, 0..) |tool, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.print(allocator, "{{\"name\":\"{s}\",\"description\":\"{s}\",\"inputSchema\":{s}}}", .{
            tool.name, tool.description, tool.input_schema_json,
        });
    }
    try buf.appendSlice(allocator, "]}");
    return try buf.toOwnedSlice(allocator);
}

/// Build an initialize result JSON string.
pub fn buildInitializeResult(allocator: Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"protocolVersion":"2024-11-05","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"devjournal-mcp","version":"0.3.0"}}}}
    , .{});
}

/// MCP tool definition.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
};

/// Read all remaining input from a reader. Caller owns memory.
pub fn readAll(allocator: Allocator, reader: *Io.Reader) ![]const u8 {
    return try reader.allocRemaining(allocator, .unlimited);
}

/// Split input into lines (JSON-RPC messages). Caller owns the returned slice; each line borrows from input.
pub fn splitLines(input: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, input, '\n');
}

/// Extract a raw JSON value as a string from a params JSON string.
/// Useful for extracting nested objects like "arguments".
pub fn extractRaw(allocator: Allocator, params_json: []const u8, field: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, params_json, .{
        .allocate = .alloc_always,
    }) catch return null;
    defer parsed.deinit();

    if (parsed.value.object.get(field)) |val| {
        return try serializeValue(allocator, val);
    }
    return null;
}

/// Extract a string field from a params JSON string.
pub fn extractString(allocator: Allocator, params_json: []const u8, field: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, params_json, .{
        .allocate = .alloc_always,
    }) catch return null;
    defer parsed.deinit();

    if (parsed.value.object.get(field)) |val| {
        if (val == .string) return try allocator.dupe(u8, val.string);
    }
    return null;
}

/// Extract an integer field from a params JSON string.
pub fn extractInteger(allocator: Allocator, params_json: []const u8, field: []const u8) !?i64 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, params_json, .{
        .allocate = .alloc_always,
    }) catch return null;
    defer parsed.deinit();

    if (parsed.value.object.get(field)) |val| {
        if (val == .integer) return @intCast(val.integer);
    }
    return null;
}

/// Extract a string array field from a params JSON string.
pub fn extractStringArray(allocator: Allocator, params_json: []const u8, field: []const u8) !?[][]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, params_json, .{
        .allocate = .alloc_always,
    }) catch return null;
    defer parsed.deinit();

    if (parsed.value.object.get(field)) |val| {
        if (val == .array) {
            var result = std.ArrayList([]const u8).empty;
            for (val.array.items) |item| {
                if (item == .string) {
                    try result.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            return try result.toOwnedSlice(allocator);
        }
    }
    return null;
}

// ==================== TESTS ====================

test "buildResponse with id" {
    const resp = try buildResponse(testing.allocator, 1, "{\"tools\":[]}");
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "\"jsonrpc\":\"2.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"tools\"") != null);
}

test "buildErrorResponse" {
    const resp = try buildErrorResponse(testing.allocator, 2, -32600, "Invalid Request");
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "\"error\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Invalid Request") != null);
}

test "buildToolResultText" {
    const result = try buildToolResultText(testing.allocator, "hello world", false);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "hello world") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"text\"") != null);
}

test "buildToolResultText error" {
    const result = try buildToolResultText(testing.allocator, "something failed", true);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "isError") != null);
}

test "buildInitializeResult" {
    const result = try buildInitializeResult(testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "devjournal-mcp") != null);
    try testing.expect(std.mem.indexOf(u8, result, "2024-11-05") != null);
}

test "buildToolsList" {
    const tools = [_]Tool{
        .{ .name = "test_tool", .description = "A test tool", .input_schema_json = "{\"type\":\"object\"}" },
    };
    const result = try buildToolsList(testing.allocator, &tools);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "test_tool") != null);
    try testing.expect(std.mem.indexOf(u8, result, "A test tool") != null);
}

test "extractString from params" {
    const params = "{\"name\":\"hello\",\"count\":5}";
    const val = try extractString(testing.allocator, params, "name");
    defer if (val) |v| testing.allocator.free(v);
    try testing.expectEqualStrings("hello", val.?);
}

test "extractString returns null for missing field" {
    const params = "{\"name\":\"hello\"}";
    const val = try extractString(testing.allocator, params, "missing");
    try testing.expect(val == null);
}

test "extractStringArray from params" {
    const params = "{\"tags\":[\"a\",\"b\",\"c\"]}";
    const arr = try extractStringArray(testing.allocator, params, "tags");
    defer if (arr) |a| {
        for (a) |s| testing.allocator.free(s);
        testing.allocator.free(a);
    };
    try testing.expect(arr != null);
    try testing.expectEqual(@as(usize, 3), arr.?.len);
    try testing.expectEqualStrings("a", arr.?[0]);
}
