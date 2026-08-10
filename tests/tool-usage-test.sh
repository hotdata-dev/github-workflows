#!/usr/bin/env bash
#
# Guards TOOL_USAGE_JQ in claude-pr-review.yml, which projects the Claude execution log
# down to the artifact the workflow uploads. The jq program is extracted from the workflow
# rather than copied, so the test exercises the shipped expression.
#
# Two jobs. First, the projection has to actually answer the question it exists for: the
# action prints only permission_denials.length to the job log, so the denied tool *names*
# live nowhere else and a change that drops them would be invisible until someone went
# looking for data that was never collected. Names turned out not to be enough -- 520 of
# 567 denials in the first week were "Bash" -- so the projection labels commands too, and
# the labels have to survive the same way.
#
# Second, and the reason this file is worth more than its assertions: the input is the full
# conversation -- every tool input and every tool result. The runner has a readable git
# credential (checkout persists one via includeIf into $RUNNER_TEMP/git-credentials-*.config)
# and Read is unrestricted, so a transcript can contain a live token. ::add-mask:: scrubs the
# job log but not artifacts. The leak assertions below hold the line that this artifact
# carries names, counts, and labels drawn from a closed vocabulary -- never text from the
# transcript. "Just the first token of the command" or "just the command prefix" is exactly
# the change that would quietly publish a credential path, so the vocabulary assertion
# below asserts the containment directly: every label in the artifact appears in CMD_JQ.

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=tests/lib.sh
. tests/lib.sh

CMD_JQ=$(extract_jq CMD_JQ)
TOOL_USAGE_JQ=$(extract_jq TOOL_USAGE_JQ)

failures=0

