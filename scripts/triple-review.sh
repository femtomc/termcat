#!/usr/bin/env bash
# triple-review.sh - Run all three code reviewers in parallel
#
# Usage: ./scripts/triple-review.sh <issue-id> [commit]
#
# Arguments:
#   issue-id  The beads issue ID (e.g., termcat-abc)
#   commit    Optional commit SHA to review (defaults to HEAD or uncommitted changes)
#
# This script:
# 1. Gets issue details and modified files automatically
# 2. Spawns Codex, Gemini, and Claude reviewers in parallel
# 3. Extracts structured JSON reviews from output
# 4. Posts reviews via `bd comment` with type=review
# 5. Shows aggregated verdict summary
#
# See docs/design/REVIEW_PROTOCOL.md for the full protocol specification.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <issue-id> [commit]"
    echo "Example: $0 termcat-abc"
    echo "Example: $0 termcat-abc abc1234  # review specific commit"
    exit 1
fi

ISSUE_ID="$1"
COMMIT_ARG="${2:-}"  # Optional commit SHA

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

# Determine commit SHA and diff spec
echo -e "${YELLOW}Detecting changes...${NC}"

if [[ -n "$COMMIT_ARG" ]]; then
    # Specific commit provided
    COMMIT_SHA="$COMMIT_ARG"
    MODIFIED_FILES=$(git diff --name-only "${COMMIT_SHA}^..${COMMIT_SHA}" 2>/dev/null || true)
    DIFF_SPEC="${COMMIT_SHA}^..${COMMIT_SHA}"
    echo "Reviewing commit: $COMMIT_SHA"
else
    # Get current HEAD SHA
    COMMIT_SHA=$(git rev-parse --short HEAD)

    # Check for uncommitted changes first
    MODIFIED_FILES=$(git diff --name-only HEAD 2>/dev/null || true)
    DIFF_SPEC="HEAD"

    if [[ -z "$MODIFIED_FILES" ]]; then
        # Working tree clean - review last commit
        MODIFIED_FILES=$(git diff --name-only HEAD~1 2>/dev/null || true)
        DIFF_SPEC="HEAD~1"
    fi
    echo "Review commit: $COMMIT_SHA"
fi

if [[ -z "$MODIFIED_FILES" ]]; then
    echo -e "${RED}Error: No modified files detected${NC}"
    echo "Make sure you have uncommitted changes or a recent commit to review."
    exit 1
fi

# Format files as bullet list and JSON array
FILES_LIST=$(echo "$MODIFIED_FILES" | sed 's/^/- /')
FILES_JSON=$(echo "$MODIFIED_FILES" | jq -R -s -c 'split("\n") | map(select(length > 0))')

echo "Files to review:"
echo "$FILES_LIST"
echo ""

# Create temp directory for logs
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

#############################################
# STRUCTURED OUTPUT FORMAT
# All reviewers use this same output format
#############################################
STRUCTURED_OUTPUT_INSTRUCTIONS='
## Output Format

After your analysis, output your review in the following EXACT format.
The JSON must be valid and appear between the delimiters exactly as shown.

=== BEADS_REVIEW_START ===
{
  "verdict": "LGTM" or "CHANGES_REQUESTED",
  "reviewer": "<your-name>",
  "issue_id": "'"$ISSUE_ID"'",
  "commit": "'"$COMMIT_SHA"'",
  "timestamp": "<current ISO-8601 timestamp>",
  "summary": "<1-2 sentence summary of your review>",
  "issues": [
    {
      "severity": "error|warning|info",
      "file": "<path to file or null>",
      "line": <line number or null>,
      "message": "<description of the issue>",
      "suggestion": "<how to fix it or null>"
    }
  ],
  "files_reviewed": '"$FILES_JSON"'
}
=== BEADS_REVIEW_END ===

IMPORTANT:
- Use the exact issue_id ("'"$ISSUE_ID"'") and commit ("'"$COMMIT_SHA"'") values shown above
- Set verdict to "LGTM" if no blocking issues, "CHANGES_REQUESTED" if there are errors/warnings
- The issues array should be empty [] if verdict is LGTM
- Output ONLY this JSON block as your final output
- Everything before === BEADS_REVIEW_START === will be ignored by the review system
'

