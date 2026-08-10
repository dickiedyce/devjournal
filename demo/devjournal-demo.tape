# DevJournal Demo — vhs tape
# https://github.com/charmbracelet/vhs
# Record with: vhs devjournal-demo.tape

# ── Settings ──────────────────────────────────────────────
Output demo.gif
Set FontSize 18
Set FontFamily "OperatorMono Nerd Font"
Set Width 1200
Set Height 700
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 50ms
Set PlaybackSpeed 1.0

# ============================================================
# 1. Title Card
# ============================================================
Type "devjournal version"
Enter
Sleep 500ms
Type "devjournal help"
Enter
Sleep 4s

# ============================================================
# 2. Initialise a project
# ============================================================
Type "clear"
Enter
Sleep 300ms

Type "# Step 1: Initialise a journal"
Enter
Sleep 500ms
Type "devjournal init --project MyProject --journal ./journal"
Enter
Sleep 2s

Type "tree ./journal"
Enter
Sleep 2s

# ============================================================
# 3. Backlog Management
# ============================================================
Type "clear"
Enter
Sleep 300ms

Type "# Step 2: Manage your backlog"
Enter
Sleep 500ms
Type "devjournal backlog add 'Implement user authentication' --priority high"
Enter
Sleep 1s
Type "devjournal backlog add 'Add dark mode toggle'"
Enter
Sleep 1s
Type "devjournal backlog add 'Write integration tests' --priority medium"
Enter
Sleep 1s
Type "devjournal backlog add 'Set up CI/CD pipeline' --priority high"
Enter
Sleep 1s
Type "devjournal backlog list"
Enter
Sleep 2s

Type "tree ./journal"
Enter
Sleep 2s

Type "# Mark an item done"
Enter
Sleep 500ms
Type "devjournal backlog done [#20260810-9a66]"
Enter
Sleep 1s
Type "devjournal backlog list"
Enter
Sleep 2s

# ============================================================
# 4. Daily Notes
# ============================================================
Type "clear"
Enter
Sleep 300ms

Type "# Step 3: Log your work with daily notes"
Enter
Sleep 500ms
Type "devjournal daily append 'Started implementing auth module'"
Enter
Sleep 1s
Type "devjournal daily append 'JWT token generation working'"
Enter
Sleep 1s
Type "devjournal daily append 'All auth tests passing'"
Enter
Sleep 1s
Type "devjournal daily show"
Enter
Sleep 2s

# ============================================================
# 5. Session Notes
# ============================================================
Type "clear"
Enter
Sleep 300ms

Type "# Step 4: Create a session summary"
Enter
Sleep 500ms
Type "devjournal session create 'Implement auth'"
Enter
Sleep 2s

Type "devjournal session list"
Enter
Sleep 2s

# ============================================================
# 6. Architecture Decision Records
# ============================================================
Type "clear"
Enter
Sleep 300ms

Type "# Step 5: Record architecture decisions"
Enter
Sleep 500ms
Type "devjournal adr create 'Use JWT for authentication'"
Enter
Sleep 2s

Type "devjournal adr list"
Enter
Sleep 2s

# ============================================================
# 7. Tagged Notes
# ============================================================
Type "clear"
Enter
Sleep 300ms

Type "# Step 6: Create tagged notes"
Enter
Sleep 500ms
Type "devjournal note create 'Rate limiting approach' api security"
Enter
Sleep 2s

Type "devjournal note create 'JWT token refresh strategy' auth security"
Enter
Sleep 2s

Type "tree ./journal"
Enter
Sleep 4s

# ============================================================
# 8. Search
# ============================================================
Type "clear"
Enter
Sleep 300ms

Type "# Step 7: Full-text search across everything"
Enter
Sleep 500ms
Type "devjournal search 'auth'"
Enter
Sleep 2s

Type "devjournal search 'JWT'"
Enter
Sleep 2s

# ============================================================
# 9. Project Summary & Dashboard
# ============================================================
Type "clear"
Enter
Sleep 300ms

Type "# Step 8: Project overview and dashboard"
Enter
Sleep 500ms
Type "devjournal project summary"
Enter
Sleep 2s

Type "devjournal dashboard"
Enter
Sleep 2s

Type "devjournal backlog list --all"
Enter
Sleep 2s

# ============================================================
# 10. JSON Output
# =============================================================
Type "clear"
Enter
Sleep 300ms

Type "# Step 9: JSON output for scripting & AI agents"
Enter
Sleep 500ms
Type "devjournal --json backlog list | jq"
Enter
Sleep 2s

Type "devjournal --json project overview | jq"
Enter
Sleep 2s

# ============================================================
# 11. Closing
# ============================================================
Type "clear"
Enter
Sleep 300ms

Type "devjournal version"
Enter
Sleep 1s

Type "devjournal project overview"
Enter
Sleep 8s
