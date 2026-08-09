const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

// Error types inferred from function bodies

/// Read a file's content and capture its mtime.
pub const ReadResult = struct {
    content: []const u8,
    mtime: Io.Timestamp,
    allocator: Allocator,

    pub fn deinit(self: *const ReadResult) void {
        self.allocator.free(self.content);
    }
};

/// Read a file relative to a directory.
pub fn readFromDir(allocator: Allocator, dir: Dir, io: Io, subpath: []const u8) !ReadResult {
    const file = try dir.openFile(io, subpath, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const content = try reader.interface.allocRemaining(allocator, .unlimited);

    return ReadResult{
        .content = content,
        .mtime = stat.mtime,
        .allocator = allocator,
    };
}

/// Write content atomically using temp-file-then-rename.
/// If mtime_guard is provided, checks the file's current mtime before writing.
pub fn writeToDir(dir: Dir, io: Io, subpath: []const u8, content: []const u8, mtime_guard: ?Io.Timestamp) !void {
    if (mtime_guard) |expected_mtime| {
        const file = dir.openFile(io, subpath, .{}) catch return error.FileNotFound;
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.mtime.nanoseconds != expected_mtime.nanoseconds) {
            return error.MtimeConflict;
        }
    }

    // Write to temp file, then rename (atomic on POSIX)
    var tmp_buf: [256]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{subpath}) catch return error.OutOfMemory;

    {
        const tmp_file = try dir.createFile(io, tmp_path, .{});
        defer tmp_file.close(io);
        var write_buf: [4096]u8 = undefined;
        var writer = tmp_file.writer(io, &write_buf);
        try writer.interface.writeAll(content);
        try writer.interface.flush();
    }

    try dir.rename(tmp_path, dir, subpath, io);
}

/// Ensure a directory exists, creating it and all parents if needed.
pub fn ensureDir(dir: Dir, io: Io, subpath: []const u8) !void {
    dir.createDirPath(io, subpath) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.Unexpected,
    };
}

/// Check if a file exists.
pub fn fileExists(dir: Dir, io: Io, subpath: []const u8) bool {
    dir.access(io, subpath, .{}) catch return false;
    return true;
}

/// Check if a directory exists.
pub fn dirExists(dir: Dir, io: Io, subpath: []const u8) bool {
    const d = dir.openDir(io, subpath, .{}) catch return false;
    d.close(io);
    return true;
}

// ==================== TESTS ====================

test "writeToDir and readFromDir roundtrip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeToDir(tmp.dir, testing.io, "test.txt", "hello world", null);

    const result = try readFromDir(testing.allocator, tmp.dir, testing.io, "test.txt");
    defer result.deinit();
    try testing.expectEqualStrings("hello world", result.content);
}

test "writeToDir atomic - no partial tmp file left" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeToDir(tmp.dir, testing.io, "test.txt", "content", null);
    // Verify the .tmp file does not exist (renamed away)
    try testing.expect(!fileExists(tmp.dir, testing.io, "test.txt.tmp"));
}

test "mtime guard passes when mtime matches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeToDir(tmp.dir, testing.io, "test.txt", "original", null);

    const read = try readFromDir(testing.allocator, tmp.dir, testing.io, "test.txt");
    defer read.deinit();

    try writeToDir(tmp.dir, testing.io, "test.txt", "updated", read.mtime);

    const result = try readFromDir(testing.allocator, tmp.dir, testing.io, "test.txt");
    defer result.deinit();
    try testing.expectEqualStrings("updated", result.content);
}

test "mtime guard fails when mtime differs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeToDir(tmp.dir, testing.io, "test.txt", "original", null);

    try testing.expectError(
        error.MtimeConflict,
        writeToDir(tmp.dir, testing.io, "test.txt", "updated", .{ .nanoseconds = 0 }),
    );

    const result = try readFromDir(testing.allocator, tmp.dir, testing.io, "test.txt");
    defer result.deinit();
    try testing.expectEqualStrings("original", result.content);
}

test "ensureDir creates nested directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try ensureDir(tmp.dir, testing.io, "a/b/c");
    try testing.expect(dirExists(tmp.dir, testing.io, "a/b/c"));
}

test "fileExists returns false for missing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expect(!fileExists(tmp.dir, testing.io, "nope.txt"));
}
