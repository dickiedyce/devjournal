const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const io_mod = @import("io");
const mcp = @import("mcp");

const VERSION = "0.3.0";

/// Seconds east of UTC applied to all timestamps (0 when --utc is given).
var utc_offset_secs: i64 = 0;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    // Check for --json, --mcp and --utc global flags
    var json_output = false;
    var mcp_mode = false;
    var utc_mode = false;
    var filtered_args = std.ArrayList([]const u8).empty;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--mcp")) {
            mcp_mode = true;
        } else if (std.mem.eql(u8, arg, "--utc")) {
            utc_mode = true;
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

    // Timestamps default to local time; --utc or DEVJOURNAL_UTC=1 forces UTC.
    if (init.minimal.environ.getPosix("DEVJOURNAL_UTC")) |val| {
        if (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true")) {
            utc_mode = true;
        }
    }
    if (!utc_mode) {
        utc_offset_secs = resolveLocalUtcOffset(arena, io, init.minimal.environ) orelse 0;
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
        try cmdInit(arena, io, init.minimal.environ, cmd_args[2..], json_output);
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
        \\  init [--project <name>] [--journal <path>]
        \\                          Initialize journal structure
        \\  backlog <subcommand>        Manage backlog items
        \\    list [--all]              List backlog items
        \\    add <text> [--priority <level>]  Add a backlog item (high/medium/low)
        \\    done <id>                 Mark item done
        \\    toggle <id>               Toggle a task checkbox (checked <-> unchecked)
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
        \\    create <title> [tags...] [--body <text>]
        \\                          Create a tagged note (body from --body or stdin)
        \\  search <query>              Full-text search across journal
        \\  dashboard                   Cross-project overview
        \\  relocate [path]             Fix moved journal path
        \\  help                        Show this help
        \\  version                     Show version
        \\
        \\Global options:
        \\  --json                      Output as JSON
        \\  --utc                       Timestamps in UTC instead of local time
        \\  DEVJOURNAL_JSON=1           Same as --json (env var)
        \\  DEVJOURNAL_UTC=1            Same as --utc (env var)
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

fn cmdInit(allocator: Allocator, io: Io, env: std.process.Environ, args: []const []const u8, json_output: bool) !void {
    // Parse --project and --journal flags
    var project_name: []const u8 = "Project";
    var journal_flag: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--project") and i + 1 < args.len) {
            i += 1;
            project_name = args[i];
        } else if (std.mem.eql(u8, args[i], "--journal") and i + 1 < args.len) {
            i += 1;
            journal_flag = args[i];
        }
    }

    // Check if .devjournal.toml already exists
    if (io_mod.fileExists(Io.Dir.cwd(), io, ".devjournal.toml")) {
        try printError(io, "init", ".devjournal.toml already exists");
        return;
    }

    // Resolve journal path: --journal > vault_root > ./journal/
    var journal_path: []const u8 = undefined;
    var used_vault_root = false;

    if (journal_flag) |flag| {
        journal_path = flag;
    } else {
        // Try loading global config for vault_root
        if (resolveVaultRoot(allocator, io, env, project_name)) |resolved| {
            journal_path = resolved;
            used_vault_root = true;
        } else {
            journal_path = "./journal";
        }
    }

    // Write .devjournal.toml
    const toml_content = try std.fmt.allocPrint(allocator,
        \\journal = "{s}"
        \\
        \\[project_meta]
        \\description = ""
        \\status = "active"
        \\
    , .{journal_path});
    try io_mod.writeToDir(Io.Dir.cwd(), io, ".devjournal.toml", toml_content, null);

    // Create journal directory structure
    const journal_dir = Io.Dir.cwd();
    try io_mod.ensureDir(journal_dir, io, journal_path);
    try io_mod.ensureDir(journal_dir, io, try std.fmt.allocPrint(allocator, "{s}/daily", .{journal_path}));
    try io_mod.ensureDir(journal_dir, io, try std.fmt.allocPrint(allocator, "{s}/sessions", .{journal_path}));

    // Create overview.md
    const overview = try core.project.buildOverview(allocator, project_name, null, null, null, "active");
    defer allocator.free(overview);
    try io_mod.writeToDir(journal_dir, io, try std.fmt.allocPrint(allocator, "{s}/overview.md", .{journal_path}), overview, null);

    // Create backlog.md
    const backlog_content = "# Backlog\n\n";
    try io_mod.writeToDir(journal_dir, io, try std.fmt.allocPrint(allocator, "{s}/backlog.md", .{journal_path}), backlog_content, null);

    var buf: [1024]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    if (json_output) {
        try out.print("{{\"status\":\"ok\",\"journal\":\"{s}\",\"project\":\"{s}\"}}\n", .{ journal_path, project_name });
    } else {
        try out.print("Initialized journal at {s} (project: {s})\n", .{ journal_path, project_name });
        if (used_vault_root) {
            try out.print("(from global vault_root in ~/.config/devjournal/config.toml)\n", .{});
        }
    }
    try out.flush();
}

