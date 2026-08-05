#!/usr/bin/env bash
#
# Asserts the workflows are valid to GitHub, not merely valid YAML.
#
# This file exists because of an outage. A shell comment inside a `run:` block explained that
# PR title and body deliberately avoid an Actions expression -- and spelled the delimiter out
# to say so. Actions parses those delimiters everywhere in a workflow file, including inside
# a run block's shell comments, and an empty pair is a syntax error. The workflow became
# unparseable, so every run started with zero jobs, the required check never reported, and
# every open pull request across the org sat behind "Please close and reopen the PR to
# trigger this workflow" until the comment was reworded.
#
# Nothing in the previous suite could see it. `yaml.safe_load` accepts the file, the shell
# runs the comment happily, and tests/context-step-test.sh explicitly *exempted* comments
# from its delimiter check. The lesson is narrow and worth encoding: YAML-valid is not
# Actions-valid, and the gap is expression syntax.
#
# actionlint is the real check and runs when available. The scan below is the part that
# always runs, because CI must not depend on a tool being installed to catch the specific
# defect that caused an outage.

set -euo pipefail

cd "$(dirname "$0")/.."

failures=0
WORKFLOW_FILE=.github/workflows/claude-pr-review.yml

# The delimiter, assembled rather than written, so this file does not trip its own scan.
OPEN="\${$(printf '%s' '{')"
CLOSE="$(printf '%s' '}')}"

