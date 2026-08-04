#!/usr/bin/env bash
#
# Guards the blocks the workflow frontloads into the review prompt. Each jq program is
# extracted from the workflow rather than copied, so the test exercises the shipped
# expression.
#
# These blocks exist because a week of tool-usage artifacts showed the reviewer spending
# 19.5 Bash calls and 5.2 permission denials per run fetching them for itself. The failure
# mode they have to be held against is not a crash -- it is a block that comes back empty
# or wrong and reads as fact. "No checks reported." on a PR whose CI is red, or a diff
# rebased against the wrong SHA, is worse than no block at all, because the reviewer will
# state it in a review. So the assertions here are mostly about what each program says when
# the input is missing, partial, or shaped unusually.

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=tests/lib.sh
. tests/lib.sh

COMMITS_JQ=$(extract_jq COMMITS_JQ)
FILES_JQ=$(extract_jq FILES_JQ)
CHECKS_JQ=$(extract_jq CHECKS_JQ)
FAILING_JOBS_JQ=$(extract_jq FAILING_JOBS_JQ)
LAST_REVIEW_JQ=$(extract_jq LAST_REVIEW_JQ)
ISSUE_COMMENTS_JQ=$(extract_jq ISSUE_COMMENTS_JQ)

failures=0

# expect <actual> <expected> <description>
expect() {
  local actual=$1 want=$2 desc=$3
  if [ "$actual" = "$want" ]; then
    echo "ok   $desc"
  else
    echo "FAIL $desc:"
    printf '     expected: %s\n     got:      %s\n' "$want" "$actual"
    failures=$((failures + 1))
  fi
}

# The paginated endpoints go through `jq -s` in the workflow, because gh 2.93 merges
# --paginate pages into one array while older versions concatenate one array per page.
slurped() {
  jq -s -r "$2" "tests/fixtures/$1"
}
plain() {
  jq -r "$2" "tests/fixtures/$1"
}

# --- Commits -----------------------------------------------------------------------------

# One line per commit: short SHA and subject only. Bodies are frequently longer than the
# diff they describe -- the fixture's first commit has a five-line body -- and the reviewer
# already has the diff.
expect "$(slurped pull-commits.json "$COMMITS_JQ")" \
  "bb3d59d6 feat(filesystem): incremental object-key sync (append)
77f4a9a8 feat(ingest): POST /jobs/sync + continuous flag" \
  "commits reduce to short SHA and subject"

expect "$(printf '[]' | jq -s -r "$COMMITS_JQ")" "No commits reported." \
  "no commits says so rather than emitting nothing"

# --- Changed files -----------------------------------------------------------------------

# status is the reason this block is not just `gh pr diff --name-only`: a rename shows up in
# the patch as a mode line the reviewer has to infer, and "renamed" states it.
expect "$(slurped pull-files.json "$FILES_JQ")" \
  "4 files, +339 -10
modified +3/-0 .github/workflows/build.yml
modified +105/-7 api/app.py
renamed +219/-3 connectors/files/__init__.py
added +12/-0 migrations/004_sync_state.sql" \
  "changed files carry status and per-file counts under a total"

expect "$(printf '[]' | jq -s -r "$FILES_JQ")" "No changed files reported." \
  "no changed files says so"

# --- CI checks ---------------------------------------------------------------------------

# Both rollup shapes have to render. CheckRun carries status/conclusion and a workflow name;
# StatusContext (Aikido, and anything else posting a commit status) carries neither and would
# render as "null null" if the filter assumed CheckRun.
expect "$(plain rollup-mixed.json "$CHECKS_JQ")" \
  "FAILURE Webapp / Test webapp service (Django)
IN_PROGRESS Webapp / Build and Push Webapp Image
PENDING aikido/code-scan
SUCCESS Claude PR Review / review" \
  "check rollup renders both CheckRun and StatusContext"

# A check that has not finished must not read as passing. IN_PROGRESS above comes from
# status because conclusion is still null -- the reviewer is told to treat anything that is
# not a pass as unproven, which only works if the unfinished state survives the projection.
expect "$(plain rollup-mixed.json "$CHECKS_JQ" | grep -c 'IN_PROGRESS\|PENDING')" "2" \
  "unfinished checks keep their unfinished state"

