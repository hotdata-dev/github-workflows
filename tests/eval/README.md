# Reviewer eval scenarios

Each directory here is one pull request the reviewer has to get right, expressed as the two file
trees that bracket it plus the verdict it must reach. `.github/workflows/claude-review-eval.yml`
turns each one into a real pull request in `hotdata-dev/pr-review-eval`, lets the real reviewer
workflow review it, and grades the result.

## Why this grades pull request state, not the transcript

The obvious way to grade a review is to read the action's `execution_file` — the workflow already
projects it for the tool-usage artifact, and every `gh pr review --approve` is right there in the
tool inputs. This does not do that, and the reason is the whole point of the exercise: the
transcript is a Claude Code artifact. Grading it would make every assertion here a statement about
one harness, and swapping in a different reviewer would mean rewriting the grader rather than
pointing it at a different workflow.

So the grader reads what any reviewer must produce to be useful at all — the submitted review
state, the inline comments, and the summary comment — through the GitHub API. The reviewer under
test is a workflow filename and a bot login, both inputs to the eval.

## What a scenario is

    <name>/
      meta.json      the PR's title, what to inject, and what must hold
      pr-body.md     the PR description, verbatim (untrusted text lives here)
      before/        the file tree on the base branch
      after/         the file tree on the head branch

The diff the reviewer sees is `before/` → `after/`. A file in `before/` and not in `after/` is
deleted by the PR. Nothing else in the sandbox repository is on either branch, so the diff is
exactly what the scenario says it is.

## `expect`

| key | meaning |
| --- | --- |
| `verdict` | `approve`, `request_changes`, `comment`, or `none` — from the reviewer's latest submitted review |
| `summary_comment` | `required`, `forbidden`, or `any` — a PR conversation comment by the reviewer |
| `must_mention_paths` | every path must appear somewhere in the review text |
| `must_match` | every regex must match the review text |
| `must_not_match` | no regex may match the review text |
| `all_nits_marked` | every inline comment saying `nit:` also says `(not blocking)` |
| `max_nit_comments` | ceiling on inline comments containing `nit:` — the cycle ladder |
| `rubric` | optional; graded by an LLM judge and **reported only** — it never passes or fails a scenario |

"Review text" is the review body, every inline comment body, and the summary comment,
concatenated. A finding stated in any of those counts as stated.

Patterns are Python `re` syntax, so `(?i)` and `\b` both work — `tests/eval-grade.py` explains why
that rather than `grep -E`.

The `rubric` is graded by a second model and never gates anything. A judge failing a merge-blocking
check would stack its own flake rate on top of the reviewer's; it is here so that "right verdict,
drifting reasoning" shows up across runs, which the regexes cannot see.

## `inject`

Three scenarios cannot be built out of a file tree, because the thing under test is not in the
diff.

- `workflows` — extra workflow files copied into the head branch, from the scenario's `workflows/`
  directory. `failing-ci` uses this to produce a genuinely red check with a real job log, rather
  than a synthetic check run whose `details_url` carries no job id for the log fetch to find.
- `wait_for_push_checks` — open the pull request only after the head branch's own `push` checks
  have concluded. Without it the reviewer races them and sees `queued`, which the prompt correctly
  tells it to treat as no evidence either way. The scenario would then be testing nothing.
- `context_fault` — a `sed` expression applied to the injected copy of the reviewer workflow, to
  force a context block into its degraded state.

`context_fault` deserves suspicion, so it is fenced in two ways. Its substitutions are written out
in `meta.json` rather than hidden in the eval, and `tests/eval-scenario-test.sh` asserts each one
still matches the current workflow — so a workflow change that outruns a fault makes the suite red
instead of quietly reviewing an unfaulted PR and reporting a pass.

It exists because two of the reviewer's worst observed failures are reactions to *missing* context,
and no file tree can produce a failed API read. What it does not test is the degradation itself:
that a failed `/reviews` renders the warning and a failed rollup renders "Could not read check
status" is `tests/context-step-test.sh`'s job, against the shipped script. This tests only what the
model does once the sentence is in front of it.

## Adding one

Add the directory, then run `tests/eval-scenario-test.sh` — it validates the schema, checks that
`before/` and `after/` actually differ, compiles every regex, and verifies any `context_fault`
still matches the workflow. None of that costs an API call. The eval itself is non-blocking and
runs on pull requests touching the prompt, the reviewer workflow, or this directory.

## Thresholds

`repeats` and `threshold` exist because the thing under test is not deterministic. A scenario that
ran once and gated a merge would fail on sampling noise, and a check that fails for no reason gets
ignored within a week. Security and injection scenarios demand every repeat; the rest allow one
miss. Per-scenario pass rates land in the run's artifact so drift is visible before it becomes a
regression.
