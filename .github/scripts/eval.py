#!/usr/bin/env python3
"""Driver for the reviewer eval. One subcommand per step of claude-review-eval.yml.

The logic lives here rather than in `run:` blocks for a reason this repository learned the hard
way: a block scalar containing a `${{ }}` interpolation is compiled into a single Actions
expression, and a single expression is capped at 21,000 characters. A long, heavily commented run
block that interpolates anything is therefore a workflow GitHub refuses to start -- zero jobs, no
check, every pull request in the org blocked. Keeping the steps to one-liners keeps that whole class
out of reach; tests/workflow-lint-test.sh guards the limit for what remains.

Subcommands:
    plan        expand scenarios into a matrix, one entry per repeat
    stage       build and push a scenario's base and head branches
    run         open the pull request, wait for the review, fetch what it produced
    cleanup     close the pull request and delete both branches
    summarise   render one graded result as markdown
    report      aggregate every result, apply thresholds, render the report
"""

import argparse
import json
import os
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
EVAL_DIR = ROOT / "tests" / "eval"
SANDBOX = os.environ.get("SANDBOX", "hotdata-dev/pr-review-eval")


def log(message):
    print(message, file=sys.stderr, flush=True)


def run(cmd, **kwargs):
    kwargs.setdefault("check", True)
    kwargs.setdefault("text", True)
    return subprocess.run(cmd, **kwargs)


def gh_json(*args):
    out = subprocess.run(
        ["gh", "api", *args], check=True, text=True, capture_output=True
    ).stdout
    return json.loads(out) if out.strip() else None


