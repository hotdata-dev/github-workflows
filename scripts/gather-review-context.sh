#!/usr/bin/env bash
#
# Gathers the pull request context that the Claude review prompt reads. The "Gather review
# context" step of .github/workflows/claude-pr-review.yml runs this file, which it checks out of
# hotdata-dev/github-workflows alongside the prompt document.
#
# It is a file rather than a `run:` block because Actions parses a `run:` block as one template
# expression and refuses any over 21,000 characters. This script is 20 KB. Inline it left roughly
# 450 characters of headroom -- about six comment lines -- and the change that crossed the line
# stopped every review in the org with "Invalid workflow file". The same parse is what makes an
# empty expression delimiter anywhere in an inline block, a shell comment included, an outage;
# that was the one before it. Neither hazard exists out here. Actions never parses this file,
# bash does, and bash has no opinion about what is in a comment.
#
# The step passes PR_NUMBER, REPO, GH_TOKEN, HEAD_SHA, BASE_REF, PR_TITLE and PR_BODY in through
# `env:`. Nothing is interpolated into this script, so no pull-request-controlled text can arrive
# here as code.
#
# -e and pipefail, which is what the step's `shell: bash` used to supply: this is mostly
# `gh ... | jq` pipelines, and gh writes its error body to stdout, so without pipefail a failed
# fetch feeds its own error text to jq and the block renders whatever jq makes of it instead of
# the guarded fallback sentence. Not -u -- the script was written without one and does not
# assume it.
set -eo pipefail

# `?` and not `:?` for PR_NUMBER, so unset is an error but empty is not. tests.yml calls the
# workflow on `push: branches: [main]` too, where there is no pull request and the number is
# legitimately empty; the reads below then degrade into their guarded "could not read" sentences,
# which is what the inline version did and what keeps the main-push smoke run exercising the
# script rather than stopping on its first line. REPO comes from github.repository and is never
# legitimately empty, so it keeps `:?`.
: "${PR_NUMBER?the calling step must set PR_NUMBER}"
: "${REPO:?the calling step must set REPO}"

# How many bytes a file occupies once JSON-escaped. Defined here, above the budget
# block, because the budget is denominated in escaped bytes -- see PROMPT_ARG_LIMIT
# below for why that is the unit and not raw bytes.
#
# `jq -Rs .` reads the whole file as one JSON string and emits it quoted, which is the
# transformation toJson() applies to the prompt input. Measured against the run that
# failed, jq came within 0.5% and on the high side, which is the side to be wrong on.
#
# head -c cuts on a byte boundary and so can split a UTF-8 character. jq does not fail
# on that; it substitutes U+FFFD, three bytes where the fragment was one or two, so a
# mid-character cut can only over-report. The fallback is for a jq that is missing or
# refuses outright: two bytes per input byte is what a file of nothing but quotes and
# newlines costs, and over-estimating only trims more.
escaped_bytes() {
  local n=''
  n=$(jq -Rs . < "$1" 2>/dev/null | wc -c | tr -d ' ') || n=''
  case "$n" in
    '' | *[!0-9]*) n=$(( $(wc -c < "$1" | tr -d ' ') * 2 )) ;;
  esac
  printf '%s' "$n"
}

# Caps. The median PR reviewed across the org is 161 changed lines and the largest
# in a week was 3,448, so 3,000 patch lines covers the corpus; the cap exists so
# one generated-file PR cannot blow up the prompt.
DIFF_MAX=3000
SINCE_MAX=2000
LOG_WINDOW=120
# The two diff blocks share one line budget rather than holding independent caps.
# They overlap by construction: the since-last-review diff is a subset of the full
# diff, exactly equal to it on a single-file PR, and DIFF_MAX + SINCE_MAX let the pair
# reach 5,000 lines of largely the same patch. The dashboard PR named below carried 42
# KB of "since your last review" stacked on 66 KB of "full diff" -- the same file,
# twice -- and the pair is what put the prompt over the limit.
#
# The budget below bounds what that costs, but bounding it is not the same as not
# spending it: every line the duplicate takes is a line of the budget the rest of the
# context does not get. So the pair is capped together and the full diff is the block
# that yields, because on cycle 2+ what changed since the last round is the reviewer's
# subject and the full patch is one allowlisted `gh pr diff` away. Cycle 1 has no
# since-diff, so the full diff keeps very nearly the whole budget.
#
# What "yields" means for the full diff is all of it, not a prefix of it: see the
# omission branch below. So this number is a threshold rather than a share -- a full diff
# that does not fit under it is replaced by a notice, and the 1,000 lines the since-diff
# leaves it are not rendered as a partial patch. No floor is written under it for that
# reason: there is nothing for a floor to protect.
DIFF_BUDGET_LINES=3000
# Byte budgets. Both of this step's outputs are interpolated into the SAME `prompt:`
# string in the review step, and that string reaches the reviewer as one environment
# variable -- so the binding limit is the kernel's MAX_ARG_STRLEN, 32 * PAGE_SIZE =
# 131072 on the runners, not the step-output limit. Past it, exec fails with
# "Argument list too long" before the reviewer starts. That failure is near-silent:
# the action reports success, the tool-usage steps skip for want of an execution log,
# no review of any kind is posted, and only the generic notify message says anything.
# A pull request rendering 186 KB of prompt failed exactly that way while threads and
# context each sat inside their own former caps -- 100 KB and 200 KB, a pair that
# could sum to 300 KB against a 131 KB limit. Hence a budget on the SUM.
#
# The earlier note here reasoned about the runner's UTF-16 accounting of step outputs.
# That limit is real and separate; it is not the one that fails first.
PROMPT_ARG_LIMIT=131072
# Every budget below counts *escaped* bytes, because the environment variable that
# fails first does not hold the prompt as written. claude-code-action's action.yml
# sets `ALL_INPUTS: toJson(inputs)` on the step it runs, so the prompt is carried
# twice: once raw as PROMPT, and once JSON-escaped inside ALL_INPUTS. The escaped copy
# is always the larger of the two, so it is always the one that reaches the limit
# first, and bounding the raw string leaves the real one unbounded.
#
# A Grafana dashboard PR is the proof: 123,401 raw bytes -- inside the limit -- and
# 135,366 escaped, and it failed on two consecutive pushes. A budget denominated in
# raw bytes does not see it at all.
#
# The expansion is not a constant that could be folded in as a factor. Prose costs
# about 1.02x and a quote-and-newline dense JSON diff about 1.20x, so the same 3,000
# lines land either side of the limit depending only on what the file holds. Hence
# every measurement below runs through escaped_bytes.
#
# What toJson(inputs) serializes beside the prompt: 38 further inputs, measured at
# 1,356 bytes on the run that failed. They are inside the same variable and spend the
# same limit. Rounded up.
ALL_INPUTS_OTHER_BYTES=2000
# What the workflow wraps around the two outputs: 494 bytes of literal header and the
# two data-tag blocks with their do-not-follow notices, plus the interpolated REPO,
# PR number and cycle. Rounded up.
PROMPT_WRAPPER_BYTES=600
# The static prompt is appended to that same string and spends the same budget, so it
# is measured rather than hard-coded: editing the prompt document must shrink what is
# left for context, not silently overflow the limit. Measured escaped, like the rest.
PROMPT_DOC="$(dirname "$0")/../docs/claude-pr-review-prompt.md"
if [ -r "$PROMPT_DOC" ]; then
  PROMPT_DOC_BYTES=$(escaped_bytes "$PROMPT_DOC")
