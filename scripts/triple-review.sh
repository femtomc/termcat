#!/usr/bin/env bash
# triple-review.sh - Run all three code reviewers in parallel
#
# Usage: ./scripts/triple-review.sh <issue-id> [commit]
#
# Arguments:
#   issue-id  The beads issue ID (e.g., termcat-abc)
#   commit    Optional commit SHA to review (defaults to HEAD~1 or uncommitted changes)
#
# This script:
# 1. Gets issue details and modified files automatically
# 2. Spawns Codex, Gemini, and Claude reviewers in parallel
# 3. Captures their stdout as review output
# 4. Posts all reviews via `bd comment`
# 5. Shows aggregated verdict summary

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <issue-id> [commit]"
    echo "Example: $0 termcat-abc"
    echo "Example: $0 termcat-abc abc1234  # review specific commit"
    exit 1
fi

ISSUE_ID="$1"
COMMIT="${2:-}"  # Optional commit SHA

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Triple Review for ${ISSUE_ID} ===${NC}"

# Get issue title
echo -e "${YELLOW}Fetching issue details...${NC}"
ISSUE_TITLE=$(bd show "$ISSUE_ID" 2>&1 | grep -v '^$' | head -1 | sed 's/^[^ ]* //')
if [[ -z "$ISSUE_TITLE" ]]; then
    echo -e "${RED}Error: Could not fetch issue ${ISSUE_ID}${NC}"
    exit 1
fi
echo "Issue: $ISSUE_TITLE"

# Get modified files
echo -e "${YELLOW}Detecting modified files...${NC}"

if [[ -n "$COMMIT" ]]; then
    # Specific commit provided - diff that commit against its parent
    MODIFIED_FILES=$(git diff --name-only "${COMMIT}^..${COMMIT}" 2>/dev/null || true)
    DIFF_SPEC="${COMMIT}^..${COMMIT}"
    echo "Reviewing commit: $COMMIT"
else
    # No commit specified - check for uncommitted changes first
    MODIFIED_FILES=$(git diff --name-only HEAD 2>/dev/null || true)
    DIFF_SPEC="HEAD"
    if [[ -z "$MODIFIED_FILES" ]]; then
        # Try comparing to previous commit if working tree is clean
        MODIFIED_FILES=$(git diff --name-only HEAD~1 2>/dev/null || true)
        DIFF_SPEC="HEAD~1"
    fi
fi

if [[ -z "$MODIFIED_FILES" ]]; then
    echo -e "${RED}Error: No modified files detected${NC}"
    echo "Make sure you have uncommitted changes or a recent commit to review."
    exit 1
fi

# Format files as bullet list
FILES_LIST=$(echo "$MODIFIED_FILES" | sed 's/^/- /')
echo "Files to review:"
echo "$FILES_LIST"
echo ""

# Create temp directory for logs
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

#############################################
# CODEX REVIEW
#############################################
codex_review() {
    local prompt='You are a senior code reviewer performing a rigorous review for issue '"$ISSUE_ID"': "'"$ISSUE_TITLE"'".

Files modified:
'"$FILES_LIST"'

## Your Mindset

Adopt an ADVERSARIAL mindset. Your job is to find problems, not to approve code. Assume the implementation has bugs until proven otherwise. Do not rubber-stamp. A quick "LGTM" without deep analysis is a failure of your responsibility.

## Your Process

1. **Understand the context deeply**
   - Run `git diff '"$DIFF_SPEC"'` to see the changes
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

4. **Output your review**
   After your analysis, output ONLY your review verdict and findings to stdout. Do not run any commands to post the review - just print it.

   Format your output as:
   - First line: "LGTM" or "CHANGES REQUESTED"
   - Following lines: Your detailed findings, explanations, and reasoning

   Example output:
   LGTM

   Verified the implementation handles all edge cases correctly...

   OR:

   CHANGES REQUESTED

   Found the following issues:
   1. Off-by-one error in line 42...'

    echo -e "${BLUE}[CODEX]${NC} Starting review..." >&2
    if codex exec --dangerously-bypass-approvals-and-sandbox "$prompt" > "$TEMP_DIR/codex_output.txt" 2>"$TEMP_DIR/codex.log"; then
        echo -e "${GREEN}[CODEX]${NC} Review complete" >&2
    else
        echo -e "${RED}[CODEX]${NC} Review failed (exit code $?)" >&2
        cat "$TEMP_DIR/codex.log" >&2
        echo "REVIEW FAILED - Codex exited with error" > "$TEMP_DIR/codex_output.txt"
    fi
}

