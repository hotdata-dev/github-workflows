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

# shellcheck source=tests/lib.sh
. tests/lib.sh

CYCLE_JQ=$(extract_jq CYCLE_JQ)
DRIFT_JQ=$(extract_jq DRIFT_JQ)
# The drift predicate takes the second reviewer's login as --arg, so the test has to supply
# it -- extracted, never written here, so it cannot outlive a change to the shipped value.
OTHER_REVIEW_BOT=$(extract_const OTHER_REVIEW_BOT)

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
  if jq --arg skip "$OTHER_REVIEW_BOT" -e -s "$DRIFT_JQ" "tests/fixtures/$fixture" >/dev/null 2>&1; then
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

# The second reviewer in the comparison trial is a Bot and reviews the same pull requests,
# and both reviewers fire on `opened` -- so its review landing before this one's is the
# ordinary cycle 1, not evidence that this reviewer's identity moved. Without the exclusion
# in the predicate the warning would fire on the first review of every PR in a trial repo,
# which is how a real drift goes unread.
expect reviews-other-review-bot.json 1 "the other reviewer's rounds do not count as ours"
expect_drift reviews-other-review-bot.json silent \
  "drift warning silent when only the other review bot has reviewed"

# And the state the exclusion makes ordinary is the one the predicate still has to catch: a
# drifted login sitting *beside* the excluded one. Every PR in a trial repo carries a
# pullfrog[bot] review, so this -- not the foreign bot alone -- is what a real identity change
# looks like from now on. A predicate that excluded $skip in a way that also swallowed its
# neighbours (`all` in place of `any`, or a filter applied to the whole array before the type
# test) passes both cases above and goes silent here, which is the only case left that matters.
expect reviews-drift-with-other-bot.json 1 "a drifted login beside the excluded one yields no rounds"
expect_drift reviews-drift-with-other-bot.json fires \
  "drift warning still fires when a drifted login sits beside the excluded one"

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