fn cmdBacklog(allocator: Allocator, io: Io, args: []const []const u8, json_output: bool) !void {
    if (args.len == 0) {
        try printError(io, "backlog", "missing subcommand (list, add, done, toggle, reorder, prioritise)");
        return;
    }

    const sub = args[0];

    if (std.mem.eql(u8, sub, "list")) {
        try cmdBacklogList(allocator, io, args[1..], json_output);
    } else if (std.mem.eql(u8, sub, "add")) {
        if (args.len < 2) {
            try printError(io, "backlog add", "missing item text");
            return;
        }
        var add_priority: ?core.backlog.Priority = null;
        if (args.len >= 4 and std.mem.eql(u8, args[2], "--priority")) {
            const p_input = args[3];
            if (p_input.len == 0) {
                try printError(io, "backlog add", "priority value required (high, medium, low)");
                return;
            }
            const tag_str = if (p_input[0] == '@') p_input else try std.fmt.allocPrint(allocator, "@{s}", .{p_input});
            add_priority = core.backlog.Priority.fromTag(tag_str) orelse {
                try printError(io, "backlog add", "priority must be high, medium, or low");
                return;
            };
        }
        try cmdBacklogAdd(allocator, io, args[1], add_priority, json_output);
    } else if (std.mem.eql(u8, sub, "done")) {
        if (args.len < 2) {
            try printError(io, "backlog done", "missing item ID");
            return;
        }
        try cmdBacklogDone(allocator, io, args[1], json_output);
    } else if (std.mem.eql(u8, sub, "toggle")) {
        if (args.len < 2) {
            try printError(io, "backlog toggle", "missing item ID");
            return;
        }
        try cmdBacklogToggle(allocator, io, args[1], json_output);
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

fn cmdBacklogList(allocator: Allocator, io: Io, args: []const []const u8, json_output: bool) !void {
    var show_all = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) show_all = true;
    }

    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, journalPath(allocator, io, "backlog.md")) catch {
        try printError(io, "backlog list", "backlog.md not found. Run 'devjournal init' first.");
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
        var first = true;
        for (items) |item| {
            if (!show_all and item.checked) continue;
            if (!first) try out.writeAll(",");
            first = false;
            if (item.id) |id| {
                var id_buf: [18]u8 = undefined;
                const id_str = id.format(&id_buf);
                if (item.priority) |p| {
                    try out.print("{{\"id\":\"{s}\",\"checked\":{s},\"text\":\"{s}\",\"priority\":\"{s}\"}}", .{
                        id_str,
                        if (item.checked) "true" else "false",
                        item.text,
                        p.toTag(),
                    });
                } else {
                    try out.print("{{\"id\":\"{s}\",\"checked\":{s},\"text\":\"{s}\"}}", .{
                        id_str,
                        if (item.checked) "true" else "false",
                        item.text,
                    });
                }
            } else {
                if (item.priority) |p| {
                    try out.print("{{\"checked\":{s},\"text\":\"{s}\",\"priority\":\"{s}\"}}", .{
                        if (item.checked) "true" else "false",
                        item.text,
                        p.toTag(),
                    });
                } else {
                    try out.print("{{\"checked\":{s},\"text\":\"{s}\"}}", .{
                        if (item.checked) "true" else "false",
                        item.text,
                    });
                }
            }
        }
        try out.writeAll("]\n");
        try out.flush();
    } else {
        var buf: [4096]u8 = undefined;
        var w = Io.File.writer(.stdout(), io, &buf);
        const out = &w.interface;
        for (items) |item| {
            if (!show_all and item.checked) continue;
            const checkbox: []const u8 = if (item.checked) "[x]" else "[ ]";
            if (item.priority) |p| {
                try out.print("- {s} {s} {s}\n", .{ checkbox, item.text, p.toTag() });
            } else {
                try out.print("- {s} {s}\n", .{ checkbox, item.text });
            }
        }
        try out.flush();
    }
}

fn todayDate(io: Io) core.ids.Id.Date {
    const now = Io.Timestamp.now(io, .real);
    const secs: u64 = @intCast(now.toSeconds() + utc_offset_secs);
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
    const secs: u64 = @intCast(now.toSeconds() + utc_offset_secs);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const hms = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}", .{
        hms.getHoursIntoDay(),
        hms.getMinutesIntoHour(),
    });
}

fn todayTimestampYYMMDDHHMM(io: Io, allocator: Allocator) ![]const u8 {
    const now = Io.Timestamp.now(io, .real);
    const secs: u64 = @intCast(now.toSeconds() + utc_offset_secs);
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
    const root = resolveJournalRoot(allocator, io);
    return std.fmt.allocPrint(allocator, "{s}/daily/{s}", .{ root, date_str });
}

/// Resolve the local UTC offset in seconds. Honours $TZ (a zone name like
/// "Europe/London" or a POSIX rule like "EST5EDT,M3.2.0,M11.1.0"), falling
/// back to /etc/localtime. Returns null when no timezone data is available.
fn resolveLocalUtcOffset(allocator: Allocator, io: Io, env: std.process.Environ) ?i64 {
    if (env.getPosix("TZ")) |tz_val| {
        var name = tz_val;
        if (name.len > 0 and (name[0] == ':' or name[0] == '/')) name = name[1..];
        if (core.tz.parsePosixRule(name)) |rule| {
            return rule.offsetAt(Io.Timestamp.now(io, .real).toSeconds());
        } else |_| {}
        if (readTzFile(allocator, io, name)) |data| {
            defer allocator.free(data);
            if (core.tz.parse(allocator, data)) |tz_val_parsed| {
                var tz = tz_val_parsed;
                defer tz.deinit();
                return tz.offsetAt(Io.Timestamp.now(io, .real).toSeconds());
            } else |_| {}
        }
    }
    const data = readEtcLocaltime(allocator, io) orelse return null;
    defer allocator.free(data);
    var tz = core.tz.parse(allocator, data) catch return null;
    defer tz.deinit();
    return tz.offsetAt(Io.Timestamp.now(io, .real).toSeconds());
}

fn readEtcLocaltime(allocator: Allocator, io: Io) ?[]const u8 {
    if (io_mod.readFromDir(allocator, Io.Dir.cwd(), io, "/etc/localtime")) |read| {
        return read.content;
    } else |_| {}
    return readTzFile(allocator, io, "UTC");
}

fn readTzFile(allocator: Allocator, io: Io, name: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrint(allocator, "/usr/share/zoneinfo/{s}", .{name}) catch return null;
    defer allocator.free(path);
    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, path) catch return null;
    return read.content;
}

