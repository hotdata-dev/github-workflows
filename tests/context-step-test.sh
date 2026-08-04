#!/usr/bin/env bash
#
# Runs the "Gather review context" step's actual shell script against a stubbed gh, because
# the jq programs being right does not make the step right. The shell around them is where
# the step can fail in the way that costs the most: this step feeds a required org-wide
# check, and until it was made continue-on-error a non-zero exit here skipped the review
# *and* the notify step, leaving the PR with no review and no explanation.
#
# `bash -e -o pipefail` is what the runner uses, and it is unforgiving of the shapes this
# script is full of: `grep | tail` finding nothing, `$(( ))` on an empty variable, a `[ ]`
# test as the last command of a branch. Each of those aborts the step. So the script is run
# here exactly as the runner runs it, with the failure modes injected: an endpoint that
# 404s, a log with no error marker, a diff past the truncation cap.

set -euo pipefail

cd "$(dirname "$0")/.."

WORKFLOW=.github/workflows/claude-pr-review.yml
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0

# The step script, extracted from the workflow rather than copied: everything indented
# inside its `run: |` block, dedented, with the two ${{ }} expressions replaced by the
# variables the stub reads. Anything else interpolated into this script would be missed
# here, which is itself worth knowing -- ${{ }} in a run block is how shell injection gets
# in, and the env: block is where PR title and body are deliberately kept.
extract_step() {
  awk '
    /^      - name: Gather review context$/ { in_step = 1 }
    in_step && /^        run: \|$/ { in_run = 1; next }
    in_run && /^        [a-z]/ { exit }
    in_run { sub(/^          /, ""); print }
  ' "$WORKFLOW"
}

extract_step \
  | sed -e 's/\${{ github.event.pull_request.number }}/"$STUB_PR"/g' \
        -e 's/\${{ github.repository }}/"$STUB_REPO"/g' \
  > "$WORK/step.sh"

if [ "$(wc -l < "$WORK/step.sh")" -lt 100 ]; then
  echo "FAIL: extracted step script is only $(wc -l < "$WORK/step.sh") lines; the awk" \
    "extraction no longer matches the workflow" >&2
  exit 1
fi
# Comments are allowed to discuss ${{ }}; code is not allowed to contain one this test
# does not substitute, because an unsubstituted expression would run here as literal text
# and hide whatever the real workflow splices in.
if grep -vE '^[[:space:]]*#' "$WORK/step.sh" | grep -q '\${{'; then
  echo "FAIL: the step gained a \${{ }} interpolation this test does not substitute:" >&2
  grep -nE '\${{' "$WORK/step.sh" | grep -vE ':[[:space:]]*#' >&2
  exit 1
fi

# A gh stub that dispatches on the endpoint. Fixtures where the shape matters; generated
# text where the size matters. FAIL_ENDPOINT makes one endpoint 404 the way a permissions
# problem or a deleted branch would.
write_gh_stub() {
  cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
FIXTURES="$STUB_FIXTURES"
args="$*"
fail_if_marked() {
  case "$FAIL_ENDPOINT" in
    "$1") exit 1 ;;
  esac
}
case "$args" in
  *"/reviews"*)            fail_if_marked reviews; cat "$FIXTURES/reviews-straddled-round.json" ;;
  *"/pulls/"*"/comments"*) fail_if_marked comments; echo '[]' ;;
  *"/pulls/"*"/commits"*)  fail_if_marked commits; cat "$FIXTURES/pull-commits.json" ;;
  *"/pulls/"*"/files"*)    fail_if_marked files; cat "$FIXTURES/pull-files.json" ;;
  *"/issues/"*"/comments"*) fail_if_marked issue_comments; cat "$FIXTURES/issue-comments.json" ;;
  *"statusCheckRollup"*)   fail_if_marked rollup; cat "$FIXTURES/rollup-mixed.json" ;;
  *"/actions/jobs/"*"/logs"*)
    fail_if_marked job_logs
    # The flag is not optional: without it real gh refuses a log body containing ANSI
    # colour and writes nothing, which is how this block silently produced
    # "(log unavailable)" on every failing job.
    case "$args" in
      *--allow-escape-sequences*) cat "$FIXTURES/$STUB_JOB_LOG" ;;
      *) echo "the response contains terminal escape sequences" >&2; exit 1 ;;
    esac
    ;;
  *"/compare/"*)           fail_if_marked compare; printf 'diff --git a/api/app.py b/api/app.py\n+incremental change\n' ;;
  *"pr diff"*)             fail_if_marked diff; seq 1 "$STUB_DIFF_LINES" | sed 's/^/+line /' ;;
  *) echo "gh stub: unhandled args: $args" >&2; exit 1 ;;
esac
STUB
  chmod +x "$WORK/bin/gh"
}