def emit_output(**pairs):
    path = os.environ.get("GITHUB_OUTPUT")
    for key, value in pairs.items():
        line = f"{key}={value}"
        if path:
            with open(path, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
        else:
            print(line)


def load_meta(name):
    return json.loads((EVAL_DIR / name / "meta.json").read_text(encoding="utf-8"))


def scenario_names():
    return sorted(p.parent.name for p in EVAL_DIR.glob("*/meta.json"))


# --- plan -----------------------------------------------------------------------------------


def cmd_plan(_args):
    wanted = os.environ.get("EVAL_SCENARIOS", "all").strip() or "all"
    override = os.environ.get("EVAL_REPEATS", "").strip()

    names = scenario_names()
    if wanted != "all":
        asked = [n.strip() for n in wanted.split(",") if n.strip()]
        unknown = [n for n in asked if n not in names]
        if unknown:
            raise SystemExit(f"unknown scenario(s): {', '.join(unknown)}")
        names = asked

    entries = []
    for name in names:
        meta = load_meta(name)
        repeats = int(override) if override else int(meta.get("repeats", 1))
        for repeat in range(1, repeats + 1):
            entries.append({"scenario": name, "repeat": repeat})

    log(f"{len(entries)} matrix entries across {len(names)} scenario(s)")
    emit_output(matrix=json.dumps(entries), count=len(entries))


# --- stage ----------------------------------------------------------------------------------


def literal_replace(text, find, replace, where):
    """Literal, not regex, and it must hit exactly once.

    A context fault that silently fails to apply is the worst outcome available here: the eval would
    review an unfaulted pull request and report that the reviewer handled a degraded context
    correctly, having never degraded anything. tests/eval-test.sh asserts every anchor against the
    workflow on each pull request, and this is the belt to that braces.
    """
    hits = text.count(find)
    if hits != 1:
        raise SystemExit(
            f"{where}: anchor matched {hits} time(s), expected exactly 1:\n  {find}"
        )
    return text.replace(find, replace)


def copy_tree(src, dest):
    for path in sorted(src.rglob("*")):
        if path.is_dir():
            continue
        target = dest / path.relative_to(src)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(path.read_bytes())


def clear_tree(work):
    for path in sorted(work.iterdir()):
        if path.name == ".git":
            continue
        run(["git", "-C", str(work), "rm", "-rq", "--ignore-unmatch", path.name])
        if path.exists():
            run(["rm", "-rf", str(path)])


def cmd_stage(_args):
    scenario = os.environ["SCENARIO"]
    repeat = os.environ["REPEAT"]
    run_id = os.environ["RUN_ID"]
    attempt = os.environ.get("RUN_ATTEMPT", "1")
    candidate_sha = os.environ["CANDIDATE_SHA"]
    reviewer_workflow = os.environ["REVIEWER_WORKFLOW"]
    token = os.environ["GH_TOKEN"]

    meta = load_meta(scenario)
    inject = meta.get("inject", {})
    src = EVAL_DIR / scenario

    tag = f"{scenario}/{run_id}-{attempt}-{repeat}"
    base_branch = f"eval-base/{tag}"
    head_branch = f"eval-head/{tag}"

    work = pathlib.Path(os.environ["RUNNER_TEMP"]) / f"sandbox-{scenario}-{repeat}"
    url = f"https://x-access-token:{token}@github.com/{SANDBOX}.git"
    run(["git", "clone", "--depth", "1", "--quiet", url, str(work)])
    run(["git", "-C", str(work), "config", "user.name", "hotdata-automation[bot]"])
    run(
        ["git", "-C", str(work), "config", "user.email",
         "hotdata-automation[bot]@users.noreply.github.com"]
    )

    # Base branch: the before/ tree and nothing else. The sandbox README is removed too, so the
    # scenario's diff is exactly what the scenario says it is.
    run(["git", "-C", str(work), "checkout", "-q", "-b", base_branch])
    clear_tree(work)
    copy_tree(src / "before", work)
    run(["git", "-C", str(work), "add", "-A"])
    run(["git", "-C", str(work), "commit", "-q", "-m", f"eval({scenario}): base state"])
    run(["git", "-C", str(work), "push", "-q", "origin", f"HEAD:{base_branch}"])

    # Head branch: the after/ tree, plus the reviewer workflow under test, plus any scenario
    # workflow. The reviewer workflow is committed here rather than dispatched because that is what
    # makes this an end-to-end test of the real `pull_request` path.
    clear_tree(work)
    copy_tree(src / "after", work)

    reviewer_src = ROOT / reviewer_workflow
    if not reviewer_src.is_file():
        raise SystemExit(f"reviewer workflow not found: {reviewer_workflow}")
    text = reviewer_src.read_text(encoding="utf-8")

    # The prompt document is fetched from `ref: main`, so without this the candidate workflow would
    # review with main's prompt and a prompt change would get no exposure at all. This is the only
    # edit made to the reviewer workflow for every scenario.
    text = literal_replace(
        text, "          ref: main", f"          ref: {candidate_sha}",
        "prompt checkout ref",
    )
    for i, fault in enumerate(inject.get("context_fault", [])):
        text = literal_replace(
            text, fault["find"], fault["replace"], f"context_fault[{i}] for {scenario}"
        )

    dest = work / reviewer_workflow
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text, encoding="utf-8")

    for name in inject.get("workflows", []):
        target = work / ".github" / "workflows" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((src / "workflows" / name).read_bytes())

    run(["git", "-C", str(work), "add", "-A"])
    run(["git", "-C", str(work), "commit", "-q", "-m", f"eval({scenario}): {meta['title']}"])
    run(["git", "-C", str(work), "push", "-q", "origin", f"HEAD:{head_branch}"])
    head_sha = subprocess.run(
        ["git", "-C", str(work), "rev-parse", "HEAD"],
        check=True, text=True, capture_output=True,
    ).stdout.strip()

    log(f"staged {scenario} repeat {repeat}: {base_branch} -> {head_branch} @ {head_sha}")
    emit_output(
        base_branch=base_branch,
        head_branch=head_branch,
        head_sha=head_sha,
        wait_for_push_checks=str(bool(inject.get("wait_for_push_checks"))).lower(),
    )


# --- run ------------------------------------------------------------------------------------


