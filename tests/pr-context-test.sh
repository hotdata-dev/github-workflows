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
COMPARE_STATUS_JQ=$(extract_jq COMPARE_STATUS_JQ)
ISSUE_COMMENTS_JQ=$(extract_jq ISSUE_COMMENTS_JQ)
THREADS_JQ=$(extract_jq THREADS_JQ)
# Both comment programs take the second reviewer's login as --arg. Extracted, not written
# here: a test carrying its own copy of the login would keep passing after the shipped
# constant changed, which is the drift extracting the programs exists to prevent.
OTHER_REVIEW_BOT=$(extract_const OTHER_REVIEW_BOT)

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
#
# --arg skip on every call, whether the program reads it or not: jq only objects to an
# undefined $skip, never to an unused one, and one helper is easier to keep right than a
# second helper for the two programs that take it.
slurped() {
  jq --arg skip "$OTHER_REVIEW_BOT" -s -r "$2" "tests/fixtures/$1"
}
plain() {
  jq --arg skip "$OTHER_REVIEW_BOT" -r "$2" "tests/fixtures/$1"
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

# A field the API omitted must not render as a number. "+null/-null" is a claim about the
# change, and the reviewer quotes these counts back in its comments; "unknown" and 0 are
# visibly not measurements. Same reason the CheckRun name is defaulted below.
expect "$(printf '[{"filename":"api/app.py"},{"status":"modified","additions":4,"deletions":1,"filename":"b.py"}]' | jq -s -r "$FILES_JQ")" \
  "2 files, +4 -1
unknown +0/-0 api/app.py
modified +4/-1 b.py" \
  "file entry missing its counts renders as unknown, not null"

expect "$(printf '[{"status":"added","additions":1,"deletions":0}]' | jq -s -r "$FILES_JQ")" \
  "1 files, +1 -0
added +1/-0 (unnamed file)" \
  "file entry missing its name says so rather than naming null"

expect "$(printf '{"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"FAILURE"}]}' | jq -r "$CHECKS_JQ")" \
  "FAILURE  / (unnamed check)" \
  "check missing its name does not become a check called null"

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

# --- Comparison status --------------------------------------------------------------------

# Only "ahead" means the reviewed SHA fast-forwards to the head, which is the one case where
# a three-dot compare really is "everything since my last review". Anything else -- and
# anything unreadable -- has to be distinguishable from it by the caller.
expect "$(printf '{"status":"ahead","ahead_by":2}' | jq -r "$COMPARE_STATUS_JQ")" "ahead" \
  "fast-forward comparison reports ahead"
expect "$(printf '{"status":"diverged"}' | jq -r "$COMPARE_STATUS_JQ")" "diverged" \
  "rebased comparison reports diverged"
expect "$(printf '{}' | jq -r "$COMPARE_STATUS_JQ")" "unknown" \
  "comparison with no status reports unknown, never ahead"

# --- Prior review threads ----------------------------------------------------------------

# This block is the prompt's other output, interpolated into the same string as pr_context
# and wrapped in <prior_review_comments>. It was an inline jq program until the exclusion
# below needed asserting, so these are its first fixture-level assertions.

# Every kept comment is labelled, and the reply carries its parent rather than a thread id:
# the reviewer decides whether prior feedback was answered by reading who said what to whom.
expect "$(slurped pull-comments-mixed-authors.json "$THREADS_JQ" | grep -c '^Author: ')" "3" \
  "every kept thread comment is labelled with its author"
expect "$(slurped pull-comments-mixed-authors.json "$THREADS_JQ" | grep -c '^Reply to #2101$')" "1" \
  "a reply carries its parent comment id, not a thread id"

# The exclusion the trial turns on. A second reviewer's findings arriving here would reach
# this reviewer as settled prior feedback -- not to be re-raised -- which is how a parallel
# comparison stops comparing two independent reviews.
expect "$(slurped pull-comments-mixed-authors.json "$THREADS_JQ" | grep -c 'pullfrog')" "0" \
  "the other review bot's inline comments do not reach the prompt"
expect "$(slurped pull-comments-mixed-authors.json "$THREADS_JQ" | grep -c '^null$')" "0" \
  "null comment body does not render as the word null"

# Withholding the only comments on the PR leaves a sentence that would otherwise be false,
# and this block's sentences are what the cycle ladder acts on. So the empty case says how
# many comments were withheld and whose, while the genuinely empty case stays plain.
expect "$(printf '[{"id":1,"user":{"login":"%s"},"path":"a.py","line":3,"created_at":"2026-08-28T00:00:00Z","body":"finding"}]' \
  "$OTHER_REVIEW_BOT" | jq --arg skip "$OTHER_REVIEW_BOT" -s -r "$THREADS_JQ")" \
  "No prior review comments. (1 comment(s) from $OTHER_REVIEW_BOT are excluded from this block.)" \
  "a block emptied by the exclusion says so, and how much it withheld"
expect "$(printf '[]' | jq --arg skip "$OTHER_REVIEW_BOT" -s -r "$THREADS_JQ")" \
  "No prior review comments." \
  "a genuinely empty block claims nothing about an exclusion"

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

expect "$(printf '[]' | jq --arg skip "$OTHER_REVIEW_BOT" -s -r "$ISSUE_COMMENTS_JQ")" \
  "No PR conversation comments." \
  "no conversation comments says so"

# The other half of the exclusion. The second reviewer posts its review body here -- a PR
# summary plus its findings -- so this endpoint carries the bulk of what it would contribute
# to this reviewer's prompt, against a block that may take half the escaped-byte budget.
expect "$(printf '[{"id":1,"user":{"login":"zfarrell"},"created_at":"2026-08-28T00:00:00Z","body":"rebased"},{"id":2,"user":{"login":"%s"},"created_at":"2026-08-28T00:01:00Z","body":"## Summary"}]' \
  "$OTHER_REVIEW_BOT" | jq --arg skip "$OTHER_REVIEW_BOT" -s -r "$ISSUE_COMMENTS_JQ")" \
  "--- zfarrell at 2026-08-28T00:00:00Z
rebased" \
  "the other review bot's conversation comments do not reach the prompt"

expect "$(printf '[{"id":2,"user":{"login":"%s"},"created_at":"2026-08-28T00:01:00Z","body":"## Summary"}]' \
  "$OTHER_REVIEW_BOT" | jq --arg skip "$OTHER_REVIEW_BOT" -s -r "$ISSUE_COMMENTS_JQ")" \
  "No PR conversation comments. (1 comment(s) from $OTHER_REVIEW_BOT are excluded from this block.)" \
  "a conversation emptied by the exclusion says so too"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