#############################################
# CODEX REVIEW
#############################################
codex_review() {
    local prompt='You are a senior code reviewer performing a rigorous review for issue '"$ISSUE_ID"': "'"$ISSUE_TITLE"'" at commit '"$COMMIT_SHA"'.

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
'"$STRUCTURED_OUTPUT_INSTRUCTIONS"

    echo -e "${BLUE}[CODEX]${NC} Starting review..." >&2
    if codex exec --dangerously-bypass-approvals-and-sandbox "$prompt" \
        > "$TEMP_DIR/codex_output.txt" \
        2> >(while IFS= read -r line; do echo "[CODEX] $line" >&2; done); then
        echo -e "${GREEN}[CODEX]${NC} Review complete" >&2
    else
        echo -e "${RED}[CODEX]${NC} Review failed (exit code $?)" >&2
    fi
}

#############################################
# GEMINI REVIEW
#############################################
gemini_review() {
    local prompt='You are a senior code reviewer performing a rigorous review for issue '"$ISSUE_ID"': "'"$ISSUE_TITLE"'" at commit '"$COMMIT_SHA"'.

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
'"$STRUCTURED_OUTPUT_INSTRUCTIONS"

    echo -e "${BLUE}[GEMINI]${NC} Starting review..." >&2
    if gemini --model gemini-3-pro-preview --allowed-tools read_file,glob,search_file_content,list_directory,run_shell_command "$prompt" \
        > "$TEMP_DIR/gemini_output.txt" \
        2> >(while IFS= read -r line; do echo "[GEMINI] $line" >&2; done); then
        echo -e "${GREEN}[GEMINI]${NC} Review complete" >&2
    else
        echo -e "${RED}[GEMINI]${NC} Review failed (exit code $?)" >&2
    fi
}

#############################################
# CLAUDE REVIEW (Design/Organization)
#############################################
claude_review() {
    local prompt='You are a senior architect reviewing code organization for issue '"$ISSUE_ID"': "'"$ISSUE_TITLE"'" at commit '"$COMMIT_SHA"'.

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
'"$STRUCTURED_OUTPUT_INSTRUCTIONS"

    echo -e "${BLUE}[CLAUDE]${NC} Starting review..." >&2
    if claude --dangerously-skip-permissions "$prompt" \
        > "$TEMP_DIR/claude_output.txt" \
        2> >(while IFS= read -r line; do echo "[CLAUDE] $line" >&2; done); then
        echo -e "${GREEN}[CLAUDE]${NC} Review complete" >&2
    else
        echo -e "${RED}[CLAUDE]${NC} Review failed (exit code $?)" >&2
    fi
}

#############################################
# EXTRACTION FUNCTIONS
#############################################

