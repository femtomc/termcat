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
2. Track which files you modified during implementation
3. **Request reviews from BOTH Codex and Gemini in parallel** using the command templates below.

   > **These are templates!** Before running, replace:
   > - `<issue-id>` with the actual issue ID (e.g., `termcat-abc`)
   > - `<issue title>` with the actual issue title
   > - `path/to/file1.zig`, `path/to/file2.zig` with the actual files you modified

   **Codex review template:**
   ```bash
   codex exec --dangerously-bypass-approvals-and-sandbox 'You are a senior code reviewer performing a rigorous review for issue <issue-id>: "<issue title>".

   Files modified:
   - path/to/file1.zig
   - path/to/file2.zig

   ## Your Mindset

   Adopt an ADVERSARIAL mindset. Your job is to find problems, not to approve code. Assume the implementation has bugs until proven otherwise. Do not rubber-stamp. A quick "LGTM" without deep analysis is a failure of your responsibility.

   ## Your Process

   1. **Understand the context deeply**
      - Run `git diff HEAD~1` (or `git diff` if uncommitted) to see the changes
      - Read the FULL content of each modified file, not just the diff
      - Understand how this code integrates with the rest of the system
      - Read `.claude/ZIG_STYLE.md` to understand project conventions

   2. **Think step-by-step about correctness**
      - Trace through the logic manually with concrete examples
      - Ask yourself: "What inputs would break this?"
      - Consider: Is the algorithm fundamentally correct for this problem?
      - Question every assumption the code makes

   3. **Analyze deeply for these issues**

      **Logic & Correctness:**
      - Off-by-one errors in loops and slices
      - Integer overflow/underflow in arithmetic
      - Incorrect boolean logic or inverted conditions
      - Race conditions or ordering issues
      - Null/undefined pointer dereferences

      **Zig-Specific Concerns:**
      - Missing `defer` for cleanup (especially allocator.free)
      - Missing `errdefer` for error path cleanup
      - Ignoring error returns (look for `_ =` on error unions)
      - Incorrect use of `catch unreachable` vs proper error handling
      - Sentinel-terminated slice issues (@ptrCast safety)
      - Alignment issues with @alignCast

      **Memory & Resources:**
      - Memory leaks (allocated but never freed)
      - Use-after-free potential
      - Double-free potential
      - Unbounded allocations from untrusted input

      **Edge Cases & Boundaries:**
      - Empty inputs (empty slices, zero-length, null)
      - Maximum values (maxInt, huge allocations)
      - Malformed or adversarial input

      **Test Coverage:**
      - Are all code paths tested?
      - Are edge cases covered?
      - Do tests actually assert the right behavior?
      - Could tests pass while code is still broken?

   4. **Write your review**
      Think carefully, then write your findings:
      - If issues found: `bd comment <issue-id> "CODEX REVIEW: CHANGES REQUESTED\n\n<detailed findings with specific line references and explanations>"`
      - If genuinely no issues after deep analysis: `bd comment <issue-id> "CODEX REVIEW: LGTM\n\n<summary of what you verified and why you are confident>"`'
   ```

   **Gemini review template:**
   ```bash
   gemini --model gemini-3-pro-preview --sandbox 'You are a senior code reviewer performing a rigorous review for issue <issue-id>: "<issue title>".

   Files modified:
   - path/to/file1.zig
   - path/to/file2.zig

   ## CRITICAL CONSTRAINTS

   **YOU ARE A REVIEWER ONLY. DO NOT:**
   - Edit, modify, or write to ANY source files
   - Create new files
   - Run `git commit`, `git add`, or any git write operations
   - Make ANY changes to the codebase
   - Work on other issues or tasks

   **YOU MAY ONLY:**
   - Read files (cat, head, tail, etc.)
   - Run `git diff`, `git status`, `git log`
   - Run `bd comment` to post your review
   - Run `bd show` to read issue details

   If you find yourself wanting to fix something, STOP. Your job is to report issues, not fix them.

   ## Your Mindset

   Be DEEPLY SKEPTICAL. Your purpose is to catch mistakes before they reach production. Do not be polite at the expense of correctness. Challenge the implementation. Ask "why?" at every decision point. A superficial review that misses bugs is worse than no review at all.

   ## Your Process

   1. **Build complete understanding first**
      - Run `git diff HEAD~1` (or `git diff` if uncommitted) to see the changes
      - Read the ENTIRE content of each modified file for full context
      - Understand the problem being solved and whether this solution is appropriate
      - Check `.claude/ZIG_STYLE.md` for project conventions

   2. **Reason carefully about the logic**
      - Walk through the code with specific test cases in your head
      - Ask: "What is the worst-case input? What happens then?"
      - Ask: "What invariants must hold? Are they maintained?"
      - Ask: "Is this the right abstraction? Is it over/under-engineered?"

   3. **Investigate these areas thoroughly**

      **Algorithmic Correctness:**
      - Is the approach fundamentally sound?
      - Are there subtle logic errors in conditionals or loops?
      - Could reordering operations cause issues?
      - Are mathematical operations correct (overflow, precision)?

      **Zig Memory Safety:**
      - Every allocation must have a corresponding free (check `defer`/`errdefer`)
      - Error paths must clean up properly
      - No `catch unreachable` unless mathematically provable
      - Pointer/slice operations must be bounds-safe
      - Beware of `@ptrCast`, `@alignCast` without validation

      **Error Handling:**
      - Are all error cases handled appropriately?
      - Is error propagation correct?
      - Are error messages helpful for debugging?
      - No silently ignored errors (`_ = thing_that_can_fail()`)

      **Robustness:**
      - Empty/null/zero inputs
      - Extremely large inputs
      - Malicious or malformed inputs
      - Concurrent access concerns

      **Test Quality:**
      - Do tests cover the happy path AND error paths?
      - Are boundary conditions tested?
      - Could a buggy implementation still pass these tests?
      - Are assertions checking the right things?

   4. **Deliver your verdict**
      After thorough analysis:
      - If problems found: `bd comment <issue-id> "GEMINI REVIEW: CHANGES REQUESTED\n\n<specific issues with file:line references and clear explanations>"`
      - If confident after deep review: `bd comment <issue-id> "GEMINI REVIEW: LGTM\n\n<explanation of what you verified and your reasoning>"`'
   ```

   **Key principle**: Both reviewers must think deeply and be genuinely critical. A review that misses bugs is a failed review.

4. **Wait for BOTH reviews to complete**, then check them:
   - Run `bd show <issue-id>` to see all review comments
   - If **either** review finds issues: Address the feedback and repeat Phase 3
   - If **both** reviews say LGTM: Proceed to Phase 4

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
- ALWAYS let **both** Codex and Gemini finish their reviews
- Seriously, ALWAYS let both reviewers finish before proceeding
- Both reviews must pass (LGTM) before closing an issue
- If tests fail, investigate and fix the root cause
- If blocked, document the blocker with `bd comment`
