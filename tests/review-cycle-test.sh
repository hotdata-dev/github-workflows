#!/usr/bin/env bash
#
# Guards the REVIEW CYCLE counter in claude-pr-review.yml against fixtures captured from
# the real reviews API. The jq program is extracted from the workflow rather than copied,
# so the test exercises the shipped expression.
#
# Regression: a counter that filtered on review state read 1 on every round, because
# dismiss_stale_reviews_on_push flips each prior APPROVED to DISMISSED. That silently
# disabled the prompt's cycle-awareness ladder on every approve-with-nits PR.

set -euo pipefail

cd "$(dirname "$0")/.."

WORKFLOW=.github/workflows/claude-pr-review.yml

JQ_PROG=$(sed -n "s/.*| jq -s '\(.*\)')\$/\1/p" "$WORKFLOW")
if [ -z "$JQ_PROG" ]; then
  echo "FAIL: could not extract the review-cycle jq program from $WORKFLOW"
  exit 1
fi
if [ "$(printf '%s\n' "$JQ_PROG" | wc -l)" -ne 1 ]; then
  echo "FAIL: extracted more than one jq program from $WORKFLOW:"
  printf '%s\n' "$JQ_PROG"
  exit 1
fi

failures=0

# expect <fixture> <expected cycle> <description>
expect() {
  local fixture=$1 want=$2 desc=$3
  local count actual
  count=$(jq -s "$JQ_PROG" "tests/fixtures/$fixture")
  actual=$((count + 1))
  if [ "$actual" -eq "$want" ]; then
    echo "ok   $desc (cycle=$actual)"
  else
    echo "FAIL $desc: expected cycle $want, got $actual"
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

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
