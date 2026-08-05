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

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
