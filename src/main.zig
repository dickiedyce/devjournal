const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const io_mod = @import("io");
const mcp = @import("mcp");

const VERSION = "0.3.0";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    // Check for --json and --mcp global flags
    var json_output = false;
    var mcp_mode = false;
    var filtered_args = std.ArrayList([]const u8).empty;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--mcp")) {
            mcp_mode = true;
        } else {
            try filtered_args.append(arena, arg);
        }
    }

    // If MCP mode, run as MCP server (consumes stdin, writes to stdout)
    if (mcp_mode) {
        try cmdMcpServer(arena, io);
        return;
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
    } else if (std.mem.eql(u8, command, "adr")) {
        try cmdAdr(arena, io, cmd_args[2..], json_output);
    } else if (std.mem.eql(u8, command, "note")) {
        try cmdNote(arena, io, cmd_args[2..], json_output);
    } else if (std.mem.eql(u8, command, "search")) {
        try cmdSearch(arena, io, cmd_args[2..], json_output);
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
        \\    reorder <id> [id...]      Move items to top in order
        \\    prioritise <id> <pos>     Move item to specific position
        \\  daily <subcommand>          Manage daily notes
        \\    show                      Show today's daily note
        \\    append <text>             Append timestamped entry
        \\    prepend <text>            Prepend entry (after frontmatter)
        \\  session <subcommand>        Session notes
        \\    create <topic>            Create session note from today's entries
        \\    list                      List all session notes
        \\  project <subcommand>        Project management
        \\    overview                  Show project overview
        \\    summary                   Show project activity summary
        \\  adr <subcommand>            Architecture Decision Records
        \\    create <title>            Create a new ADR (auto-numbered)
        \\    list                      List all ADRs
        \\  note <subcommand>           Generic notes
        \\    create <title> [tags...]  Create a tagged note
        \\  search <query>              Full-text search across journal
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
    } else if (std.mem.eql(u8, sub, "reorder")) {
        if (args.len < 2) {
            try printError(io, "backlog reorder", "missing item IDs");
            return;
        }
        try cmdBacklogReorder(allocator, io, args[1..], json_output);
    } else if (std.mem.eql(u8, sub, "prioritise") or std.mem.eql(u8, sub, "prioritize")) {
        if (args.len < 3) {
            try printError(io, "backlog prioritise", "usage: prioritise <id> <position>");
            return;
        }
        const pos = std.fmt.parseInt(usize, args[2], 10) catch {
            try printError(io, "backlog prioritise", "position must be a number");
            return;
        };
        try cmdBacklogPrioritise(allocator, io, args[1], pos, json_output);
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
    } else if (std.mem.eql(u8, sub, "prepend")) {
        if (args.len < 2) {
            try printError(io, "daily prepend", "missing text");
            return;
        }
        try cmdDailyPrepend(allocator, io, args[1], json_output);
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
    } else if (std.mem.eql(u8, sub, "list")) {
        try cmdSessionList(allocator, io, json_output);
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
    } else if (std.mem.eql(u8, sub, "summary")) {
        try cmdProjectSummary(allocator, io, json_output);
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

// ==================== v0.2 Commands ====================

fn cmdBacklogReorder(allocator: Allocator, io: Io, id_list: []const []const u8, json_output: bool) !void {
    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, "journal/backlog.md") catch {
        try printError(io, "backlog reorder", "journal/backlog.md not found.");
        return;
    };
    defer read.deinit();

    const new_content = core.backlog.reorder(allocator, read.content, id_list) catch {
        try printError(io, "backlog reorder", "failed to reorder");
        return;
    };
    defer allocator.free(new_content);

    try io_mod.writeToDir(Io.Dir.cwd(), io, "journal/backlog.md", new_content, read.mtime);

    var buf: [1024]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    if (json_output) {
        try out.print("{{\"status\":\"ok\",\"reordered\":{d}}}\n", .{id_list.len});
    } else {
        try out.print("Reordered {d} items to top\n", .{id_list.len});
    }
    try out.flush();
}

