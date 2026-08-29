# Comment style harness

A procedure for testing changes to the review prompt's `## Comment Style` section before
they reach `main`. It is not a CI check and cannot be one: it needs model calls, and its
output is prose that another model judges. Run it by hand, as a gate on the pull request.

## Why it exists

The prompt deploys org-wide from `main` with no staging, so the first time a rule change
meets a real pull request is in production, across every repository at once. Three rule
changes have been through this harness. It caught a defect in each, and none of the three
had been predicted by the people who wrote the rules:

- A `<details>`-folding ruleset that read as a 40% reduction was cutting **4%** of real
  volume. It relocated text rather than deleting it, and folded text returns whole through
  `<prior_review_comments>` on later review cycles.
- Folding scope-limiting facts made comments read **more** severe than the originals they
  replaced: the finding stayed visible while the bound on it did not.
- Coupling proof to convention-existence ("write a failure scenario only for blocking
  findings, or where no convention covers the issue") dropped the consequence from the two
  highest-impact findings in the corpus, because a convention happened to exist for both.
  A convention existing means the fix is uncontroversial. It says nothing about how bad
  the bug is.

## When to run it

Any edit to `## Comment Style`, `## Severity Classification` or `## Output Rules` in
`docs/claude-pr-review-prompt.md`.

## What it cannot tell you

The harness measures how comments are **written**, given findings that already exist. It
rewrites real posted comments under a candidate ruleset; it does not review any code.

It therefore says nothing about finding-rate, false positives, or missed bugs. A rule
change that made the reviewer notice less would pass this harness cleanly. Do not cite it
as evidence of review quality in that sense.

## The corpus

`docs/comment-style-corpus.json`, refreshed by `scripts/fetch-comment-style-corpus.sh`.
The bodies are committed rather than fetched live, so an edited or deleted comment cannot
move the baseline silently.

19 comments over three pull requests, of which 14 carry `baseline: true` and are the ones
every recorded number was measured against. They were chosen for adversarial shape, not
coverage:

| Source | Exercises |
|---|---|
| `github-workflows#38` | shell and jq; one comment fusing three findings; one whose finding *is* its mechanism |
| `runtimedb#1242` | Rust and SQL; long mechanism chains; a low-likelihood, high-consequence nit |
| `runtimedb#1236` | Docker and TOML; the only blocking finding; two absence-claims |

The five non-baseline comments are corpus but not baseline. Rewriting them produces a
total that no recorded number compares to.

## Running it

Dispatch two agents in parallel, one per repository, so the two reports are independent.
Each gets:

1. The candidate `## Comment Style` text **verbatim**, with a note on what changed.
2. Its slice of the corpus.
3. The brief below.
4. Acceptance criteria, when there is a specific regression to check.

### The brief

Two lines in it do most of the work. Keep both.

> Apply the style rules faithfully. Do not optimise for shortness beyond what the rules
> require.
>
> Preserve every technical claim. You are restyling, not re-reviewing. Do not add findings
> and do not drop findings.
>
> Where a rule forced a genuinely bad tradeoff, say so explicitly rather than silently
> working around it.

The last line is what produces the useful signal. Without it an agent resolves an
ambiguous rule quietly and the ambiguity never surfaces.

Rewriting rather than re-reviewing is deliberate: re-reviewing a past pull request changes
which findings appear, and the difference between rulesets is then unreadable against that
variance.

### Ask for

- The rewritten comments in full.
- A word-count table: original, previous run, this run.
- An assessment naming, per comment: whether it reads more severe, less severe or the same
  as the original; whether the author can act on it; and any rule that was ambiguous.

### Acceptance criteria

State them as pass-or-fail before the run, and make each name a specific comment. Vague
criteria produce vague reports. The gate run for the current rules used:

1. Consequence restored on the comments that had lost it (name them).
2. The comments that were unactionable are actionable (name them).
3. No distortion in either direction — "same" is the pass, on every comment.
4. No regression on the comments that had improved (name them).

Criterion 4 matters more than it looks. Two of the three defects above were introduced by
a change that fixed something else.

## Counting method

Pin it, or runs are not comparable. Two agents counting the same corpus differed by 3%.

Prose words only: strip fenced code blocks, strip the `nit:` / `super nit:` /
`(not blocking)` prefix, then count whitespace-separated tokens. Folded `<details>` content
counts as prose — a ruleset that hides text has not removed it.

## Baseline

Measured over the 14 baseline comments, by the two agents that ran each ruleset.

| Ruleset | Total prose words | Change |
|---|---|---|
| As posted | 2,338 | — |
| Sentence caps + `<details>` folds | 2,290 | −2% |
| Proof-scaling, first draft | 938 | −60% |
| Shipped (PR #39) | 1,256 | −46% |

The first draft of proof-scaling scored best and was rejected: it bought the extra 14
points by dropping consequences, which is the second defect listed above.

Recomputing the "as posted" row by the pinned method above gives 2,377 rather than 2,338 —
a 2% disagreement between two agents counting the same text. The rows here are internally
consistent because one agent counted each, but a future ruleset measured by the pinned
method will not be exactly comparable to them. Re-measure the "as posted" row alongside any
new one.
