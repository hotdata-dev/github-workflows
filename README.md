# github-workflows

Central repository for organization-wide GitHub Actions workflows enforced across all `hotdata-dev` repos via org rulesets.

## Workflows

### Claude PR Review

Automated code review on every pull request using [claude-code-action](https://github.com/anthropics/claude-code-action). Reviews are severity-based:

- **P0/P1 issues** — requests changes with inline comments
- **P2/P3 issues** — approves with non-blocking suggestions
- **No issues** — silent approve

The review prompt lives in [`docs/claude-pr-review-prompt.md`](docs/claude-pr-review-prompt.md).

## Setup

Requires:
- `ANTHROPIC_API_KEY` org secret
- [Claude Code GitHub App](https://github.com/apps/claude) installed on the org
- Org ruleset pointing to this repo's workflow