fn cmdBacklogPrioritise(allocator: Allocator, io: Io, id_str: []const u8, position: usize, json_output: bool) !void {
    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, "journal/backlog.md") catch {
        try printError(io, "backlog prioritise", "journal/backlog.md not found.");
        return;
    };
    defer read.deinit();

    const new_content = core.backlog.prioritise(allocator, read.content, id_str, position) catch |err| {
        if (err == error.ItemNotFound) {
            try printError(io, "backlog prioritise", "item not found");
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
        try out.print("{{\"status\":\"ok\",\"id\":\"{s}\",\"position\":{d}}}\n", .{ id_str, position });
    } else {
        try out.print("Moved {s} to position {d}\n", .{ id_str, position });
    }
    try out.flush();
}

fn cmdDailyPrepend(allocator: Allocator, io: Io, text: []const u8, json_output: bool) !void {
    const path = try todayFilename(allocator, io);
    defer allocator.free(path);

    const time_str = try todayTimeHM(io, allocator);
    defer allocator.free(time_str);

    const entry = try core.daily.buildEntry(allocator, time_str, text);
    defer allocator.free(entry);

    var existing_content: []const u8 = "";
    var mtime_guard: ?Io.Timestamp = null;
    var read_owned = false;
    if (io_mod.readFromDir(allocator, Io.Dir.cwd(), io, path)) |read| {
        existing_content = read.content;
        mtime_guard = read.mtime;
        read_owned = true;
    } else |_| {}

    const new_content = try core.daily.prependContent(allocator, existing_content, entry);
    defer allocator.free(new_content);

    if (read_owned) allocator.free(existing_content);

    io_mod.ensureDir(Io.Dir.cwd(), io, "journal/daily") catch {};
    try io_mod.writeToDir(Io.Dir.cwd(), io, path, new_content, mtime_guard);

    var buf: [1024]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    if (json_output) {
        try out.print("{{\"status\":\"ok\",\"entry\":\"{s}\"}}\n", .{entry});
    } else {
        try out.print("Prepended: {s}", .{entry});
    }
    try out.flush();
}

fn cmdSessionList(allocator: Allocator, io: Io, json_output: bool) !void {
    // List files in journal/sessions/
    var dir = Io.Dir.cwd().openDir(io, "journal/sessions", .{ .iterate = true }) catch {
        try printError(io, "session list", "journal/sessions/ not found.");
        return;
    };
    defer dir.close(io);

    var filenames = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (filenames.items) |f| allocator.free(f);
        filenames.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".md")) {
            try filenames.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    const summaries = try core.session.parseSessionFilenames(allocator, filenames.items);
    defer allocator.free(summaries);

    // Sort by date
    std.mem.sort(core.session.SessionSummary, summaries, {}, struct {
        fn lessThan(_: void, a: core.session.SessionSummary, b: core.session.SessionSummary) bool {
            return std.mem.lessThan(u8, a.date, b.date);
        }
    }.lessThan);

    var buf: [4096]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;

    if (json_output) {
        try out.writeAll("[");
        for (summaries, 0..) |s, i| {
            if (i > 0) try out.writeAll(",");
            try out.print("{{\"date\":\"{s}\",\"topic\":\"{s}\"}}", .{ s.date, s.topic });
        }
        try out.writeAll("]\n");
    } else {
        if (summaries.len == 0) {
            try out.writeAll("No session notes found.\n");
        } else {
            for (summaries) |s| {
                try out.print("{s} {s}\n", .{ s.date, s.topic });
            }
        }
    }
    try out.flush();
}

fn cmdProjectSummary(allocator: Allocator, io: Io, json_output: bool) !void {
    // Read session filenames
    var dir = Io.Dir.cwd().openDir(io, "journal/sessions", .{ .iterate = true }) catch {
        try printError(io, "project summary", "journal/sessions/ not found.");
        return;
    };
    defer dir.close(io);

    var dates = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (dates.items) |d| allocator.free(d);
        dates.deinit(allocator);
    }
    var topics = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (topics.items) |t| allocator.free(t);
        topics.deinit(allocator);
    }
    var counts = std.ArrayListUnmanaged(usize).empty;
    defer counts.deinit(allocator);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (core.session.parseSessionFilename(entry.name)) |summary| {
            try dates.append(allocator, try allocator.dupe(u8, summary.date));
            try topics.append(allocator, try allocator.dupe(u8, summary.topic));
            try counts.append(allocator, 0); // entry count unknown without reading file
        }
    }

    const summary = try core.project.buildSummary(allocator, dates.items, topics.items, counts.items);
    defer allocator.free(summary.sessions);

    var buf: [4096]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;

    if (json_output) {
        try out.print("{{\"session_count\":{d},\"total_entries\":{d}}}\n", .{ summary.session_count, summary.total_entries });
    } else {
        try out.print("Sessions: {d}\n", .{summary.session_count});
        for (summary.sessions) |s| {
            try out.print("  {s} {s}\n", .{ s.date, s.topic });
        }
    }
    try out.flush();
}

