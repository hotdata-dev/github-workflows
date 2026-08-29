#!/usr/bin/env bash
#
# The corpus is committed so the numbers in docs/comment-style-harness.md stay checkable, but
# committing it does not by itself hold the baseline still: the fetch script derives baseline
# membership from whichever comments exist on the source pull requests at fetch time, and two
# of the three sources contribute every comment they have. One comment added to #38, one
# deleted from #1242, or one edited to lose its `nit:` prefix, and a re-fetch writes a corpus
# the recorded totals were never measured against, with nothing failing.
#
# So the shape is asserted here and declared in the script, and the script's own guard reads
# the same two constants. Changing the corpus deliberately means changing them, which is the
# "say so in the commit" step made mechanical.
set -uo pipefail

CORPUS=docs/comment-style-corpus.json
FETCH_SCRIPT=scripts/fetch-comment-style-corpus.sh
failures=0

expect() {
  if [ "$1" = "$2" ]; then
    echo "ok   $3"
  else
    echo "FAIL $3"
    printf '     expected: %s\n     got:      %s\n' "$2" "$1"
    failures=$((failures + 1))
  fi
}

# Read out of the script rather than repeated here, for the reason tests/lib.sh extracts the
# shipped jq: a second copy of a constant drifts from the first, and a test asserting 19 while
# the script guards 14 is a test that passes over the bug.
const_of() {
  local name=$1 value
  value=$(sed -n "s/^$name=\([0-9]*\)\$/\1/p" "$FETCH_SCRIPT")
  if [ -z "$value" ]; then
    echo "FAIL: no $name=<number> assignment in $FETCH_SCRIPT" >&2
    exit 1
  fi
  printf '%s' "$value"
}

EXPECTED_COMMENTS=$(const_of EXPECTED_COMMENTS) || exit 1
EXPECTED_BASELINE=$(const_of EXPECTED_BASELINE) || exit 1

expect "$(jq '.comments | length' "$CORPUS")" "$EXPECTED_COMMENTS" \
  "the committed corpus holds the number of comments the fetch script expects"
expect "$(jq '[.comments[] | select(.baseline)] | length' "$CORPUS")" "$EXPECTED_BASELINE" \
  "the committed corpus holds the number of baseline comments the fetch script expects"

# The baseline rows in the harness document are per-source, so a source dropping out of the
# baseline entirely would still satisfy the totals above.
expect "$(jq '[.comments[] | select(.baseline) | .pr] | unique | length' "$CORPUS")" "3" \
  "all three sources still contribute to the baseline"

# An empty body restyles to nothing and would quietly shrink every total measured against it.
expect "$(jq '[.comments[] | select(.body | length == 0)] | length' "$CORPUS")" "0" \
  "no comment in the corpus has an empty body"

# severity is derived from the posted prefix, so a comment edited to lose its prefix silently
# re-labels as blocking -- the tier whose rules are the least like a nit's.
expect "$(jq -r '[.comments[] | select(.severity | IN("nit", "super nit", "blocking") | not)] | length' "$CORPUS")" "0" \
  "every comment carries one of the three known severities"

if [ "$failures" -eq 0 ]; then
  echo "all tests passed"
else
  echo "$failures test(s) failed"
  exit 1
fi
