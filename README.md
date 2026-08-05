# github-workflows

Central repository for organization-wide GitHub Actions workflows enforced across all `hotdata-dev` repos via org rulesets.

## Workflows

### Claude PR Review

Automated code review on every pull request using [claude-code-action](https://github.com/anthropics/claude-code-action). Reviews are severity-based:

- **P0/P1 issues** — requests changes with inline comments
- **P2/P3 issues** — approves with non-blocking suggestions
- **No issues** — silent approve

The review prompt lives in [`docs/claude-pr-review-prompt.md`](docs/claude-pr-review-prompt.md).

### Frontloaded review context

The workflow gathers the PR into the prompt before the reviewer starts: title and description,
commits, changed files with per-file line counts, CI check status with log excerpts from failing
jobs, the diff since the reviewer's own last review, the full diff, and the PR conversation.

This is not a convenience. The reviewer's allowlist is four `gh pr` commands plus `rg`, `Read`,
`Grep`, and `Glob`, and the checkout is `fetch-depth: 1` — so the reviewer cannot reach git history,
cannot run tests, and cannot pipe or redirect even the commands it is allowed. Before this, it spent
19.5 Bash calls and 5.2 permission denials per run trying anyway; 86% of runs hit at least one
denial, and one review approved a PR with the words "reviewed statically (test suite not run in this
environment)" while CI had already run those tests. Runs with no denials averaged 14 turns and 98
seconds against 37 turns and 270 seconds for runs with five or more.

Each block degrades to a sentence saying what is missing rather than to silence, because a reviewer
handed an empty CI block will state that CI is clean. Two reads get a stronger treatment: a failed
`/reviews` or `/pulls/{n}/comments` would otherwise render as `REVIEW CYCLE: 1` and "no prior review
comments", which are claims rather than gaps, so those failures are disclosed to the reviewer in a
`## Context warnings` block at the top of the context. The step is `continue-on-error`: a failure
there once skipped the review step and the notify step with it, leaving the PR with no review and no
explanation.

Both step outputs are byte-bounded (100 KB of comment threads, 200 KB of context), with per-block
caps beneath that — 3,000 diff lines, 40 KB per CI log excerpt, 40 KB of PR description, 3,000
characters per comment. The description's cap is the newest and is measured on sanitised bytes: the
blocks are appended in order, so an uncapped block ahead of the diff does not merely inflate the
output, it spends the budget the diff was going to use. The
caps are deliberately far below any plausible runner limit: 400 inline comments rendered 1.1 MB of
threads before they existed, and the runner accounts for output size in UTF-16, so a byte count here
is not the number it checks against. Blocks are ordered so that truncation sacrifices the PR
conversation before the diff or the CI status.

Everything reaching the prompt is attacker-controlled — title, body, diff, CI logs, comments — so the
block delimiters are neutralised by shape rather than by exact string: `</pr_context >`,
`</PR_CONTEXT>` and `< / pr_context foo="1">` all read as the same delimiter to a model, and any of
them would otherwise end the data block early and land the rest where it reads as instructions.

The same text gets a second treatment for a different sink. The action echoes the assembled prompt
into the job log line by line, and GitHub reads a workflow command in that log as a *command* — so a
marker in a PR body, a diff hunk, a CI excerpt, or a review comment writes an annotation onto the
review's own check run. One run carried two `failure` annotations whose text was prose from a review
comment discussing `##[error]`.

The two spellings are not parsed alike, and one review settled which is which: its diff carried both
forms on `+` prefixed lines, the `+` was consumed on `##[error]` and survived on `::error::`, and all
seven annotations were the former. So `::command::` is matched only at the start of a trimmed line,
while `##[...]` is matched anywhere in one — a leading `+`, a timestamp, or a markdown backtick
defuses nothing. That makes the CI excerpt the most reliable source of these rather than an exempt
one, since it fetches the window around `##[error]` from an already-timestamped log.

So `##[` is broken by a single space wherever it appears — those lines are usually source or log text
and restructuring them would misrepresent the file being reviewed — while a line-leading `::` gets a
visible `[log marker neutralised]` prefix, because there the whole line was the command. A mid-line
`::` is left alone, which keeps every `std::collections::HashMap` in a Rust diff intact.

Both substitutions run *before* the byte caps, not after. They are the only thing here that makes text
longer — a bare `::` line is 3 bytes in and 28 out — so capping first would leave the budgets bounding
nothing: 100 KB of `::`-only comment lines would leave as ~930 KB. Truncating afterwards is safe in
the direction that matters, since `head -c` only drops the tail and cannot re-expose a marker the
prefix was covering.

### Tool usage artifact

Each run attaches a `claude-tool-usage-pr-<number>` artifact (14-day retention): tool call counts,
Bash command labels with `compound` and `has_subst` flags, the denied subset of both, and the run's
turn count and cost. It exists to diagnose permission denials against the workflow's `--allowedTools`
list, since the job log records only the number of denials, never what was refused. Tool names alone
proved insufficient — 520 of 567 denials in the first week were `Bash`, which is every command there
is.

`has_subst` exists for what the frontloaded context left behind. Denials fell from 5.2 per run to
0.3, and the remainder moved from reads to the *write* path: 4 of the first 16 runs were refused on
`gh pr review` or `gh pr comment`, both allowlisted, one of them three times before the review
landed. The hypothesis is the review body rather than the command — a body is markdown, and a
backtick inside a double-quoted argument is command substitution to anything parsing shell — so the
flag is tested against the raw command, where `compound` is tested with quoted spans removed. It is
carried on `commands` as well as `denied_commands`, because a denial rate needs a base rate.

The artifact is a projection of the action's execution log, never the log itself — that file is the
full conversation, and the runner holds a git credential the reviewer can read, which artifacts
(unlike job logs) would not mask. Command labels come from the fixed vocabulary in `CMD_JQ`, never
from the transcript, so no path, search pattern, or credential can ride along in a "command prefix".
`tests/tool-usage-test.sh` asserts that containment directly. Both the projection and the upload are
non-fatal.

## Setup

Requires:
- `ANTHROPIC_API_KEY` org secret
- [Claude Code GitHub App](https://github.com/apps/claude) installed on the org
- Org ruleset pointing to this repo's workflow
