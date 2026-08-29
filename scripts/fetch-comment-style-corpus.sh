#!/usr/bin/env bash
# Snapshots the review comments the comment-style harness measures against.
#
# The harness compares rewritten comments to what the reviewer actually posted, so its
# numbers only mean something against a fixed corpus. Re-fetching on every run would let
# an edited or deleted comment move the baseline silently, which is why the bodies are
# committed rather than pulled live. Run this only to add a PR to the corpus or to
# refresh it deliberately, and say so in the commit that changes the numbers.
#
# Usage: scripts/fetch-comment-style-corpus.sh [output-path]
set -euo pipefail

OUT="${1:-docs/comment-style-corpus.json}"

# owner/repo:pr. Chosen for adversarial shape rather than coverage -- see
# docs/comment-style-harness.md for what each one exercises.
SOURCES=(
  "hotdata-dev/github-workflows:38"
  "hotdata-dev/runtimedb:1242"
  "hotdata-dev/runtimedb:1236"
)

# The shape the recorded numbers were measured against. Baseline membership is derived
# from whichever comments exist at fetch time, and #38 and #1242 contribute all of theirs,
# so one comment added, deleted, or edited to lose its `nit:` prefix silently rewrites the
# set that docs/comment-style-harness.md says its totals came from. The guard at the end
# refuses to leave that unremarked; tests/comment-style-corpus-test.sh reads these two
# constants rather than repeating them. Changing the corpus on purpose means changing them
# in the same commit as the table.
EXPECTED_COMMENTS=19
EXPECTED_BASELINE=14

# The 14 comments the baseline in docs/comment-style-harness.md was measured against.
# Every comment on #38 and #1242 qualified; #1236 contributes four of its nine, picked
# to add a blocking finding and a second domain. The rest of #1236 is corpus but not
# baseline -- rewriting it would produce a total that no recorded number compares to.
BASELINE_IDS='[3884595787, 3884597515, 3884598006, 3885278816]'

# The reviewer's login. Comments from anyone else are the PR conversation, not review
# output, and restyling them would measure the wrong thing.
REVIEWER='claude[bot]'

tmp=$(mktemp)
# All three, not just $tmp: .page and .merged are removed inline at the end of each
# iteration, so an abort between them -- a gh 404 on a repo the token cannot see is the
# likely one -- leaves them behind under set -e.
trap 'rm -f "$tmp" "$tmp".page "$tmp".merged' EXIT
echo '[]' > "$tmp"

for source in "${SOURCES[@]}"; do
  repo="${source%%:*}"
  pr="${source##*:}"
  echo "fetching ${repo}#${pr}" >&2
  # --paginate because a long review history spans pages, and a partial corpus is a
  # baseline that quietly drifts from the one the numbers were taken against.
  # --slurp so multi-page histories arrive as one array of pages rather than
  # concatenated arrays, which jq cannot read as a single document.
  gh api "repos/${repo}/pulls/${pr}/comments" --paginate --slurp \
    | jq --arg repo "$repo" --arg pr "$pr" --arg who "$REVIEWER" \
         --argjson baseline_extra "$BASELINE_IDS" '
      [ .[][]
        | select(.user.login == $who)
        | { repo: $repo,
            pr: ($pr | tonumber),
            id: .id,
            path: .path,
            line: .line,
            # The severity the rules key off. Anything without a prefix is a blocking
            # finding: the prompt requires the marker on non-blocking comments only.
            severity: (if (.body | startswith("super nit:")) then "super nit"
                       elif (.body | startswith("nit:")) then "nit"
                       else "blocking" end),
            # Whole-PR membership for #38 and #1242; per-comment for #1236.
            baseline: (($pr | tonumber) as $n
                       | if $n == 1236 then (.id | IN($baseline_extra[])) else true end),
            body: .body }
      ]' > "${tmp}.page"
  jq -s '.[0] + .[1]' "$tmp" "${tmp}.page" > "${tmp}.merged"
  mv "${tmp}.merged" "$tmp"
  rm -f "${tmp}.page"
done

jq --arg who "$REVIEWER" '{
  fetched_utc: (now | todate),
  reviewer: $who,
  comments: .
}' "$tmp" > "$OUT"

count=$(jq '.comments | length' "$OUT")
baseline=$(jq '[.comments[] | select(.baseline)] | length' "$OUT")
if [ "$count" != "$EXPECTED_COMMENTS" ] || [ "$baseline" != "$EXPECTED_BASELINE" ]; then
  echo "corpus changed shape: ${count} comments / ${baseline} baseline" \
       "(expected ${EXPECTED_COMMENTS}/${EXPECTED_BASELINE})." >&2
  echo "The totals in docs/comment-style-harness.md were measured against the expected" \
       "shape. Re-measure the baseline table, or restore the corpus." >&2
  exit 1
fi
echo "wrote ${count} comments to ${OUT} (${baseline} baseline)" >&2