else
  # A moved path or a narrowed sparse-checkout pattern. Assume large rather than
  # assume nothing: an over-generous figure truncates context, a missing one puts the
  # exec failure back.
  PROMPT_DOC_BYTES=20000
  echo "::warning::Could not measure ${PROMPT_DOC}; assuming ${PROMPT_DOC_BYTES} bytes when sizing the prompt budget."
fi
# 1 KB of slack. Deliberately small: every byte held back here is context the reviewer
# does not get, and the terms above are measured rather than estimated. A pull request
# that assembles under the limit today is not newly truncated -- only the ones that
# already fail outright change behaviour.
PROMPT_BUDGET=$((PROMPT_ARG_LIMIT - ALL_INPUTS_OTHER_BYTES - PROMPT_WRAPPER_BYTES \
  - PROMPT_DOC_BYTES - 1024))
# threads keeps a cap of its own so a comment dump cannot eat the budget the diff
# needs: 400 inline comments rendered 1.1 MB on their own. It is also held to half the
# budget, so a long review history can never starve the diff completely.
THREADS_MAX_BYTES=100000
if [ "$THREADS_MAX_BYTES" -gt $((PROMPT_BUDGET / 2)) ]; then
  THREADS_MAX_BYTES=$((PROMPT_BUDGET / 2))
fi
# One job log can be mostly a single line: LOG_WINDOW counts lines and a CI log
# line has no length limit, so a base64 or JSON dump next to the first error marker
# would otherwise consume the whole context ahead of the diff.
#
# One allowance for all of them, because a per-excerpt cap does not bound the set.
# FAILING_JOBS_JQ takes three jobs and each writes two excerpts -- a summary and a
# window -- so the old 40000 apiece was a 240 KB ceiling on log text, twice
# PROMPT_BUDGET, and all of it ordered above `## Full diff`. The byte cap cuts from the
# tail, so the diff is the block that paid: three verbose failing jobs took it out of
# the context entirely. 40000 was sized against the old 200 KB context cap, so the
# allowance is scaled off PROMPT_BUDGET like THREADS_MAX_BYTES instead. It is not also
# kept as a per-excerpt cap: a quarter of the context is around 15 KB, so 40000 could
# never be the binding number and stating it would only imply a second bound that does
# not exist.
#
# Derived below, beside CTX_MAX_BYTES, rather than here: like the conversation, the
# changed-file list and the since-diff, this share is of the context these excerpts are
# written into and not of the whole prompt budget. A quarter of PROMPT_BUDGET is *half* the
# context once threads is at its own cap, and it is charged raw rather than escaped --
# cap_log_excerpt bills through wc -c -- so at the 1.20x this file measures for
# quote-dense text those bytes arrive larger than they were counted. Three verbose failing
# jobs beside a long review history is the run where that lands on the tail cut, and what
# the tail cut takes is the conversation and then the full diff's omission instructions.
# The truncation notices, as constants rather than literals at their call sites. The
# prompt document quotes them and tells the reviewer that seeing one means the block is
# incomplete and the rest has to be fetched before drawing conclusions from it -- so a
# notice whose wording moves without the document moving with it is a notice the
# reviewer no longer recognises, and a partial review comes back looking like a whole
# one. Two of these had already drifted that way. tests/context-step-test.sh reads them
# out of here and fails if the document stops quoting one.
NOTICE_CONTEXT='context truncated to fit the review prompt'
NOTICE_THREADS='prior review comments truncated'
NOTICE_LOG='log excerpt truncated'
NOTICE_LINES='truncated: first'
NOTICE_CONVO='PR conversation truncated'
NOTICE_FILES='changed file list truncated'
NOTICE_COMMITS='commit list truncated'
NOTICE_SINCE='since-diff cut to fit the review prompt'
# Not a truncation notice: this block is absent, not short. It is listed with the others
# because the contract is the same -- the prompt document has to quote it, or the reviewer
# reads a diff heading with no patch under it and no idea that a patch exists.
NOTICE_OMITTED='full diff omitted: too large for the review prompt'
CTX="${RUNNER_TEMP}/pr-context.md"
: > "$CTX"

# gh refuses a raw-text body containing ANSI colour unless told to allow escape
# sequences, and a diff or a job log earns an escape byte from any file holding
# terminal output -- this repository's own job-log fixtures do. That refusal and
# its --allow-escape-sequences opt-out arrived together in gh 2.97.0 as a security
# fix; ubuntu-latest ships 2.96.0, where the flag is an unknown-flag error and the
# refusal does not exist either. So every raw fetch tries the flag and falls back
# to the bare call: on 2.96 the first attempt fails and the second succeeds, on
# 2.97+ the first succeeds. Pinning either form breaks on the other, and the
# runner image updates weekly.
# head -c against a *file*, never a pipe: `sed ... | head -c` closes the pipe early
# and SIGPIPE takes the producer down under pipefail, which is the shape that has
# already cost this step its error window once.
cap_file() {
  if [ "$(wc -c < "$1" | tr -d " ")" -gt "$2" ]; then
    head -c "$2" "$1" > "$1.cut"
    mv "$1.cut" "$1"
    echo "($3)" >> "$1"
  fi
}

# cap_log_excerpt <file> <notice> [max] -- cap one log excerpt against what is left of
# the shared allowance, then charge what it emitted against that allowance. Charging the
# size *after* the cap counts the notice line too, so the excerpts cannot overspend by
# announcing themselves. [max] is an optional ceiling for callers that must not take the
# whole of what is left; without it an excerpt may.
#
# A later job can be cut to nothing this way, which is the intended order: the first
# failing job is the one whose cause is usually being read, and an excerpt reduced to
# its truncation notice still tells the reviewer the log exists and was not empty.
cap_log_excerpt() {
  local limit=${3:-$LOG_REMAINING}
  if [ "$LOG_REMAINING" -lt "$limit" ]; then limit=$LOG_REMAINING; fi
  if [ "$limit" -lt 1 ]; then
    # Not cap_file with a zero limit: `head -c 0` is an error on BSD head rather than an
    # empty file, and this script runs under `set -e`, so that would abort the step and
    # cost the review the whole context -- which is the failure this file exists to avoid,
    # arrived at from the other direction.
    if [ -s "$1" ]; then
      : > "$1"
      echo "($2)" >> "$1"
    fi
  else
    # Escaped, like every other cap in this file. Billing raw `wc -c` against a share of a
    # budget denominated in escaped bytes under-charged by whatever the content's expansion
    # is -- about 1.20x for the quote-dense text a CI log is full of -- so an allowance of
    # a quarter of the context arrived as nearer a third of it, and the blocks written after
    # these excerpts paid the difference.
    cap_file_escaped "$1" "$limit" "$2"
  fi
  LOG_REMAINING=$((LOG_REMAINING - $(escaped_bytes "$1")))
  if [ "$LOG_REMAINING" -lt 0 ]; then LOG_REMAINING=0; fi
}