fn cmdAdr(allocator: Allocator, io: Io, args: []const []const u8, json_output: bool) !void {
    if (args.len == 0) {
        try printError(io, "adr", "missing subcommand (create, list)");
        return;
    }

    const sub = args[0];

    if (std.mem.eql(u8, sub, "create")) {
        if (args.len < 2) {
            try printError(io, "adr create", "missing title");
            return;
        }
        try cmdAdrCreate(allocator, io, args[1], json_output);
    } else if (std.mem.eql(u8, sub, "list")) {
        try cmdAdrList(allocator, io, json_output);
    } else {
        try printError(io, "adr", "unknown subcommand");
    }
}

fn cmdAdrCreate(allocator: Allocator, io: Io, title: []const u8, json_output: bool) !void {
    io_mod.ensureDir(Io.Dir.cwd(), io, "journal/adr") catch {};

    // Scan existing ADR files to find next number
    var dir = Io.Dir.cwd().openDir(io, "journal/adr", .{ .iterate = true }) catch {
        try printError(io, "adr create", "cannot open journal/adr/");
        return;
    };
    defer dir.close(io);

    var filenames = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (filenames.items) |f| allocator.free(f);
        filenames.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        try filenames.append(allocator, try allocator.dupe(u8, entry.name));
    }

    const next_num = core.adr.nextNumber(filenames.items);

    const date = todayDate(io);
    const adr_content = core.adr.build(
        allocator,
        next_num,
        title,
        "proposed",
        date,
        null,
        "(TODO: describe the context)",
        "(TODO: describe the decision)",
        null,
    ) catch {
        try printError(io, "adr create", "failed to build ADR");
        return;
    };
    defer allocator.free(adr_content);

    var fname_buf: [12]u8 = undefined;
    const fname = core.adr.formatFilename(next_num, &fname_buf);
    const full_path = try std.fmt.allocPrint(allocator, "journal/adr/{s}", .{fname});
    defer allocator.free(full_path);

    try io_mod.writeToDir(Io.Dir.cwd(), io, full_path, adr_content, null);

    var buf: [1024]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    if (json_output) {
        try out.print("{{\"status\":\"ok\",\"number\":{d},\"path\":\"{s}\"}}\n", .{ next_num, full_path });
    } else {
        try out.print("Created ADR-{d:0>3}: {s}\n", .{ next_num, title });
    }
    try out.flush();
}

fn cmdAdrList(allocator: Allocator, io: Io, json_output: bool) !void {
    var dir = Io.Dir.cwd().openDir(io, "journal/adr", .{ .iterate = true }) catch {
        try printError(io, "adr list", "journal/adr/ not found.");
        return;
    };
    defer dir.close(io);

    var filenames = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (filenames.items) |f| allocator.free(f);
        filenames.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (core.adr.parseFilenameNumber(entry.name) != null) {
            try filenames.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    // Sort by number
    std.mem.sort([]const u8, filenames.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            const na = core.adr.parseFilenameNumber(a) orelse 0;
            const nb = core.adr.parseFilenameNumber(b) orelse 0;
            return na < nb;
        }
    }.lessThan);

    var buf: [4096]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;

    if (json_output) {
        try out.writeAll("[");
        for (filenames.items, 0..) |f, i| {
            if (i > 0) try out.writeAll(",");
            try out.print("\"{s}\"", .{f});
        }
        try out.writeAll("]\n");
    } else {
        if (filenames.items.len == 0) {
            try out.writeAll("No ADRs found.\n");
        } else {
            for (filenames.items) |f| {
                try out.print("{s}\n", .{f});
            }
        }
    }
    try out.flush();
}

fn cmdNote(allocator: Allocator, io: Io, args: []const []const u8, json_output: bool) !void {
    if (args.len == 0) {
        try printError(io, "note", "missing subcommand (create)");
        return;
    }

    const sub = args[0];

    if (std.mem.eql(u8, sub, "create")) {
        if (args.len < 2) {
            try printError(io, "note create", "missing title");
            return;
        }
        // Remaining args are tags
        const tags = if (args.len > 2) args[2..] else null;
        try cmdNoteCreate(allocator, io, args[1], tags, json_output);
    } else {
        try printError(io, "note", "unknown subcommand");
    }
}

