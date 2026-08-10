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
TESTS_FILE=.github/workflows/tests.yml
CONTEXT_SCRIPT=scripts/gather-review-context.sh

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

# cancel-in-progress cancels whatever else is in the group, so the group needs a key that is
# never empty on any event the workflow accepts. It is keyed on the pull request number, and
# tests.yml calls this workflow on `push: branches: [main]` as well, where there is no pull
# request and that key expands to nothing -- collapsing every main-push run into one constant
# group. Two merges landing close together would then cancel each other, and because the
# cancellation lands on a *called* workflow it takes the caller's whole Tests run with it, so a
# commit on main silently loses its test signal.
#
# Checked as a property of the expression rather than by evaluating it: the PR number must be
# followed by a `||` fallback, so the group stays unique when there is no pull request.
group_line=$(grep -n '^  group:' "$WORKFLOW_FILE" | head -1)
if [ -z "$group_line" ]; then
  echo "FAIL $WORKFLOW_FILE has no workflow-level concurrency group; this check proves nothing"
  failures=$((failures + 1))
elif ! printf '%s\n' "$group_line" | grep -q 'pull_request\.number[[:space:]]*||'; then
  echo "FAIL the concurrency group keys on the pull request number with no fallback, so on a"
  echo "     push to main it collapses to a constant and concurrent merges cancel each other's"
  echo "     Tests run:"
  printf '%s\n' "$group_line" | sed 's/^/       /'
  failures=$((failures + 1))
else
  echo "ok   the concurrency group stays unique when there is no pull request"
fi

# Every read the context step makes needs a permission declared on the job, because the job
# declares `permissions:` explicitly and anything unlisted is `none`. That failure is silent
# by design -- each block degrades to its "could not read" sentence -- so a missing line here
# does not turn a run red, it just quietly empties the block. Two were missing on the first
# production run (checks and statuses), and no local test could see it: a personal access
# token has every scope, so the step works on a laptop and fails on the runner.
#
# The table is endpoint-shape to permission. It is deliberately coarse; the point is that
# adding a new API call to the step forces a decision about its permission.
step_script=$(cat "$CONTEXT_SCRIPT" 2>/dev/null || true)
# Fail loudly if the script went missing or shrank to nothing. check_permission returns early
# when the pattern is absent from the script, so an empty step_script silently turns all six
# checks into no-ops -- in the one file whose purpose is catching a permission that is silently
# missing. (declared fails safe: empty means every check reports FAIL.)
if [ "$(printf '%s\n' "$step_script" | wc -l)" -lt 100 ]; then
  echo "FAIL $CONTEXT_SCRIPT is missing or too short; the permission table proves nothing"
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

