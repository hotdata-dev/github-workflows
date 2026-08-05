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
caps beneath that — 3,000 diff lines, 40 KB per CI log excerpt, 3,000 characters per comment. The
caps are deliberately far below any plausible runner limit: 400 inline comments rendered 1.1 MB of
threads before they existed, and the runner accounts for output size in UTF-16, so a byte count here
is not the number it checks against. Blocks are ordered so that truncation sacrifices the PR
conversation before the diff or the CI status.

Everything reaching the prompt is attacker-controlled — title, body, diff, CI logs, comments — so the
block delimiters are neutralised by shape rather than by exact string: `</pr_context >`,
`</PR_CONTEXT>` and `< / pr_context foo="1">` all read as the same delimiter to a model, and any of
them would otherwise end the data block early and land the rest where it reads as instructions.

### Tool usage artifact

Each run attaches a `claude-tool-usage-pr-<number>` artifact (14-day retention): tool call counts,
Bash command labels with a compound flag, the denied subset of both, and the run's turn count and
cost. It exists to diagnose permission denials against the workflow's `--allowedTools` list, since
the job log records only the number of denials, never what was refused. Tool names alone proved
insufficient — 520 of 567 denials in the first week were `Bash`, which is every command there is.

The artifact is a projection of the action's execution log, never the log itself — that file is the
full conversation, and the runner holds a git credential the reviewer can read, which artifacts
(unlike job logs) would not mask. Command labels come from the fixed vocabulary in `CMD_JQ`, never
from the transcript, so no path, search pattern, or credential can ride along in a "command prefix".
`tests/tool-usage-test.sh` asserts that containment directly. Both the projection and the upload are
non-fatal.

### Reviewer evals

`tests/` asserts that the context step assembles the right prompt. It says nothing about whether the
reviewer then behaves, and until now nothing did — a prompt change could not be evaluated before
merge at all, because the workflow resolves `docs/claude-pr-review-prompt.md` from `main`, so a pull
request editing the prompt is reviewed by the prompt it replaces.

`.github/workflows/claude-review-eval.yml` closes that. Each scenario in
[`tests/eval/`](tests/eval/) becomes a real pull request in `hotdata-dev/pr-review-eval`, with a
*copy of the reviewer workflow committed into the head branch* — so the thing being graded is the
real file on the real `pull_request` path, and the copy comes from the pull request under review
rather than from `main`. Eight scenarios: a clean refactor that must be approved silently, an
incremental loader whose strict `>` watermark drops rows that tie, a telemetry helper that posts
`os.environ` to an external host, an injection attempt in the description paired with a dropped
authorization check, cosmetic-only findings, review cycle 5 against a nit the author declined, a
degraded CI block, and a genuinely red check with a real job log.

Grading reads **pull request state through the API** — the submitted review verdict, the inline
comments, the summary comment — never the action's execution log. That distinction is what makes the
reviewer swappable: the log is a Claude Code artifact, so grading it would make every assertion a
statement about one harness. `reviewer_workflow` and `reviewer_login` are the only two things tying
the eval to Claude, so a different reviewer is a different input, not a rewrite.

Three scenarios need something a file tree cannot express, and each is fenced. A real failing check
comes from a workflow injected into the head branch, because a synthetic check run carries no job id
for the log fetch to find. Prior review comments are posted while the pull request is still a draft
and it is marked ready afterwards, because the reviewer starts the moment it becomes reviewable and
anything posted later is invisible to it. A degraded context block comes from a literal substitution
against the injected workflow — and `tests/eval-test.sh` asserts every anchor still matches the
workflow exactly once, because a fault that silently stops applying would have the eval review an
*unfaulted* pull request and report that the reviewer handled a degradation it never created.

The eval is reporting-only and passes on a rate, not a run: scenarios declare `repeats` and a
`threshold`, security and injection demanding every repeat. The reviewer is not deterministic, and a
merge-gating check that goes red on sampling noise gets ignored within a week. The judge rubric is
recorded and never gates anything, for the same reason doubled.

What runs on every pull request is `tests/eval-test.sh`, not the eval: scenario schemas, trees that
actually differ, regexes that compile, fault anchors, and the grader itself pinned against committed
API payloads in both directions — a scenario passing when it should and failing when the reviewer
approves a bug, posts an unmarked nit, leaves nits at cycle 5, claims CI is green when the block said
it could not be read, or never reviews at all. None of that costs an API call.

### Startup-fatal workflow limits

`tests/workflow-lint-test.sh` checks two things that make a workflow unstartable rather than merely
wrong, both of which have taken the org down. Neither is visible to `yaml.safe_load`, to the shell,
or to actionlint, and the suite passed on both broken commits.

The first is an empty `${{ }}` expression, which Actions rejects outright — it arrived in a shell
comment that spelled the delimiter out to explain why the code avoided it.

The second is the 21,000-character cap on a single expression. A block scalar containing an
interpolation is compiled into one `format(...)` expression whose length is the *dedented* scalar,
so a long, heavily commented `run:` block that interpolates anything is a workflow GitHub refuses to
load: the run concludes `failure` in 0s with **zero jobs**, no check reports, and every pull request
in the org blocks. The two commits either side of it measure 24,860 characters (broken) and 20,545
(the revert) — 455 to spare, or about six comment lines. So the check warns from 90% of the cap, and
warns separately about a long block that has *no* expression yet, since adding one would make the
same text fatal. The way out is to move the interpolations into `env:`, which removes the cap from
that block entirely.

## Setup

Requires:
- `ANTHROPIC_API_KEY` org secret
- [Claude Code GitHub App](https://github.com/apps/claude) installed on the org
- Org ruleset pointing to this repo's workflow
