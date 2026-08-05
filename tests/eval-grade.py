#!/usr/bin/env python3
"""Grade one reviewed pull request against a scenario's expectations.

Reads four files and writes one JSON object to stdout. It performs no network access, which is
what makes it testable: tests/eval-test.sh drives it against committed fixtures, so the grading
logic is under deterministic test even though the thing it grades is not.

    eval-grade.py --meta tests/eval/hidden-bug/meta.json \
                  --reviews reviews.json --comments comments.json --convo issue-comments.json \
                  [--reviewer 'claude[bot]'] [--rubric-pass true|false|unknown]

Why the inputs are these four and not the action's execution log: the log is a Claude Code
artifact. Grading it would make every assertion in tests/eval/ a statement about one harness, and
pointing the eval at a different reviewer would mean rewriting this file rather than passing a
different --reviewer. Reviews, inline comments and the PR conversation are what *any* reviewer has
to produce to be useful, so they are what gets graded.

Python rather than jq and grep because the expectations are regexes. `(?i)` and `\b` are the two
things scenario patterns need most and the two that portable POSIX tooling handles worst -- BSD and
GNU grep disagree about `\b`, and neither ERE dialect has `(?i)`. Patterns in meta.json are
therefore Python `re` syntax, which is also the dialect whoever writes a scenario will expect.
"""

import argparse
import json
import re
import sys

# A review "verdict" in the sense the scenarios mean it: the reviewer's standing position on the
# pull request. GitHub spells the same thing three ways depending on how it was submitted.
STATE_TO_VERDICT = {
    "APPROVED": "approve",
    "CHANGES_REQUESTED": "request_changes",
    "COMMENTED": "comment",
}

# `nit:` and `super nit:` are the prompt's own vocabulary; the classification assertions key on it.
NIT_RE = re.compile(r"(?:^|\s|\*|_|`)(?:super\s+)?nit\s*:", re.IGNORECASE)
NOT_BLOCKING_RE = re.compile(r"\(\s*not\s+blocking\s*\)", re.IGNORECASE)


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def mine(items, login):
    return [item for item in items if (item.get("user") or {}).get("login") == login]


def resolve_verdict(reviews):
    """The reviewer's latest *position*, not its latest event.

    Inline comments are themselves review objects with state COMMENTED sharing the round's
    commit_id, so the most recent review by timestamp is very often a comment that says nothing
    about approval. Taking it as the verdict would report `comment` for a round that plainly
    requested changes. So APPROVED and CHANGES_REQUESTED are resolved first, among themselves, and
    COMMENTED is only the answer when the reviewer never took a position at all.

    DISMISSED is ignored rather than treated as a verdict: the org ruleset sets
    dismiss_stale_reviews_on_push, so it means "this was superseded", not "this was the outcome".
    """
    positions = [r for r in reviews if r.get("state") in ("APPROVED", "CHANGES_REQUESTED")]
    if positions:
        latest = max(positions, key=lambda r: r.get("submitted_at") or "")
        return STATE_TO_VERDICT[latest["state"]], latest
    commented = [r for r in reviews if r.get("state") == "COMMENTED"]
    if commented:
        latest = max(commented, key=lambda r: r.get("submitted_at") or "")
        return "comment", latest
    return "none", None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--meta", required=True)
    parser.add_argument("--reviews", required=True)
    parser.add_argument("--comments", required=True)
    parser.add_argument("--convo", required=True)
    parser.add_argument("--reviewer", default="claude[bot]")
    parser.add_argument("--rubric-pass", default="unknown", choices=["true", "false", "unknown"])
    args = parser.parse_args()

    meta = load(args.meta)
    expect = meta.get("expect", {})
    reviews = load(args.reviews)
    comments = load(args.comments)
    convo = load(args.convo)

    my_reviews = mine(reviews, args.reviewer)
    my_comments = mine(comments, args.reviewer)
    my_convo = mine(convo, args.reviewer)

    verdict, _ = resolve_verdict(my_reviews)

    # Everything the reviewer said, in one string. A finding stated in a summary comment is as
    # stated as one in an inline comment, and which of the three a reviewer chooses is a matter of
    # style that the scenarios deliberately do not pin.
    review_text = "\n".join(
        [r.get("body") or "" for r in my_reviews]
        + [c.get("body") or "" for c in my_comments]
        + [c.get("body") or "" for c in my_convo]
    )

    nit_comments = [c for c in my_comments if NIT_RE.search(c.get("body") or "")]
    checks = []

    def check(name, ok, detail):
        checks.append({"name": name, "ok": bool(ok), "detail": detail})

    want_verdict = expect.get("verdict", "any")
    if want_verdict != "any":
        check("verdict", verdict == want_verdict, f"wanted {want_verdict}, got {verdict}")

    want_summary = expect.get("summary_comment", "any")
    if want_summary == "required":
        check("summary_comment", bool(my_convo), f"{len(my_convo)} summary comment(s)")
    elif want_summary == "forbidden":
        check(
            "summary_comment",
            not my_convo,
            "no summary comment" if not my_convo else f"{len(my_convo)} unwanted summary comment(s)",
        )

    for path in expect.get("must_mention_paths", []):
        check(f"mentions {path}", path in review_text, "" if path in review_text else "absent")

    for pattern in expect.get("must_match", []):
        hit = re.search(pattern, review_text)
        check(f"matches /{pattern}/", hit, hit.group(0) if hit else "no match")

    for pattern in expect.get("must_not_match", []):
        hit = re.search(pattern, review_text)
        check(f"does not match /{pattern}/", not hit, hit.group(0) if hit else "")

    if expect.get("all_nits_marked"):
        unmarked = [
            c for c in nit_comments if not NOT_BLOCKING_RE.search(c.get("body") or "")
        ]
        check(
            "nits marked (not blocking)",
            not unmarked,
            "" if not unmarked else f"{len(unmarked)} nit comment(s) missing (not blocking)",
        )

    if "max_nit_comments" in expect:
        cap = expect["max_nit_comments"]
        check(f"at most {cap} nit comment(s)", len(nit_comments) <= cap, f"{len(nit_comments)} found")

    # Reviews by a bot that is not the reviewer under test. Not a failure -- aikido-pr-checks,
    # codecov and sentry are installed org-wide and may weigh in -- but if the reviewer's own
    # workflow somehow ran twice, or a second reviewer variant reviewed the same pull request, the
    # verdict above is answering the wrong question and the report has to say so.
    others = sorted(
        {
            (r.get("user") or {}).get("login")
            for r in reviews
            if (r.get("user") or {}).get("login") != args.reviewer
            and ((r.get("user") or {}).get("type") == "Bot")
        }
    )

    result = {
        "scenario": meta.get("name"),
        "reviewer": args.reviewer,
        "verdict": verdict,
        "ok": all(c["ok"] for c in checks),
        "checks": checks,
        # Reported, never fatal. The judge is a second model's opinion about a first model's
        # output; letting it fail a merge-gating check would import its flake rate on top of the
        # reviewer's own. It is here to make "the verdict was right but the reasoning drifted"
        # visible across runs, which the regexes cannot see.
        "rubric_pass": {"true": True, "false": False, "unknown": None}[args.rubric_pass],
        "observed": {
            "reviews": len(my_reviews),
            "inline_comments": len(my_comments),
            "nit_comments": len(nit_comments),
            "summary_comments": len(my_convo),
            "review_chars": len(review_text),
            "other_bot_reviewers": others,
        },
    }
    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