fn cmdNoteCreate(allocator: Allocator, io: Io, title: []const u8, tags: ?[]const []const u8, json_output: bool) !void {
    io_mod.ensureDir(Io.Dir.cwd(), io, "journal/notes") catch {};

    const date = todayDate(io);
    var date_buf: [10]u8 = undefined;
    const date_str = std.fmt.bufPrint(&date_buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        date.year, date.month, date.day,
    }) catch unreachable;

    const note_content = core.note.build(
        allocator,
        title,
        tags,
        date_str,
        "(TODO: write your note here)",
    ) catch {
        try printError(io, "note create", "failed to build note");
        return;
    };
    defer allocator.free(note_content);

    // Sanitize title for filename
    var fname_buf: [128]u8 = undefined;
    const fname = std.fmt.bufPrint(&fname_buf, "{s}.md", .{title}) catch {
        try printError(io, "note create", "title too long for filename");
        return;
    };

    const full_path = try std.fmt.allocPrint(allocator, "journal/notes/{s}", .{fname});
    defer allocator.free(full_path);

    try io_mod.writeToDir(Io.Dir.cwd(), io, full_path, note_content, null);

    var buf: [1024]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    if (json_output) {
        try out.print("{{\"status\":\"ok\",\"path\":\"{s}\"}}\n", .{full_path});
    } else {
        try out.print("Created: {s}\n", .{full_path});
    }
    try out.flush();
}

fn cmdSearch(allocator: Allocator, io: Io, args: []const []const u8, json_output: bool) !void {
    if (args.len == 0) {
        try printError(io, "search", "missing query");
        return;
    }

    const query = args[0];

    // Search all markdown files in journal/
    var all_matches = std.ArrayListUnmanaged(core.search.Match).empty;
    defer {
        for (all_matches.items) |m| {
            allocator.free(m.file);
            allocator.free(m.line);
        }
        all_matches.deinit(allocator);
    }

    try searchDir(allocator, io, "journal", query, &all_matches);

    var buf: [8192]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;

    if (json_output) {
        try out.writeAll("[");
        for (all_matches.items, 0..) |m, i| {
            if (i > 0) try out.writeAll(",");
            try out.print("{{\"file\":\"{s}\",\"line\":{d},\"text\":\"{s}\"}}", .{ m.file, m.line_number, m.line });
        }
        try out.writeAll("]\n");
    } else {
        if (all_matches.items.len == 0) {
            try out.print("No matches for \"{s}\".\n", .{query});
        } else {
            for (all_matches.items) |m| {
                try out.print("{s}:{d}: {s}\n", .{ m.file, m.line_number, m.line });
            }
        }
    }
    try out.flush();
}

fn searchDir(allocator: Allocator, io: Io, dir_path: []const u8, query: []const u8, results: *std.ArrayListUnmanaged(core.search.Match)) !void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(full_path);

        if (entry.kind == .directory) {
            try searchDir(allocator, io, full_path, query, results);
        } else if (std.mem.endsWith(u8, entry.name, ".md")) {
            const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, full_path) catch continue;
            defer read.deinit();

            const matches = core.search.searchContent(allocator, read.content, query, full_path) catch continue;
            defer allocator.free(matches);

            for (matches) |m| {
                try results.append(allocator, .{
                    .file = try allocator.dupe(u8, m.file),
                    .line_number = m.line_number,
                    .line = try allocator.dupe(u8, m.line),
                    .match_start = m.match_start,
                });
            }
        }
    }
}

// ==================== MCP Server ====================

fn cmdMcpServer(allocator: Allocator, io: Io) !void {
    var stdin_buf: [65536]u8 = undefined;
    var stdin_reader = Io.File.reader(.stdin(), io, &stdin_buf);
    var stdout_buf: [65536]u8 = undefined;
    var stdout_writer = Io.File.writer(.stdout(), io, &stdout_buf);
    const out = &stdout_writer.interface;
    const reader = &stdin_reader.interface;

    const tools = getTools();

    // Read all stdin at once, then process each line as a JSON-RPC message
    const all_input = mcp.readAll(allocator, reader) catch return;
    defer allocator.free(all_input);

    var lines = mcp.splitLines(all_input);
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const request = mcp.parseRequest(allocator, line) catch continue;
        defer if (request.params_raw) |p| allocator.free(p);

        const response_json = handleMcpRequest(allocator, io, request, &tools) catch {
            const err_resp = mcp.buildErrorResponse(allocator, request.id, -32603, "Internal error") catch continue;
            defer allocator.free(err_resp);
            out.writeAll(err_resp) catch break;
            out.writeAll("\n") catch break;
            out.flush() catch break;
            continue;
        };
        defer allocator.free(response_json);

        // Skip empty responses (notifications)
        if (response_json.len == 0) continue;

        out.writeAll(response_json) catch break;
        out.writeAll("\n") catch break;
        out.flush() catch break;
    }
}

