#!/usr/bin/env bash
#
# Guards TOOL_USAGE_JQ in claude-pr-review.yml, which projects the Claude execution log
# down to the artifact the workflow uploads. The jq program is extracted from the workflow
# rather than copied, so the test exercises the shipped expression.
#
# Two jobs. First, the projection has to actually answer the question it exists for: the
# action prints only permission_denials.length to the job log, so the denied tool *names*
# live nowhere else and a change that drops them would be invisible until someone went
# looking for data that was never collected.
#
# Second, and the reason this file is worth more than its assertions: the input is the full
# conversation -- every tool input and every tool result. The runner has a readable git
# credential (checkout persists one via includeIf into $RUNNER_TEMP/git-credentials-*.config)
# and Read is unrestricted, so a transcript can contain a live token. ::add-mask:: scrubs the
# job log but not artifacts. The leak assertions below hold the line that this artifact
# carries names and counts only; widening the projection to "just the tool inputs too" is
# exactly the change that would quietly publish a token.

set -euo pipefail

cd "$(dirname "$0")/.."

WORKFLOW=.github/workflows/claude-pr-review.yml

TOOL_USAGE_JQ=$(sed -n "s/^ *TOOL_USAGE_JQ='\(.*\)'\$/\1/p" "$WORKFLOW")
if [ -z "$TOOL_USAGE_JQ" ]; then
  echo "FAIL: no TOOL_USAGE_JQ='...' assignment found in $WORKFLOW" >&2
  exit 1
fi
if [ "$(printf '%s\n' "$TOOL_USAGE_JQ" | wc -l)" -ne 1 ]; then
  echo "FAIL: more than one TOOL_USAGE_JQ assignment in $WORKFLOW" >&2
  exit 1
fi

failures=0

# project <fixture> -- run the shipped filter over a fixture
project() {
  jq "$TOOL_USAGE_JQ" "tests/fixtures/$1"
}

# expect_jq <fixture> <jq expression> <expected> <description>
expect_jq() {
  local fixture=$1 expr=$2 want=$3 desc=$4 actual
  actual=$(project "$fixture" | jq -c "$expr")
  if [ "$actual" = "$want" ]; then
    echo "ok   $desc"
  else
    echo "FAIL $desc: expected $want, got $actual"
    failures=$((failures + 1))
  fi
}

# expect_absent <fixture> <needle> <description> -- the needle is in the fixture and must
# not survive the projection
expect_absent() {
  local fixture=$1 needle=$2 desc=$3
  if ! grep -qF -- "$needle" "tests/fixtures/$fixture"; then
    echo "FAIL $desc: fixture no longer contains '$needle', so the test proves nothing"
    failures=$((failures + 1))
    return
  fi
  if project "$fixture" | grep -qF -- "$needle"; then
    echo "FAIL $desc: '$needle' leaked into the projection"
    failures=$((failures + 1))
  else
    echo "ok   $desc"
  fi
}

# The denial names are the whole point: two Grep denials and one Glob, ranked.
expect_jq execution-log-denials.json '.denials' \
  '[{"name":"Grep","n":2},{"name":"Glob","n":1}]' \
  "denied tool names survive with counts"

# Calls are counted per tool, most-used first, independent of whether they were denied.
expect_jq execution-log-denials.json '.tool_calls[0]' \
  '{"name":"Grep","n":2}' \
  "tool calls counted and ranked"
expect_jq execution-log-denials.json '[.tool_calls[].name] | sort' \
  '["Bash","Grep","Read"]' \
  "every called tool appears once"

# Enough of the result message to compare runs before and after an allowlist change.
expect_jq execution-log-denials.json '.result.num_turns' '19' "turn count carried through"
expect_jq execution-log-denials.json '.result.subtype' '"success"' "result subtype carried through"

# The leak assertions. The fixture has the reviewer reading the runner's git credentials
# file, which is the concrete path by which a token reaches the transcript.
expect_absent execution-log-denials.json \
  "eC1hY2Nlc3MtdG9rZW46Z2hzX0ZBS0VUT0tFTkZPUlRFU1RT" \
  "credential from a tool result does not reach the artifact"
expect_absent execution-log-denials.json \
  "git-credentials-82efe7dc.config" \
  "file path from a tool input does not reach the artifact"
expect_absent execution-log-denials.json \
  "diff --git" \
  "repository contents from a tool result do not reach the artifact"
expect_absent execution-log-denials.json \
  "retention-days" \
  "search patterns from a denied call do not reach the artifact"

# A clean run: no denials, and the MCP inline-comment tool counted like any other.
expect_jq execution-log-clean.json '.denials' '[]' "clean run reports no denials"
expect_jq execution-log-clean.json '[.tool_calls[].name] | sort' \
  '["Bash","mcp__github_inline_comment__create_inline_comment"]' \
  "mcp tool names counted"

# A cancelled or crashed run leaves a log with no result message. The step is
# continue-on-error, but the filter should still produce a usable artifact rather than
# abort, so the tool calls made before the run died are not lost.
expect_jq execution-log-truncated.json '.denials' '[]' "log with no result message yields no denials"
expect_jq execution-log-truncated.json '.tool_calls' '[{"name":"Read","n":1}]' \
  "tool calls survive a log with no result message"
expect_jq execution-log-truncated.json '.result.num_turns' 'null' \
  "missing result message yields null fields, not an error"

# Degenerate input must not crash the filter.
empty=$(printf '[]' | jq -c "$TOOL_USAGE_JQ")
if [ "$empty" = '{"tool_calls":[],"denials":[],"result":{"subtype":null,"is_error":null,"num_turns":null,"duration_ms":null,"total_cost_usd":null}}' ]; then
  echo "ok   empty log projects to empty counts"
else
  echo "FAIL empty log: got $empty"
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