# cap_file_escaped <file> <budget> <notice> -- trim <file> until it fits <budget> once
# escaped. The raw cut point is found by measuring, scaling and re-measuring rather
# than by assuming a ratio, because the ratio is a property of the content: the same
# 3,000 lines cost 1.02x as prose and 1.20x as JSON. Escaped size is monotonic in raw
# length, so scaling by how far over budget the file is converges downward. Two or
# three passes is typical on real input; the loop bound is a backstop, not the
# mechanism.
cap_file_escaped() {
  local file=$1 budget=$2 notice=$3 esc raw target i=0
  # The notice is appended after the cut, so its bytes come out of the budget first. A
  # cap that put the file back over the limit by announcing itself would be the same
  # bug in miniature.
  budget=$((budget - 300))
  if [ "$budget" -lt 1 ]; then budget=1; fi
  esc=$(escaped_bytes "$file")
  if [ "$esc" -le "$budget" ]; then return 0; fi
  while [ "$i" -lt 8 ]; do
    raw=$(wc -c < "$file" | tr -d ' ')
    # The 0.98 is deliberate undershoot: the ratio is measured over the whole file but
    # applied to a prefix, and a prefix denser than the average would otherwise land
    # just over and spend another pass.
    target=$(awk -v r="$raw" -v e="$esc" -v b="$budget" \
      'BEGIN { t = int(r * b / e * 0.98); print (t < 1) ? 1 : t }')
    head -c "$target" "$file" > "$file.cut"
    mv "$file.cut" "$file"
    esc=$(escaped_bytes "$file")
    if [ "$esc" -le "$budget" ]; then break; fi
    i=$((i + 1))
  done
  # Drop the partial line the byte cut left behind. A context ending in `"range": tru`
  # puts a mangled fragment of a patch line where the reviewer reads patch lines, and
  # it is the last thing before the notice. Guarded on there being an earlier boundary
  # to fall back to: a block that is one enormous line -- a base64 CI log dump is how
  # that happens -- has none, and losing all of it would cost more than ending
  # mid-line. Removing a line only shrinks the file, so the budget still holds.
  if [ "$(awk 'END {print NR}' "$file")" -gt 1 ]; then
    if sed '$d' "$file" > "$file.cut"; then mv "$file.cut" "$file"; fi
  fi
  echo "($notice)" >> "$file"
}

fetch_raw() {
  RAW_OUT=$1
  shift
  gh "$@" --allow-escape-sequences > "$RAW_OUT" 2>/dev/null && return 0
  gh "$@" > "$RAW_OUT" 2>/dev/null
}

# Count distinct commits already reviewed, never review state: the org ruleset
# sets dismiss_stale_reviews_on_push, so a push flips a prior APPROVED to
# DISMISSED and a state filter stops matching it. Inline comments each create
# their own COMMENTED review sharing the round's commit_id, so unique commit_id
# == round count, +/-1 when a push lands mid-round and splits it across two SHAs.
# Coupled to the reviewer's login: if that ever changes the count silently drops
# to 0 and every round looks like the first, hence the warning below.
CYCLE_JQ='[.[][] | select(.user.login == "claude[bot]") | .commit_id] | unique | length'
# The login of the second automated reviewer running beside this one, and the one value
# three programs below have to agree on. A comparison trial has Pullfrog reviewing the same
# pull requests, and both reviewers fire on `opened`, so its output reaches this reviewer
# through two reads that filter by nothing: `/pulls/{n}/comments` becomes
# <prior_review_comments> and `/issues/{n}/comments` becomes the PR conversation. Left in,
# it costs the trial its independence -- whichever reviewer posts first sets what the other
# reads as settled prior feedback -- and it costs the diff blocks the bytes, since comment
# threads may take half the escaped-byte budget and a cut context measured 0.92 findings a
# run against 1.91 uncut. So the exclusion is not tidiness; it is what keeps the two arms
# of the comparison, and the reviewer's own budget, intact.
#
# Handed to jq with --arg at each site rather than written into each program, because a
# second copy of a constant is a copy free to drift from the first. tests/lib.sh reads this
# assignment for the same reason it extracts the jq programs.
#
# It comes out when the trial ends. Nothing else in the org posts reviews.
OTHER_REVIEW_BOT='pullfrog[bot]'
# Only consulted when CYCLE is 0; see the warning below. Kept in its own variable
# so tests/review-cycle-test.sh can assert it against the fixtures.
#
# $skip is excluded from the predicate, not merely from the count: the trial makes a bot
# review on a genuine cycle 1 the ordinary case, so without it every first review in a
# trial repo would report a reviewer-identity drift that has not happened -- and an alarm
# that fires on every PR is an alarm nobody reads on the PR where it is real.
DRIFT_JQ='any(.[][]; .user.type == "Bot" and .user.login != $skip)'
# Never fail the review over the cycle number; degrade to 1, but say so. gh
# writes its error body to stdout, so an unguarded pipe into jq aborts the step
# under `bash -e` and skips the failure-notification step below.
# CTX_WARNINGS collects the degradations the *model* has to know about, as opposed
# to the ones only an operator cares about. The distinction is whether the fallback
# is blank or is an assertion: "Could not read the diff." is visibly missing data,
# but "REVIEW CYCLE: 1" and "No prior review comments." are claims, and a failed
# read makes them false ones.
WARN_FILE="${RUNNER_TEMP}/ctx-warnings.md"
: > "$WARN_FILE"
if ! REVIEWS=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" --paginate); then
  echo "::warning::Could not read prior reviews; treating this as review cycle 1."
  {
    echo "- The prior reviews could not be read, so the REVIEW CYCLE number in this"
    echo "  prompt may be wrong: it defaults to 1. If this is not really your first"
    echo "  review, treat the cycle ladder as unknown, and do not take the cycle"
    echo "  number as evidence that nothing was raised before."
  } >> "$WARN_FILE"
  REVIEWS=''
fi
CYCLE=$(printf '%s' "$REVIEWS" | jq -s "$CYCLE_JQ" 2>/dev/null) || CYCLE=''
if [ -z "$CYCLE" ]; then
  echo "::warning::Could not parse prior reviews; treating this as review cycle 1."
  CYCLE=0
elif [ "$CYCLE" -eq 0 ] && printf '%s' "$REVIEWS" \
  | jq --arg skip "$OTHER_REVIEW_BOT" -e -s "$DRIFT_JQ" >/dev/null 2>&1; then
  # claude[bot] was the only bot submitting reviews across the org when this was
  # written (598 of 598 sampled), and $OTHER_REVIEW_BOT is the stated exception,
  # so any *other* bot review that the login filter did not count means the
  # reviewer's identity moved and the counter has silently pinned at 1.
  echo "::warning::Bot reviews exist but none matched the reviewer login; the review cycle counter is stale."
fi
echo "review_cycle=$((CYCLE + 1))" >> $GITHUB_OUTPUT