#############################################
# GEMINI REVIEW
#############################################
gemini_review() {
    local prompt='You are a senior code reviewer performing a rigorous review for issue '"$ISSUE_ID"': "'"$ISSUE_TITLE"'".

Files modified:
'"$FILES_LIST"'

## CRITICAL CONSTRAINTS

**YOU ARE A REVIEWER ONLY. DO NOT:**
- Use `write_file` or `replace` tools
- Create, edit, or modify ANY files
- Run `git commit`, `git add`, or any git write operations
- Make ANY changes to the codebase
- Work on other issues or tasks

**YOU MAY ONLY:**
- Use `read_file` to read file contents
- Use `glob` and `search_file_content` to find and search files
- Run `git diff`, `git status`, `git log` via shell
- Run `bd show` to read issue details

If you find yourself wanting to fix something, STOP. Your job is to report issues, not fix them.

## Your Mindset

Be DEEPLY SKEPTICAL. Your purpose is to catch mistakes before they reach production. Do not be polite at the expense of correctness. Challenge the implementation. Ask "why?" at every decision point. A superficial review that misses bugs is worse than no review at all.

## Your Process

1. **Build complete understanding first**
   - Run `git diff '"$DIFF_SPEC"'` to see the changes
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

4. **Output your review**
   After your analysis, output ONLY your review verdict and findings. Do not run any commands to post the review.

   Format your output as:
   - First line: "LGTM" or "CHANGES REQUESTED"
   - Following lines: Your detailed findings, explanations, and reasoning'

    echo -e "${BLUE}[GEMINI]${NC} Starting review..." >&2
    if gemini --model gemini-3-pro-preview --allowed-tools read_file,glob,search_file_content,list_directory,run_shell_command "$prompt" > "$TEMP_DIR/gemini_output.txt" 2>"$TEMP_DIR/gemini.log"; then
        echo -e "${GREEN}[GEMINI]${NC} Review complete" >&2
    else
        echo -e "${RED}[GEMINI]${NC} Review failed (exit code $?)" >&2
        cat "$TEMP_DIR/gemini.log" >&2
        echo "REVIEW FAILED - Gemini exited with error" > "$TEMP_DIR/gemini_output.txt"
    fi
}

#############################################
# CLAUDE REVIEW (Design/Organization)
#############################################
claude_review() {
    local prompt='You are a senior architect reviewing code organization for issue '"$ISSUE_ID"': "'"$ISSUE_TITLE"'".

Files modified:
'"$FILES_LIST"'

## CRITICAL CONSTRAINTS

**YOU ARE A REVIEWER ONLY. DO NOT:**
- Create, edit, or modify ANY files
- Run `git commit`, `git add`, or any git write operations
- Make ANY changes to the codebase
- Work on other issues or tasks

**YOU MAY ONLY:**
- Read files to understand code structure
- Run `git diff`, `git status`, `git log`
- Run `bd show` to read issue details

## Your Mindset

Focus on SOFTWARE DESIGN, not correctness. Assume the code works—your job is to evaluate whether it is well-structured, maintainable, and appropriately abstracted. Be critical of complexity. Simple solutions that work are better than clever solutions.

## Your Process

1. **Understand the change in context**
   - Run `git diff '"$DIFF_SPEC"'` to see what changed
   - Read the full modified files to understand structure
   - Look at surrounding code to understand existing patterns
   - Check `.claude/ZIG_STYLE.md` for project conventions

2. **Evaluate organization and modularity**

   **Module Structure:**
   - Does each file/module have a clear, single responsibility?
   - Are related functions grouped logically?
   - Is the public API minimal and well-defined?
   - Could this be split or should it be merged with something else?

   **Abstraction Quality:**
   - Is the abstraction level appropriate for the problem?
   - Are there unnecessary layers of indirection?
   - Is there premature generalization (YAGNI violation)?
   - Is there under-abstraction causing duplication?

   **Coupling & Cohesion:**
   - Do modules depend on implementation details they should not?
   - Are dependencies explicit and minimal?
   - Do things that change together live together?

   **Interface Design:**
   - Are function signatures clear and minimal?
   - Do types communicate intent?
   - Are there too many parameters (struct needed)?
   - Is the API easy to use correctly, hard to misuse?

   **Code Duplication:**
   - Is there copy-paste that should be extracted?
   - Conversely, is there forced reuse that hurts clarity?

3. **Output your review**
   After your analysis, output ONLY your review verdict and findings. Do not run any commands to post the review.

   Format your output as:
   - First line: "LGTM" or "CHANGES REQUESTED"
   - Following lines: Your detailed findings, explanations, and reasoning'

    echo -e "${BLUE}[CLAUDE]${NC} Starting review..." >&2
    if claude --dangerously-skip-permissions "$prompt" > "$TEMP_DIR/claude_output.txt" 2>"$TEMP_DIR/claude.log"; then
        echo -e "${GREEN}[CLAUDE]${NC} Review complete" >&2
    else
        echo -e "${RED}[CLAUDE]${NC} Review failed (exit code $?)" >&2
        cat "$TEMP_DIR/claude.log" >&2
        echo "REVIEW FAILED - Claude exited with error" > "$TEMP_DIR/claude_output.txt"
    fi
}