# Actions loads .yaml as well as .yml, and an unscanned workflow would go unmentioned
# rather than reported.
shopt -s nullglob
WORKFLOWS=(.github/workflows/*.yml .github/workflows/*.yaml)
if [ "${#WORKFLOWS[@]}" -eq 0 ]; then
  echo "FAIL no workflow files found; the scan proves nothing"
  exit 1
fi

for wf in "${WORKFLOWS[@]}"; do
  # The distinction that caused the outage, and the one the scan has to make: a delimiter in
  # a *YAML* comment is stripped by the YAML parser and never reaches Actions, while the same
  # characters inside a block scalar are part of the string value and are parsed. So block
  # scalars are scanned line for line, comments included, and outside them YAML comment lines
  # are skipped. Scanning raw text without that distinction reports the harmless env: comment
  # that has sat in this workflow since before any of this and would train the reader to
  # ignore the check.
  bad=$(awk -v open="$OPEN" -v shut="$CLOSE" '
    function scan(line, where,    i, rest, j, expr) {
      while ((i = index(line, open)) > 0) {
        rest = substr(line, i + length(open))
        j = index(rest, shut)
        if (j == 0) { print FILENAME ":" FNR ": unterminated expression (" where ")"; return }
        expr = substr(rest, 1, j - 1)
        gsub(/^[ \t]+|[ \t]+$/, "", expr)
        # Empty and unterminated only. A character class over what an expression may contain
        # rejects valid ones -- hashFiles and format calls use slashes, braces and percent
        # signs that no reasonable class covers -- and a heuristic that hard-fails CI on
        # correct input gets deleted rather than fixed. actionlint checks the grammar
        # properly, and now actually runs in CI.
        if (expr == "")
          print FILENAME ":" FNR ": empty expression in " where \
            " -- Actions rejects the whole workflow"
        line = substr(rest, j + length(shut))
      }
    }
    {
      indent = match($0, /[^ ]/) - 1
      if (indent < 0) indent = length($0)
      if (in_block) {
        if ($0 ~ /^[ \t]*$/) next
        if (indent < block_indent) in_block = 0
        else { scan($0, "a block scalar (a shell comment counts)"); next }
      }
      if ($0 ~ /:[ \t]*[|>][-+0-9]*[ \t]*$/) {
        in_block = 1
        block_indent = indent + 1
        next
      }
      # Outside a block scalar a whole-line YAML comment is invisible to Actions.
      if ($0 ~ /^[ \t]*#/) next
      scan($0, "a value")
    }
  ' "$wf") || {
    echo "FAIL the expression scan itself failed on $wf; the scan proves nothing"
    failures=$((failures + 1))
    continue
  }
  if [ -n "$bad" ]; then
    echo "FAIL $wf has invalid Actions expressions:"
    printf '%s\n' "$bad" | sed 's/^/       /'
    failures=$((failures + 1))
  else
    echo "ok   $wf expressions are well formed"
  fi
done

# Every read the context step makes needs a permission declared on the job, because the job
# declares `permissions:` explicitly and anything unlisted is `none`. That failure is silent
# by design -- each block degrades to its "could not read" sentence -- so a missing line here
# does not turn a run red, it just quietly empties the block. Two were missing on the first
# production run (checks and statuses), and no local test could see it: a personal access
# token has every scope, so the step works on a laptop and fails on the runner.
#
# The table is endpoint-shape to permission. It is deliberately coarse; the point is that
# adding a new API call to the step forces a decision about its permission.
step_script=$(awk '
  /^      - name: Gather review context$/ { in_step = 1 }
  in_step && /^        run: \|$/ { in_run = 1; next }
  in_run && /^        [a-z]/ { exit }
  in_run { print }
' "$WORKFLOW_FILE")
# Fail loudly if the extraction drifted. check_permission returns early when the pattern is
# absent from the script, so an empty step_script silently turns all six checks into no-ops --
# in the one file whose purpose is catching a permission that is silently missing. (declared
# fails safe: empty means every check reports FAIL.)
if [ "$(printf '%s\n' "$step_script" | wc -l)" -lt 100 ]; then
  echo "FAIL the context-step extraction no longer matches $WORKFLOW_FILE;" \
    "the permission table proves nothing"
  failures=$((failures + 1))
fi
declared=$(awk '/^    permissions:$/ { p = 1; next } p && /^      [a-z-]+:/ { print $1 } p && /^    [a-z]/ { exit }' \
  "$WORKFLOW_FILE" | tr -d ':')

# check <pattern> <permission> <what it is for>
check_permission() {
  printf '%s\n' "$step_script" | grep -qF -- "$1" || return 0
  if printf '%s\n' "$declared" | grep -qx "$2"; then
    echo "ok   $2 is declared for $3"
  else
    echo "FAIL the step calls $3 but the job never grants $2: read"
    failures=$((failures + 1))
  fi
}

check_permission "/actions/jobs/" actions "the failing-job log excerpts"
check_permission "/issues/" issues "the PR conversation comments"
check_permission "statusCheckRollup" checks "the CheckRun half of the CI rollup"
check_permission "statusCheckRollup" statuses "the StatusContext half of the CI rollup"
check_permission "/compare/" contents "the since-last-review comparison"
check_permission "/pulls/" pull-requests "the PR reads"

# The scan above is a backstop for one class. actionlint checks the schema, the expression
# grammar, and the shell; run it when it is on PATH. shellcheck findings are excluded because
# the run blocks here intentionally use unquoted word splitting for job ids.
if command -v actionlint >/dev/null 2>&1; then
  if out=$(actionlint "${WORKFLOWS[@]}" 2>&1); then
    echo "ok   actionlint reports no findings"
  else
    remaining=$(printf '%s\n' "$out" | grep -v 'shellcheck reported' || true)
    if printf '%s\n' "$remaining" | grep -qE '\[(expression|syntax-check|events|workflow-call)\]'; then
      echo "FAIL actionlint reports errors that would stop the workflow from starting:"
      printf '%s\n' "$remaining" | grep -E '\[(expression|syntax-check|events|workflow-call)\]' \
        | sed 's/^/       /'
      failures=$((failures + 1))
    else
      echo "ok   actionlint reports no startup-fatal findings"
    fi
  fi
else
  echo "skip actionlint not installed; only the expression scan ran"
fi

# The prompt document reaches the model through steps.prompt.outputs.content, which is the one
# path into the prompt that `neutralise_untrusted` never touches -- it runs over the two
# context step outputs only. So a workflow command written *here* is not conditional on what
# an author does: it annotates the review's own check run on every run in the org, for as long
# as the line is on main. This file documents the sanitiser, so it necessarily talks about the
# markers, and one draft of that paragraph shipped a live `##[error]` for exactly that reason.
#
# Only the parsable spellings count. `##[` with no closing bracket on the line is inert (there
# is nothing to close the command), and `## [error]` is the already-spaced form -- both appear
# in the paragraph on purpose, and the contrast is the point of it.
PROMPT_DOC=docs/claude-pr-review-prompt.md
if [ ! -f "$PROMPT_DOC" ]; then
  echo "FAIL $PROMPT_DOC is missing, so the marker scan proves nothing"
  failures=$((failures + 1))
elif found=$(grep -nE '##\[[A-Za-z][^]]*\]|^[[:space:]]*::' "$PROMPT_DOC"); then
  echo "FAIL $PROMPT_DOC contains a parsable Actions workflow command. It is injected into"
  echo "     the prompt unsanitised, so this annotates every review run in the org:"
  printf '%s\n' "$found" | sed 's/^/       /'
  failures=$((failures + 1))
else
  echo "ok   the prompt document carries no parsable workflow command"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