# Same guard as the counter above: unguarded `gh api | jq` aborts the step, and a
# failure here *skips* the review step, so the notify step's failure check never
# fires and the PR gets no review and no explanation.
COMMENTS_OK=1
if ! COMMENTS=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments" --paginate); then
  COMMENTS_OK=0
  echo "::warning::Could not read prior review comments; reviewing without them."
  {
    echo "- The prior inline review comments could not be read. That block is empty"
    echo "  because the fetch failed, not because there were none. Do not conclude"
    echo "  that no feedback was given; read the threads with gh pr view before"
    echo "  re-raising anything."
  } >> "$WARN_FILE"
  COMMENTS=''
fi
# "No prior review comments." is only true when the fetch worked and returned
# none. Saying it after a failed fetch is the same false claim as an empty CI block
# reading as a green one, and it is the claim the cycle ladder acts on.
#
# $skip's comments are dropped here -- see OTHER_REVIEW_BOT above for why. The drop is
# announced only when it empties the block, and that asymmetry is the point: with other
# comments still present the block claims nothing about being every comment on the PR, but
# "No prior review comments." on a PR that has some is the same false claim as an empty CI
# block reading as a green one. So the empty case names what was withheld and how much.
#
# Single-line and single-quoted so tests/lib.sh can extract it; it was inline, and inline
# meant the one program in this script that shapes the prompt's other output could not be
# asserted against a fixture at all.
THREADS_JQ='(add // []) as $all | ($all | map(select(.user.login != $skip))) as $kept | ($kept | map(.id)) as $ids | (($all | length) - ($kept | length)) as $dropped | if ($kept | length) == 0 then (if $dropped > 0 then "No prior review comments. (\($dropped) comment(s) from \($skip) are excluded from this block.)" else "No prior review comments." end) else ($kept | sort_by(.created_at) | .[] | "---", "Author: \(.user.login)", "File: \(.path)", (if .line then "Line: \(.line)" else empty end), (if .in_reply_to_id then (if (.in_reply_to_id | IN($ids[])) then "Reply to #\(.in_reply_to_id)" else "Reply to a comment excluded from this block" end) else "Thread #\(.id)" end), "", ((.body // "")[0:3000])) end'
if [ "$COMMENTS_OK" -eq 0 ]; then
  THREADS='Unavailable: the prior inline review comments could not be read. This block is empty because the fetch failed, not because there were none.'
else
  THREADS=$(printf '%s' "$COMMENTS" | jq --arg skip "$OTHER_REVIEW_BOT" -s -r "$THREADS_JQ") \
    || THREADS='Unavailable: the prior inline review comments could not be parsed.'
fi

# The prompt wraps both blocks below in <prior_review_comments> and <pr_context>
# and tells the reviewer to treat their contents as data. A PR body, a diff hunk,
# or a CI log containing the closing tag ends the block early, and everything the
# author wrote after it lands *outside* the marked region, where it reads as
# prompt. The tags are fixed strings, so neutralising them is complete: there is
# no other spelling the model parses as the same delimiter.
# perl, not sed: this has to be case-insensitive and whitespace-tolerant, and BSD
# sed has no case-insensitive substitute flag, so a sed version would either be a
# GNU-only `I` flag or twenty spelled-out character classes. perl ships on every
# runner image. `</pr_context >`, `</PR_CONTEXT>` and `< / pr_context foo="1">` all
# read as the same delimiter to a model, so matching the shape is the only version
# of this that is not walked around by whitespace.
strip_block_tags() {
  perl -pe 's{< \s* /? \s* (?: pr_context | prior_review_comments ) [^>]* >}{[block tag removed]}gix'
}

# strip_block_tags runs BEFORE the cap, not on the way out. The substitution can grow
# the text -- a 12-byte `<pr_context>` becomes a 19-byte `[block tag removed]` -- so
# capping first and stripping afterwards would bound something other than what is
# emitted, and an author who writes that tag a few hundred times gets the assembled
# prompt back over MAX_ARG_STRLEN. Stripping first also means a cut cannot leave a live
# tag behind: there are none left for it to bisect.
THREADS_FILE="${RUNNER_TEMP}/threads.md"
printf '%s\n' "$THREADS" | strip_block_tags > "$THREADS_FILE"
cap_file_escaped "$THREADS_FILE" "$THREADS_MAX_BYTES" \
  "${NOTICE_THREADS}; read the rest with gh pr view"

# The bound that keeps the assembled prompt inside MAX_ARG_STRLEN. Context gets what the
# threads block did not spend; threads is capped and written by this point, so its final
# size is known rather than assumed.
#
# Derived here rather than at the cap site at the end of the file, because the full diff
# block needs it: it decides whether to render a patch or a notice, and it cannot make that
# call without knowing what the whole context is allowed to weigh. The cap at the end still
# applies it -- this only moves the arithmetic above its first reader.
THREADS_BYTES=$(escaped_bytes "$THREADS_FILE")
CTX_MAX_BYTES=$((PROMPT_BUDGET - THREADS_BYTES))
# Unreachable while THREADS_MAX_BYTES is clamped to half the budget. Kept because the
# alternative if that clamp is ever loosened is `head -c` with a negative count, and an
# empty context degrades a review where a failing cap_file loses it entirely.
if [ "$CTX_MAX_BYTES" -lt 0 ]; then
  CTX_MAX_BYTES=0
fi

# The PR conversation is the last block written, which without a cap of its own makes it
# both the block that overflows the budget and the block the tail cut removes to pay for
# the overflow -- 300 comments rendered 700 KB, and on www.hotdata.dev#332 the heading did
# not render at all. An eighth of the context, the smallest share, because it is the block
# the reviewer can most afford to lose: the inline threads carry the review history and
# this carries the rest of the discussion.
#
# Denominated in CTX_MAX_BYTES rather than PROMPT_BUDGET, which is why it is derived here
# and not beside the other caps: an eighth of the larger total is a quarter of the context
# once threads is at its own cap, and a share that grows when the review history grows is
# not a share. Every per-block share of the context reads the same way -- the log allowance
# below, the changed-file list, and the since-diff. Only threads is a share of
# PROMPT_BUDGET, because it is the block CTX_MAX_BYTES is derived by subtracting.
#
# Bounding it is also what makes the full diff's fit decision answerable. That decision
# asks "is there room for the whole patch", and the question has no answer while an
# unbounded block is still to come.
CONVO_MAX_BYTES=$((CTX_MAX_BYTES / 8))
# The log allowance, for the reasons given where LOG_WINDOW is set. Same denominator, same
# argument: these excerpts are written into the context, so the context is what they are a
# share of.
LOG_BUDGET=$((CTX_MAX_BYTES / 8))
LOG_REMAINING=$LOG_BUDGET
# What the summary may take of it. The excerpts are written summary first, window
# second, but the window is the block worth more: across five real failed job logs the
# cause sat immediately above the first ##[error] in four, and the summary is what
# covers the fifth. Sharing an allowance first-come-first-served would invert that --
# `tail -n 20` bounds the summary in lines, not bytes, so twenty stack-trace or JSON
# lines take everything and the window for the same job renders as its own truncation
# notice. Held to a quarter so the window keeps the larger share of whatever is left.
LOG_SUMMARY_MAX=$((LOG_BUDGET / 4))

DELIMITER="REVIEW_CONTEXT_$(openssl rand -hex 16)"
{
  echo "threads<<${DELIMITER}"
  cat "$THREADS_FILE"
  echo "${DELIMITER}"
} >> $GITHUB_OUTPUT