#############################################
# MAIN - Run all three in parallel
#############################################
echo -e "${YELLOW}Starting all three reviewers in parallel...${NC}"
echo ""

# Run all three in background
codex_review &
CODEX_PID=$!

gemini_review &
GEMINI_PID=$!

claude_review &
CLAUDE_PID=$!

# Wait for all to complete
echo "Waiting for reviews to complete..."
echo "  Codex PID: $CODEX_PID"
echo "  Gemini PID: $GEMINI_PID"
echo "  Claude PID: $CLAUDE_PID"
echo ""

wait $CODEX_PID
wait $GEMINI_PID
wait $CLAUDE_PID

echo ""
echo -e "${YELLOW}Posting reviews...${NC}"

# Helper to extract verdict from review output
# Looks for exact match of "LGTM" or "CHANGES REQUESTED" on the first non-empty line
get_verdict() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "FAILED"
        return
    fi

    # Get first non-empty line, trimmed
    local first_line
    first_line=$(grep -m1 -v '^[[:space:]]*$' "$file" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Exact match (case-insensitive)
    if [[ "${first_line^^}" == "LGTM" ]]; then
        echo "LGTM"
    elif [[ "${first_line^^}" == "CHANGES REQUESTED" ]]; then
        echo "CHANGES REQUESTED"
    else
        echo "UNKNOWN"
    fi
}

# Post a review, showing errors if posting fails
# Prints status to stderr, verdict to stdout (for capture)
post_review() {
    local name="$1"
    local output_file="$2"
    local prefix="$3"

    if [[ ! -f "$output_file" ]] || [[ ! -s "$output_file" ]]; then
        echo -e "  ${RED}✗${NC} $name review output missing or empty" >&2
        echo "FAILED"
        return
    fi

    local verdict
    verdict=$(get_verdict "$output_file")
    local review_content
    review_content=$(cat "$output_file")

    if bd comment "$ISSUE_ID" "$prefix$review_content" >&2; then
        echo -e "  ${GREEN}✓${NC} Posted $name review ($verdict)" >&2
    else
        echo -e "  ${RED}✗${NC} Failed to post $name review (bd comment error above)" >&2
    fi
    echo "$verdict"
}

CODEX_VERDICT=$(post_review "Codex" "$TEMP_DIR/codex_output.txt" "CODEX REVIEW: ")
GEMINI_VERDICT=$(post_review "Gemini" "$TEMP_DIR/gemini_output.txt" "GEMINI REVIEW: ")
CLAUDE_VERDICT=$(post_review "Claude" "$TEMP_DIR/claude_output.txt" "CLAUDE REVIEW (DESIGN): ")

echo ""
echo -e "${BLUE}=== Review Summary ===${NC}"

# Count verdicts
LGTM_COUNT=0
CHANGES_COUNT=0

for verdict in "$CODEX_VERDICT" "$GEMINI_VERDICT" "$CLAUDE_VERDICT"; do
    if [[ "$verdict" == "LGTM" ]]; then
        ((LGTM_COUNT++))
    elif [[ "$verdict" == "CHANGES REQUESTED" ]]; then
        ((CHANGES_COUNT++))
    fi
done

echo -e "  Codex:  $CODEX_VERDICT"
echo -e "  Gemini: $GEMINI_VERDICT"
echo -e "  Claude: $CLAUDE_VERDICT"
echo ""

if [[ $LGTM_COUNT -eq 3 ]]; then
    echo -e "${GREEN}All three reviewers approved! Ready to commit.${NC}"
elif [[ $CHANGES_COUNT -gt 0 ]]; then
    echo -e "${YELLOW}$CHANGES_COUNT reviewer(s) requested changes. Address feedback and re-run:${NC}"
    echo "   ./scripts/triple-review.sh $ISSUE_ID"
else
    echo -e "${YELLOW}Some reviews may have failed or returned unexpected output.${NC}"
    echo "Check the review details below."
fi

echo ""
echo -e "${YELLOW}Full review details:${NC}"
echo ""
bd show "$ISSUE_ID"