# project <fixture> -- run the shipped filter over a fixture, composed as the workflow does
project() {
  jq "$CMD_JQ $TOOL_USAGE_JQ" "tests/fixtures/$1"
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

# The denial names: three Bash, two Grep, one Glob, ranked.
expect_jq execution-log-denials.json '.denials' \
  '[{"name":"Bash","n":3},{"name":"Grep","n":2},{"name":"Glob","n":1}]' \
  "denied tool names survive with counts"

# Calls are counted per tool, most-used first, independent of whether they were denied.
expect_jq execution-log-denials.json '.tool_calls[0]' \
  '{"name":"Bash","n":5}' \
  "tool calls counted and ranked"
expect_jq execution-log-denials.json '[.tool_calls[].name] | sort' \
  '["Bash","Grep","Read"]' \
  "every called tool appears once"

# Enough of the result message to compare runs before and after an allowlist change.
expect_jq execution-log-denials.json '.result.num_turns' '19' "turn count carried through"
expect_jq execution-log-denials.json '.result.subtype' '"success"' "result subtype carried through"

# Bash calls are labelled, and compound forms are counted apart from bare ones. `gh pr diff`
# appears twice for that reason: allowlisted on its own, refused the moment it is redirected
# into a file and chained -- which is why the artifact has to distinguish them.
expect_jq execution-log-denials.json \
  '[.commands[] | .cmd + (if .compound then " (compound)" else "" end)] | sort' \
  '["cat/head/tail","gh pr diff","gh pr diff (compound)","rg","run tests/build"]' \
  "Bash commands labelled, compound forms kept separate"

# `timeout 900 uv run pytest` has to reach "run tests/build" rather than "other": the
# wrappers the reviewer puts in front of a command are what norm exists to strip.
expect_jq execution-log-denials.json \
  '[.commands[] | select(.cmd == "run tests/build")] | length' '1' \
  "timeout wrapper stripped before labelling"

# The denied subset is the actionable half: what the allowlist is actually costing.
expect_jq execution-log-denials.json \
  '[.denied_commands[] | .cmd + (if .compound then " (compound)" else "" end)] | sort' \
  '["cat/head/tail","gh pr diff (compound)","run tests/build"]' \
  "denied Bash commands labelled"

# Non-Bash denials carry no command label -- there is no command to label.
expect_jq execution-log-denials.json '[.denied_commands[].n] | add' '3' \
  "only Bash denials appear in denied_commands"

# compound is tested against the raw command string, so anything that merely *looks* like
# shell structure inflates it -- and a `|` inside quotes is a regex alternation, not a pipe.
# `rg -n 'a|b'` is a single allowlisted command; counting it as compound corrupts the one
# number the flag exists to produce, because the compound rows are read as "allowlisted but
# refused for being chained". Quoted spans are removed before the test for that reason.
compound_of() {
  printf '%s' "$1" | jq -R -r "$CMD_JQ classify | .compound | tostring"
}
# expect_compound <command> <true|false> <description>
expect_compound() {
  local actual
  actual=$(compound_of "$1")
  if [ "$actual" = "$2" ]; then
    echo "ok   $3"
  else
    echo "FAIL $3: expected compound=$2, got $actual for: $1"
    failures=$((failures + 1))
  fi
}

expect_compound "rg -n 'drive_write|promote_widened' src/" false \
  "single-quoted alternation is not compound"
expect_compound 'rg -n "LoadSource::Result|ResultStatus" src/' false \
  "double-quoted alternation is not compound"
expect_compound 'gh pr diff 21 | head -50' true \
  "a real pipe is compound"
expect_compound 'gh pr diff 21 > f.diff && wc -l f.diff' true \
  "a redirect and chain are compound"
expect_compound "rg -n 'a|b' src/ | head -20" true \
  "an alternation plus a real pipe is still compound"
expect_compound 'rg -n foo src/' false \
  "a plain search is not compound"

# has_subst answers the denial the frontloaded context did not remove: an allowlisted
# `gh pr review` refused on the way to posting. Unlike compound it is tested against the raw
# command, because the suspected trigger lives *inside* the quoted body -- a review body is
# markdown, and backticks in a double-quoted argument are command substitution to anything
# parsing shell. Running it through `unquoted` first would delete the evidence.
#
# Measured before this landed: `gh pr review` is refused on 29% of its 241 attempts across
# 170 settled-window runs, on 8 repos, costing the affected runs +$0.46 and +73s each --
# while `compound` reported 1 of 71. See issue #33.
subst_of() {
  printf '%s' "$1" | jq -R -r "$CMD_JQ classify | .has_subst | tostring"
}
# expect_subst <command> <true|false> <description>
expect_subst() {
  local actual
  actual=$(subst_of "$1")
  if [ "$actual" = "$2" ]; then
    echo "ok   $3"
  else
    echo "FAIL $3: expected has_subst=$2, got $actual for: $1"
    failures=$((failures + 1))
  fi
}

expect_subst 'gh pr review 21 --approve --body "nit: `foo` is wrong"' true \
  "a backtick inside the review body is flagged"
expect_subst 'gh pr comment 21 --body "see $(basename x)"' true \
  "an explicit command substitution is flagged"
expect_subst 'gh pr review 21 --approve --body "no markdown here"' false \
  "a plain body is not flagged"
expect_subst 'rg -n foo src/' false \
  "a plain search is not flagged"
# The distinction from compound, stated as an assertion: quoted spans are removed for one
# flag and kept for the other, so a body whose only shell-ish characters are backticks is
# has_subst without being compound. Getting these the same way round would make the two
# columns redundant and lose the write-path denials again.
expect_compound 'gh pr review 21 --approve --body "nit: `foo` is wrong"' false \
  "a backtick in a quoted body is not compound"

# End to end over the shape actually seen in production: the reviewer's first
# `gh pr review --request-changes` was refused, and the retry that landed carried the same
# feedback with the backticks removed. Both rows are `gh pr review`; has_subst is the only
# thing that tells them apart, which is the whole reason it is grouped on.
expect_jq execution-log-review-body.json \
  '[.commands[] | {cmd, has_subst, n}] | sort_by(.has_subst)' \
  '[{"cmd":"gh pr review","has_subst":false,"n":1},{"cmd":"gh pr review","has_subst":true,"n":1}]' \
  "the flagged and unflagged attempts are counted apart"
expect_jq execution-log-review-body.json '.denied_commands' \
  '[{"cmd":"gh pr review","compound":false,"has_subst":true,"n":1}]' \
  "the denied review post is flagged and not compound"

# Same boundary as every other label: the flag is a boolean, so no part of the body it was
# computed from may ride along with it.
expect_absent execution-log-review-body.json "GetUpdates.tsx" \
  "the review body does not reach the artifact"
expect_absent execution-log-review-body.json "rateLimit" \
  "code quoted in the review body does not reach the artifact"

# The containment assertion, and the one that has to keep holding: every label the
# projection emits is a literal in CMD_JQ. Nothing derived from the transcript can satisfy
# it, so the artifact cannot grow a credential path, a search pattern, or a file name
# without this failing first.
# Both sides sorted, and sorted after they are assembled: GNU comm rejects unsorted input
# outright where BSD comm quietly compares it anyway. The `["", "other"]` fallback in verb
# matches the same pattern as the real pairs, so "other" arrives here as a label like any
# other -- asserted below rather than assumed, since losing it would let an unrecognised
# command through this check.
vocabulary=$(printf '%s' "$CMD_JQ" | grep -o '", "[a-z /]*"\]' | sed 's/^", "//; s/"\]$//' | sort -u)
if [ -z "$vocabulary" ]; then
  echo "FAIL vocabulary: no labels found in CMD_JQ, so the containment test proves nothing"
  failures=$((failures + 1))
elif ! printf '%s\n' "$vocabulary" | grep -qx other; then
  echo "FAIL vocabulary: no \"other\" fallback label in CMD_JQ"
  failures=$((failures + 1))
else
  emitted=$(project execution-log-denials.json | jq -r '[.commands[], .denied_commands[]] | .[].cmd' | sort -u)
  unknown=$(comm -23 <(printf '%s\n' "$emitted" | sort -u) <(printf '%s\n' "$vocabulary" | sort -u))
  if [ -z "$unknown" ]; then
    echo "ok   every emitted label comes from the CMD_JQ vocabulary"
  else
    echo "FAIL emitted labels outside the CMD_JQ vocabulary: $unknown"
    failures=$((failures + 1))
  fi
fi

# Names are the other half of the boundary, and the half that reads as safe because tool
# names look like a fixed set. They are not: `name` is whatever the assistant message
# emitted, so a hallucinated tool whose name repeats a path it just read would be copied
# into the artifact verbatim. toolname bounds them to the shape a real registry entry has.
named=$(printf '%s' '[{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read /home/runner/work/_temp/git-credentials-82efe7dc.config","input":{}}]}}]' \
  | jq -c "$CMD_JQ $TOOL_USAGE_JQ")
if printf '%s' "$named" | grep -qF "git-credentials-82efe7dc.config"; then
  echo "FAIL a tool name carrying a path reached the artifact: $named"
  failures=$((failures + 1))
elif printf '%s' "$named" | jq -e '.tool_calls == [{"name":"unknown","n":1}]' >/dev/null; then
  echo "ok   out-of-shape tool name reduces to \"unknown\""
else
  echo "FAIL out-of-shape tool name did not reduce to \"unknown\": $named"
  failures=$((failures + 1))
fi

# Same for a denial's tool_name, which comes from the same untrusted field.
denied_named=$(printf '%s' '[{"type":"result","permission_denials":[{"tool_name":"Bash eC1hY2Nlc3MtdG9rZW46Z2hzX0ZBS0VUT0tFTg==","tool_input":{}}]}]' \
  | jq -c "$CMD_JQ $TOOL_USAGE_JQ")
if printf '%s' "$denied_named" | grep -qF "eC1hY2Nlc3MtdG9rZW46"; then
  echo "FAIL a denial tool_name carrying a token reached the artifact: $denied_named"
  failures=$((failures + 1))
else
  echo "ok   out-of-shape denial tool_name does not reach the artifact"
fi

# An unrecognised command must fall back to "other" and carry none of itself across. A bare
# curl with a bearer token is the worst case: the whole command is the secret.
leaky='[{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"curl -H \"Authorization: Bearer ghs_FAKETOKENFORTESTS\" https://api.github.com"}}]}}]'
leaked=$(printf '%s' "$leaky" | jq -c "$CMD_JQ $TOOL_USAGE_JQ")
if printf '%s' "$leaked" | grep -qF "ghs_FAKETOKENFORTESTS" \
  || printf '%s' "$leaked" | grep -qF "curl"; then
  echo "FAIL unrecognised command leaked into the projection: $leaked"
  failures=$((failures + 1))
elif printf '%s' "$leaked" | jq -e '.commands == [{"cmd":"other","compound":false,"has_subst":false,"n":1}]' >/dev/null; then
  echo "ok   unrecognised command reduces to \"other\""
else
  echo "FAIL unrecognised command did not reduce to \"other\": $leaked"
  failures=$((failures + 1))
fi

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
expect_absent execution-log-denials.json \
  "ANTHROPIC_API_KEY" \
  "search patterns inside a Bash command do not reach the artifact"
expect_absent execution-log-denials.json \
  "pr21.diff" \
  "file names inside a Bash command do not reach the artifact"

# A clean run: no denials, and the MCP inline-comment tool counted like any other.
expect_jq execution-log-clean.json '.denials' '[]' "clean run reports no denials"
expect_jq execution-log-clean.json '[.tool_calls[].name] | sort' \
  '["Bash","mcp__github_inline_comment__create_inline_comment"]' \
  "mcp tool names counted"

# A cancelled or crashed run leaves a log with no result message. The step is
# continue-on-error, but the filter should still produce a usable artifact rather than
# abort, so the tool calls made before the run died are not lost.
expect_jq execution-log-truncated.json '.denials' '[]' "log with no result message yields no denials"
expect_jq execution-log-truncated.json '.denied_commands' '[]' \
  "log with no result message yields no denied commands"
expect_jq execution-log-truncated.json '.tool_calls' '[{"name":"Read","n":1}]' \
  "tool calls survive a log with no result message"
expect_jq execution-log-truncated.json '.result.num_turns' 'null' \
  "missing result message yields null fields, not an error"

# Degenerate input must not crash the filter.
empty=$(printf '[]' | jq -c "$CMD_JQ $TOOL_USAGE_JQ")
if [ "$empty" = '{"tool_calls":[],"commands":[],"denials":[],"denied_commands":[],"result":{"subtype":null,"is_error":null,"num_turns":null,"duration_ms":null,"total_cost_usd":null}}' ]; then
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
