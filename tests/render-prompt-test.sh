#!/usr/bin/env bash
#
# Guards the mechanical cycle gating in scripts/render-prompt.sh, and asserts the shipped
# prompt actually renders the way each cycle needs it to. These run against the real
# docs/claude-pr-review-prompt.md, not a fixture, so editing the prompt into a state where
# a late cycle can emit nits again fails the suite.
#
# Regression this exists for: the prompt used to carry a "Review Cycle Awareness" ladder
# ("Cycle 5+: blocking issues only. Do not leave any nits.") and the model ignored it. Over
# the cycle 6+ reviews sampled, output was 31 comments, 0 blocking, 100% nits. The gating is
# mechanical now -- the nit taxonomy is not in the cycle 3+ prompt at all -- so these tests
# check for the absence of text rather than trusting a rule to be obeyed.

set -euo pipefail

cd "$(dirname "$0")/.."

RENDER=scripts/render-prompt.sh
PROMPT=docs/claude-pr-review-prompt.md

failures=0

pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

render() { bash "$RENDER" "$1" < "$PROMPT"; }

# has <cycle> <pattern> <description>
has() {
  if render "$1" | grep -qF -- "$2"; then pass "cycle $1 keeps: $3"; else fail "cycle $1 is missing: $3"; fi
}

# lacks <cycle> <pattern> <description>
lacks() {
  if render "$1" | grep -qF -- "$2"; then fail "cycle $1 still contains: $3"; else pass "cycle $1 drops: $3"; fi
}

echo "-- marker mechanics --"

# Each comparison operator, on both sides of its boundary.
fixture=$(mktemp)
trap 'rm -f "$fixture"' EXIT
cat > "$fixture" <<'EOF'
always
<!-- cycle==1 -->
only-one
<!-- /cycle -->
<!-- cycle<=2 -->
upto-two
<!-- /cycle -->
<!-- cycle>=3 -->
three-plus
<!-- /cycle -->
tail
EOF

# expect_render <cycle> <space separated expected lines>
expect_render() {
  local cycle=$1 want=$2 got
  got=$(bash "$RENDER" "$cycle" < "$fixture" | tr '\n' ' ' | sed 's/  */ /g;s/ $//')
  if [ "$got" = "$want" ]; then
    pass "cycle $cycle renders '$want'"
  else
    fail "cycle $cycle: expected '$want', got '$got'"
  fi
}

expect_render 1 "always only-one upto-two tail"
expect_render 2 "always upto-two tail"
expect_render 3 "always three-plus tail"
expect_render 9 "always three-plus tail"

# Markers themselves must never reach the model.
if bash "$RENDER" 1 < "$fixture" | grep -q '<!-- '; then
  fail "marker comments leak into the rendered output"
else
  pass "marker comments are stripped from the output"
fi

echo "-- input validation --"

# expect_reject <args...> -- the script must exit 2, not silently mis-render
expect_reject() {
  local desc=$1; shift
  if bash "$RENDER" "$@" < "$fixture" >/dev/null 2>&1; then
    fail "accepted invalid input: $desc"
  else
    pass "rejects $desc"
  fi
}
expect_reject "a non-numeric cycle" abc
expect_reject "cycle 0" 0
expect_reject "a negative cycle" -1
expect_reject "no arguments"

# Malformed markers are a hard error so the caller can fall back to the full prompt rather
# than ship a half-stripped one.
for bad in '<!-- cycle>=2 -->\nx\n<!-- cycle>=3 -->\ny\n<!-- /cycle -->' \
           '<!-- cycle>=2 -->\nx' \
           'x\n<!-- /cycle -->'; do
  if printf '%b\n' "$bad" | bash "$RENDER" 2 >/dev/null 2>&1; then
    fail "accepted malformed markers: $bad"
  else
    pass "rejects malformed markers: $bad"
  fi
done

