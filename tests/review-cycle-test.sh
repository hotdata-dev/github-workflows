#!/usr/bin/env bash
#
# Guards the REVIEW CYCLE counter in claude-pr-review.yml against fixtures captured from
# the real reviews API. The jq program is extracted from the workflow rather than copied,
# so the test exercises the shipped expression.
#
# Regression: the counter used to filter on review state (CHANGES_REQUESTED/APPROVED). On
# a PR whose every round ends in approve-with-nits, dismiss_stale_reviews_on_push flips
# each of those approvals to DISMISSED, so the filter matched nothing and the counter read
# 1 forever, silently disabling the prompt's cycle-awareness ladder. CHANGES_REQUESTED
# survives a push, so request-changes PRs counted correctly and the bug stayed hidden.

set -euo pipefail

cd "$(dirname "$0")/.."

WORKFLOW=.github/workflows/claude-pr-review.yml

# extract_jq <shell variable name> -- pull a single-quoted jq program out of the workflow
extract_jq() {
  local name=$1 prog
  prog=$(sed -n "s/^ *$name='\(.*\)'\$/\1/p" "$WORKFLOW")
  if [ -z "$prog" ]; then
    echo "FAIL: no $name='...' assignment found in $WORKFLOW" >&2
    exit 1
  fi
  if [ "$(printf '%s\n' "$prog" | wc -l)" -ne 1 ]; then
    echo "FAIL: more than one $name assignment in $WORKFLOW:" >&2
    printf '%s\n' "$prog" >&2
    exit 1
  fi
  printf '%s' "$prog"
}

CYCLE_JQ=$(extract_jq CYCLE_JQ)
DRIFT_JQ=$(extract_jq DRIFT_JQ)
LAST_SHA_JQ=$(extract_jq LAST_SHA_JQ)
TRUNCATED_JQ=$(extract_jq TRUNCATED_JQ)
# PATCH_JQ contains a literal \n that BSD sed expands when writing a backreference, which
# would silently turn the jq program's escape into a real newline. Pull it with awk instead so
# the test exercises the same two characters the workflow ships.
PATCH_JQ=$(awk -F"'" '/^ *PATCH_JQ=/ {print $2; found=1} END {exit !found}' "$WORKFLOW") || {
  echo "FAIL: no PATCH_JQ='...' assignment found in $WORKFLOW" >&2
  exit 1
}

failures=0

# expect <fixture> <expected cycle> <description>
expect() {
  local fixture=$1 want=$2 desc=$3
  local count actual
  count=$(jq -s "$CYCLE_JQ" "tests/fixtures/$fixture")
  actual=$((count + 1))
  if [ "$actual" -eq "$want" ]; then
    echo "ok   $desc (cycle=$actual)"
  else
    echo "FAIL $desc: expected cycle $want, got $actual"
    failures=$((failures + 1))
  fi
}

# expect_drift <fixture> <fires|silent> <description>
expect_drift() {
  local fixture=$1 want=$2 desc=$3 actual=silent
  if jq -e -s "$DRIFT_JQ" "tests/fixtures/$fixture" >/dev/null 2>&1; then
    actual=fires
  fi
  if [ "$actual" = "$want" ]; then
    echo "ok   $desc ($actual)"
  else
    echo "FAIL $desc: expected $want, got $actual"
    failures=$((failures + 1))
  fi
}

# No prior reviews.
expect reviews-first-review.json 1 "opened PR is cycle 1"

# monopoly#1560: nine review rounds, every one an approve-with-nits that the next push
# dismissed. The tenth review must know it is the tenth.
expect reviews-approve-with-nits.json 10 "nine dismissed approve-with-nits rounds count"

# Rounds counted regardless of state; approvals by other bots and by humans do not count.
expect reviews-mixed-bots.json 3 "only claude[bot] rounds count, one per commit"

# The counter is keyed on the reviewer's login. If claude-code-action ever posts under a
# different identity the count collapses to 0 and every round reads as cycle 1 again --
# the original bug. The drift predicate is the runtime backstop for that; it is only
# consulted when the count is 0, so it has to separate "the login moved" from "genuine
# first review".
expect reviews-foreign-reviewer.json 1 "unknown reviewer login yields no rounds"
expect_drift reviews-foreign-reviewer.json fires "drift warning fires when the login moved"
expect_drift reviews-first-review.json silent "drift warning silent on a genuine cycle 1"

# gh 2.93 merges --paginate pages into one array; older versions concatenate one array per
# page. `jq -s '.[][]'` must handle both, so keep a concatenated fixture.
expect reviews-paginated.json 3 "concatenated --paginate pages count once each"

# Known +/-1: monopoly#1534 round 1 posted 5 inline comments against a89f19e8, then its
# approve landed 5s later against 951c8afa because a push arrived mid-review, so 5 real
# rounds count as 6. Harmless against a 5-step ladder; asserted so a future change to the
# counter has to acknowledge this case rather than shift it silently.
expect reviews-straddled-round.json 7 "push landing mid-round splits it in two"

# The incremental-diff base: head SHA of the most recent claude[bot] review. Cycle 2+ diffs
# that SHA against the PR head so a re-review sees the push and not the whole PR again.
#
# expect_last_sha <fixture> <expected sha or empty> <description>
expect_last_sha() {
  local fixture=$1 want=$2 desc=$3 actual
  actual=$(jq -s -r "$LAST_SHA_JQ" "tests/fixtures/$fixture")
  if [ "$actual" = "$want" ]; then
    echo "ok   $desc"
  else
    echo "FAIL $desc: expected '$want', got '$actual'"
    failures=$((failures + 1))
  fi
}