fn handleMcpRequest(allocator: Allocator, io: Io, request: mcp.Request, tools: *const [TOOLS_COUNT]mcp.Tool) ![]const u8 {
    if (std.mem.eql(u8, request.method, "initialize")) {
        return mcp.buildInitializeResult(allocator);
    }

    if (std.mem.eql(u8, request.method, "notifications/initialized")) {
        // No response needed for notifications - return empty string
        return try allocator.dupe(u8, "");
    }

    if (std.mem.eql(u8, request.method, "tools/list")) {
        const result = try mcp.buildToolsList(allocator, tools);
        return mcp.buildResponse(allocator, request.id, result);
    }

    if (std.mem.eql(u8, request.method, "tools/call")) {
        const params = request.params_raw orelse return mcp.buildErrorResponse(allocator, request.id, -32600, "Missing params");
        const tool_name = try mcp.extractString(allocator, params, "name") orelse
            return mcp.buildErrorResponse(allocator, request.id, -32600, "Missing tool name");
        defer allocator.free(tool_name);

        const args_json = try mcp.extractRaw(allocator, params, "arguments") orelse "{}";
        defer if (!std.mem.eql(u8, args_json, "{}")) allocator.free(args_json);

        const result_text = dispatchTool(allocator, io, tool_name, args_json) catch |err| {
            const err_text = try std.fmt.allocPrint(allocator, "Tool error: {s}", .{@errorName(err)});
            defer allocator.free(err_text);
            const result = try mcp.buildToolResultText(allocator, err_text, true);
            return mcp.buildResponse(allocator, request.id, result);
        };
        defer allocator.free(result_text);

        const result = try mcp.buildToolResultText(allocator, result_text, false);
        return mcp.buildResponse(allocator, request.id, result);
    }

    // Unknown method
    return mcp.buildErrorResponse(allocator, request.id, -32601, "Method not found");
}

const TOOLS_COUNT = 11;

fn getTools() [TOOLS_COUNT]mcp.Tool {
    return [_]mcp.Tool{
        .{
            .name = "devjournal_init",
            .description = "Initialize a new journal structure with project overview and backlog",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"project\":{\"type\":\"string\",\"description\":\"Project name\"}}}",
        },
        .{
            .name = "devjournal_backlog_list",
            .description = "List all open backlog items",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
        },
        .{
            .name = "devjournal_backlog_add",
            .description = "Add a new item to the backlog",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\",\"description\":\"Item text\"}},\"required\":[\"text\"]}",
        },
        .{
            .name = "devjournal_backlog_done",
            .description = "Mark a backlog item as done",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\",\"description\":\"Item ID like [#20260809-xxxx]\"}},\"required\":[\"id\"]}",
        },
        .{
            .name = "devjournal_daily_show",
            .description = "Show today's daily note content",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
        },
        .{
            .name = "devjournal_daily_append",
            .description = "Append a timestamped entry to today's daily note",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\",\"description\":\"Entry text\"}},\"required\":[\"text\"]}",
        },
        .{
            .name = "devjournal_session_create",
            .description = "Create a session note from today's daily entries",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"topic\":{\"type\":\"string\",\"description\":\"Session topic\"}},\"required\":[\"topic\"]}",
        },
        .{
            .name = "devjournal_project_overview",
            .description = "Show project overview metadata",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
        },
        .{
            .name = "devjournal_dashboard",
            .description = "Show cross-project dashboard summary",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
        },
        .{
            .name = "devjournal_adr_create",
            .description = "Create a new Architecture Decision Record (auto-numbered)",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\",\"description\":\"ADR title\"}},\"required\":[\"title\"]}",
        },
        .{
            .name = "devjournal_search",
            .description = "Search across all journal files for a query string",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Search query\"}},\"required\":[\"query\"]}",
        },
    };
}