# Title and body reach the shell through env, never an Actions expression
# interpolation: both are attacker-controlled text and would otherwise be spliced
# into this script. (The header explains why no interpolation can reach this file at
# all now; tests/context-step-test.sh still rejects the delimiter anywhere in it.)
#
# First in the file on purpose: the byte cap keeps the head, so anything the
# reviewer must not miss has to be above the blocks that can grow.
if [ -s "$WARN_FILE" ]; then
  {
    echo "## Context warnings"
    cat "$WARN_FILE"
    echo
  } >> "$CTX"
fi

{
  echo "## Pull request"
  echo "Title: ${PR_TITLE}"
  echo "Base branch: ${BASE_REF}"
  echo "Head SHA: ${HEAD_SHA}"
  echo
  echo "### Description"
  if [ -n "${PR_BODY}" ]; then printf '%s\n' "${PR_BODY}"; else echo "(no description)"; fi
} >> "$CTX"

# Each block: read, project, and fall back to a sentence saying what is missing.
# A missing block must read as missing, never as "there are no commits".
COMMITS_JQ='[.[][]] | if length == 0 then "No commits reported." else map("\(.sha[0:8]) \(.commit.message | split("\n")[0])") | join("\n") end'
if COMMITS_JSON=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/commits" --paginate); then
  COMMITS=$(printf '%s' "$COMMITS_JSON" | jq -s -r "$COMMITS_JQ" 2>/dev/null) \
    || COMMITS="Could not parse commits."
else
  echo "::warning::Could not read commits."
  COMMITS="Could not read commits."
fi
# Capped for the same reason as the changed-file list below, and it was the last fetched
# block without one. The endpoint tops out at 250 commits, so the ordinary ceiling is around
# 15 KB -- already a quarter of the context on a maxed-threads run -- but the rendered line
# is a SHA and a git subject, and a git subject has no length bound, so the real ceiling is
# whatever the author wrote. It sits above `## Full diff`, so an overflow here is paid for by
# the omission notice and the conversation.
COMMITS_FILE="${RUNNER_TEMP}/commits.md"
printf '%s\n' "$COMMITS" | strip_block_tags > "$COMMITS_FILE"
cap_file_escaped "$COMMITS_FILE" $((CTX_MAX_BYTES / 8)) \
  "${NOTICE_COMMITS}; read the rest with gh pr view --json commits"
{ echo; echo "## Commits"; cat "$COMMITS_FILE"; } >> "$CTX"

# status carries added/modified/removed/renamed, which the raw patch does not spell
# out for renames, and the per-file counts let the reviewer budget its reading.
# Every field defaulted: a payload missing .additions would otherwise render
# "+null", and the reviewer quotes these numbers back in review comments.
FILES_JQ='[.[][]] | if length == 0 then "No changed files reported." else "\(length) files, +\([.[].additions // 0] | add) -\([.[].deletions // 0] | add)", (.[] | "\(.status // "unknown") +\(.additions // 0)/-\(.deletions // 0) \(.filename // "(unnamed file)")") end'
if FILES_JSON=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/files" --paginate); then
  FILES=$(printf '%s' "$FILES_JSON" | jq -s -r "$FILES_JQ" 2>/dev/null) \
    || FILES="Could not parse changed files."
else
  echo "::warning::Could not read changed files."
  FILES="Could not read changed files."
fi
# Capped, because `--paginate` returns up to GitHub's 3,000-file ceiling and a line per
# file is around 60 bytes -- 180 KB, over the whole budget, from a block with no cap of its
# own. It matters more than its size suggests: this is the block the full diff's omission
# notice sends the reviewer to, so it is the last one that should be able to overflow. An
# eighth of the context, the same share as the conversation.
FILES_FILE="${RUNNER_TEMP}/changed-files.md"
printf '%s\n' "$FILES" | strip_block_tags > "$FILES_FILE"
cap_file_escaped "$FILES_FILE" $((CTX_MAX_BYTES / 8)) \
  "${NOTICE_FILES}; read the rest with gh pr view --json files"
{ echo; echo "## Changed files"; cat "$FILES_FILE"; } >> "$CTX"

# The reviewer cannot run tests -- no dependencies are installed and the allowlist
# would refuse anyway -- but CI already ran them. Whether they passed is the one
# fact it was asserting without evidence.
#
# This block is the third channel $skip reaches, and the one where it does the most damage.
# Pullfrog posts its verdict as a check -- `pullfrog-approval`, failing when it requested
# changes -- and the prompt tells this reviewer that a failing check is a blocking issue to
# name and cite. So an unfiltered rollup does not merely leak the other arm's conclusion; it
# converts it into a request-changes this reviewer cannot substantiate from the diff.
# `pullfrog` (the run-status check) rides along for the same reason, and its detailsUrl would
# otherwise feed FAILING_JOBS_JQ below the *other reviewer's own job log* as a failing-job
# excerpt, at up to an eighth of the context.
#
# Matched by name against the app slug rather than by a second constant: a GitHub App's bot
# login is its slug plus "[bot]", and its checks are the slug and slug-prefixed names, so
# $skip still carries the one value all five programs agree on. Both rollup shapes are
# matched -- a CheckRun by .name, a StatusContext by .context -- because which of the two an
# app posts is the app's choice, not ours.
#
# Silent while other checks remain, and stated when the exclusion empties the block: a list
# claims nothing about being every check, but "No checks reported." on a PR that has some is
# a false claim, and this is the block whose emptiness the README warns gets read as green.
# One definition of "belongs to the other reviewer", composed into both programs below rather
# than written into each: they are two programs, and a second copy of the rule is a copy free to
# disagree with the first about what it matches -- which it already did, the failing-job scan
# testing only .name while the list tested .context as well. Composed the way the workflow
# composes CMD_JQ into TOOL_USAGE_JQ.
#
# It reads both names on the entry, not one. For a check the app posts itself, .name is the check
# ("pullfrog", "pullfrog-approval") and there is no workflow behind it; for one that reached the
# rollup from an Actions run, .name is the *job* name and .workflowName is the workflow's `name:`.
# So a name-only test makes this exclusion depend on a job key in another repository staying
# `pullfrog`: `name: Pullfrog` over a job called `review` arrives as
# {name: "review", workflowName: "Pullfrog"} and slips through both programs whole. Dropping a
# check belonging to a workflow named for the other reviewer is the intent in either shape.
# Compared downcased for the same reason -- the slug is lowercase by construction, and a job name
# is whatever someone typed.
CHECK_OWNER_JQ='def slug: $skip | sub("\\[bot\\]$"; "") | ascii_downcase; def theirs: [(if .__typename == "CheckRun" then (.name // "") else (.context // "") end), (.workflowName // "")] | any(. != "" and (ascii_downcase | . == slug or startswith(slug + "-")));'
CHECKS_JQ='def render: if .__typename == "CheckRun" then "\(.conclusion // .status // "UNKNOWN") \(.workflowName // "") / \(.name // "(unnamed check)")" else "\(.state // "UNKNOWN") \(.context // "status")" end; (.statusCheckRollup // []) as $all | ($all | map(select(theirs | not))) as $kept | (($all | length) - ($kept | length)) as $dropped | if ($kept | length) == 0 then (if $dropped > 0 then "No checks reported. (\($dropped) check(s) from \(slug) are excluded from this block; they carry a verdict from another reviewer, not a CI result.)" else "No checks reported." end) else ($kept | map(render) | sort | join("\n")) end'
# Actions check runs carry the job id in detailsUrl; scan rather than capture so a
# non-Actions check with no job id drops out instead of erroring.
FAILING_JOBS_JQ='[(.statusCheckRollup // [])[] | select(.__typename == "CheckRun") | select(theirs | not) | select((.conclusion // "") | test("FAILURE|TIMED_OUT|ACTION_REQUIRED")) | (.detailsUrl // "") | [scan("/job/([0-9]+)")] | flatten | .[0] // empty] | unique | .[0:3] | join(" ")'
if ROLLUP=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json statusCheckRollup); then
  CHECKS=$(printf '%s' "$ROLLUP" | jq --arg skip "$OTHER_REVIEW_BOT" -r "$CHECK_OWNER_JQ $CHECKS_JQ" 2>/dev/null) \
    || CHECKS="Could not parse checks."
  JOB_IDS=$(printf '%s' "$ROLLUP" | jq --arg skip "$OTHER_REVIEW_BOT" -r "$CHECK_OWNER_JQ $FAILING_JOBS_JQ" 2>/dev/null) || JOB_IDS=''
