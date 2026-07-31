#!/usr/bin/env bash
#
# Renders the review prompt for one specific review cycle, on stdout, from the prompt on
# stdin. Blocks wrapped in cycle markers are kept or dropped here, before the prompt ever
# reaches the model:
#
#   <!-- cycle==1 -->  ... <!-- /cycle -->   kept only on cycle 1
#   <!-- cycle<=2 -->  ... <!-- /cycle -->   kept on cycles 1-2
#   <!-- cycle>=3 -->  ... <!-- /cycle -->   kept on cycle 3 and later
#
# Why this is a script and not three sentences in the prompt: the prompt used to carry a
# "Review Cycle Awareness" ladder telling the model to taper nits as cycles climbed, and
# measurement showed it was ignored outright. Across cycle 6+ reviews the ladder's rule was
# "blocking issues only, do not leave any nits" and the actual output was 31 comments, 0 of
# them blocking, 100% nits. Advisory self-restraint loses to a 50-line criteria checklist
# that invites finding things. A block that is never sent cannot be ignored.
#
# Markers must sit alone on their own line and must not nest. Malformed markers are a hard
# error (exit 2) rather than a silent mis-render; the caller falls back to the full prompt.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: render-prompt.sh <review-cycle> < prompt.md" >&2
  exit 2
fi

case $1 in
  '' | *[!0-9]*)
    echo "render-prompt.sh: review cycle must be a positive integer, got '$1'" >&2
    exit 2
    ;;
esac

if [ "$1" -lt 1 ]; then
  echo "render-prompt.sh: review cycle must be >= 1, got '$1'" >&2
  exit 2
fi

# `cat -s` collapses the run of blank lines a dropped block leaves behind. pipefail keeps
# awk's exit status, so a malformed marker still fails the pipeline.
awk -v C="$1" '
BEGIN { depth = 0; keep = 1; err = "" }

/^<!-- cycle(<=|>=|==)[0-9]+ -->$/ {
  if (depth) { err = "nested cycle block at line " NR; exit 2 }
  spec = $0
  sub(/^<!-- cycle/, "", spec)
  sub(/ -->$/, "", spec)
  op = substr(spec, 1, 2)
  n = substr(spec, 3) + 0
  depth = 1
  if (op == "<=")      keep = (C <= n)
  else if (op == ">=") keep = (C >= n)
  else                 keep = (C == n)
  next
}

/^<!-- \/cycle -->$/ {
  if (!depth) { err = "unmatched <!-- /cycle --> at line " NR; exit 2 }
  depth = 0
  keep = 1
  next
}

{ if (!depth || keep) print }

END {
  if (err != "") { printf "render-prompt.sh: %s\n", err > "/dev/stderr"; exit 2 }
  if (depth)     { printf "render-prompt.sh: unclosed cycle block\n" > "/dev/stderr"; exit 2 }
}
' | cat -s