/// Read .devjournal.toml and return the journal root path.
/// Falls back to "journal" (relative to CWD) if config not found or unreadable.
fn resolveJournalRoot(allocator: Allocator, io: Io) []const u8 {
    if (io_mod.readFromDir(allocator, Io.Dir.cwd(), io, ".devjournal.toml")) |read| {
        defer read.deinit();
        if (core.config.parse(allocator, read.content)) |cfg| {
            defer cfg.deinit(allocator);
            return allocator.dupe(u8, cfg.journal_path) catch "journal";
        } else |_| {}
    } else |_| {}
    return "journal";
}

/// Build a path under the journal root (e.g. "backlog.md" -> "journal/backlog.md" or "/vault/journal/backlog.md").
fn journalPath(allocator: Allocator, io: Io, suffix: []const u8) []const u8 {
    const root = resolveJournalRoot(allocator, io);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, suffix }) catch suffix;
}

/// Try to resolve a journal path from the global vault_root config.
/// Returns null if no global config or no vault_root set.
fn resolveVaultRoot(allocator: Allocator, io: Io, env: std.process.Environ, project_name: []const u8) ?[]const u8 {
    const config_path = core.config.globalConfigPath(allocator, env) orelse return null;
    defer allocator.free(config_path);

    // Read the global config file (absolute path)
    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, config_path) catch return null;
    defer read.deinit();

    const global_cfg = core.config.parseGlobal(allocator, read.content) catch return null;
    defer global_cfg.deinit(allocator);

    const vr = global_cfg.vault_root orelse return null;
    return std.fmt.allocPrint(allocator, "{s}/Projects/{s}", .{ vr, project_name }) catch null;
}