# A missing context script has to fail loudly somewhere, and it cannot be the context step: that
# one is continue-on-error, so `bash <missing file>` exits 127 into a green run. The prompt
# document gets this for free -- `cat` on a missing file fails its step -- and the script needs an
# explicit check to match.
#
# Scoped to the step, not grepped over the file, because where the check sits is the whole property
# being asserted: the same `-f` test moved into the context step would satisfy a file-wide grep and
# prove nothing. So pull the one step and require both halves -- that it tests for the script, and
# that it is not continue-on-error.
precondition_step=$(awk '/^      - name: Verify the context step.s preconditions$/ { found = 1; next }
                         found && /^      - / { exit }
                         found { print }' "$WORKFLOW_FILE")
if [ -z "$precondition_step" ]; then
  echo "FAIL no 'Verify the context step's preconditions' step in $WORKFLOW_FILE; a missing"
  echo "     context script would exit 127 inside a continue-on-error step and leave the run"
  echo "     green with an empty context"
  failures=$((failures + 1))
elif ! printf '%s\n' "$precondition_step" | grep -q -- '-f .*gather-review-context\.sh\|script=.*gather-review-context\.sh'; then
  echo "FAIL the precondition step does not test for the context script:"
  printf '%s\n' "$precondition_step" | sed 's/^/       /'
  failures=$((failures + 1))
elif printf '%s\n' "$precondition_step" | grep -q 'continue-on-error'; then
  echo "FAIL the precondition step is continue-on-error, so the check it makes cannot fail the"
  echo "     job and proves nothing"
  failures=$((failures + 1))
else
  echo "ok   a missing context script fails the job rather than emptying the context"
fi

# The context step is continue-on-error, so everything it can fail at -- a checkout that does not
# deliver the script, a bad path, a rename that stops matching the sparse pattern -- leaves the run
# green with pr_context, threads and review_cycle all unset. Ungated, the review step then runs on
# that: a blank REVIEW CYCLE and an empty prior-comments block read as cycle 1 with nothing raised
# before, which is a false statement rather than a missing one, and it reaches every consumer repo
# at once. The script's own guards exist to stop exactly that claim, and they cannot help if the
# script never ran. So the review must be gated on the context step having succeeded.
# The condition is a folded block, so collect its continuation lines too: everything indented
# past the `if:` key, up to the next key of the step.
review_gate=$(awk '/^      - uses: anthropics\/claude-code-action/ { found = 1; next }
                   found && /^        if:/ { print; in_if = 1; next }
                   in_if && /^          / { print; next }
                   in_if { exit }' "$WORKFLOW_FILE")
if [ -z "$review_gate" ]; then
  echo "FAIL could not find the review step's if: in $WORKFLOW_FILE; this check proves nothing"
  failures=$((failures + 1))
elif ! printf '%s\n' "$review_gate" | grep -q "steps\.context\.outcome == 'success'"; then
  echo "FAIL the review step does not require the context step to have succeeded, so a failed"
  echo "     context read sends the model an empty context that reads as a clean cycle 1:"
  printf '%s\n' "$review_gate" | sed 's/^/       /'
  failures=$((failures + 1))
else
  echo "ok   the review step runs only when the context step succeeded"
fi

# The table above forces a new API call in the context step to declare its permission on the
# review job. That does nothing for the smoke job in tests.yml, which calls the review workflow
# and has to grant the same set by hand: a caller cannot give a reusable workflow more than it
# holds, so a permission added on one side and not the other fails the smoke job with Actions'
# "is requesting 'x: read', but is only allowed 'x: none'" -- loud, but on a file that looks
# unrelated to the change that caused it. Asserting the two match keeps the claim in tests.yml's
# comment true by construction instead of by review.
#
# Name and value both, so pull-requests: write degrading to read is caught too.
perm_pairs() {
  awk '/^    permissions:$/ { p = 1; next }
       p && /^      [a-z-]+:[[:space:]]/ { print $1, $2 }
       p && /^    [a-z]/ { exit }' "$1" | sort
}
review_perms=$(perm_pairs "$WORKFLOW_FILE")
smoke_perms=$(perm_pairs "$TESTS_FILE")
if [ -z "$review_perms" ] || [ -z "$smoke_perms" ]; then
  echo "FAIL a permissions block came back empty (review: $(printf '%s' "$review_perms" | wc -l)," \
    "smoke: $(printf '%s' "$smoke_perms" | wc -l)); the parity check proves nothing"
  failures=$((failures + 1))
elif [ "$review_perms" != "$smoke_perms" ]; then
  echo "FAIL the smoke job in $TESTS_FILE does not grant what the review job declares."
  echo "     A caller cannot grant a reusable workflow more than it holds, so the smoke job"
  echo "     fails until both sides agree. Difference (< review job, > smoke job):"
  diff <(printf '%s\n' "$review_perms") <(printf '%s\n' "$smoke_perms") | sed 's/^/       /'
  failures=$((failures + 1))
else
  echo "ok   the smoke job grants exactly what the review job declares"
fi

# Actions evaluates a `run:` block as a template, and the value it evaluates cannot exceed
# 21,000 characters. Going over does not fail the step -- it fails the whole workflow at load
# time, which is the same outage shape as the empty expression above: no jobs, the required
# check never reports, every open pull request in the org blocks.
#
# This has already happened once. #26 pushed the context step to 22,016 characters and had to
# be reverted (8b04393), which took an unrelated tool-usage flag down with it; #29 then moved
# that step out to the context script. Nothing in the suite could see either the breach or how
# close the file sat beforehand -- 20,545 characters, about eight comment lines of headroom.
#
# So the budget is 20,000, not 21,000: a block within a few comments of the ceiling is the
# defect, because the next person adding a comment is the one who takes the org down. Blocks
# over budget belong in scripts/ like the context step, not trimmed to fit.
#
# The measurement has to match what Actions counts, which is the block scalar's *value* --
# indentation stripped. Counting raw lines overstates every block (the context step reads
# 24,285 that way) and would make the budget meaningless. Implemented against the standard
# library only: this is the check for the defect that caused an outage, so it cannot be the
# one that skips when a YAML module is missing.
RUN_BUDGET=20000
SCANNER=$(mktemp)
trap 'rm -f "$SCANNER" "$SCANNER.yml"' EXIT
cat > "$SCANNER" <<'PY'
import sys

budget, paths = int(sys.argv[1]), sys.argv[2:]
found = 0
for path in paths:
    with open(path) as fh:
        lines = fh.readlines()
    i = 0
    while i < len(lines):
        stripped = lines[i].rstrip("\n")
        key = stripped.lstrip()
        # `- run: |` is a run block too -- a step may put run first, with no name. Skipping it
        # would leave the largest kind of block unmeasured while the check still reported ok,
        # which is the failure this file exists to prevent. The list marker is part of the
        # key's indentation: `      - run:` puts the step map at column 8, so content has to
        # be indented past 8, not past 6.
        while key.startswith("- "):
            key = key[2:]
        if key.startswith("run:"):
            rest = key[4:].strip()
            # Measured off the stripped key, so the list marker counts as indentation:
            # `      - run:` gives 8, the column `run` actually sits at.
            key_indent = len(stripped) - len(key)
            start = i + 1
            if not rest.startswith(("|", ">")):
                # Single-line plain scalar: the value is the text, no trailing newline.
                found += 1
                size = len(rest)
                i += 1
            else:
                i += 1
                body, block_indent = [], None
                while i < len(lines):
                    raw = lines[i].rstrip("\n")
                    if not raw.strip():             # blank lines belong to the block
                        body.append("")
                        i += 1
                        continue
                    indent = len(raw) - len(raw.lstrip())
                    if indent <= key_indent:
                        break
                    if block_indent is None:
                        block_indent = indent
                    body.append(raw[block_indent:])
                    i += 1
                # Clip chomping: trailing blank lines collapse to the single closing newline.
                while body and body[-1] == "":
                    body.pop()
                found += 1
                # Exact for the `|` family, which is what every block over a few hundred
                # characters here uses. A folded `>` joins lines with spaces, so this
                # over-counts it by the newlines -- erring toward failing early, which is the
                # safe direction for a budget.
                size = len("\n".join(body) + "\n") if body else 0
            if size >= budget:
                print(f"{path}:{start}: run block is {size} characters, "
                      f"budget {budget} (Actions rejects the workflow at 21000)")
            continue
        i += 1
if not found:
    print("NO-RUN-BLOCKS-FOUND")
PY

# The scanner is checked against known sizes before it is trusted on the real files. A
# sentinel that only proves blocks were *found* cannot distinguish a correct measurement from
# one that reads every block as zero -- and a budget check that always measures low reports ok
# forever.
#
# All three shapes the scanner branches on appear here: `- run: |` with the run key first (this
# was missed at first review and would have gone unmeasured with the check still green), the
# same block under a `name:`, and a plain single-line `run:` -- which is the most common shape
# in these files and the one branch that has no block-scalar logic to fall back on.
#
# Sizes are countable by eye, so the assertion needs no YAML parser to justify: two 9-character
# lines plus their newlines is 20, one 10-character line plus its newline is 11, and a plain
# scalar is its text with no trailing newline, so `echo hello` is 10.
cat > "$SCANNER.yml" <<'YML'
name: selftest
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: |
          aaaaaaaaa
          bbbbbbbbb
      - name: named step
        run: |
          cccccccccc
      - name: plain scalar
        run: echo hello
YML
measured=$(python3 "$SCANNER" 1 "$SCANNER.yml" | sed 's/.*run block is \([0-9]*\) characters.*/\1/' | sort -n | tr '\n' ' ')
if [ "$measured" != "10 11 20 " ]; then
  echo "FAIL the run-block scanner mis-measures a known input: expected sizes '10 11 20 ', got"
  echo "     '$measured' -- so the budget check below cannot be trusted"
  failures=$((failures + 1))
else
  echo "ok   the run-block scanner measures all three run: shapes correctly"
fi

oversized=$(python3 "$SCANNER" "$RUN_BUDGET" "${WORKFLOWS[@]}") || {
  echo "FAIL the run-block size scan itself failed; the budget check proves nothing"
  failures=$((failures + 1))
  oversized=""
}
if [ "$oversized" = "NO-RUN-BLOCKS-FOUND" ]; then
  echo "FAIL the run-block scan found no run: blocks at all; the budget check proves nothing"
  failures=$((failures + 1))
elif [ -n "$oversized" ]; then
  echo "FAIL a run: block is at or over the ${RUN_BUDGET}-character budget. Actions fails the"
  echo "     whole workflow at 21000 -- no jobs, no required check, every org PR blocked."
  echo "     Move the script to scripts/ rather than trimming comments to fit:"
  printf '%s\n' "$oversized" | sed 's/^/       /'
  failures=$((failures + 1))
else
  echo "ok   every run: block is under the ${RUN_BUDGET}-character budget"
fi

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

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