# A marker that is ALMOST right is the dangerous case, not an obviously broken one. An
# unrecognised marker keeps its whole block and exits 0, so before this was an error a stray
# indent or CRLF silently shipped the full nit-bearing prompt at cycle 6 -- indistinguishable
# from the behaviour this script exists to remove. Each of these must exit non-zero.
#
# near_miss <description> <printf format producing the file>
near_miss() {
  local desc=$1 body=$2 out
  # The assignment lives in the `if` condition on purpose: under `set -e` a bare
  # `out=$(failing command)` aborts this script instead of running the assertion.
  if out=$(printf '%b' "$body" | bash "$RENDER" 1 2>&1); then
    fail "silently ignored a near-miss marker ($desc); its block would leak at every cycle"
  elif printf '%s' "$out" | grep -q 'malformed cycle marker'; then
    pass "rejects near-miss marker: $desc"
  else
    fail "rejected $desc but without a malformed-marker message"
  fi
}
near_miss "CRLF line endings"        'keep\r\n<!-- cycle>=3 -->\r\nLATE\r\n<!-- /cycle -->\r\n'
near_miss "trailing space on marker" 'keep\n<!-- cycle>=3 --> \nLATE\n<!-- /cycle -->\n'
near_miss "indented marker"          'keep\n  <!-- cycle>=3 -->\nLATE\n  <!-- /cycle -->\n'
near_miss "indented closing marker"  'keep\n<!-- cycle>=3 -->\nLATE\n  <!-- /cycle -->\n'
near_miss "missing space in marker"  'keep\n<!--cycle>=3-->\nLATE\n<!-- /cycle -->\n'
near_miss "unknown operator"         'keep\n<!-- cycle!=3 -->\nLATE\n<!-- /cycle -->\n'
near_miss "non-numeric bound"        'keep\n<!-- cycle>=x -->\nLATE\n<!-- /cycle -->\n'

# The real prompt must contain only strict markers, or CI is asserting against a file that
# silently stopped being gated.
if bash "$RENDER" 1 < "$PROMPT" >/dev/null 2>&1; then
  pass "the shipped prompt has no malformed markers"
else
  fail "the shipped prompt contains a malformed marker"
fi

echo "-- shipped prompt, cycle 1 (full review) --"
has 1 "### Documentation" "the Documentation criterion"
has 1 "### Code Quality" "the Code Quality criterion"
has 1 "## Severity Classification" "the nit taxonomy"
has 1 'gh pr diff' "the full-diff instruction"
lacks 1 "## Handling Prior Feedback" "prior-feedback handling (nothing to handle yet)"
lacks 1 "incremental_diff" "the incremental diff reference"

echo "-- shipped prompt, cycle 2 (focused review) --"
# Documentation drops at cycle 2+: doc/comment drift was 42% of late-cycle comments, and most
# of it is churn the review loop created by asking the author to change the code underneath.
lacks 2 "### Documentation" "the Documentation criterion"
has 2 "## Severity Classification" "the nit taxonomy (nits are still useful at cycle 2)"
has 2 "## Handling Prior Feedback" "prior-feedback handling"
has 2 "incremental_diff" "the incremental diff reference"
has 2 "Do not charge the author for churn you caused" "the churn guard"

echo "-- shipped prompt, cycle 3+ (blocking only) --"
for c in 3 6 12; do
  lacks "$c" "## Severity Classification" "the nit taxonomy"
  lacks "$c" "super nit" "the super nit vocabulary"
  lacks "$c" "### Documentation" "the Documentation criterion"
  lacks "$c" "### Code Quality" "the Code Quality criterion"
  has "$c" "Report **blocking issues only**" "the blocking-only instruction"
  has "$c" "incremental_diff" "the incremental diff reference"
done

# The single most important assertion in this file: at a late cycle there must be no
# instruction anywhere that tells the model how to format a non-blocking comment. If a
# future edit reintroduces one, the 100%-nits behaviour comes back.
if render 5 | grep -qE 'nit:|\(not blocking\)'; then
  fail "cycle 5 prompt still explains how to write a nit"
else
  pass "cycle 5 prompt has no nit format to follow"
fi

# Exactly one Decision Framework must survive at every cycle -- two would leave the model
# choosing between contradictory approve/request-changes rules.
for c in 1 2 3 7; do
  n=$(render "$c" | grep -c '^## Decision Framework$' || true)
  if [ "$n" -eq 1 ]; then
    pass "cycle $c has exactly one Decision Framework"
  else
    fail "cycle $c has $n Decision Framework sections, expected 1"
  fi
done

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
