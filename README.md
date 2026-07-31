# github-workflows

Central repository for organization-wide GitHub Actions workflows enforced across all `hotdata-dev` repos via org rulesets.

## Workflows

### Claude PR Review

Automated code review on every pull request using [claude-code-action](https://github.com/anthropics/claude-code-action). Reviews are severity-based:

- **P0/P1 issues** — requests changes with inline comments
- **P2/P3 issues** — approves with non-blocking suggestions
- **No issues** — silent approve

The review prompt lives in [`docs/claude-pr-review-prompt.md`](docs/claude-pr-review-prompt.md).

Each run attaches a `claude-tool-usage-pr-<number>` artifact (14-day retention): tool call counts,
denied tool names, and the run's turn count and cost. It exists to diagnose permission denials
against the workflow's `--allowedTools` list, since the job log records only the number of denials,
never which tools were refused.

The artifact is a projection of the action's execution log, never the log itself — that file is the
full conversation, and the runner holds a git credential the reviewer can read, which artifacts
(unlike job logs) would not mask. `TOOL_USAGE_JQ` in the workflow emits names and counts only, and
`tests/tool-usage-test.sh` asserts that tool inputs, tool results, and repository contents cannot
reach the artifact. Both the projection and the upload are non-fatal.

## Setup

Requires:
- `ANTHROPIC_API_KEY` org secret
- [Claude Code GitHub App](https://github.com/apps/claude) installed on the org
- Org ruleset pointing to this repo's workflow
