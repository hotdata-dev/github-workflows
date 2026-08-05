#!/usr/bin/env bash
#
# Shared by the test scripts in this directory. Every jq program is extracted from the file that
# ships it rather than copied into a test, so the tests exercise the shipped expression. That
# only works while each program stays a single-line, single-quoted assignment -- extract_jq fails
# loudly rather than silently testing half a program.
#
# Two sources, because the shipped shell lives in two places now. The context script moved out of
# the workflow when its `run:` block came within a few comment lines of the 21,000-character
# Actions expression limit; the remaining blocks are small and still inline. extract_jq searches
# both and rejects a name defined in each, so a program moving between them needs no change here
# and a duplicate cannot go unnoticed.

WORKFLOW=.github/workflows/claude-pr-review.yml
CONTEXT_SCRIPT=scripts/gather-review-context.sh
JQ_SOURCES=("$WORKFLOW" "$CONTEXT_SCRIPT")

# extract_jq <shell variable name> -- pull a single-quoted jq program out of the shipped shell
extract_jq() {
  local name=$1 prog found=() src
  for src in "${JQ_SOURCES[@]}"; do
    if [ -n "$(sed -n "s/^ *$name='\(.*\)'\$/\1/p" "$src")" ]; then
      found+=("$src")
    fi
  done
  if [ "${#found[@]}" -eq 0 ]; then
    echo "FAIL: no $name='...' assignment found in ${JQ_SOURCES[*]}" >&2
    exit 1
  fi
  if [ "${#found[@]}" -gt 1 ]; then
    echo "FAIL: $name is assigned in more than one of ${found[*]}" >&2
    exit 1
  fi
  prog=$(sed -n "s/^ *$name='\(.*\)'\$/\1/p" "${found[0]}")
  if [ "$(printf '%s\n' "$prog" | wc -l)" -ne 1 ]; then
    echo "FAIL: more than one $name assignment in ${found[0]}:" >&2
    printf '%s\n' "$prog" >&2
    exit 1
  fi
  printf '%s' "$prog"
}
