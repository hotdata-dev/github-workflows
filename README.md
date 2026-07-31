# github-workflows

Central repository for organization-wide GitHub Actions workflows enforced across all `hotdata-dev` repos via org rulesets.

## Workflows

### Claude PR Review

Automated code review on every pull request using [claude-code-action](https://github.com/anthropics/claude-code-action). Reviews are severity-based:

- **Blocking issues** — requests changes with inline comments plus a summary comment
- **Nits / super nits** — approves with non-blocking inline comments
- **No issues** — silent approve

The review prompt lives in [`docs/claude-pr-review-prompt.md`](docs/claude-pr-review-prompt.md).

#### Review cycles

Re-reviews narrow as a PR iterates, so a long-running PR converges instead of accumulating new suggestions every round. The workflow counts prior review rounds and enforces the narrowing itself — [`scripts/render-prompt.sh`](scripts/render-prompt.sh) strips the sections a cycle does not qualify for before the prompt is sent, rather than asking the model to restrain itself.

| Cycle | Scope | Reports | Model |
| --- | --- | --- | --- |
| 1 | full diff | blocking + nits + docs | `claude-opus-5[1m]` |
| 2 | changes since last review | blocking + nits | `claude-opus-5[1m]` |
| 3+ | changes since last review | blocking only | `claude-sonnet-5` |

The model is pinned per cycle. Leaving it unpinned is what silently moved these reviews from `claude-opus-4-8[1m]` to `claude-opus-5[1m]`, which tripled cost per PR — change the pins deliberately, in a commit.

## Setup

Requires:
- `ANTHROPIC_API_KEY` org secret
- [Claude Code GitHub App](https://github.com/apps/claude) installed on the org
- Org ruleset pointing to this repo's workflow