else
  echo "::warning::Could not read check status."
  CHECKS="Could not read check status."
  JOB_IDS=''
fi
{
  echo
  echo "## CI checks as of $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "This workflow runs on the same push as the rest of CI, so checks are often"
  echo "still queued or in progress here. A check that is not reported as passing"
  echo "has not passed yet -- it has not necessarily failed."
  echo
  printf '%s\n' "$CHECKS"
} >> "$CTX"
# Two windows, not a tail. Across five real failed job logs the informative text
# sat immediately above the first ##[error] in four of them (a rustfmt diff, an
# npm parity error, a docker push failure, a build error body). In the fifth --
# a Django suite whose later steps kept running -- "FAILED (failures=1)" was 670
# lines above ##[error] and a tail returned docker cleanup, so the summary lines
# get collected separately from wherever they landed.
LOG_SUMMARY_RE='FAILED \(|FAIL: |ERROR: |test result: FAILED|panicked at|Tests:.*failed|Ran [0-9]+ tests?'
for JOB_ID in $JOB_IDS; do
  JOB_LOG="${RUNNER_TEMP}/job-${JOB_ID}.log"
  { echo; echo "### Failing job ${JOB_ID}"; } >> "$CTX"
  if ! fetch_raw "$JOB_LOG" api "repos/${REPO}/actions/jobs/${JOB_ID}/logs"; then
    echo "(log unavailable)" >> "$CTX"
    continue
  fi
  SUMMARY=$(grep -E "$LOG_SUMMARY_RE" "$JOB_LOG" | tail -n 20) || SUMMARY=''
  if [ -n "$SUMMARY" ]; then
    EXCERPT="${RUNNER_TEMP}/job-${JOB_ID}-summary.txt"
    printf '%s\n' "$SUMMARY" > "$EXCERPT"
    cap_log_excerpt "$EXCERPT" "${NOTICE_LOG}: summary lines" "$LOG_SUMMARY_MAX"
    { echo "Summary lines:"; cat "$EXCERPT"; echo; } >> "$CTX"
  fi
  # The *first* error marker: later steps in the same job add their own, and the
  # failing step's is the one with the cause above it.
  #
  # -m1 rather than `| head -1`: with pipefail, head closing the pipe after one
  # line sends grep SIGPIPE, grep exits 141, and the guard below swallows it as
  # "no error marker" -- so the window silently becomes a 120-line tail. Whether
  # it fires depends on how much grep has buffered, so it misses the small logs
  # and hits the ones with a marker per diagnostic (tsc, clippy, eslint), which
  # are exactly the logs where the first-error window is worth the most. -m1 stops
  # grep at the first match and drops the pipe stage that made the race possible.
  ERR_LINE=$(grep -n -m1 '##\[error\]' "$JOB_LOG" | cut -d: -f1) || ERR_LINE=''
  if [ -n "$ERR_LINE" ]; then
    START=$((ERR_LINE - LOG_WINDOW + 1))
    if [ "$START" -lt 1 ]; then START=1; fi
    EXCERPT="${RUNNER_TEMP}/job-${JOB_ID}-window.txt"
    sed -n "${START},${ERR_LINE}p" "$JOB_LOG" > "$EXCERPT"
    cap_log_excerpt "$EXCERPT" "${NOTICE_LOG}; read the rest in the job log"
    {
      echo "Log lines ${START}-${ERR_LINE}, ending at the first error:"
      cat "$EXCERPT"
    } >> "$CTX"
  else
    EXCERPT="${RUNNER_TEMP}/job-${JOB_ID}-tail.txt"
    tail -n "$LOG_WINDOW" "$JOB_LOG" > "$EXCERPT"
    cap_log_excerpt "$EXCERPT" "${NOTICE_LOG}; read the rest in the job log"
    { echo "Last ${LOG_WINDOW} log lines:"; cat "$EXCERPT"; } >> "$CTX"
  fi
done

