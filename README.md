# DevJournal

A CLI tool for managing the journaling process for coding projects. Works standalone from the command line, alongside markdown-based tools like Obsidian, and as an MCP server for AI agents.

![DevJournal demo](demo/demo.gif)

## Features

- **Backlog management** — add, list, done, reorder, prioritise items with deterministic IDs
- **Daily notes** — timestamped entries with append and prepend
- **Session notes** — create summaries from daily entries
- **Architecture Decision Records** — auto-numbered ADRs with frontmatter
- **Project overview** — metadata with YAML frontmatter
- **Full-text search** — case-insensitive search across all journal files
- **MCP server** — JSON-RPC 2.0 transport for AI agent integration
- **Atomic writes** — mtime conflict guard prevents data loss

## Installation

```bash
# Build and install to ~/.local/bin/
zig build install-local

# Or just build
zig build
# Binary at ./zig-out/bin/devjournal
```

Requires Zig 0.17.0+.

## Quick Start

```bash
# Initialize a journal in the current directory
devjournal init --project MyProject

# Initialize with a custom journal location
devjournal init --project MyProject --journal /path/to/journal

# Add backlog items
devjournal backlog add "Implement feature X"
devjournal backlog add "Fix bug Y" --priority high

# Log daily work
devjournal daily append "Started working on feature X"
devjournal daily append "Feature X complete, tests passing"

# Mark items done
devjournal backlog done [#20260809-xxxx]

# Create a session note from today's entries
devjournal session create "Build feature X"

# Create an ADR
devjournal adr create "Use Zig for CLI tool"

# Search across all journal files
devjournal search "feature X"

# See everything at a glance
devjournal dashboard
```

## Commands

| Command                                         | Description                                        |
| ----------------------------------------------- | -------------------------------------------------- |
| `init [--project <name>] [--journal <path>]`    | Initialize journal structure                       |
| `backlog list [--all]`                          | List open backlog items (with priorities)          |
| `backlog add <text> [--priority <level>]`       | Add a backlog item (high/medium/low)               |
| `backlog done <id>`                             | Mark item done with timestamp                      |
| `backlog toggle <id>`                           | Toggle a task checkbox (check/uncheck)             |
| `backlog reorder <id> [id...]`                  | Move items to top in order                         |
| `backlog prioritise <id> <pos>`                 | Move item to specific position                     |
| `daily show`                                    | Show today's daily note                            |
| `daily append <text>`                           | Append timestamped entry                           |
| `daily prepend <text>`                          | Prepend entry (after frontmatter)                  |
| `session create <topic>`                        | Create session note from today's entries           |
| `session list`                                  | List all session notes                             |
| `project overview`                              | Show project metadata                              |
| `project summary`                               | Show activity summary                              |
| `adr create <title>`                            | Create auto-numbered ADR                           |
| `adr list`                                      | List all ADRs                                      |
| `note create <title> [tags...] [--body <text>]` | Create a tagged note (body from `--body` or stdin) |
| `search <query>`                                | Full-text search across journal                    |
| `dashboard`                                     | Cross-project overview                             |
| `relocate [path]`                               | Fix moved journal path                             |

## Global Options

- `--json` — Output as JSON (for scripting and AI agents)
- `DEVJOURNAL_JSON=1` — Same as `--json` (environment variable)
- `--utc` — Timestamps in UTC instead of local time
- `DEVJOURNAL_UTC=1` — Same as `--utc` (environment variable)

Timestamps (daily entry times, `@done` stamps, note/ADR dates) default to local
time, honouring `$TZ` and `/etc/localtime`.

## Shell Alias

For a shorter command, add this to your shell profile (`~/.zshrc`, `~/.bashrc`):

```bash
alias dj='devjournal'
```

## MCP Server

Run as an MCP server for AI agent integration:

```bash
devjournal --mcp
```

Exposes 11 MCP tools (`devjournal_init`, `devjournal_backlog_list`, etc.) via JSON-RPC 2.0 over stdio.

## Journal Structure

```text
journal/
    overview.md          # Project metadata (YAML frontmatter)
    backlog.md           # Task list with IDs
    daily/
        2026-08-09.md    # Daily notes
    sessions/
        2026-08-09 Topic.md
    adr/
        ADR-001.md       # Architecture Decision Records
    notes/               # Generic tagged notes
```

## Configuration

### Per-project: `.devjournal.toml`

A `.devjournal.toml` file in the project root:

```toml
journal = "./journal"

[project_meta]
description = "My project"
repo = "owner/repo"
tech = ["Zig", "Shell"]
status = "active"
```

### Global: `~/.config/devjournal/config.toml`

Optional global config for setting a default vault location. When `vault_root`
is set, `devjournal init` creates journals under `{vault_root}/Projects/{name}/`
automatically — no need to pass `--journal` every time.

```toml
[defaults]
vault_root = "/path/to/your/obsidian/vault/Code Journal"
```

Respects `$XDG_CONFIG_HOME` if set (defaults to `~/.config`).

### Journal path priority

When running `devjournal init`:

1. `--journal <path>` flag (explicit)
2. `vault_root` from global config → `{vault_root}/Projects/{name}/`
3. `./journal/` (default fallback)

## License

MIT