fn dispatchTool(allocator: Allocator, io: Io, tool_name: []const u8, args_json: []const u8) ![]const u8 {
    if (std.mem.eql(u8, tool_name, "devjournal_init")) {
        return mcp.buildToolResultText(allocator, "Init: use devjournal init from CLI", false);
    }

    if (std.mem.eql(u8, tool_name, "devjournal_backlog_list")) {
        const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, "journal/backlog.md") catch
            return mcp.buildToolResultText(allocator, "No backlog.md found", true);
        defer read.deinit();

        const items = try core.backlog.parseItems(allocator, read.content);
        defer allocator.free(items);

        var buf = std.ArrayList(u8).empty;
        for (items) |item| {
            if (item.checked) continue;
            const id_str = if (item.id) |id| blk: {
                var id_buf: [18]u8 = undefined;
                break :blk id.format(&id_buf);
            } else "no-id";
            try buf.print(allocator, "- {s} {s}\n", .{ id_str, item.text });
        }
        return try buf.toOwnedSlice(allocator);
    }

    if (std.mem.eql(u8, tool_name, "devjournal_backlog_add")) {
        const text = try mcp.extractString(allocator, args_json, "text") orelse
            return allocator.dupe(u8, "Missing text parameter");
        defer allocator.free(text);

        const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, "journal/backlog.md") catch
            return allocator.dupe(u8, "No backlog.md found");
        defer read.deinit();

        const date = todayDate(io);
        const line = try core.backlog.buildItemLine(allocator, text, date);
        defer allocator.free(line);

        const new_content = try insertAfterLastOpenItem(allocator, read.content, line);
        defer allocator.free(new_content);

        try io_mod.writeToDir(Io.Dir.cwd(), io, "journal/backlog.md", new_content, read.mtime);
        return try std.fmt.allocPrint(allocator, "Added: {s}", .{line});
    }

    if (std.mem.eql(u8, tool_name, "devjournal_backlog_done")) {
        const id_str = try mcp.extractString(allocator, args_json, "id") orelse
            return allocator.dupe(u8, "Missing id parameter");
        defer allocator.free(id_str);

        const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, "journal/backlog.md") catch
            return allocator.dupe(u8, "No backlog.md found");
        defer read.deinit();

        const ts = try todayTimestampYYMMDDHHMM(io, allocator);
        defer allocator.free(ts);

        const new_content = core.backlog.markDone(allocator, read.content, id_str, ts) catch |err| {
            if (err == error.ItemNotFound) return allocator.dupe(u8, "Item not found");
            return err;
        };
        defer allocator.free(new_content);

        try io_mod.writeToDir(Io.Dir.cwd(), io, "journal/backlog.md", new_content, read.mtime);
        return try std.fmt.allocPrint(allocator, "Marked done: {s}", .{id_str});
    }

    if (std.mem.eql(u8, tool_name, "devjournal_daily_show")) {
        const path = try todayFilename(allocator, io);
        defer allocator.free(path);

        const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, path) catch
            return allocator.dupe(u8, "No daily note for today");
        defer read.deinit();

        return try allocator.dupe(u8, read.content);
    }

    if (std.mem.eql(u8, tool_name, "devjournal_daily_append")) {
        const text = try mcp.extractString(allocator, args_json, "text") orelse
            return allocator.dupe(u8, "Missing text parameter");
        defer allocator.free(text);

        const path = try todayFilename(allocator, io);
        defer allocator.free(path);

        const time_str = try todayTimeHM(io, allocator);
        defer allocator.free(time_str);

        const entry = try core.daily.buildEntry(allocator, time_str, text);
        defer allocator.free(entry);

        var existing_content: []const u8 = "";
        var mtime_guard: ?Io.Timestamp = null;
        var read_owned = false;
        if (io_mod.readFromDir(allocator, Io.Dir.cwd(), io, path)) |read| {
            existing_content = read.content;
            mtime_guard = read.mtime;
            read_owned = true;
        } else |_| {}

        const new_content = try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing_content, entry });
        defer allocator.free(new_content);

        if (read_owned) allocator.free(existing_content);

        io_mod.ensureDir(Io.Dir.cwd(), io, "journal/daily") catch {};
        try io_mod.writeToDir(Io.Dir.cwd(), io, path, new_content, mtime_guard);
        return try std.fmt.allocPrint(allocator, "Appended: {s}", .{entry});
    }

    if (std.mem.eql(u8, tool_name, "devjournal_session_create")) {
        const topic = try mcp.extractString(allocator, args_json, "topic") orelse
            return allocator.dupe(u8, "Missing topic parameter");
        defer allocator.free(topic);

        const path = try todayFilename(allocator, io);
        defer allocator.free(path);

        const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, path) catch
            return allocator.dupe(u8, "No daily note for today");
        defer read.deinit();

        const entries = try core.daily.parseEntries(allocator, read.content);
        defer allocator.free(entries);

        // Convert entries to string slices for buildSessionNote
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
        return try std.fmt.allocPrint(allocator, "Created session: {s} ({d} entries)", .{ full_path, entries.len });
    }

    if (std.mem.eql(u8, tool_name, "devjournal_project_overview")) {
        const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, "journal/overview.md") catch
            return allocator.dupe(u8, "No overview.md found");
        defer read.deinit();

        const maybe_info = core.project.parseOverview(allocator, read.content) catch
            return allocator.dupe(u8, "Failed to parse overview");
        if (maybe_info) |info| {
            defer info.deinit();
            return try std.fmt.allocPrint(allocator, "{s} ({s})", .{ info.name, info.status });
        }
        return allocator.dupe(u8, "No overview found");
    }

    if (std.mem.eql(u8, tool_name, "devjournal_dashboard")) {
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

        return try std.fmt.allocPrint(allocator, "Backlog: {d} open, {d} done\nToday's entries: {d}", .{ open_count, done_count, entry_count });
    }

    if (std.mem.eql(u8, tool_name, "devjournal_adr_create")) {
        const title = try mcp.extractString(allocator, args_json, "title") orelse
            return allocator.dupe(u8, "Missing title parameter");
        defer allocator.free(title);

        io_mod.ensureDir(Io.Dir.cwd(), io, "journal/adr") catch {};

        var dir = Io.Dir.cwd().openDir(io, "journal/adr", .{ .iterate = true }) catch
            return allocator.dupe(u8, "Cannot open journal/adr/");
        defer dir.close(io);

        var filenames = std.ArrayListUnmanaged([]const u8).empty;
        defer {
            for (filenames.items) |f| allocator.free(f);
            filenames.deinit(allocator);
        }

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            try filenames.append(allocator, try allocator.dupe(u8, entry.name));
        }

        const next_num = core.adr.nextNumber(filenames.items);
        const date = todayDate(io);
        const adr_content = core.adr.build(allocator, next_num, title, "proposed", date, null, "(TODO)", "(TODO)", null) catch
            return allocator.dupe(u8, "Failed to build ADR");
        defer allocator.free(adr_content);

        var fname_buf: [12]u8 = undefined;
        const fname = core.adr.formatFilename(next_num, &fname_buf);
        const full_path = try std.fmt.allocPrint(allocator, "journal/adr/{s}", .{fname});
        defer allocator.free(full_path);

        try io_mod.writeToDir(Io.Dir.cwd(), io, full_path, adr_content, null);
        return try std.fmt.allocPrint(allocator, "Created ADR-{d:0>3}: {s}", .{ next_num, title });
    }

    if (std.mem.eql(u8, tool_name, "devjournal_search")) {
        const query = try mcp.extractString(allocator, args_json, "query") orelse
            return allocator.dupe(u8, "Missing query parameter");
        defer allocator.free(query);

        var all_matches = std.ArrayListUnmanaged(core.search.Match).empty;
        defer {
            for (all_matches.items) |m| {
                allocator.free(m.file);
                allocator.free(m.line);
            }
            all_matches.deinit(allocator);
        }

        try searchDir(allocator, io, "journal", query, &all_matches);

        var buf = std.ArrayList(u8).empty;
        for (all_matches.items) |m| {
            try buf.print(allocator, "{s}:{d}: {s}\n", .{ m.file, m.line_number, m.line });
        }

        if (all_matches.items.len == 0) {
            return try std.fmt.allocPrint(allocator, "No matches for \"{s}\"", .{query});
        }
        return try buf.toOwnedSlice(allocator);
    }

    return try std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{tool_name});
}

// findJournalPath removed - MCP tools use hardcoded "journal" path
// Can be restored when .devjournal.toml config is wired up for MCP mode