def wait_for_push_checks(head_sha, timeout=600):
    """Let the scenario's own CI finish before the reviewer looks at it.

    Without this the reviewer races the checks and sees `queued`, which the prompt correctly tells
    it to treat as no evidence either way -- so a scenario about a failing check would be testing
    nothing. Checks attach to the SHA, so they carry over to the pull request once it opens.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        runs = gh_json(f"repos/{SANDBOX}/actions/runs?head_sha={head_sha}") or {}
        pending = [
            r for r in runs.get("workflow_runs", [])
            if r.get("event") == "push" and r.get("status") != "completed"
        ]
        done = [
            r for r in runs.get("workflow_runs", [])
            if r.get("event") == "push" and r.get("status") == "completed"
        ]
        if done and not pending:
            log(f"push checks concluded: {[r['conclusion'] for r in done]}")
            return
        time.sleep(10)
    log("timed out waiting for push checks; continuing")


def post_prior_comments(pr_number, head_sha, comments):
    """Inline comments from earlier rounds, posted while the pull request is still a draft.

    Ordering is the whole difficulty: the reviewer starts the moment the pull request becomes
    reviewable, so anything posted afterwards is invisible to it. Opening as a draft and marking it
    ready afterwards makes that deterministic -- `ready_for_review` is one of the reviewer
    workflow's trigger types, and its job-level `draft == false` guard skips the draft open.
    """
    created = []
    for comment in comments:
        args = [
            f"repos/{SANDBOX}/pulls/{pr_number}/comments",
            "-f", f"commit_id={head_sha}",
            "-f", f"path={comment['path']}",
            "-f", f"body={comment['body']}",
        ]
        if "in_reply_to" in comment:
            args += ["-F", f"in_reply_to={created[comment['in_reply_to']]}"]
        else:
            args += ["-F", f"line={comment['line']}", "-f", "side=RIGHT"]
        result = gh_json("-X", "POST", *args)
        created.append(result["id"])
        log(f"posted prior comment {result['id']} on {comment['path']}")
    return created


def wait_for_review_run(head_sha, reviewer_workflow, timeout=1500):
    """Wait for the injected reviewer workflow's run on this SHA to finish.

    A run that never appears and a run that appears with zero jobs are different failures and both
    matter: the first means the trigger did not fire, the second is the startup failure that has
    twice blocked every pull request in the org. Neither is allowed to look like "the reviewer chose
    not to review".
    """
    deadline = time.time() + timeout
    seen = None
    while time.time() < deadline:
        runs = (gh_json(f"repos/{SANDBOX}/actions/runs?head_sha={head_sha}") or {}).get(
            "workflow_runs", []
        )
        mine = [r for r in runs if r.get("path") == reviewer_workflow]
        if mine:
            seen = max(mine, key=lambda r: r.get("run_started_at") or "")
            if seen.get("status") == "completed":
                jobs = gh_json(f"repos/{SANDBOX}/actions/runs/{seen['id']}/jobs") or {}
                return {
                    "run_id": seen["id"],
                    "conclusion": seen.get("conclusion"),
                    "job_count": jobs.get("total_count", 0),
                    "html_url": seen.get("html_url"),
                }
        time.sleep(15)
    return {
        "run_id": seen["id"] if seen else None,
        "conclusion": "timed_out" if seen else "never_started",
        "job_count": 0,
        "html_url": seen.get("html_url") if seen else None,
    }


def cmd_run(_args):
    scenario = os.environ["SCENARIO"]
    base_branch = os.environ["BASE_BRANCH"]
    head_branch = os.environ["HEAD_BRANCH"]
    head_sha = os.environ["HEAD_SHA"]
    reviewer_workflow = os.environ["REVIEWER_WORKFLOW"]
    temp = pathlib.Path(os.environ["RUNNER_TEMP"])

    meta = load_meta(scenario)
    inject = meta.get("inject", {})
    body = (EVAL_DIR / scenario / "pr-body.md").read_text(encoding="utf-8")

    if str(inject.get("wait_for_push_checks", "")).lower() in ("true", "1"):
        wait_for_push_checks(head_sha)

    created = gh_json(
        "-X", "POST", f"repos/{SANDBOX}/pulls",
        "-f", f"title={meta['title']}",
        "-f", f"body={body}",
        "-f", f"head={head_branch}",
        "-f", f"base={base_branch}",
        "-F", "draft=true",
    )
    pr_number = created["number"]
    log(f"opened draft {SANDBOX}#{pr_number}")
    emit_output(pr_number=pr_number, pr_url=created["html_url"])

    post_prior_comments(pr_number, head_sha, inject.get("prior_comments", []))

    # Draft -> ready is what fires the reviewer, so everything the reviewer must see is already in
    # place by this point.
    run(["gh", "pr", "ready", str(pr_number), "--repo", SANDBOX])
    log("marked ready for review")

    outcome = wait_for_review_run(head_sha, reviewer_workflow)
    log(f"reviewer run: {outcome}")
    (temp / "run-outcome.json").write_text(json.dumps(outcome), encoding="utf-8")

    # The review is submitted before the job ends, but the API is eventually consistent enough that
    # a completed run occasionally precedes a visible review by a second or two.
    for _ in range(12):
        reviews = gh_json(f"repos/{SANDBOX}/pulls/{pr_number}/reviews?per_page=100") or []
        if reviews:
            break
        time.sleep(5)

    comments = gh_json(f"repos/{SANDBOX}/pulls/{pr_number}/comments?per_page=100") or []
    convo = gh_json(f"repos/{SANDBOX}/issues/{pr_number}/comments?per_page=100") or []
    (temp / "reviews.json").write_text(json.dumps(reviews), encoding="utf-8")
    (temp / "comments.json").write_text(json.dumps(comments), encoding="utf-8")
    (temp / "convo.json").write_text(json.dumps(convo), encoding="utf-8")
    log(f"fetched {len(reviews)} review(s), {len(comments)} inline, {len(convo)} conversation")

    if outcome["conclusion"] in ("never_started", "timed_out") or outcome["job_count"] == 0:
        # Loud, but not fatal: the grader still runs and records `none`, and the report shows the
        # scenario as errored rather than as a reviewer that declined to review.
        log(f"::warning::reviewer run did not produce a review: {outcome}")


# --- cleanup, summarise, report -------------------------------------------------------------


def cmd_cleanup(_args):
    for key in ("HEAD_BRANCH", "BASE_BRANCH"):
        branch = os.environ.get(key, "")
        if not branch:
            continue
        result = subprocess.run(
            ["gh", "api", "-X", "DELETE", f"repos/{SANDBOX}/git/refs/heads/{branch}"],
            text=True, capture_output=True,
        )
        log(f"delete {branch}: {'ok' if result.returncode == 0 else result.stderr.strip()}")


def cmd_summarise(args):
    data = json.loads(pathlib.Path(args.result).read_text(encoding="utf-8"))
    mark = "PASS" if data["ok"] else "FAIL"
    print(f"### {data['scenario']} — {mark} (verdict: `{data['verdict']}`)")
    print()
    for check in data["checks"]:
        icon = "x" if check["ok"] else " "
        detail = f" — {check['detail']}" if check["detail"] else ""
        print(f"- [{icon}] {check['name']}{detail}")
    print()
    obs = data["observed"]
    print(
        f"{obs['inline_comments']} inline comment(s), {obs['nit_comments']} nit(s), "
        f"{obs['summary_comments']} summary comment(s)."
    )
    if obs["other_bot_reviewers"]:
        print()
        print(f"Other bot reviewers present: {', '.join(obs['other_bot_reviewers'])}.")


def cmd_report(args):
    results = []
    for path in sorted(pathlib.Path(args.directory).rglob("result-*.json")):
        try:
            results.append(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError) as exc:
            log(f"skipping unreadable {path}: {exc}")

    by_scenario = {}
    for result in results:
        by_scenario.setdefault(result["scenario"], []).append(result)

    print("## Reviewer eval")
    print()
    if not results:
        print("No results were produced. Every scenario job failed before grading — treat this as")
        print("an eval failure, not as a passing reviewer.")
        return

    print("| Scenario | Passed | Threshold | Met | Verdicts |")
    print("| --- | --- | --- | --- | --- |")
    unmet = []
    for name in sorted(by_scenario):
        runs = by_scenario[name]
        meta = load_meta(name)
        passed = sum(1 for r in runs if r["ok"])
        # A threshold is a statement about a full set of repeats. When fewer ran -- a pull request
        # forces one repeat, or a job died -- scale it, and never round it up to more than ran.
        declared_repeats = int(meta.get("repeats", 1))
        declared_threshold = int(meta.get("threshold", 1))
        if len(runs) < declared_repeats:
            threshold = max(1, round(declared_threshold * len(runs) / declared_repeats))
        else:
            threshold = declared_threshold
        met = passed >= threshold
        if not met:
            unmet.append(name)
        verdicts = ", ".join(f"`{r['verdict']}`" for r in runs)
        print(
            f"| {name} | {passed}/{len(runs)} | {threshold} | {'yes' if met else 'NO'} | {verdicts} |"
        )

    print()
    rubrics = [r for r in results if r.get("rubric_pass") is not None]
    if rubrics:
        agreed = sum(1 for r in rubrics if r["rubric_pass"] == r["ok"])
        print(f"Judge agreed with the deterministic checks on {agreed}/{len(rubrics)} run(s).")
        print()

    if unmet:
        print(f"**Below threshold: {', '.join(unmet)}.**")
    else:
        print("Every scenario met its threshold.")
    print()
    print(
        "This check is reporting only and does not block the pull request — the reviewer is "
        "non-deterministic, so scenarios pass on a rate. Investigate a scenario that drops below "
        "its threshold two runs in a row."
    )
    for name in sorted(by_scenario):
        for result in by_scenario[name]:
            if not result["ok"]:
                bad = [c["name"] for c in result["checks"] if not c["ok"]]
                print()
                print(f"- `{name}` failed on: {', '.join(bad)}")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "stage", "run", "cleanup"):
        sub.add_parser(name)
    summarise = sub.add_parser("summarise")
    summarise.add_argument("result")
    report = sub.add_parser("report")
    report.add_argument("directory")

    args = parser.parse_args()
    return {
        "plan": cmd_plan,
        "stage": cmd_stage,
        "run": cmd_run,
        "cleanup": cmd_cleanup,
        "summarise": cmd_summarise,
        "report": cmd_report,
    }[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
