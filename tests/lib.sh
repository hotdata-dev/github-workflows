#!/usr/bin/env bash
#
# Shared by the test scripts in this directory. Every jq program in the workflow is
# extracted from the workflow rather than copied into a test, so the tests exercise the
# shipped expression. That only works while each program stays a single-line, single-quoted
# assignment -- extract_jq fails loudly rather than silently testing half a program.

WORKFLOW=.github/workflows/claude-pr-review.yml

# extract_jq <shell variable name> -- pull a single-quoted jq program out of the workflow
extract_jq() {
  local name=$1 prog
  prog=$(sed -n "s/^ *$name='\(.*\)'\$/\1/p" "$WORKFLOW")
  if [ -z "$prog" ]; then
    echo "FAIL: no $name='...' assignment found in $WORKFLOW" >&2
    exit 1
  fi
  if [ "$(printf '%s\n' "$prog" | wc -l)" -ne 1 ]; then
    echo "FAIL: more than one $name assignment in $WORKFLOW:" >&2
    printf '%s\n' "$prog" >&2
    exit 1
  fi
  printf '%s' "$prog"
}