fn cmdBacklogAdd(allocator: Allocator, io: Io, text: []const u8, priority: ?core.backlog.Priority, json_output: bool) !void {
    const backlog = journalPath(allocator, io, "backlog.md");
    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, backlog) catch {
        try printError(io, "backlog add", "backlog.md not found. Run 'devjournal init' first.");
        return;
    };
    defer read.deinit();

    const date = todayDate(io);
    const line = if (priority) |p|
        try core.backlog.buildItemLineWithPriority(allocator, text, date, p)
    else
        try core.backlog.buildItemLine(allocator, text, date);
    defer allocator.free(line);

    // Find insertion point: after last - [ ] line, or at end
    const new_content = try insertAfterLastOpenItem(allocator, read.content, line);
    defer allocator.free(new_content);

    try io_mod.writeToDir(Io.Dir.cwd(), io, backlog, new_content, read.mtime);

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
    const backlog = journalPath(allocator, io, "backlog.md");
    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, backlog) catch {
        try printError(io, "backlog done", "backlog.md not found.");
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

    try io_mod.writeToDir(Io.Dir.cwd(), io, backlog, new_content, read.mtime);

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
    io_mod.ensureDir(Io.Dir.cwd(), io, journalPath(allocator, io, "daily")) catch {};

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
    const sess_dir = journalPath(allocator, io, "sessions");
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sess_dir, fname });
    defer allocator.free(full_path);

    io_mod.ensureDir(Io.Dir.cwd(), io, sess_dir) catch {};
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
    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, journalPath(allocator, io, "overview.md")) catch {
        try printError(io, "project overview", "overview.md not found. Run 'devjournal init' first.");
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
    if (io_mod.readFromDir(allocator, Io.Dir.cwd(), io, journalPath(allocator, io, "overview.md"))) |read| {
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
    if (io_mod.readFromDir(allocator, Io.Dir.cwd(), io, journalPath(allocator, io, "backlog.md"))) |read| {
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

fn cmdBacklogToggle(allocator: Allocator, io: Io, id_str: []const u8, json_output: bool) !void {
    const backlog = journalPath(allocator, io, "backlog.md");
    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, backlog) catch {
        try printError(io, "backlog toggle", "backlog.md not found.");
        return;
    };
    defer read.deinit();

    const new_content = core.backlog.toggleTask(allocator, read.content, id_str) catch |err| {
        if (err == error.ItemNotFound) {
            try printError(io, "backlog toggle", "item not found");
            return;
        }
        return err;
    };
    defer allocator.free(new_content);

    try io_mod.writeToDir(Io.Dir.cwd(), io, backlog, new_content, read.mtime);

    var buf: [1024]u8 = undefined;
    var w = Io.File.writer(.stdout(), io, &buf);
    const out = &w.interface;
    if (json_output) {
        try out.print("{{\"status\":\"ok\",\"id\":\"{s}\"}}\n", .{id_str});
    } else {
        try out.print("Toggled task: {s}\n", .{id_str});
    }
    try out.flush();
}

fn cmdBacklogReorder(allocator: Allocator, io: Io, id_list: []const []const u8, json_output: bool) !void {
    const backlog = journalPath(allocator, io, "backlog.md");
    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, backlog) catch {
        try printError(io, "backlog reorder", "backlog.md not found.");
        return;
    };
    defer read.deinit();

    const new_content = core.backlog.reorder(allocator, read.content, id_list) catch {
        try printError(io, "backlog reorder", "failed to reorder");
        return;
    };
    defer allocator.free(new_content);

    try io_mod.writeToDir(Io.Dir.cwd(), io, backlog, new_content, read.mtime);

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
    const backlog = journalPath(allocator, io, "backlog.md");
    const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, backlog) catch {
        try printError(io, "backlog prioritise", "backlog.md not found.");
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

    try io_mod.writeToDir(Io.Dir.cwd(), io, backlog, new_content, read.mtime);

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

    io_mod.ensureDir(Io.Dir.cwd(), io, journalPath(allocator, io, "daily")) catch {};
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
    var dir = Io.Dir.cwd().openDir(io, journalPath(allocator, io, "sessions"), .{ .iterate = true }) catch {
        try printError(io, "session list", "sessions/ not found.");
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
    var dir = Io.Dir.cwd().openDir(io, journalPath(allocator, io, "sessions"), .{ .iterate = true }) catch {
        try printError(io, "project summary", "sessions/ not found.");
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
    const adr_dir = journalPath(allocator, io, "adr");
    io_mod.ensureDir(Io.Dir.cwd(), io, adr_dir) catch {};

    // Scan existing ADR files to find next number
    var dir = Io.Dir.cwd().openDir(io, adr_dir, .{ .iterate = true }) catch {
        try printError(io, "adr create", "cannot open adr directory");
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
    const full_path = try std.fmt.allocPrint(allocator, "{s}/adr/{s}", .{ resolveJournalRoot(allocator, io), fname });
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
    var dir = Io.Dir.cwd().openDir(io, journalPath(allocator, io, "adr"), .{ .iterate = true }) catch {
        try printError(io, "adr list", "adr/ not found.");
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
        const parsed = parseNoteCreateArgs(allocator, args[1..]) catch |err| switch (err) {
            error.MissingTitle => {
                try printError(io, "note create", "missing title");
                return;
            },
            error.MissingBodyValue => {
                try printError(io, "note create", "--body requires a value");
                return;
            },
            else => return err,
        };
        defer allocator.free(parsed.tags);

        // Body comes from --body, else piped stdin, else the placeholder
        var stdin_content: ?[]const u8 = null;
        defer if (stdin_content) |s| allocator.free(s);
        if (parsed.body == null) {
            stdin_content = readStdinIfPiped(allocator, io);
        }

        const body = core.note.resolveBody(parsed.body, stdin_content);
        try cmdNoteCreate(allocator, io, parsed.title, parsed.tags, body, json_output);
    } else {
        try printError(io, "note", "unknown subcommand");
    }
}

const NoteCreateArgs = struct {
    title: []const u8,
    tags: []const []const u8,
    body: ?[]const u8,
};

/// Parse `note create` arguments: first non-flag arg is the title, remaining
/// non-flag args are tags. `--body <text>` or `--body=<text>` sets the body.
fn parseNoteCreateArgs(allocator: Allocator, args: []const []const u8) !NoteCreateArgs {
    var title: ?[]const u8 = null;
    var body: ?[]const u8 = null;
    var tags = std.ArrayList([]const u8).empty;
    errdefer tags.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--body")) {
            i += 1;
            if (i >= args.len) return error.MissingBodyValue;
            body = args[i];
        } else if (std.mem.startsWith(u8, arg, "--body=")) {
            body = arg["--body=".len..];
        } else if (title == null) {
            title = arg;
        } else {
            try tags.append(allocator, arg);
        }
    }

    return .{
        .title = title orelse return error.MissingTitle,
        .tags = try tags.toOwnedSlice(allocator),
        .body = body,
    };
}

/// Read all of stdin when it is piped (not a TTY). Returns null for a TTY or
/// empty input. Caller owns the returned memory.
fn readStdinIfPiped(allocator: Allocator, io: Io) ?[]const u8 {
    const stdin = Io.File.stdin();
    const is_tty = stdin.isTty(io) catch true;
    if (is_tty) return null;

    var buf: [8192]u8 = undefined;
    var reader = stdin.reader(io, &buf);
    const content = reader.interface.allocRemaining(allocator, .unlimited) catch return null;
    if (content.len == 0) {
        allocator.free(content);
        return null;
    }
    return content;
}

fn cmdNoteCreate(allocator: Allocator, io: Io, title: []const u8, tags: []const []const u8, body: []const u8, json_output: bool) !void {
    const notes_dir = journalPath(allocator, io, "notes");
    io_mod.ensureDir(Io.Dir.cwd(), io, notes_dir) catch {};

    const date = todayDate(io);
    var date_buf: [10]u8 = undefined;
    const date_str = std.fmt.bufPrint(&date_buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        date.year, date.month, date.day,
    }) catch unreachable;

    const note_content = core.note.build(
        allocator,
        title,
        if (tags.len > 0) tags else null,
        date_str,
        body,
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

    const full_path = try std.fmt.allocPrint(allocator, "{s}/notes/{s}", .{ resolveJournalRoot(allocator, io), fname });
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

    // Search all markdown files in the resolved journal directory
    const journal_root = resolveJournalRoot(allocator, io);
    var all_matches = std.ArrayListUnmanaged(core.search.Match).empty;
    defer {
        for (all_matches.items) |m| {
            allocator.free(m.file);
            allocator.free(m.line);
        }
        all_matches.deinit(allocator);
    }

    try searchDir(allocator, io, journal_root, query, &all_matches);

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

const TOOLS_COUNT = 23;

fn getTools() [TOOLS_COUNT]mcp.Tool {
    return [_]mcp.Tool{
        .{
            .name = "devjournal_init",
            .description = "Initialize a new journal structure with project overview and backlog",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"project\":{\"type\":\"string\",\"description\":\"Project name\"}}}",
        },
        .{
            .name = "devjournal_project_list",
            .description = "List all projects in the journal",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
        },
        .{
            .name = "devjournal_project_create",
            .description = "Create a new project with overview.md and backlog.md",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"project\":{\"type\":\"string\",\"description\":\"Project name\"},\"description\":{\"type\":\"string\",\"description\":\"Project description\"},\"repo\":{\"type\":\"string\",\"description\":\"Repository (owner/repo)\"},\"tech\":{\"type\":\"string\",\"description\":\"Tech stack\"}},\"required\":[\"project\"]}",
        },
        .{
            .name = "devjournal_project_overview",
            .description = "Show project overview metadata (description, status, repo, tech)",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
        },
        .{
            .name = "devjournal_project_context",
            .description = "Load full project context: overview, recent sessions, and open backlog items. Use this at the start of a session.",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
        },
        .{
            .name = "devjournal_project_summary",
            .description = "Show project activity summary (session count, total entries)",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
        },
        .{
            .name = "devjournal_backlog_read",
            .description = "Read raw backlog content (all items including done)",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
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
            .name = "devjournal_backlog_reorder",
            .description = "Reorder backlog items by moving given IDs to the top in order",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"ids\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Item IDs in desired order\"}},\"required\":[\"ids\"]}",
        },
        .{
            .name = "devjournal_backlog_prioritise",
            .description = "Move a backlog item to a specific position (1 = top)",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\",\"description\":\"Item ID\"},\"position\":{\"type\":\"integer\",\"description\":\"Target position (1-indexed)\"}},\"required\":[\"id\",\"position\"]}",
        },
        .{
            .name = "devjournal_toggle_task",
            .description = "Toggle a backlog item's checkbox (checked <-> unchecked). Use for non-backlog tasks like review findings or debug hypotheses.",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\",\"description\":\"Item ID or text substring\"}},\"required\":[\"id\"]}",
        },
        .{
            .name = "devjournal_daily_show",
            .description = "Show today's daily note content",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
        },
        .{
            .name = "devjournal_daily_read",
            .description = "Read today's daily note content (alias of daily_show)",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
        },
        .{
            .name = "devjournal_daily_append",
            .description = "Append a timestamped entry to today's daily note",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\",\"description\":\"Entry text\"}},\"required\":[\"text\"]}",
        },
        .{
            .name = "devjournal_daily_prepend",
            .description = "Prepend an entry to today's daily note (after frontmatter)",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\",\"description\":\"Entry text\"}},\"required\":[\"text\"]}",
        },
        .{
            .name = "devjournal_session_create",
            .description = "Create a session note from today's daily entries",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"topic\":{\"type\":\"string\",\"description\":\"Session topic\"}},\"required\":[\"topic\"]}",
        },
        .{
            .name = "devjournal_session_list",
            .description = "List all session notes sorted by date",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
        },
        .{
            .name = "devjournal_create_note",
            .description = "Create a generic note with optional tags. For ADRs, TILs, debug logs, code reviews.",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\",\"description\":\"Note title\"},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Tags for the note\"},\"body\":{\"type\":\"string\",\"description\":\"Note body content\"}},\"required\":[\"title\"]}",
        },
        .{
            .name = "devjournal_adr_create",
            .description = "Create a new Architecture Decision Record (auto-numbered)",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\",\"description\":\"ADR title\"}},\"required\":[\"title\"]}",
        },
        .{
            .name = "devjournal_dashboard",
            .description = "Show cross-project dashboard summary",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
        },
        .{
            .name = "devjournal_search",
            .description = "Search across all journal files for a query string",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Search query\"}},\"required\":[\"query\"]}",
        },
    };
}

fn dispatchTool(allocator: Allocator, io: Io, tool_name: []const u8, args_json: []const u8) ![]const u8 {
    const journal = resolveJournalRoot(allocator, io);
    if (std.mem.eql(u8, tool_name, "devjournal_init")) {
        return mcp.buildToolResultText(allocator, "Init: use devjournal init from CLI", false);
    }

    if (std.mem.eql(u8, tool_name, "devjournal_backlog_list")) {
        const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, journalPath(allocator, io, "backlog.md")) catch
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
            if (item.priority) |p| {
                try buf.print(allocator, "- {s} {s} {s}\n", .{ id_str, item.text, p.toTag() });
            } else {
                try buf.print(allocator, "- {s} {s}\n", .{ id_str, item.text });
            }
        }
        return try buf.toOwnedSlice(allocator);
    }

    if (std.mem.eql(u8, tool_name, "devjournal_backlog_add")) {
        const text = try mcp.extractString(allocator, args_json, "text") orelse
            return allocator.dupe(u8, "Missing text parameter");
        defer allocator.free(text);

        const backlog = journalPath(allocator, io, "backlog.md");
        const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, backlog) catch
            return allocator.dupe(u8, "No backlog.md found");
        defer read.deinit();

        const date = todayDate(io);
        const line = try core.backlog.buildItemLine(allocator, text, date);
        defer allocator.free(line);

        const new_content = try insertAfterLastOpenItem(allocator, read.content, line);
        defer allocator.free(new_content);

        try io_mod.writeToDir(Io.Dir.cwd(), io, backlog, new_content, read.mtime);
        return try std.fmt.allocPrint(allocator, "Added: {s}", .{line});
    }

    if (std.mem.eql(u8, tool_name, "devjournal_backlog_done")) {
        const id_str = try mcp.extractString(allocator, args_json, "id") orelse
            return allocator.dupe(u8, "Missing id parameter");
        defer allocator.free(id_str);

        const backlog = journalPath(allocator, io, "backlog.md");
        const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, backlog) catch
            return allocator.dupe(u8, "No backlog.md found");
        defer read.deinit();

        const ts = try todayTimestampYYMMDDHHMM(io, allocator);
        defer allocator.free(ts);

        const new_content = core.backlog.markDone(allocator, read.content, id_str, ts) catch |err| {
            if (err == error.ItemNotFound) return allocator.dupe(u8, "Item not found");
            return err;
        };
        defer allocator.free(new_content);

        try io_mod.writeToDir(Io.Dir.cwd(), io, backlog, new_content, read.mtime);
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

        io_mod.ensureDir(Io.Dir.cwd(), io, journalPath(allocator, io, "daily")) catch {};
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
        const sess_dir = journalPath(allocator, io, "sessions");
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sess_dir, fname });
        defer allocator.free(full_path);

        io_mod.ensureDir(Io.Dir.cwd(), io, sess_dir) catch {};
        try io_mod.writeToDir(Io.Dir.cwd(), io, full_path, note, null);
        return try std.fmt.allocPrint(allocator, "Created session: {s} ({d} entries)", .{ full_path, entries.len });
    }

    if (std.mem.eql(u8, tool_name, "devjournal_project_overview")) {
        const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, journalPath(allocator, io, "overview.md")) catch
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
        if (io_mod.readFromDir(allocator, Io.Dir.cwd(), io, journalPath(allocator, io, "backlog.md"))) |read| {
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

        io_mod.ensureDir(Io.Dir.cwd(), io, journalPath(allocator, io, "adr")) catch {};

        var dir = Io.Dir.cwd().openDir(io, journalPath(allocator, io, "adr"), .{ .iterate = true }) catch
            return allocator.dupe(u8, "Cannot open adr directory");
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
        const full_path = try std.fmt.allocPrint(allocator, "{s}/adr/{s}", .{ journal, fname });
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

        try searchDir(allocator, io, journal, query, &all_matches);

        var buf = std.ArrayList(u8).empty;
        for (all_matches.items) |m| {
            try buf.print(allocator, "{s}:{d}: {s}\n", .{ m.file, m.line_number, m.line });
        }

        if (all_matches.items.len == 0) {
            return try std.fmt.allocPrint(allocator, "No matches for \"{s}\"", .{query});
        }
        return try buf.toOwnedSlice(allocator);
    }

    // === New tools (project context, backlog read/reorder/prioritise, daily read/prepend, session list, create note, toggle task) ===

    if (std.mem.eql(u8, tool_name, "devjournal_project_list")) {
        var dir = Io.Dir.cwd().openDir(io, journal, .{ .iterate = true }) catch
            return allocator.dupe(u8, "No journal directory found");
        defer dir.close(io);

        var buf = std.ArrayList(u8).empty;
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind == .directory) {
                // Check if it has overview.md
                const overview_path = try std.fmt.allocPrint(allocator, "{s}/{s}/overview.md", .{ journal, entry.name });
                defer allocator.free(overview_path);
                if (io_mod.fileExists(Io.Dir.cwd(), io, overview_path)) {
                    try buf.print(allocator, "{s}\n", .{entry.name});
                }
            }
        }
        if (buf.items.len == 0) {
            return allocator.dupe(u8, "No projects found");
        }
        return try buf.toOwnedSlice(allocator);
    }

    if (std.mem.eql(u8, tool_name, "devjournal_project_create")) {
        const project = try mcp.extractString(allocator, args_json, "project") orelse
            return allocator.dupe(u8, "Missing project parameter");
        defer allocator.free(project);

        const description = try mcp.extractString(allocator, args_json, "description");
        defer if (description) |d| allocator.free(d);
        const repo = try mcp.extractString(allocator, args_json, "repo");
        defer if (repo) |r| allocator.free(r);
        const tech = try mcp.extractString(allocator, args_json, "tech");
        defer if (tech) |t| allocator.free(t);

        const project_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ journal, project });
        defer allocator.free(project_dir);
        io_mod.ensureDir(Io.Dir.cwd(), io, project_dir) catch {};

        const overview = try core.project.buildOverview(allocator, project, description, repo, if (tech) |t| &[_][]const u8{t} else null, "active");
        defer allocator.free(overview);

        const overview_path = try std.fmt.allocPrint(allocator, "{s}/overview.md", .{project_dir});
        defer allocator.free(overview_path);
        try io_mod.writeToDir(Io.Dir.cwd(), io, overview_path, overview, null);

        const backlog_path = try std.fmt.allocPrint(allocator, "{s}/backlog.md", .{project_dir});
        defer allocator.free(backlog_path);
        const backlog_content = try std.fmt.allocPrint(allocator, "# Backlog -- {s}\n\n", .{project});
        defer allocator.free(backlog_content);
        try io_mod.writeToDir(Io.Dir.cwd(), io, backlog_path, backlog_content, null);

        return try std.fmt.allocPrint(allocator, "Created project: {s}", .{project});
    }

    if (std.mem.eql(u8, tool_name, "devjournal_project_context")) {
        // Composite: overview + recent sessions + open backlog items
        var buf = std.ArrayList(u8).empty;

        // Overview
        if (io_mod.readFromDir(allocator, Io.Dir.cwd(), io, journalPath(allocator, io, "overview.md"))) |read| {
            defer read.deinit();
            if (core.project.parseOverview(allocator, read.content)) |maybe_info| {
                if (maybe_info) |info| {
                    defer info.deinit();
                    try buf.print(allocator, "## Project: {s}\nStatus: {s}\n", .{ info.name, info.status });
                    if (info.repo) |r| try buf.print(allocator, "Repo: {s}\n", .{r});
                    if (info.tech) |t| {
                        try buf.appendSlice(allocator, "Tech:");
                        for (t) |item| try buf.print(allocator, " {s}", .{item});
                        try buf.append(allocator, '\n');
                    }
                    try buf.append(allocator, '\n');
                }
            } else |_| {}
        } else |_| {}

        // Recent sessions (last 3)
        var dir = Io.Dir.cwd().openDir(io, journalPath(allocator, io, "sessions"), .{ .iterate = true }) catch null;
        if (dir) |*d| {
            defer d.close(io);
            var filenames = std.ArrayListUnmanaged([]const u8).empty;
            defer {
                for (filenames.items) |f| allocator.free(f);
                filenames.deinit(allocator);
            }
            var iter = d.iterate();
            while (try iter.next(io)) |entry| {
                if (core.session.parseSessionFilename(entry.name) != null) {
                    try filenames.append(allocator, try allocator.dupe(u8, entry.name));
                }
            }
            // Sort by date (descending)
            std.mem.sort([]const u8, filenames.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, b, a); // reverse for descending
                }
            }.lessThan);

            if (filenames.items.len > 0) {
                try buf.appendSlice(allocator, "## Recent Sessions\n");
                const count = @min(filenames.items.len, 3);
                for (filenames.items[0..count]) |f| {
                    if (core.session.parseSessionFilename(f)) |s| {
                        try buf.print(allocator, "- {s} {s}\n", .{ s.date, s.topic });
                    }
                }
                try buf.append(allocator, '\n');
            }
        }

        // Open backlog items
        if (io_mod.readFromDir(allocator, Io.Dir.cwd(), io, journalPath(allocator, io, "backlog.md"))) |read| {
            defer read.deinit();
            if (core.backlog.parseItems(allocator, read.content)) |items| {
                defer allocator.free(items);
                var open_count: usize = 0;
                try buf.appendSlice(allocator, "## Open Backlog Items\n");
                for (items) |item| {
                    if (!item.checked) {
                        open_count += 1;
                        const id_str = if (item.id) |id| blk: {
                            var id_buf: [18]u8 = undefined;
                            break :blk id.format(&id_buf);
                        } else "no-id";
                        try buf.print(allocator, "- {s} {s}\n", .{ id_str, item.text });
                    }
                }
                if (open_count == 0) {
                    try buf.appendSlice(allocator, "(none)\n");
                }
            } else |_| {}
        } else |_| {}

        if (buf.items.len == 0) {
            return allocator.dupe(u8, "No project context found. Run 'devjournal init' first.");
        }
        return try buf.toOwnedSlice(allocator);
    }

    if (std.mem.eql(u8, tool_name, "devjournal_project_summary")) {
        var dir = Io.Dir.cwd().openDir(io, journalPath(allocator, io, "sessions"), .{ .iterate = true }) catch
            return allocator.dupe(u8, "No sessions found");
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
                try counts.append(allocator, 0);
            }
        }

        const summary = try core.project.buildSummary(allocator, dates.items, topics.items, counts.items);
        defer allocator.free(summary.sessions);

        var buf = std.ArrayList(u8).empty;
        try buf.print(allocator, "Sessions: {d}\n", .{summary.session_count});
        for (summary.sessions) |s| {
            try buf.print(allocator, "  {s} {s}\n", .{ s.date, s.topic });
        }
        return try buf.toOwnedSlice(allocator);
    }

    if (std.mem.eql(u8, tool_name, "devjournal_backlog_read")) {
        const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, journalPath(allocator, io, "backlog.md")) catch
            return mcp.buildToolResultText(allocator, "No backlog.md found", true);
        defer read.deinit();
        return try allocator.dupe(u8, read.content);
    }

    if (std.mem.eql(u8, tool_name, "devjournal_backlog_reorder")) {
        const ids_json = try mcp.extractRaw(allocator, args_json, "ids") orelse
            return allocator.dupe(u8, "Missing ids parameter");
        defer allocator.free(ids_json);

        const id_list = try mcp.extractStringArray(allocator, ids_json, "") orelse
            return allocator.dupe(u8, "Failed to parse ids array");
        defer {
            for (id_list) |s| allocator.free(s);
            allocator.free(id_list);
        }

        const backlog = journalPath(allocator, io, "backlog.md");
        const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, backlog) catch
            return allocator.dupe(u8, "No backlog.md found");
        defer read.deinit();

        const new_content = core.backlog.reorder(allocator, read.content, id_list) catch
            return allocator.dupe(u8, "Failed to reorder");
        defer allocator.free(new_content);

        try io_mod.writeToDir(Io.Dir.cwd(), io, backlog, new_content, read.mtime);
        return try std.fmt.allocPrint(allocator, "Reordered {d} items to top", .{id_list.len});
    }

    if (std.mem.eql(u8, tool_name, "devjournal_backlog_prioritise")) {
        const id_str = try mcp.extractString(allocator, args_json, "id") orelse
            return allocator.dupe(u8, "Missing id parameter");
        defer allocator.free(id_str);

        const position = try mcp.extractInteger(allocator, args_json, "position") orelse
            return allocator.dupe(u8, "Missing position parameter");

        const backlog = journalPath(allocator, io, "backlog.md");
        const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, backlog) catch
            return allocator.dupe(u8, "No backlog.md found");
        defer read.deinit();

        const new_content = core.backlog.prioritise(allocator, read.content, id_str, @intCast(position)) catch |err| {
            if (err == error.ItemNotFound) return allocator.dupe(u8, "Item not found");
            return err;
        };
        defer allocator.free(new_content);

        try io_mod.writeToDir(Io.Dir.cwd(), io, backlog, new_content, read.mtime);
        return try std.fmt.allocPrint(allocator, "Moved {s} to position {d}", .{ id_str, position });
    }

    if (std.mem.eql(u8, tool_name, "devjournal_toggle_task")) {
        const id_str = try mcp.extractString(allocator, args_json, "id") orelse
            return allocator.dupe(u8, "Missing id parameter");
        defer allocator.free(id_str);

        const backlog = journalPath(allocator, io, "backlog.md");
        const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, backlog) catch
            return allocator.dupe(u8, "No backlog.md found");
        defer read.deinit();

        const new_content = core.backlog.toggleTask(allocator, read.content, id_str) catch |err| {
            if (err == error.ItemNotFound) return allocator.dupe(u8, "Item not found");
            return err;
        };
        defer allocator.free(new_content);

        try io_mod.writeToDir(Io.Dir.cwd(), io, backlog, new_content, read.mtime);
        return try std.fmt.allocPrint(allocator, "Toggled task: {s}", .{id_str});
    }

    if (std.mem.eql(u8, tool_name, "devjournal_daily_read")) {
        // Alias of daily_show
        const path = try todayFilename(allocator, io);
        defer allocator.free(path);
        const read = io_mod.readFromDir(allocator, Io.Dir.cwd(), io, path) catch
            return allocator.dupe(u8, "No daily note for today");
        defer read.deinit();
        return try allocator.dupe(u8, read.content);
    }

    if (std.mem.eql(u8, tool_name, "devjournal_daily_prepend")) {
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

        const new_content = try core.daily.prependContent(allocator, existing_content, entry);
        defer allocator.free(new_content);
        if (read_owned) allocator.free(existing_content);

        io_mod.ensureDir(Io.Dir.cwd(), io, journalPath(allocator, io, "daily")) catch {};
        try io_mod.writeToDir(Io.Dir.cwd(), io, path, new_content, mtime_guard);
        return try std.fmt.allocPrint(allocator, "Prepended: {s}", .{entry});
    }

    if (std.mem.eql(u8, tool_name, "devjournal_session_list")) {
        var dir = Io.Dir.cwd().openDir(io, journalPath(allocator, io, "sessions"), .{ .iterate = true }) catch
            return allocator.dupe(u8, "No sessions directory found");
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

        std.mem.sort(core.session.SessionSummary, summaries, {}, struct {
            fn lessThan(_: void, a: core.session.SessionSummary, b: core.session.SessionSummary) bool {
                return std.mem.lessThan(u8, a.date, b.date);
            }
        }.lessThan);

        var buf = std.ArrayList(u8).empty;
        if (summaries.len == 0) {
            return allocator.dupe(u8, "No session notes found.");
        }
        for (summaries) |s| {
            try buf.print(allocator, "{s} {s}\n", .{ s.date, s.topic });
        }
        return try buf.toOwnedSlice(allocator);
    }

    if (std.mem.eql(u8, tool_name, "devjournal_create_note")) {
        const title = try mcp.extractString(allocator, args_json, "title") orelse
            return allocator.dupe(u8, "Missing title parameter");
        defer allocator.free(title);

        const body = try mcp.extractString(allocator, args_json, "body") orelse "(TODO: write your note here)";
        defer if (!std.mem.eql(u8, body, "(TODO: write your note here)")) allocator.free(body);

        const tags = try mcp.extractStringArray(allocator, args_json, "tags");
        defer if (tags) |t| {
            for (t) |s| allocator.free(s);
            allocator.free(t);
        };

        const date = todayDate(io);
        var date_buf: [10]u8 = undefined;
        const date_str = std.fmt.bufPrint(&date_buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
            date.year, date.month, date.day,
        }) catch unreachable;

        const note_content = core.note.build(allocator, title, tags, date_str, body) catch
            return allocator.dupe(u8, "Failed to build note");
        defer allocator.free(note_content);

        var fname_buf: [128]u8 = undefined;
        const fname = std.fmt.bufPrint(&fname_buf, "{s}.md", .{title}) catch
            return allocator.dupe(u8, "Title too long for filename");

        io_mod.ensureDir(Io.Dir.cwd(), io, journalPath(allocator, io, "notes")) catch {};
        const full_path = try std.fmt.allocPrint(allocator, "{s}/notes/{s}", .{ journal, fname });
        defer allocator.free(full_path);

        try io_mod.writeToDir(Io.Dir.cwd(), io, full_path, note_content, null);
        return try std.fmt.allocPrint(allocator, "Created: {s}", .{full_path});
    }

    return try std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{tool_name});
}

