const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const io_mod = @import("io");

const VERSION = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    // Check for --json global flag
    var json_output = false;
    var filtered_args = std.ArrayList([]const u8).empty;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else {
            try filtered_args.append(arena, arg);
        }
    }

    // Check env var for JSON output
    if (init.minimal.environ.getPosix("DEVJOURNAL_JSON")) |val| {
        if (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true")) {
            json_output = true;
        }
    }

    const cmd_args = filtered_args.items;

    // Skip the binary name
    if (cmd_args.len < 2) {
        try printUsage(io);
        return;
    }

    const command = cmd_args[1];

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(io);
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        try printVersion(io, json_output);
    } else if (std.mem.eql(u8, command, "init")) {
        try cmdInit(arena, io, cmd_args[2..], json_output);
    } else if (std.mem.eql(u8, command, "backlog")) {
        try cmdBacklog(arena, io, cmd_args[2..], json_output);
    } else if (std.mem.eql(u8, command, "daily")) {
        try cmdDaily(arena, io, cmd_args[2..], json_output);
    } else if (std.mem.eql(u8, command, "session")) {
        try cmdSession(arena, io, cmd_args[2..], json_output);
    } else if (std.mem.eql(u8, command, "project")) {
        try cmdProject(arena, io, cmd_args[2..], json_output);
    } else if (std.mem.eql(u8, command, "dashboard")) {
        try cmdDashboard(arena, io, json_output);
    } else if (std.mem.eql(u8, command, "relocate")) {
        try cmdRelocate(arena, io, cmd_args[2..], json_output);
    } else {
        try printError(io, "unknown command", command);
        try printUsage(io);
    }
}

fn printUsage(io: Io) !void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    try out.print(
        \\devjournal - manage coding journals
        \\
        \\Usage: devjournal [--json] <command> [args...]
        \\
        \\Commands:
        \\  init [--project <name>]     Initialize journal structure
        \\  backlog <subcommand>        Manage backlog items
        \\    list [--all]              List backlog items
        \\    add <text> [--priority]   Add a backlog item
        \\    done <id>                 Mark item done
        \\  daily <subcommand>          Manage daily notes
        \\    show                      Show today's daily note
        \\    append <text>             Append timestamped entry
        \\  session <subcommand>        Session notes
        \\    create <topic>            Create session note from today's entries
        \\  project <subcommand>        Project management
        \\    overview                  Show project overview
        \\  dashboard                   Cross-project overview
        \\  relocate [path]             Fix moved journal path
        \\  help                        Show this help
        \\  version                     Show version
        \\
        \\Global options:
        \\  --json                      Output as JSON
        \\  DEVJOURNAL_JSON=1           Same as --json (env var)
        \\
    , .{});
    try out.flush();
}

fn printVersion(io: Io, json_output: bool) !void {
    var buf: [1024]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    if (json_output) {
        try out.print("{{\"version\":\"{s}\"}}\n", .{VERSION});
    } else {
        try out.print("devjournal {s}\n", .{VERSION});
    }
    try out.flush();
}

fn printError(io: Io, context: []const u8, detail: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = Io.File.writer(.stderr(), io, &buf);
    const out = &w.interface;
    try out.print("error: {s}: {s}\n", .{ context, detail });
    try out.flush();
}

fn cmdInit(allocator: Allocator, io: Io, args: []const []const u8, json_output: bool) !void {
    // Parse --project flag
    var project_name: []const u8 = "Project";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--project") and i + 1 < args.len) {
            i += 1;
            project_name = args[i];
        }
    }

    // Check if .devjournal.toml already exists
    if (io_mod.fileExists(Io.Dir.cwd(), io, ".devjournal.toml")) {
        try printError(io, "init", ".devjournal.toml already exists");
        return;
    }

    // Write .devjournal.toml
    const toml_content = try std.fmt.allocPrint(allocator,
        \\journal = "./journal"
        \\
        \\[project_meta]
        \\description = ""
        \\status = "active"
        \\
    , .{});
    try io_mod.writeToDir(Io.Dir.cwd(), io, ".devjournal.toml", toml_content, null);

    // Create journal directory structure
    const journal_dir = Io.Dir.cwd();
    try io_mod.ensureDir(journal_dir, io, "journal");
    try io_mod.ensureDir(journal_dir, io, "journal/daily");
    try io_mod.ensureDir(journal_dir, io, "journal/sessions");

    // Create overview.md
    const overview = try core.project.buildOverview(allocator, project_name, null, null, null, "active");
    defer allocator.free(overview);
    try io_mod.writeToDir(journal_dir, io, "journal/overview.md", overview, null);

    // Create backlog.md
    const backlog_content = "# Backlog\n\n";
    try io_mod.writeToDir(journal_dir, io, "journal/backlog.md", backlog_content, null);

    var buf: [1024]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    if (json_output) {
        try out.print("{{\"status\":\"ok\",\"journal\":\"./journal\",\"project\":\"{s}\"}}\n", .{project_name});
    } else {
        try out.print("Initialized journal at ./journal (project: {s})\n", .{project_name});
    }
    try out.flush();
}