# The diff since the reviewer's own last round. REVIEWS is already in hand for the
# cycle counter, and the last commit_id it submitted against is exactly the base
# for "what changed since I looked". Ordered by submitted_at, not array order,
# because inline comments and the round's verdict are separate review objects.
LAST_REVIEW_JQ='[.[][] | select(.user.login == "claude[bot]") | select(.submitted_at != null) | {commit_id, submitted_at}] | sort_by(.submitted_at) | last | (.commit_id // "")'
LAST_SHA=$(printf '%s' "$REVIEWS" | jq -s -r "$LAST_REVIEW_JQ" 2>/dev/null) || LAST_SHA=''
# Lines this block spends, which the full diff below subtracts from the shared budget.
# It stays 0 on every path that renders no patch -- cycle 1, a rebase, a failed fetch
# -- so the full diff gets the whole budget exactly as it did before there was a
# since-diff to share with.
SINCE_USED=0
if [ -n "$LAST_SHA" ] && [ "$LAST_SHA" != "null" ] && [ "$LAST_SHA" != "$HEAD_SHA" ]; then
  SINCE_FILE="${RUNNER_TEMP}/since-last-review.diff"
  # The compare API, not git: the checkout is fetch-depth 1, so no base branch and
  # no prior commit exists locally to diff against.
  #
  # Ask for the JSON first and only use the diff when the comparison is a clean
  # fast-forward. compare/A...B is three-dot, so it diffs from the *merge base* of
  # the two, which equals "since A" only while the branch has done nothing but gain
  # commits. After a rebase or a squash-and-force-push the old SHA usually stays
  # reachable, so this call succeeds and returns the whole PR plus anything the
  # rebase pulled in from upstream -- under a heading that says the opposite. A
  # reviewer trusting that heading re-raises issues the author already settled, and
  # SINCE_MAX can drop the part that genuinely is new. status is "ahead" only for
  # the fast-forward case; "diverged" and "behind" fall through to the message.
  COMPARE_STATUS_JQ='.status // "unknown"'
  SINCE_STATUS=$(gh api "repos/${REPO}/compare/${LAST_SHA}...${HEAD_SHA}" 2>/dev/null \
    | jq -r "$COMPARE_STATUS_JQ" 2>/dev/null) || SINCE_STATUS='unknown'
  if [ "$SINCE_STATUS" = "ahead" ] \
    && fetch_raw "$SINCE_FILE" api "repos/${REPO}/compare/${LAST_SHA}...${HEAD_SHA}" \
    -H "Accept: application/vnd.github.diff"; then
    # awk, not `wc -l`: wc pads its count with spaces on BSD and the number
    # is interpolated into the notice below, not just compared.
    SINCE_LINES=$(awk 'END {print NR}' "$SINCE_FILE")
    # Line-capped and then byte-capped, because a line cap does not bound bytes: at the
    # 1.20x this file measures for quote-dense JSON, 2,000 lines of dashboard patch is
    # about 120 KB escaped, which is over CTX_MAX_BYTES on its own. This block is written
    # *above* the full diff, so without the byte cap it is the block that drives the tail
    # cut on a cycle-2+ generated-file PR -- and what the tail cut then removes is the
    # full diff's omission notice and the conversation, not the since-diff that spent the
    # budget.
    #
    # Half of CTX_MAX_BYTES, not of PROMPT_BUDGET. Those are the same number only when
    # there is no review history: threads has already taken its own half out of
    # PROMPT_BUDGET by this point, so on a cycle-5+ PR with a long comment history a share
    # denominated in the larger total is the whole of what remains, and this one block can
    # fill the context allowance by itself -- the very failure the byte cap is here to
    # stop, one level up. The context is what this block writes into, so the context is
    # what its share is measured against.
    #
    # cap_file_escaped rather than a smaller SINCE_MAX: the prefix is still what this
    # block wants, for the reason the full diff below no longer keeps one -- `gh api
    # .../compare` is not allowlisted, so a notice in place of this patch leaves the
    # reviewer nothing it can fetch instead.
    SINCE_CAPPED="${RUNNER_TEMP}/since-capped.diff"
    head -n "$SINCE_MAX" "$SINCE_FILE" > "$SINCE_CAPPED"
    if [ "$SINCE_LINES" -gt "$SINCE_MAX" ]; then
      echo "(${NOTICE_LINES} ${SINCE_MAX} of ${SINCE_LINES} lines)" >> "$SINCE_CAPPED"
    fi
    # Its own notice, rather than a second copy of the line-cap wording, because the two
    # caps fire independently and the byte cap fires at a *lower* line count than
    # SINCE_MAX on exactly the dense content it exists for. Reusing the line wording there
    # printed "truncated: first 2000 of 1500 lines" -- a claim about a cut that did not
    # happen, naming a figure the reviewer was not given. These notices are a contract
    # with the prompt document; one of them stating a falsehood is worse than none.
    cap_file_escaped "$SINCE_CAPPED" $((CTX_MAX_BYTES / 3)) \
      "${NOTICE_SINCE}; read the whole patch with gh pr diff"
    # Recounted after both caps, because this is what the full diff is charged for. Fixing
    # it at min(SINCE_LINES, SINCE_MAX) before the byte cap charged the full diff for lines
    # this block did not end up spending: a dense since-diff cut to 400 rendered lines still
    # reserved 2,000, leaving FULL_DIFF_MAX at 1,000 and omitting a 1,500-line full diff
    # that the byte allowance had ample room for. The same over-reserve the conversation
    # had, in the other currency, and with no notice to explain where the budget went.
    SINCE_USED=$(awk 'END {print NR}' "$SINCE_CAPPED")
    {
      echo
      echo "## Diff since your last review (${LAST_SHA} to ${HEAD_SHA})"
      cat "$SINCE_CAPPED"
    } >> "$CTX"
  else
    {
      echo
      echo "## Diff since your last review"
      echo "Unavailable: ${LAST_SHA} does not fast-forward to ${HEAD_SHA}"
      echo "(comparison status: ${SINCE_STATUS})."
      echo "The branch was rebased or force-pushed, so there is no meaningful"
      echo "\"since last review\" diff. Review the full diff below instead, and"
      echo "read the prior review comments to see what was already raised."
    } >> "$CTX"
  fi
fi

# Whatever the since-diff left of the shared budget, bounded above by DIFF_MAX so a PR
# with no since-diff renders exactly what it always did. SINCE_MAX keeps the
# subtraction from reaching zero; see DIFF_BUDGET_LINES above.
FULL_DIFF_MAX=$((DIFF_BUDGET_LINES - SINCE_USED))
if [ "$FULL_DIFF_MAX" -gt "$DIFF_MAX" ]; then FULL_DIFF_MAX=$DIFF_MAX; fi

# Issue comments, not the pull comments above: the PR conversation is a separate
# endpoint from the inline review threads, and only the threads were ever passed.
#
# Fetched and capped here, above the full diff, and written below it -- see the write site
# for why the two are separated. Capped in its own file rather than appended straight to
# $CTX, so the cap is on this block and not on the whole context: appending first and
# capping after is the tail cut, which is what put this block's heading off the end of the
# prompt on www.hotdata.dev#332. Stripped before the cap for the reason strip_block_tags
# always runs first -- the substitution grows the text, so a cap on the unstripped file
# bounds a smaller string than the one emitted.
#
# $skip is excluded here as well, and for the same reason: the review body Pullfrog posts
# is a PR summary plus its findings, and this endpoint is where it lands. The empty case
# names the withholding on the same principle as the threads block above.
ISSUE_COMMENTS_JQ='[.[][]] as $all | ($all | map(select(.user.login != $skip))) as $kept | (($all | length) - ($kept | length)) as $dropped | if ($kept | length) == 0 then (if $dropped > 0 then "No PR conversation comments. (\($dropped) comment(s) from \($skip) are excluded from this block.)" else "No PR conversation comments." end) else ($kept | sort_by(.created_at) | map("--- \(.user.login) at \(.created_at)\n\((.body // "")[0:3000])") | join("\n")) end'
if CONVO_JSON=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" --paginate); then
  CONVO=$(printf '%s' "$CONVO_JSON" | jq --arg skip "$OTHER_REVIEW_BOT" -s -r "$ISSUE_COMMENTS_JQ" 2>/dev/null) \
    || CONVO="Could not parse PR conversation comments."
else
  echo "::warning::Could not read PR conversation comments."
  CONVO="Could not read PR conversation comments."
fi
CONVO_FILE="${RUNNER_TEMP}/pr-conversation.md"
printf '%s\n' "$CONVO" | strip_block_tags > "$CONVO_FILE"
cap_file_escaped "$CONVO_FILE" "$CONVO_MAX_BYTES" \
  "${NOTICE_CONVO}; read the rest with gh pr view"
# What the block will really cost, heading included, rather than what it was allowed to.
CONVO_BYTES=$(($(escaped_bytes "$CONVO_FILE") + 100))