// Journal path is now resolved from .devjournal.toml via resolveJournalRoot()

// ==================== TESTS ====================

test "parseNoteCreateArgs title and tags" {
    const args = [_][]const u8{ "TIL -- x", "til", "zig" };
    const parsed = try parseNoteCreateArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.tags);

    try testing.expectEqualStrings("TIL -- x", parsed.title);
    try testing.expectEqual(@as(usize, 2), parsed.tags.len);
    try testing.expectEqualStrings("til", parsed.tags[0]);
    try testing.expectEqualStrings("zig", parsed.tags[1]);
    try testing.expect(parsed.body == null);
}

test "parseNoteCreateArgs with --body flag" {
    const args = [_][]const u8{ "TIL -- x", "--body", "Some body text.", "til" };
    const parsed = try parseNoteCreateArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.tags);

    try testing.expectEqualStrings("TIL -- x", parsed.title);
    try testing.expectEqualStrings("Some body text.", parsed.body.?);
    try testing.expectEqual(@as(usize, 1), parsed.tags.len);
    try testing.expectEqualStrings("til", parsed.tags[0]);
}

test "parseNoteCreateArgs with --body= form" {
    const args = [_][]const u8{ "Review -- PR 12", "--body=Findings here." };
    const parsed = try parseNoteCreateArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.tags);

    try testing.expectEqualStrings("Review -- PR 12", parsed.title);
    try testing.expectEqualStrings("Findings here.", parsed.body.?);
    try testing.expectEqual(@as(usize, 0), parsed.tags.len);
}

test "parseNoteCreateArgs body flag before title" {
    const args = [_][]const u8{ "--body", "First.", "Debug -- login", "debug" };
    const parsed = try parseNoteCreateArgs(testing.allocator, &args);
    defer testing.allocator.free(parsed.tags);

    try testing.expectEqualStrings("Debug -- login", parsed.title);
    try testing.expectEqualStrings("First.", parsed.body.?);
    try testing.expectEqual(@as(usize, 1), parsed.tags.len);
}

test "parseNoteCreateArgs errors without title" {
    const args = [_][]const u8{};
    try testing.expectError(error.MissingTitle, parseNoteCreateArgs(testing.allocator, &args));

    const only_body = [_][]const u8{ "--body", "text" };
    try testing.expectError(error.MissingTitle, parseNoteCreateArgs(testing.allocator, &only_body));
}

test "parseNoteCreateArgs errors when --body lacks a value" {
    const args = [_][]const u8{ "Title", "--body" };
    try testing.expectError(error.MissingBodyValue, parseNoteCreateArgs(testing.allocator, &args));
}
