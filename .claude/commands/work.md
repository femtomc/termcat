# Work Command

Pick up an issue from the tracker and work it to completion.

## Phase 1: Select Issue

1. Run `bd ready` to see issues with no blockers
2. Pick the highest priority issue (P0 > P1 > P2 > P3)
3. Run `bd show <issue-id>` to read full details
4. Run `bd update <issue-id> --status in_progress` to claim it

## Phase 2: Implement

1. **Understand** the requirements fully before writing code
2. **Explore** relevant code to understand existing patterns
3. **Plan** your approach
4. **Implement** following Zig idioms:
   - Follow `.claude/ZIG_STYLE.md` conventions
   - Run `zig fmt .` before considering work complete
   - Run `zig build test` to ensure all tests pass
   - Add tests if the change warrants them

## Phase 3: Review Cycle

When you believe the implementation is complete:

1. Run `zig fmt --check src/` and `zig build test` one final time
2. Run the triple review script:
   ```bash
   ./scripts/triple-review.sh <issue-id>
   ```

   This script automatically:
   - Detects modified files from git
   - Fetches the issue title
   - Spawns Codex, Gemini, and Claude reviewers in parallel
   - Waits for all three to complete
   - Shows all review comments

3. Review the results:
   - If **any** reviewer requested changes: Address the feedback and re-run the script
   - If **all three** say LGTM: Proceed to Phase 4

## Phase 4: Complete

1. Close the issue: `bd close <issue-id>`
2. Commit and push:
   ```bash
   git add <modified-files>
   git commit -m "type: description"
   bd sync
   git push
   ```

   Commit types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`

3. Summarize what was accomplished
4. **Stop** - do not automatically pick up another issue

## Rules

- Work **ONE** issue at a time
- **Always** run `zig fmt` before completing
- **Always** run `zig build test` before completing
- **Do not skip the review cycle**. **DO NOT do the review yourself**.
- ALWAYS let **all three** reviewers (Codex, Gemini, Claude) finish their reviews
- Seriously, ALWAYS let all three reviewers finish before proceeding
- All three reviews must pass (LGTM) before closing an issue
- If tests fail, investigate and fix the root cause
- If blocked, document the blocker with `bd comment`