fn cmdBacklog(allocator: Allocator, io: Io, args: []const []const u8, json_output: bool) !void {
    if (args.len == 0) {
        try printError(io, "backlog", "missing subcommand (list, add, done)");
        return;
    }

    const sub = args[0];

    if (std.mem.eql(u8, sub, "list")) {
        try cmdBacklogList(allocator, io, json_output);
    } else if (std.mem.eql(u8, sub, "add")) {
        if (args.len < 2) {
            try printError(io, "backlog add", "missing item text");
            return;
        }
        try cmdBacklogAdd(allocator, io, args[1], json_output);
    } else if (std.mem.eql(u8, sub, "done")) {
        if (args.len < 2) {
            try printError(io, "backlog done", "missing item ID");
            return;
        }
        try cmdBacklogDone(allocator, io, args[1], json_output);
    } else {
        try printError(io, "backlog", "unknown subcommand");
    }
}

fn cmdBacklogList(allocator: Allocator, io: Io, json_output: bool) !void {
    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, "journal/backlog.md") catch {
        try printError(io, "backlog list", "journal/backlog.md not found. Run 'devjournal init' first.");
        return;
    };
    defer read.deinit();

    const items = try core.backlog.parseItems(allocator, read.content);
    defer allocator.free(items);

    if (json_output) {
        var buf: [4096]u8 = undefined;
        var w = Io.File.writer(.stdout(), io, &buf);
        const out = &w.interface;
        try out.writeAll("[");
        for (items, 0..) |item, idx| {
            if (idx > 0) try out.writeAll(",");
            try out.print("{{\"checked\":{s},\"text\":\"{s}\"}}", .{
                if (item.checked) "true" else "false",
                item.text,
            });
        }
        try out.writeAll("]\n");
        try out.flush();
    } else {
        var buf: [4096]u8 = undefined;
        var w = Io.File.writer(.stdout(), io, &buf);
        const out = &w.interface;
        for (items) |item| {
            const checkbox: []const u8 = if (item.checked) "[x]" else "[ ]";
            try out.print("- {s} {s}\n", .{ checkbox, item.text });
        }
        try out.flush();
    }
}

fn todayDate(io: Io) core.ids.Id.Date {
    const now = Io.Timestamp.now(io, .real);
    const secs: u64 = @intCast(now.toSeconds());
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const day_seconds = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = day_seconds.calculateMonthDay();
    return .{
        .year = day_seconds.year,
        .month = @intFromEnum(month_day.month),
        .day = month_day.day_index + 1,
    };
}

fn todayTimeHM(io: Io, allocator: Allocator) ![]const u8 {
    const now = Io.Timestamp.now(io, .real);
    const secs: u64 = @intCast(now.toSeconds());
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const hms = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}", .{
        hms.getHoursIntoDay(),
        hms.getMinutesIntoHour(),
    });
}

fn todayTimestampYYMMDDHHMM(io: Io, allocator: Allocator) ![]const u8 {
    const now = Io.Timestamp.now(io, .real);
    const secs: u64 = @intCast(now.toSeconds());
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const day_seconds = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = day_seconds.calculateMonthDay();
    const hms = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>2}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        @as(u8, @intCast(@mod(day_seconds.year, 100))),
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        hms.getHoursIntoDay(),
        hms.getMinutesIntoHour(),
    });
}

fn todayFilename(allocator: Allocator, io: Io) ![]const u8 {
    const date = todayDate(io);
    var date_buf: [14]u8 = undefined;
    const date_str = core.daily.formatFilename(date, &date_buf);
    return std.fmt.allocPrint(allocator, "journal/daily/{s}", .{date_str});
}