# Empty means "no base to diff from" and the workflow falls back to the full diff. Both of
# these must produce empty rather than a stray SHA: a wrong base would silently narrow the
# review to the wrong range, which is worse than reviewing everything.
expect_last_sha reviews-first-review.json "" "no prior claude review yields no diff base"
expect_last_sha reviews-foreign-reviewer.json "" "foreign reviewer login yields no diff base"

# Reviews by other bots and by humans land *after* claude's last round in this fixture. The
# base has to be claude's own last commit_id (bbbb), not the newest review overall (dddd),
# or cycle 2+ would diff against a tree claude never reviewed and skip real changes.
expect_last_sha reviews-mixed-bots.json \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "diff base ignores newer non-claude reviews"
expect_last_sha reviews-paginated.json \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "diff base survives concatenated --paginate pages"

# The last round's state is irrelevant: dismiss_stale_reviews_on_push turns claude's own
# approvals into DISMISSED, and a dismissed review still reviewed that tree.
expect_last_sha reviews-approve-with-nits.json \
  fab04bd24df816278c5ac3aa38935f47ecac9b03 "dismissed approval still serves as the diff base"

# An unfinished round must never become the base. Both of these shipped broken: the base was
# "newest claude review's commit_id", which trusts trees claude never finished reading, and
# the cycle 2+ prompt tells the model not to look outside the incremental diff. So whatever
# the dead round never reached was reviewed by no cycle at all -- silently.
#
# Cancelled round: round 1 finished against aaa, round 2 posted two inline comments against
# bbb and was killed by cancel-in-progress. bbb is not reviewed, so the base stays at aaa and
# bbb's changes come back around.
expect_last_sha reviews-cancelled-round.json \
  a1111111111111111111111111111111111111aa "a cancelled round does not become the diff base"

# Straddled round: a push landed mid-review, so the round's inline comments are on bbb but its
# approve landed on ccc. Claude read bbb and never saw ccc, so ccc must not be the base --
# this is the case a plain "last finished review" filter still gets wrong.
expect_last_sha reviews-straddled-latest-round.json \
  b2222222222222222222222222222222222222bb "a straddled round bases on the tree that was read"

# Nothing has finished yet: no base at all, and the review reads the full diff. Falling back
# is correct here -- guessing a base would hide the unreviewed remainder of the dead round.
expect_last_sha reviews-only-partial-round.json "" "an unfinished first round yields no base"

# PATCH_JQ renders the compare response into the text the model actually reviews on cycle 2+,
# so it gets the same fixture treatment as the counter. Captured shape: a modified file with a
# patch, a binary file the API returns with no patch at all, and a removed file.
render_patch() { jq -r "$PATCH_JQ" "tests/fixtures/$1"; }

# expect_patch_line <fixture> <pattern> <description>
expect_patch_line() {
  local fixture=$1 pattern=$2 desc=$3
  if render_patch "$fixture" | grep -qF -- "$pattern"; then
    echo "ok   $desc"
  else
    echo "FAIL $desc: no line matching '$pattern'"
    failures=$((failures + 1))
  fi
}

expect_patch_line compare-incremental.json \
  "=== python/webapp/orgs/tasks.py (modified) ===" "patch output headers each file with status"
expect_patch_line compare-incremental.json \
  "+    if dry_run and provisioned:" "patch output carries the actual hunk"
expect_patch_line compare-incremental.json \
  "=== docs/architecture.png (added) ===" "a binary file still appears in the patch output"
# Without the .patch // fallback jq emits null here and the file vanishes from the review
# surface with no indication it changed at all.
expect_patch_line compare-incremental.json \
  "[no textual patch available]" "a file with no patch says so instead of dropping out"
expect_patch_line compare-incremental.json \
  "=== python/webapp/orgs/legacy.py (removed) ===" "a removed file appears in the patch output"

if render_patch compare-incremental.json | grep -q 'null'; then
  echo "FAIL patch output contains a literal null"
  failures=$((failures + 1))
else
  echo "ok   patch output never contains a literal null"
fi

# The header and its hunk must land on separate lines. If the \n in PATCH_JQ ever degrades to
# the two characters backslash-n, the whole diff arrives as one unreadable line per file.
if [ "$(render_patch compare-incremental.json | wc -l | tr -d ' ')" -ge 9 ]; then
  echo "ok   patch output keeps its newline between header and hunk"
else
  echo "FAIL patch output collapsed onto too few lines; check the newline escape in PATCH_JQ"
  failures=$((failures + 1))
fi

# expect_truncated <fixture> <fires|silent> <description>
expect_truncated() {
  local fixture=$1 want=$2 desc=$3 actual=silent
  if jq -e "$TRUNCATED_JQ" "tests/fixtures/$fixture" >/dev/null 2>&1; then
    actual=fires
  fi
  if [ "$actual" = "$want" ]; then
    echo "ok   $desc ($actual)"
  else
    echo "FAIL $desc: expected $want, got $actual"
    failures=$((failures + 1))
  fi
}

# 300 files is the compare API's cap, and the call is not paginated. A push that wide returns a
# prefix that is valid, non-empty and under the size limit, so nothing else catches it and the
# model is told a partial diff is the complete review surface.
expect_truncated compare-file-cap.json fires "file cap at 300 trips the truncation guard"
expect_truncated compare-incremental.json silent "an ordinary compare does not trip the guard"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