expect "$(plain rollup-empty.json "$CHECKS_JQ")" "No checks reported." \
  "empty rollup says so rather than claiming success"

expect "$(printf '{}' | jq -r "$CHECKS_JQ")" "No checks reported." \
  "missing rollup key does not error"

# --- Failing job ids ---------------------------------------------------------------------

# Only the failing Actions check has a job log worth tailing. The PENDING StatusContext has
# no detailsUrl to scan at all, and scanning -- rather than capturing -- is what keeps it
# from erroring on that row.
expect "$(plain rollup-mixed.json "$FAILING_JOBS_JQ")" "92080648031" \
  "job id extracted from the failing check only"

expect "$(plain rollup-empty.json "$FAILING_JOBS_JQ")" "" \
  "no failing checks yields no job ids"

# A check whose detailsUrl is not an Actions job URL must drop out silently: the log fetch
# is keyed on a numeric job id and there is nothing to fetch here.
expect "$(printf '{"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"FAILURE","detailsUrl":"https://app.aikido.dev/scan/1"}]}' | jq -r "$FAILING_JOBS_JQ")" \
  "" "failing check with no job id in detailsUrl drops out"

# --- Base SHA for the since-last-review diff ---------------------------------------------

# The blast radius if this picks the wrong SHA: the reviewer is handed a diff labelled
# "since your last review" that is not, and re-raises settled issues or misses new ones.
#
# Ordering is by submitted_at, not array order. A round is several review objects (each
# inline comment is its own COMMENTED review) and the API does not promise the newest last.
expect "$(slurped reviews-straddled-round.json "$LAST_REVIEW_JQ")" \
  "ffe5a7d50cccac18957cb592f4330d27473d10fb" \
  "base SHA is the latest reviewed commit by submitted_at"

# Cycle 1: no prior review, so there is no incremental diff to ask for. Empty string, not
# null -- the workflow tests it with [ -n ].
expect "$(slurped reviews-first-review.json "$LAST_REVIEW_JQ")" "" \
  "no prior review yields an empty base SHA"

# Same coupling as the cycle counter: keyed on the reviewer's login. If that moves, this
# must degrade to "no prior review" and let the reviewer read the full diff, never fall back
# to some other bot's or a human's commit_id.
expect "$(slurped reviews-foreign-reviewer.json "$LAST_REVIEW_JQ")" "" \
  "reviews by another login do not supply the base SHA"

expect "$(printf '[]' | jq -s -r "$LAST_REVIEW_JQ")" "" \
  "no reviews at all yields an empty base SHA"

# A PENDING review has no submitted_at. Sorting on null would put it anywhere, and it has no
# commit the author can have responded to yet.
expect "$(printf '[{"user":{"login":"claude[bot]"},"commit_id":"aaa","submitted_at":null}]' | jq -s -r "$LAST_REVIEW_JQ")" \
  "" "unsubmitted review is not treated as the last review"

# --- PR conversation ---------------------------------------------------------------------

# Chronological, and every author labelled: the reviewer's own prior summary comments are in
# here alongside the humans', and it has to be able to tell them apart.
expect "$(slurped issue-comments.json "$ISSUE_COMMENTS_JQ" | grep -c '^--- ')" "3" \
  "every conversation comment is labelled with its author"

expect "$(slurped issue-comments.json "$ISSUE_COMMENTS_JQ" | head -1)" \
  "--- claude[bot] at 2026-08-02T17:12:00Z" \
  "conversation is ordered oldest first, not by id"

# GitHub returns body: null for a comment whose text was removed. Without the // "" this
# renders the literal string "null" as if the bot had said it.
expect "$(slurped issue-comments.json "$ISSUE_COMMENTS_JQ" | grep -c '^null$')" "0" \
  "null comment body does not render as the word null"

expect "$(printf '[]' | jq -s -r "$ISSUE_COMMENTS_JQ")" "No PR conversation comments." \
  "no conversation comments says so"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