fn cmdBacklogAdd(allocator: Allocator, io: Io, text: []const u8, json_output: bool) !void {
    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, "journal/backlog.md") catch {
        try printError(io, "backlog add", "journal/backlog.md not found. Run 'devjournal init' first.");
        return;
    };
    defer read.deinit();

    const date = todayDate(io);
    const line = try core.backlog.buildItemLine(allocator, text, date);
    defer allocator.free(line);

    // Find insertion point: after last - [ ] line, or at end
    const new_content = try insertAfterLastOpenItem(allocator, read.content, line);
    defer allocator.free(new_content);

    try io_mod.writeToDir(Io.Dir.cwd(), io, "journal/backlog.md", new_content, read.mtime);

    var buf: [1024]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    if (json_output) {
        try out.print("{{\"status\":\"ok\",\"item\":\"{s}\"}}\n", .{line});
    } else {
        try out.print("Added: {s}\n", .{line});
    }
    try out.flush();
}

fn insertAfterLastOpenItem(allocator: Allocator, content: []const u8, new_line: []const u8) ![]const u8 {
    // Find the end position of the last unchecked item line (after its \n)
    var last_open_end: ?usize = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var pos: usize = 0;
    while (lines.next()) |line| {
        if (core.backlog.parseItemLine(line)) |item| {
            if (!item.checked) {
                last_open_end = pos + line.len + 1; // position right after the \n
            }
        }
        pos += line.len + 1; // +1 for newline
    }

    if (last_open_end) |end| {
        // Splice: content_before + new_line + \n + content_after
        return std.fmt.allocPrint(allocator, "{s}{s}\n{s}", .{
            content[0..end],
            new_line,
            content[end..],
        });
    }

    // No open items - append at end
    return std.fmt.allocPrint(allocator, "{s}{s}\n", .{ content, new_line });
}

fn cmdBacklogDone(allocator: Allocator, io: Io, id_str: []const u8, json_output: bool) !void {
    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, "journal/backlog.md") catch {
        try printError(io, "backlog done", "journal/backlog.md not found.");
        return;
    };
    defer read.deinit();

    const ts = try todayTimestampYYMMDDHHMM(io, allocator);
    defer allocator.free(ts);

    const new_content = core.backlog.markDone(allocator, read.content, id_str, ts) catch |err| {
        if (err == error.ItemNotFound) {
            try printError(io, "backlog done", "item not found");
            return;
        }
        return err;
    };
    defer allocator.free(new_content);

    try io_mod.writeToDir(Io.Dir.cwd(), io, "journal/backlog.md", new_content, read.mtime);

    var buf: [1024]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    if (json_output) {
        try out.print("{{\"status\":\"ok\",\"id\":\"{s}\"}}\n", .{id_str});
    } else {
        try out.print("Marked done: {s}\n", .{id_str});
    }
    try out.flush();
}

fn cmdDaily(allocator: Allocator, io: Io, args: []const []const u8, json_output: bool) !void {
    if (args.len == 0) {
        try printError(io, "daily", "missing subcommand (show, append)");
        return;
    }

    const sub = args[0];

    if (std.mem.eql(u8, sub, "show")) {
        try cmdDailyShow(allocator, io, json_output);
    } else if (std.mem.eql(u8, sub, "append")) {
        if (args.len < 2) {
            try printError(io, "daily append", "missing text");
            return;
        }
        try cmdDailyAppend(allocator, io, args[1], json_output);
    } else {
        try printError(io, "daily", "unknown subcommand");
    }
}

fn cmdDailyShow(allocator: Allocator, io: Io, json_output: bool) !void {
    const path = try todayFilename(allocator, io);
    defer allocator.free(path);

    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, path) catch {
        var buf: [1024]u8 = undefined;
        var w = Io.File.writer(.stdout(), io, &buf);
        const out = &w.interface;
        if (json_output) {
            try out.print("{{\"status\":\"empty\",\"path\":\"{s}\"}}\n", .{path});
        } else {
            try out.print("No daily note for today ({s})\n", .{path});
        }
        try out.flush();
        return;
    };
    defer read.deinit();

    var buf: [4096]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    if (json_output) {
        try out.print("{{\"status\":\"ok\",\"content\":\"{s}\"}}\n", .{read.content});
    } else {
        try out.writeAll(read.content);
    }
    try out.flush();
}

