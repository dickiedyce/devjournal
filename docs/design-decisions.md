# DevJournal Design Decisions

## Overview

**DevJournal** is a CLI tool for managing the journaling process for coding projects. It handles backlogs, ADRs, overviews, daily notes, and session notes. It works standalone from the command line, alongside markdown-based tools like Obsidian, and as an MCP server for AI agents (Copilot, etc.).

---

## Language and Runtime

**Decision: Zig**

- Single static binary, zero external dependencies.
- Best-in-class cross-compilation.
- No hidden allocations, explicit memory management.
- Strong compile-time guarantees.

**Trade-offs accepted:** No existing YAML or MCP libraries in the Zig ecosystem. We hand-roll a YAML subset parser (~200-400 lines) and implement MCP JSON-RPC from scratch. These are manageable for the scope of this tool.

---

## Output Format

**Decision: Human-readable default with `--json` flag and `DEVJOURNAL_JSON` env var.**

- Default output is human-readable with alignment and color.
- `--json` global flag switches to structured JSON output.
- `DEVJOURNAL_JSON=1` environment variable overrides the default (useful for AI agent contexts).
- A shell alias `dj='devjournal --json'` provides a shorthand for machine-oriented use.

This follows the `git` convention — humans get colors, machines get JSON.

---

## Journal Discovery

**Decision: `.devjournal.toml` marker file in the project directory.**

The tool searches upward from `cwd` for `.devjournal.toml`. The marker lives in the **project directory** and points to the **journal folder**:

```toml
# .devjournal.toml (in project root)
journal = "../ObsidianVault/Code Journal"
```

**Resolution order (highest priority first):**

1. `DEVJOURNAL_PATH` environment variable
2. `.devjournal.toml` found by walking up from `cwd`
3. Error with helpful message

**Key insight:** The journal is a **self-contained folder** with a fixed internal layout. The tool does not assume anything about the parent vault structure. If the journal happens to be inside an Obsidian vault, Obsidian can browse it. If not, the tool still works.

### Journal folder layout

```
Code Journal/
    overview.md
    backlog.md
    daily/
        2026-08-09.md
    sessions/
        2026-08-09 Implement YAML parser.md
    adr/
        ADR-001.md
```

### Relocation

```
devjournal relocate /new/path/to/journal    # update .devjournal.toml
devjournal relocate                         # interactive prompt
```

On any command, if the journal path is invalid, the tool suggests `devjournal relocate`.

---

## Command Structure

**Decision: Hierarchical subcommands** following the `git`/`cargo` convention.

```
devjournal init [--project <name>]        # Create .devjournal.toml + journal structure
devjournal project <subcommand>           # list, create, overview, summary
devjournal backlog <subcommand>           # list, add, done, reorder, prioritise
devjournal daily <subcommand>             # show, append, prepend
devjournal session <subcommand>           # create, list
devjournal adr <subcommand>               # create, list, show
devjournal note <subcommand>              # create, read, append, search
devjournal search <query>                 # full-text journal search
devjournal dashboard                      # cross-project overview
devjournal relocate [path]                # fix moved journal
```

---

## Configuration

**Decision: Minimal `.devjournal.toml` for v0.1.**

```toml
journal = "../ObsidianVault/Code Journal"   # required: path to journal folder
```

Optional `[project_meta]` section for seeding `overview.md` on `init`:

```toml
[project_meta]
description = "CLI tool for managing coding journals"
repo = "dd/DevJournal"
tech = ["Zig", "Shell"]
status = "active"
```

Paths to daily notes, sessions, etc. are fixed by convention (not configurable in v0.1). Custom layouts deferred to v0.2.

---

## Backlog Item IDs

**Decision: Date + content hash. Format: `[#YYYYMMDD-XXXX]`**

- `YYYYMMDD` — full 4-digit year + month + day
- `XXXX` — 4-character hex hash derived from the item text

```markdown
- [ ] [#20260809-a3f2] Implement YAML parser
- [ ] [#20260809-b7c1] Design CLI structure @high
- [x] [#20260808-d4e9] Write ADR for ID scheme @done (26-08-09 14:30)
```

**Properties:**

- Deterministic: same text on same day produces the same ID.
- Globally unique across machines: no coordination needed.
- Human-readable date component for quick scanning.
- Agents can check "does this item exist?" without scanning the whole file.