# Extract JSON from noisy output
# IMPORTANT: Models often echo the format in thinking, producing multiple blocks.
# We find the LAST VALID start/end pair (where end comes after start).
extract_review_json() {
    local output_file="$1"

    if [[ ! -f "$output_file" ]] || [[ ! -s "$output_file" ]]; then
        return 1
    fi

    # Find line numbers of all delimiter pairs
    local starts_str ends_str
    starts_str=$(grep -n '=== BEADS_REVIEW_START ===' "$output_file" 2>/dev/null | cut -d: -f1 || true)
    ends_str=$(grep -n '=== BEADS_REVIEW_END ===' "$output_file" 2>/dev/null | cut -d: -f1 || true)

    if [[ -z "$starts_str" || -z "$ends_str" ]]; then
        return 1  # No delimiters found
    fi

    # Find the last VALID pair: iterate ends in reverse, find matching start
    # A valid pair has start < end with no other start in between
    local best_start="" best_end=""

    # Convert to arrays (bash 3.2 compatible)
    local ends_arr=()
    while IFS= read -r line; do
        ends_arr+=("$line")
    done <<< "$ends_str"

    local starts_arr=()
    while IFS= read -r line; do
        starts_arr+=("$line")
    done <<< "$starts_str"

    # Iterate ends from last to first
    local i=${#ends_arr[@]}
    while [[ $i -gt 0 ]]; do
        ((i--))
        local end_line="${ends_arr[$i]}"

        # Find the closest start that comes before this end
        local j=${#starts_arr[@]}
        while [[ $j -gt 0 ]]; do
            ((j--))
            local start_line="${starts_arr[$j]}"
            if [[ $start_line -lt $end_line ]]; then
                best_start="$start_line"
                best_end="$end_line"
                break 2  # Found valid pair, exit both loops
            fi
        done
    done

    if [[ -z "$best_start" || -z "$best_end" ]]; then
        return 1  # No valid pair found
    fi

    # Extract lines between delimiters (exclusive of delimiters)
    local json_lines
    json_lines=$(sed -n "$((best_start + 1)),$((best_end - 1))p" "$output_file")

    # Validate JSON and normalize
    if echo "$json_lines" | jq -c '.' 2>/dev/null; then
        return 0
    else
        return 1  # JSON parse failed
    fi
}

# Create a canonical FAILED review when extraction fails
create_failed_review() {
    local reviewer="$1"
    local reason="$2"
    local output_file="$3"

    # Capture last 50 lines of output for debugging (truncate to 2000 chars)
    local tail_output=""
    if [[ -f "$output_file" ]]; then
        tail_output=$(tail -50 "$output_file" 2>/dev/null | head -c 2000 || true)
    fi

    # Generate canonical FAILED review JSON
    jq -n \
        --arg verdict "FAILED" \
        --arg reviewer "$reviewer" \
        --arg issue_id "$ISSUE_ID" \
        --arg commit "$COMMIT_SHA" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg summary "Review extraction failed: $reason" \
        --arg error_output "$tail_output" \
        --argjson files_reviewed "$FILES_JSON" \
        '{
            verdict: $verdict,
            reviewer: $reviewer,
            issue_id: $issue_id,
            commit: $commit,
            timestamp: $timestamp,
            summary: $summary,
            issues: [],
            files_reviewed: $files_reviewed,
            error_output: $error_output
        }'
}

# Post review to beads and return verdict
post_review() {
    local name="$1"
    local reviewer_id="$2"
    local output_file="$3"

    local json verdict

    if json=$(extract_review_json "$output_file"); then
        # Successful extraction
        verdict=$(echo "$json" | jq -r '.verdict')

        # Post as structured comment with review prefix
        # NOTE: --type=review flag is a Phase 2 feature requiring beads changes
        # For now, we use a parseable prefix format: [REVIEW:<reviewer>] <json>
        if bd comment "$ISSUE_ID" "[REVIEW:$reviewer_id] $json" >&2; then
            echo -e "  ${GREEN}✓${NC} Posted $name review ($verdict)" >&2
        else
            echo -e "  ${RED}✗${NC} Failed to post $name review" >&2
        fi
    else
        # Extraction failed - create canonical FAILED review
        verdict="FAILED"
        json=$(create_failed_review "$reviewer_id" "No valid JSON block found in output" "$output_file")

        if bd comment "$ISSUE_ID" "[REVIEW:$reviewer_id] $json" >&2; then
            echo -e "  ${YELLOW}⚠${NC} Posted $name review (FAILED - extraction error)" >&2
        else
            echo -e "  ${RED}✗${NC} Failed to post $name review" >&2
        fi
    fi

    echo "$verdict"
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

wait $CODEX_PID || true
wait $GEMINI_PID || true
wait $CLAUDE_PID || true

echo ""
echo -e "${YELLOW}Posting reviews...${NC}"

CODEX_VERDICT=$(post_review "Codex" "codex" "$TEMP_DIR/codex_output.txt")
GEMINI_VERDICT=$(post_review "Gemini" "gemini" "$TEMP_DIR/gemini_output.txt")
CLAUDE_VERDICT=$(post_review "Claude" "claude" "$TEMP_DIR/claude_output.txt")

echo ""
echo -e "${BLUE}=== Review Summary (commit $COMMIT_SHA) ===${NC}"

# Count verdicts
LGTM_COUNT=0
CHANGES_COUNT=0
FAILED_COUNT=0

for verdict in "$CODEX_VERDICT" "$GEMINI_VERDICT" "$CLAUDE_VERDICT"; do
    case "$verdict" in
        LGTM) ((LGTM_COUNT++)) ;;
        CHANGES_REQUESTED) ((CHANGES_COUNT++)) ;;
        FAILED) ((FAILED_COUNT++)) ;;
    esac
done

echo -e "  Codex:  $CODEX_VERDICT"
echo -e "  Gemini: $GEMINI_VERDICT"
echo -e "  Claude: $CLAUDE_VERDICT"
echo ""

if [[ $LGTM_COUNT -eq 3 ]]; then
    echo -e "${GREEN}All three reviewers approved! Ready to commit.${NC}"
    exit 0
elif [[ $FAILED_COUNT -gt 0 ]]; then
    echo -e "${RED}$FAILED_COUNT review(s) failed to complete. Check output and re-run:${NC}"
    echo "   ./scripts/triple-review.sh $ISSUE_ID"
    exit 1
elif [[ $CHANGES_COUNT -gt 0 ]]; then
    echo -e "${YELLOW}$CHANGES_COUNT reviewer(s) requested changes.${NC}"
    echo ""
    echo "View details with: bd comments $ISSUE_ID"
    echo "Re-run after fixes: ./scripts/triple-review.sh $ISSUE_ID"
    exit 1
else
    echo -e "${YELLOW}Unexpected review state. Check the output files.${NC}"
    exit 1
fi