DIFF_FILE="${RUNNER_TEMP}/pr.diff"
if fetch_raw "$DIFF_FILE" pr diff "$PR_NUMBER" --repo "$REPO"; then
  DIFF_LINES=$(awk 'END {print NR}' "$DIFF_FILE")
  # What is left of the byte budget for this block: the whole allowance, less what the
  # blocks above already spent, less the conversation still to be written. Measured on the
  # stripped text on both sides, because strip_block_tags grows `<pr_context>` from 12
  # bytes to 19 and it is the emitted string that has to fit -- the same reason the cap at
  # the end of this file strips before it measures.
  strip_block_tags < "$CTX" > "${RUNNER_TEMP}/fit-ctx"
  strip_block_tags < "$DIFF_FILE" > "${RUNNER_TEMP}/fit-diff"
  DIFF_ALLOWANCE=$((CTX_MAX_BYTES - $(escaped_bytes "${RUNNER_TEMP}/fit-ctx") - CONVO_BYTES))
  DIFF_ESCAPED=$(escaped_bytes "${RUNNER_TEMP}/fit-diff")
  # Set in the omission branch below and read after the group command. `{ ... } >> file` is
  # a group, not a subshell, so the assignment survives -- which is the point: spelling the
  # condition a second time thirty lines down leaves the two free to drift, and the drift is
  # silent in exactly the direction that matters. The block would render the omission text
  # while the annotation said nothing, or the reverse, which is the invisible failure this
  # annotation exists to end.
  DIFF_OMITTED=0
  {
    echo
    echo "## Full diff"
    # A heading with nothing under it is a claim, and the wrong one: a fetch that
    # succeeded with no body is not the same fact as a PR with no changes, and the
    # prompt has just told the reviewer not to re-fetch what it was given.
    if [ "$DIFF_LINES" -eq 0 ]; then
      echo "The diff came back empty. That is unusual for a pull request; treat it"
      echo "as missing rather than as \"nothing changed\" and run gh pr diff."
    elif [ "$DIFF_LINES" -le "$FULL_DIFF_MAX" ] && [ "$DIFF_ESCAPED" -le "$DIFF_ALLOWANCE" ]; then
      cat "$DIFF_FILE"
    else
      # All or nothing, and this is the nothing. A prefix of a patch is worse than no
      # patch: it reads as the whole thing. What survives a cut is whichever files sort
      # first rather than whichever matter, and the notice saying so used to be one line
      # at the end of a context the reviewer had already read past. Across two weeks of
      # production runs, 108 had their context cut and only 23% re-fetched anything; the
      # ones that did found 1.91 issues per run against 0.92 for the ones that did not,
      # and 40% of the cut runs on PRs over 1,000 lines posted no finding at all.
      #
      # Omitting is only affordable because this is the one diff block the reviewer can
      # replace by itself: `gh pr diff` is allowlisted and was refused 0 times in 54
      # attempts over those two weeks. The since-diff above keeps its prefix precisely
      # because it has no such escape -- `gh api .../compare` is not allowlisted, so
      # trading its prefix for a notice would trade partial information for none.
      DIFF_OMITTED=1
      echo "(${NOTICE_OMITTED}; ${DIFF_LINES} lines)"
      echo
      echo "The patch is NOT below. Nothing has been shown to you and nothing has been"
      echo "summarised. Do not review, approve or draw any conclusion about this pull"
      echo "request from the blocks above alone."
      echo
      echo "Get it before you review:"
      echo "  - gh pr diff ${PR_NUMBER} --repo ${REPO} for the whole patch."
      echo "  - If that is too large to read at once, work from the '## Changed files'"
      echo "    list above -- it names every path with its own +/- counts -- and Read"
      echo "    those files from the checkout."
      echo "  - Say in your review that the diff was omitted and which files you read."
    fi
  } >> "$CTX"
  if [ "$DIFF_OMITTED" -eq 1 ]; then
    # A notice, not a warning, for the same reason the byte cap below uses one: a
    # generated-file PR reaches this legitimately and a warning that cried regression on
    # every one of them would stop being read. It exists so an operator reading a thin
    # review can see the reviewer was never handed the patch -- the failure mode this
    # block replaced was invisible, because a line-capped diff said so only in a
    # parenthetical and never in an annotation.
    echo "::notice::Full diff omitted from the review prompt: ${DIFF_LINES} lines, ${DIFF_ESCAPED} escaped bytes against a ${DIFF_ALLOWANCE} byte allowance and a ${FULL_DIFF_MAX} line cap."
  fi
else
  echo "::warning::Could not read the diff."
  { echo; echo "## Full diff"; echo "Could not read the diff; run gh pr diff."; } >> "$CTX"
fi

# Written last, prepared above the full diff. The ordering argument for writing it last is
# unchanged -- it is the block the reviewer can most afford to lose. But the diff's fit
# decision has to subtract what this block will actually weigh, and a reserve of
# CONVO_MAX_BYTES is not that: the common case is "No PR conversation comments.", 29 bytes,
# and reserving an eighth of the budget against it hands back around 1,200 patch lines that
# nothing will spend. That over-reserve was cheap while the shortfall cost the diff a
# prefix; now it costs the whole block, so it would convert directly into omissions on pull
# requests whose diff would have fit. Fetching here and measuring the capped file makes the
# reserve exact. This endpoint does not depend on the diff, so nothing else moves.
{ echo; echo "## PR conversation"; cat "$CONVO_FILE"; } >> "$CTX"

# CTX_MAX_BYTES is derived above, beside the threads cap it is computed from, because the
# full diff block reads it. The per-block caps still matter -- they decide *what* survives,
# and they keep any one block from arriving here having already crowded out the diff -- but
# what follows is what makes the total fit.
#
# Stripped before the cap, for the same reason as the threads block above: the
# substitution grows `<pr_context>` from 12 bytes to 19, so a cap applied to the
# unstripped file bounds a smaller string than the one actually emitted. This is the
# block where it matters most -- the diff, the PR body and the log excerpt are all
# author-controlled, and this is the file they land in.
strip_block_tags < "$CTX" > "$CTX.stripped"
mv "$CTX.stripped" "$CTX"
CTX_ESCAPED=$(escaped_bytes "$CTX")
if [ "$CTX_ESCAPED" -gt "$CTX_MAX_BYTES" ]; then
  # A notice rather than a warning. No line cap bounds bytes: 3,000 lines of prose is
  # about 60 KB escaped and 3,000 lines of dashboard JSON about 200 KB, so a
  # generated-file PR reaches this legitimately and often, and a warning that cried
  # regression every time would stop being read. It is here so an operator reading a
  # thin review can see the context was cut and by how much -- and so a budget that
  # starts firing on ordinary prose PRs, which would mean something really did
  # regress, is visible rather than silent.
  echo "::notice::Review context reached ${CTX_ESCAPED} escaped bytes against a ${CTX_MAX_BYTES} byte budget and was truncated to fit the review prompt."
fi
cap_file_escaped "$CTX" "$CTX_MAX_BYTES" \
  "${NOTICE_CONTEXT}; read what is missing with gh pr diff and gh pr view"

CTX_DELIMITER="PR_CONTEXT_$(openssl rand -hex 16)"
{
  echo "pr_context<<${CTX_DELIMITER}"
  cat "$CTX"
  echo "${CTX_DELIMITER}"
} >> $GITHUB_OUTPUT