fn cmdDailyAppend(allocator: Allocator, io: Io, text: []const u8, json_output: bool) !void {
    const path = try todayFilename(allocator, io);
    defer allocator.free(path);

    const time_str = try todayTimeHM(io, allocator);
    defer allocator.free(time_str);

    const entry = try core.daily.buildEntry(allocator, time_str, text);
    defer allocator.free(entry);

    // Try to read existing daily note
    var existing_content: []const u8 = "";
    var mtime_guard: ?Io.Timestamp = null;
    if (io_mod.readFromDir(allocator, Io.Dir.cwd(), io, path)) |read| {
        existing_content = read.content;
        mtime_guard = read.mtime;
        // Don't free read.content yet, we're using it
    } else |_| {}

    const new_content = try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing_content, entry });
    defer allocator.free(new_content);

    // Create directory if needed
    io_mod.ensureDir(Io.Dir.cwd(), io, "journal/daily") catch {};

    try io_mod.writeToDir(Io.Dir.cwd(), io, path, new_content, mtime_guard);

    // Free the existing content we read
    if (existing_content.len > 0) {
        allocator.free(existing_content);
    }

    var buf: [1024]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    if (json_output) {
        try out.print("{{\"status\":\"ok\",\"entry\":\"{s}\"}}\n", .{entry});
    } else {
        try out.print("Appended: {s}", .{entry});
    }
    try out.flush();
}

fn cmdSession(allocator: Allocator, io: Io, args: []const []const u8, json_output: bool) !void {
    if (args.len == 0) {
        try printError(io, "session", "missing subcommand (create)");
        return;
    }

    const sub = args[0];

    if (std.mem.eql(u8, sub, "create")) {
        if (args.len < 2) {
            try printError(io, "session create", "missing topic");
            return;
        }
        try cmdSessionCreate(allocator, io, args[1], json_output);
    } else {
        try printError(io, "session", "unknown subcommand");
    }
}

fn cmdSessionCreate(allocator: Allocator, io: Io, topic: []const u8, json_output: bool) !void {
    const path = try todayFilename(allocator, io);
    defer allocator.free(path);

    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, path) catch {
        try printError(io, "session create", "no daily note for today");
        return;
    };
    defer read.deinit();

    const entries = try core.daily.parseEntries(allocator, read.content);
    defer allocator.free(entries);

    // Build entry strings from parsed entries
    var entry_strings = std.ArrayList([]const u8).empty;
    defer {
        for (entry_strings.items) |s| allocator.free(s);
        entry_strings.deinit(allocator);
    }
    for (entries) |entry| {
        const s = try std.fmt.allocPrint(allocator, "{s} -- {s}", .{ entry.timestamp, entry.text });
        try entry_strings.append(allocator, s);
    }

    const date = todayDate(io);
    const note = try core.session.buildSessionNote(allocator, "Project", topic, date, entry_strings.items);
    defer allocator.free(note);

    var fname_buf: [128]u8 = undefined;
    const fname = core.session.formatFilename(date, topic, &fname_buf);
    const full_path = try std.fmt.allocPrint(allocator, "journal/sessions/{s}", .{fname});
    defer allocator.free(full_path);

    io_mod.ensureDir(Io.Dir.cwd(), io, "journal/sessions") catch {};
    try io_mod.writeToDir(Io.Dir.cwd(), io, full_path, note, null);

    var buf: [1024]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    if (json_output) {
        try out.print("{{\"status\":\"ok\",\"path\":\"{s}\",\"entries\":{d}}}\n", .{ full_path, entries.len });
    } else {
        try out.print("Created session note: {s} ({d} entries)\n", .{ full_path, entries.len });
    }
    try out.flush();
}

fn cmdProject(allocator: Allocator, io: Io, args: []const []const u8, json_output: bool) !void {
    if (args.len == 0) {
        try printError(io, "project", "missing subcommand (overview)");
        return;
    }

    const sub = args[0];

    if (std.mem.eql(u8, sub, "overview")) {
        try cmdProjectOverview(allocator, io, json_output);
    } else {
        try printError(io, "project", "unknown subcommand");
    }
}