Priority tags: `@high`, `@medium`, `@low` (appended at end of line).
Done timestamp: `@done (YY-MM-DD HH:mm)` (appended when marked done).

---

## Session Model

**Decision: Append-only daily notes with optional session summaries.**

No explicit `session start` / `session end` lifecycle. Instead:

- `devjournal daily append "message"` — timestamps an entry in today's daily note. This is the workhorse command.
- `devjournal session create "Topic"` — creates a session note from the day's entries, synthesizing a summary.

The daily note is the timeline. Session notes are curated summaries of focused work.

---

## YAML Frontmatter

**Decision: Hand-rolled YAML subset parser in pure Zig.**

The parser covers only the YAML constructs used in the vault:

- Scalar strings (`key: value`)
- Lists (`key:\n  - item\n  - item`)
- Booleans and nulls
- Quoted strings

Estimated ~200-400 lines. Fully testable, zero dependencies. If full YAML compliance is ever needed, the parser can be swapped for `libyaml` via Zig's C interop.

---

## File I/O Safety

**Decision: Atomic writes with mtime conflict guard.**

- **Atomic writes:** Write to a `.tmp` file, then `rename()` over the original. Prevents corruption on crash.
- **Mtime guard:** Before writing, check that the file's mtime matches what was seen at read time. If it changed (e.g. Obsidian edited the file), abort with an error and suggest retrying.
- **`--force` flag:** Overrides the mtime guard.
- **No file locking.** Obsidian doesn't lock files, so locking would only partially solve the problem.

---

## Architecture

**Decision: Single binary, dual mode (CLI + MCP).**

```
src/
    core/           # Domain logic (pure, no I/O)
        yaml.zig        # YAML subset parser
        frontmatter.zig # Frontmatter extraction/injection
        backlog.zig     # Backlog operations
        daily.zig       # Daily note operations
        session.zig     # Session note operations
        project.zig     # Project operations
        ids.zig         # ID generation (date + hash)
        config.zig      # .devjournal.toml parsing
    cli/            # CLI argument parsing + human output
        main.zig
        commands/
            init.zig
            backlog.zig
            daily.zig
            ...
    mcp/            # MCP JSON-RPC transport
        server.zig
        handlers.zig
    io/             # File I/O with atomic writes + mtime guard
        atomic.zig
        vault.zig
tests/
    integration/
        backlog_test.zig
        daily_test.zig
        session_test.zig
```

- **CLI mode:** `devjournal backlog add "Fix YAML parser"` — parses args, calls core, formats output.
- **MCP mode:** `devjournal --mcp` (or auto-detected when stdin is not a TTY and no subcommand given) — reads JSON-RPC from stdin, calls core, writes JSON-RPC to stdout.

---

## Testing Strategy

- **Unit tests** (inline `test` blocks in source): Pure logic — YAML parser, ID generation, frontmatter parsing, markdown formatting.
- **Integration tests** (`tests/integration/`): Each test creates a temp journal directory, runs commands, asserts on file contents, cleans up.
- **Snapshot tests**: Capture expected human-readable output strings for diffing.
- **No filesystem mocking.** Real temp directories provide better coverage with less complexity.

---

## v0.1 Scope (MVP)

| Command                          | Description                                          |
| -------------------------------- | ---------------------------------------------------- |
| `init`                           | Create `.devjournal.toml` + journal folder structure |
| `project list`                   | List all projects                                    |
| `project create`                 | Create a new project with overview.md                |
| `project overview`               | Show project overview                                |
| `backlog list`                   | List backlog items                                   |
| `backlog add`                    | Add a backlog item                                   |
| `backlog done`                   | Mark a backlog item done                             |
| `daily show`                     | Show today's daily note                              |
| `daily append`                   | Append a timestamped entry                           |
| `session create`                 | Create a session note from today's entries           |
| `dashboard`                      | Cross-project overview                               |
| `relocate`                       | Fix moved journal path                               |
| Global `--json`                  | Structured output for all commands                   |
| Global `DEVJOURNAL_JSON` env var | Same as `--json`                                     |

## Deferred to v0.2

- ADRs, TILs, debug logs, code reviews (`adr`, `note` commands)
- `search` (full-text journal search)
- `backlog reorder`, `backlog prioritise`
- `daily prepend`
- `session list`
- `project summary` (activity over date range)
- MCP server transport (`--mcp` mode)
- Custom vault structure paths
- GitHub issue sync
- Templates
