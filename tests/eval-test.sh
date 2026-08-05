#!/usr/bin/env bash
#
# The eval's own tests, and the whole of what runs on every pull request -- the eval itself costs
# real API calls and real minutes, so it is not in this suite.
#
# Two halves, in the order they can fail:
#
#   1. Every scenario in tests/eval/ is well formed. Schema, trees that actually differ, regexes
#      that compile, and -- the one that matters most -- context faults whose anchor still exists
#      in the reviewer workflow.
#   2. tests/eval-grade.py grades correctly, against committed API payloads.
#
# The second half exists because an eval whose grader is wrong is worse than no eval. It reports
# green while the reviewer regresses, or red while the reviewer is fine, and either way the
# scenarios stop being believed. The grader is pure and offline precisely so this can be pinned
# without spending an API call, so there is no excuse for leaving it untested.

set -euo pipefail

cd "$(dirname "$0")/.."

WORKFLOW=.github/workflows/claude-pr-review.yml
FIXTURES=tests/fixtures
GRADE=tests/eval-grade.py
failures=0

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

fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

# --- 1. Scenario definitions ---------------------------------------------------------------

shopt -s nullglob
SCENARIOS=(tests/eval/*/meta.json)
if [ "${#SCENARIOS[@]}" -eq 0 ]; then
  echo "FAIL no scenarios found under tests/eval; this suite proves nothing"
  exit 1
fi
echo "ok   found ${#SCENARIOS[@]} scenario(s)"

for meta in "${SCENARIOS[@]}"; do
  dir=$(dirname "$meta")
  name=$(basename "$dir")

  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$meta" 2>/dev/null; then
    fail "$name: meta.json is not valid JSON"
    continue
  fi

  # The schema, and every regex compiled. A pattern that does not compile would otherwise surface
  # as a grader crash halfway through a paid eval run.
  if ! problems=$(python3 - "$meta" <<'PY'
import json, re, sys

meta = json.load(open(sys.argv[1]))
problems = []

if not meta.get("name"):
    problems.append("no name")
if not meta.get("title"):
    problems.append("no title")
if not meta.get("summary"):
    problems.append("no summary")

expect = meta.get("expect")
if not isinstance(expect, dict):
    problems.append("no expect block")
    expect = {}

verdict = expect.get("verdict", "any")
if verdict not in ("approve", "request_changes", "comment", "none", "any"):
    problems.append(f"unknown verdict {verdict!r}")
summary = expect.get("summary_comment", "any")
if summary not in ("required", "forbidden", "any"):
    problems.append(f"unknown summary_comment {summary!r}")

for key in ("must_match", "must_not_match"):
    for pattern in expect.get(key, []):
        try:
            re.compile(pattern)
        except re.error as exc:
            problems.append(f"{key} pattern /{pattern}/ does not compile: {exc}")

repeats = meta.get("repeats")
threshold = meta.get("threshold")
if not isinstance(repeats, int) or repeats < 1:
    problems.append(f"repeats must be a positive integer, got {repeats!r}")
if not isinstance(threshold, int) or threshold < 1:
    problems.append(f"threshold must be a positive integer, got {threshold!r}")
# A threshold above repeats can never be met, so the scenario would be permanently red -- and it
# would look like a reviewer regression rather than a typo in a JSON file.
if isinstance(repeats, int) and isinstance(threshold, int) and threshold > repeats:
    problems.append(f"threshold {threshold} exceeds repeats {repeats}; unsatisfiable")

# An expectation block with nothing assertable in it passes for free. That is the shape a scenario
# decays into when someone loosens it to stop a flake, and it must not be silent.
assertable = (
    verdict != "any"
    or summary != "any"
    or expect.get("must_match")
    or expect.get("must_not_match")
    or expect.get("must_mention_paths")
    or expect.get("all_nits_marked")
    or "max_nit_comments" in expect
)
if not assertable:
    problems.append("expect block asserts nothing; the scenario would pass unconditionally")

print("\n".join(problems))
PY
  ); then
    fail "$name: schema check crashed"
    continue
  fi
  if [ -n "$problems" ]; then
    echo "FAIL $name: invalid meta.json:"
    printf '%s\n' "$problems" | sed 's/^/       /'
    failures=$((failures + 1))
  else
    echo "ok   $name: meta.json is well formed"
  fi

  [ -f "$dir/pr-body.md" ] || fail "$name: no pr-body.md"

  # The trees have to differ, or the pull request has an empty diff and the reviewer is being asked
  # about nothing. `diff -r` rather than comparing file lists, because a scenario whose only change
  # is inside a file would pass a name-only comparison.
  if [ -d "$dir/before" ] && [ -d "$dir/after" ]; then
    if diff -r "$dir/before" "$dir/after" >/dev/null 2>&1; then
      fail "$name: before/ and after/ are identical, so the PR would have an empty diff"
    else
      echo "ok   $name: before/ and after/ differ"
    fi
  else
    fail "$name: needs both before/ and after/ directories"
  fi

  # Injected workflows must exist and be parsable, or the scenario silently loses the check it
  # exists to produce -- failing-ci would grade a PR with no failing CI.
  while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    if [ ! -f "$dir/workflows/$wf" ]; then
      fail "$name: inject.workflows names $wf but $dir/workflows/$wf does not exist"
    elif command -v actionlint >/dev/null 2>&1 \
      && ! actionlint -shellcheck= "$dir/workflows/$wf" >/dev/null 2>&1; then
      fail "$name: injected workflow $wf does not lint"
    else
      echo "ok   $name: injected workflow $wf is present"
    fi
  done < <(python3 -c '
import json, sys
meta = json.load(open(sys.argv[1]))
for name in meta.get("inject", {}).get("workflows", []):
    print(name)
' "$meta")

  # The assertion this half of the suite is really for. A context fault is a literal string
  # replacement against the reviewer workflow, so a workflow edit that touches the anchored line
  # makes the fault a no-op: the eval would then review an *unfaulted* pull request and report that
  # the reviewer handled a degraded context correctly, having never degraded anything. Exactly once,
  # not merely present, because two matches means the replacement lands somewhere unintended too.
  while IFS= read -r find; do
    [ -n "$find" ] || continue
    hits=$(grep -cF -- "$find" "$WORKFLOW" || true)
    if [ "$hits" = "1" ]; then
      echo "ok   $name: context fault anchor still matches $WORKFLOW exactly once"
    else
      echo "FAIL $name: context fault anchor matches $WORKFLOW $hits time(s), expected exactly 1."
      echo "     The fault would not apply, so the eval would grade an unfaulted pull request and"
      echo "     report a pass for a condition it never created. Re-anchor it:"
      printf '       %s\n' "$find"
      failures=$((failures + 1))
    fi
  done < <(python3 -c '
import json, sys
meta = json.load(open(sys.argv[1]))
for fault in meta.get("inject", {}).get("context_fault", []):
    print(fault["find"])
' "$meta")
done

# --- 2. The grader --------------------------------------------------------------------------

# grade <meta> <reviews> <comments> <convo> -- echo the exit status, leave JSON in $OUT
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT
grade() {
  set +e
  python3 "$GRADE" --meta "$1" --reviews "$2" --comments "$3" --convo "$4" \
    --reviewer 'claude[bot]' > "$OUT" 2>"$OUT.err"
  local status=$?
  set -e
  if [ ! -s "$OUT" ]; then
    echo "grader wrote nothing; stderr:" >&2
    cat "$OUT.err" >&2
  fi
  echo "$status"
}
field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$OUT" "$1"
}
check_detail() {
  python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
for c in data["checks"]:
    if not c["ok"]:
        print(c["name"])
' "$OUT"
}

# The verdict resolution that a naive "latest review wins" gets wrong. Both fixtures put a
# COMMENTED review *after* the real position, because that is what actually happens: every inline
# comment is its own review object sharing the round's commit_id, so the newest review by timestamp
# is usually a comment saying nothing about approval.
expect "$(grade tests/eval/golden-path/meta.json \
  "$FIXTURES/eval-reviews-approved.json" "$FIXTURES/eval-empty.json" "$FIXTURES/eval-empty.json")" \
  "0" "golden-path passes on an approve with no comments"
expect "$(field verdict)" "approve" "an APPROVED review resolves to approve despite a later COMMENTED"

expect "$(grade tests/eval/hidden-bug/meta.json \
  "$FIXTURES/eval-reviews-changes.json" "$FIXTURES/eval-empty.json" \
  "$FIXTURES/eval-convo-summary.json")" \
  "0" "hidden-bug passes when the summary names the watermark boundary"
expect "$(field verdict)" "request_changes" \
  "a CHANGES_REQUESTED review resolves to request_changes despite a later COMMENTED"

# The failure direction, which is the half that decides whether this eval can catch a regression.
# An approve on the hidden-bug scenario is precisely the reviewer failure worth catching.
expect "$(grade tests/eval/hidden-bug/meta.json \
  "$FIXTURES/eval-reviews-approved.json" "$FIXTURES/eval-empty.json" "$FIXTURES/eval-empty.json")" \
  "1" "hidden-bug fails when the reviewer approves instead"
if [ "$(check_detail | grep -c '^verdict$')" -ge 1 ]; then
  echo "ok   the failing check is named as the verdict"
else
  echo "FAIL the wrong check failed on an approved hidden-bug:"
  check_detail | sed 's/^/       /'
  failures=$((failures + 1))
fi

# No review at all -- the shape a broken reviewer workflow produces, and the one that must never
# read as a pass. Before PR #27 this was the outage signature: no run, no check, no review.
expect "$(grade tests/eval/golden-path/meta.json \
  "$FIXTURES/eval-empty.json" "$FIXTURES/eval-empty.json" "$FIXTURES/eval-empty.json")" \
  "1" "a pull request with no review at all fails rather than passing quietly"
expect "$(field verdict)" "none" "no review resolves to the none verdict"

# summary_comment: forbidden. golden-path approves silently, so a summary comment is a regression
# against the prompt's own output rules.
expect "$(grade tests/eval/golden-path/meta.json \
  "$FIXTURES/eval-reviews-approved.json" "$FIXTURES/eval-empty.json" \
  "$FIXTURES/eval-convo-summary.json")" \
  "1" "golden-path fails when the reviewer posts a summary comment on an approve"

# The nit rule, both ways. The marked fixture also carries a `nit:` from a *human*, which must not
# be attributed to the reviewer -- otherwise a chatty human could fail the reviewer's scenario.
expect "$(grade tests/eval/nits-only/meta.json \
  "$FIXTURES/eval-reviews-approved.json" "$FIXTURES/eval-comments-nits.json" \
  "$FIXTURES/eval-empty.json")" \
  "0" "nits-only passes when every reviewer nit says (not blocking)"
expect "$(python3 -c 'import json;print(json.load(open("'"$OUT"'"))["observed"]["nit_comments"])')" \
  "2" "a human's nit is not counted as the reviewer's"

expect "$(grade tests/eval/nits-only/meta.json \
  "$FIXTURES/eval-reviews-approved.json" "$FIXTURES/eval-comments-unmarked-nit.json" \
  "$FIXTURES/eval-empty.json")" \
  "1" "an unmarked nit fails the classification rule"

# max_nit_comments -- the cycle ladder. cycle-convergence allows zero, so a single nit fails it
# even though the verdict and everything else is right.
expect "$(grade tests/eval/cycle-convergence/meta.json \
  "$FIXTURES/eval-reviews-approved.json" "$FIXTURES/eval-comments-nits.json" \
  "$FIXTURES/eval-empty.json")" \
  "1" "cycle-convergence fails when nits are left at cycle 5"

# must_not_match reads the summary comment too, not just inline bodies. A false-green CI claim is
# the production failure this scenario exists for, and it would most naturally be written there.
CLAIM=$(mktemp)
cat > "$CLAIM" <<'JSON'
[
  {
    "id": 400,
    "user": {"login": "claude[bot]", "type": "Bot"},
    "created_at": "2026-08-05T12:00:41Z",
    "body": "Looks good and all checks pass, so this is safe to merge."
  }
]
JSON
expect "$(grade tests/eval/degraded-context/meta.json \
  "$FIXTURES/eval-reviews-approved.json" "$FIXTURES/eval-empty.json" "$CLAIM")" \
  "1" "degraded-context fails on a false green claim made in the summary comment"
rm -f "$CLAIM"

# And the same scenario passing: silence about CI is acceptable, asserting it is not.
expect "$(grade tests/eval/degraded-context/meta.json \
  "$FIXTURES/eval-reviews-approved.json" "$FIXTURES/eval-empty.json" "$FIXTURES/eval-empty.json")" \
  "0" "degraded-context passes when the review claims nothing about CI"

# A foreign bot reviewing the same pull request is reported but never fatal: aikido-pr-checks,
# codecov and sentry are all installed org-wide on the sandbox repo.
grade tests/eval/golden-path/meta.json \
  "$FIXTURES/eval-reviews-approved.json" "$FIXTURES/eval-empty.json" "$FIXTURES/eval-empty.json" \
  > /dev/null
if python3 -c '
import json, sys
others = json.load(open(sys.argv[1]))["observed"]["other_bot_reviewers"]
sys.exit(0 if "aikido-pr-checks[bot]" in others else 1)
' "$OUT"; then
  echo "ok   a foreign bot reviewer is reported without failing the scenario"
else
  echo "FAIL a foreign bot reviewer was not reported in observed.other_bot_reviewers"
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