# run_step <description> -- run the extracted script in a clean temp dir, echo its exit code
run_step() {
  # ${WORK:?} so an unset WORK cannot turn this into `rm -rf /bin`.
  rm -rf "${WORK:?}/bin" "${WORK:?}/rt" "${WORK:?}/out.txt"
  mkdir -p "$WORK/bin" "$WORK/rt"
  write_gh_stub
  : > "$WORK/out.txt"
  set +e
  env PATH="$WORK/bin:$PATH" \
    RUNNER_TEMP="$WORK/rt" \
    GITHUB_OUTPUT="$WORK/out.txt" \
    STUB_FIXTURES="$PWD/tests/fixtures" \
    STUB_PR=172 \
    STUB_REPO=hotdata-dev/dlthubworker \
    STUB_JOB_LOG="${STUB_JOB_LOG:-job-log-django.txt}" \
    STUB_DIFF_LINES="${STUB_DIFF_LINES:-40}" \
    FAIL_ENDPOINT="${FAIL_ENDPOINT:-none}" \
    HEAD_SHA="${HEAD_SHA:-1d01475432236aa4fbca722aaaa2687c2b2e4947}" \
    BASE_REF=main \
    PR_TITLE='feat(filesystem): continuous sync' \
    PR_BODY='Adds a watermark. `$(touch /tmp/pwned)` and ${{ github.token }} are literal text here.' \
    bash -e -o pipefail "$WORK/step.sh" > "$WORK/step.out" 2>&1
  echo $?
  set -e
}

# The rendered pr_context output, between its heredoc delimiters.
context() {
  awk '/^pr_context<</ { d = substr($0, 13); next } d && $0 == d { exit } d' "$WORK/out.txt"
}

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

# expect_context <grep pattern> <description>
expect_context() {
  if context | grep -qE -- "$1"; then
    echo "ok   $2"
  else
    echo "FAIL $2: no line matching /$1/ in the rendered context"
    failures=$((failures + 1))
  fi
}

# --- The whole step, nothing failing ----------------------------------------------------

expect "$(run_step)" "0" "step exits 0 with every endpoint answering"

for section in '^## Pull request' '^## Commits' '^## Changed files' '^## CI checks' \
  '^## Diff since your last review' '^## Full diff' '^## PR conversation'; do
  expect_context "$section" "renders the ${section#^## } block"
done

# The review_cycle output still has to be there: it predates this step's other blocks and
# the prompt's cycle-awareness ladder reads it.
expect "$(grep -c '^review_cycle=7$' "$WORK/out.txt")" "1" \
  "review cycle counted from the same reviews payload"

# PR body reaches the context as text. If it ever arrives any other way than through env,
# this is the assertion that catches it -- the body here is a command substitution and a
# ${{ }} expression, and both must survive as characters.
expect_context '\$\(touch /tmp/pwned\)' "PR body interpolates as literal text, not shell"
expect "$([ -e /tmp/pwned ] && echo leaked || echo safe)" "safe" \
  "command substitution in the PR body did not execute"

# --- Failing CI job ---------------------------------------------------------------------

# The Django log: summary 50 lines above the error marker, which a tail window missed.
expect_context 'FAILED \(failures=1' "test summary line pulled from the failing job log"
expect_context 'FAIL: test_fence_stays_warn_only_while_mcp_forwards' \
  "failing test name reaches the context"
expect_context 'Log lines [0-9]+-[0-9]+, ending at the first error' \
  "error window labelled with its line range"

# Only the failing check has a log fetched. The IN_PROGRESS and PENDING rows in the rollup
# fixture must not turn into log requests, and the stub would exit non-zero if asked.
expect "$(context | grep -c '^### Failing job ')" "1" \
  "one log fetched, for the failing check only"

# The other shape, and the common one: no test-runner summary anywhere, the cause sitting
# directly above the error marker. Here that is a rustfmt diff -- four of five sampled logs
# looked like this, which is why the error window exists alongside the summary grep.
expect "$(STUB_JOB_LOG=job-log-rustfmt.txt run_step)" "0" \
  "step exits 0 on a log with no summary line"
expect_context 'assert!\(!req_off.continuous\)' \
  "cause above the error marker reaches the context when no summary exists"
if context | grep -q 'Summary lines:'; then
  echo "FAIL log with no summary line still printed a summary heading"
  failures=$((failures + 1))
else
  echo "ok   no summary heading when nothing matched"
fi

# A log with no ##[error]: the window falls back to a tail rather than computing a window
# from an empty line number, which under `set -e` would abort the step.
expect "$(STUB_JOB_LOG=pull-commits.json run_step)" "0" \
  "log with no error marker does not abort the step"
expect_context 'Last 120 log lines' "log with no error marker falls back to a tail"

# --- Truncation --------------------------------------------------------------------------

expect "$(STUB_DIFF_LINES=4000 run_step)" "0" "step exits 0 on an oversized diff"
expect_context '\(truncated: first 3000 of 4000 lines' "oversized diff truncated with a notice"
expect "$(context | grep -c '^+line ')" "3000" "truncated diff carries exactly the cap"

# --- Degradation --------------------------------------------------------------------------

# Every endpoint failing individually has to leave the step green and the block explicit.
# A block that silently renders as empty is the dangerous case: the reviewer states "no
# tests changed" or "CI is clean" on the strength of a failed API call.
for endpoint in commits files rollup diff issue_comments compare job_logs reviews comments; do
  expect "$(FAIL_ENDPOINT=$endpoint run_step)" "0" "step exits 0 when $endpoint fails"
done

FAIL_ENDPOINT=rollup run_step > /dev/null
expect "$(context | grep -cF 'Could not read check status')" "1" \
  "failed rollup says so rather than reporting no checks"
FAIL_ENDPOINT=files run_step > /dev/null
expect "$(context | grep -cF 'Could not read changed files')" "1" \
  "failed file list says so rather than reporting no changes"
FAIL_ENDPOINT=job_logs run_step > /dev/null
expect "$(context | grep -cF '(log unavailable)')" "1" \
  "unavailable job log says so"
FAIL_ENDPOINT=compare run_step > /dev/null
expect "$(context | grep -cF 'force-pushed')" "1" \
  "unavailable comparison explains the likely cause"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