fn cmdProjectOverview(allocator: Allocator, io: Io, json_output: bool) !void {
    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, "journal/overview.md") catch {
        try printError(io, "project overview", "journal/overview.md not found. Run 'devjournal init' first.");
        return;
    };
    defer read.deinit();

    var info = core.project.parseOverview(allocator, read.content) catch {
        try printError(io, "project overview", "failed to parse overview.md");
        return;
    } orelse {
        try printError(io, "project overview", "no frontmatter found in overview.md");
        return;
    };
    defer info.deinit();

    var buf: [4096]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    if (json_output) {
        try out.print("{{\"name\":\"{s}\",\"status\":\"{s}\"", .{ info.name, info.status });
        if (info.repo) |r| {
            try out.print(",\"repo\":\"{s}\"", .{r});
        }
        try out.print("}}\n", .{});
    } else {
        try out.print("{s} ({s})\n", .{ info.name, info.status });
        if (info.repo) |r| {
            try out.print("  repo: {s}\n", .{r});
        }
        if (info.tech) |t| {
            try out.writeAll("  tech:");
            for (t) |item| {
                try out.print(" {s}", .{item});
            }
            try out.writeAll("\n");
        }
    }
    try out.flush();
}

fn cmdDashboard(allocator: Allocator, io: Io, json_output: bool) !void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;

    if (!json_output) {
        try out.writeAll("--- Dashboard ---\n");
    }

    // Read overview
    var has_overview = false;
    if (io_mod.readFromDir(allocator, Io.Dir.cwd(), io, "journal/overview.md")) |read| {
        defer read.deinit();
        if (core.project.parseOverview(allocator, read.content)) |maybe_info| {
            if (maybe_info) |*info| {
                defer info.deinit();
                has_overview = true;
                if (!json_output) {
                    try out.print("Project: {s} ({s})\n", .{ info.name, info.status });
                }
            }
        } else |_| {}
    } else |_| {}

    // Count backlog items
    var open_count: usize = 0;
    var done_count: usize = 0;
    if (io_mod.readFromDir(allocator, Io.Dir.cwd(), io, "journal/backlog.md")) |read| {
        defer read.deinit();
        if (core.backlog.parseItems(allocator, read.content)) |items| {
            defer allocator.free(items);
            for (items) |item| {
                if (item.checked) done_count += 1 else open_count += 1;
            }
        } else |_| {}
    } else |_| {}

    // Count daily entries
    var entry_count: usize = 0;
    const path = try todayFilename(allocator, io);
    defer allocator.free(path);
    if (io_mod.readFromDir(allocator, Io.Dir.cwd(), io, path)) |read| {
        defer read.deinit();
        if (core.daily.parseEntries(allocator, read.content)) |entries| {
            defer allocator.free(entries);
            entry_count = entries.len;
        } else |_| {}
    } else |_| {}

    if (json_output) {
        try out.print("{{\"has_overview\":{s},\"backlog\":{{\"open\":{d},\"done\":{d}}},\"today_entries\":{d}}}\n", .{
            if (has_overview) "true" else "false",
            open_count,
            done_count,
            entry_count,
        });
    } else {
        try out.print("Backlog: {d} open, {d} done\n", .{ open_count, done_count });
        try out.print("Today's entries: {d}\n", .{entry_count});
    }
    try out.flush();
}

fn cmdRelocate(allocator: Allocator, io: Io, args: []const []const u8, json_output: bool) !void {
    if (args.len == 0) {
        try printError(io, "relocate", "missing new journal path");
        return;
    }

    const new_path = args[0];

    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, ".devjournal.toml") catch {
        try printError(io, "relocate", ".devjournal.toml not found. Run 'devjournal init' first.");
        return;
    };
    defer read.deinit();

    var cfg = core.config.parse(allocator, read.content) catch {
        try printError(io, "relocate", "failed to parse .devjournal.toml");
        return;
    };
    defer cfg.deinit(allocator);

    const new_cfg = core.config.Config{
        .journal_path = new_path,
        .project_meta = cfg.project_meta,
    };

    const new_content = try core.config.serialize(allocator, new_cfg);
    defer allocator.free(new_content);

    try io_mod.writeToDir(Io.Dir.cwd(), io, ".devjournal.toml", new_content, read.mtime);

    var buf: [1024]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    if (json_output) {
        try out.print("{{\"status\":\"ok\",\"journal\":\"{s}\"}}\n", .{new_path});
    } else {
        try out.print("Journal path updated to: {s}\n", .{new_path});
    }
    try out.flush();
}
