#!/usr/bin/env python3
"""
agent-orchestrator daemon — picks one ready issue per tick, dispatches it
to the worker, and updates labels based on outcome.

Designed to be invoked once per timer tick (concurrency = 1). On each
invocation it processes at most one issue synchronously to completion.
"""
import json
import os
import subprocess
import sys
import tomllib
from pathlib import Path

LABEL_READY = "agent:ready"
LABEL_RUNNING = "agent:running"
LABEL_DONE = "agent:done"
LABEL_FAILED = "agent:failed"

CONFIG_PATH = Path(os.environ.get(
    "AGENT_ORCH_CONFIG",
    Path.home() / ".config" / "agent-orchestrator" / "config.toml",
))

REPO_ROOT = Path(__file__).resolve().parent
WORKER = REPO_ROOT / "worker.sh"


def gh(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True)


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        sys.exit(f"config not found at {CONFIG_PATH}")
    with CONFIG_PATH.open("rb") as f:
        return tomllib.load(f)


def list_issues(repo: str, label: str) -> list[dict]:
    result = gh(
        "issue", "list",
        "--repo", repo,
        "--label", label,
        "--state", "open",
        "--json", "number,title,body,labels",
        "--limit", "50",
    )
    return json.loads(result.stdout)


def replace_label(repo: str, number: int, remove: str, add: str) -> None:
    gh(
        "issue", "edit", str(number),
        "--repo", repo,
        "--remove-label", remove,
        "--add-label", add,
    )


def comment(repo: str, number: int, body: str) -> None:
    gh("issue", "comment", str(number), "--repo", repo, "--body", body)


def safety_check(repo: str) -> bool:
    """Refuse to take new work if any issues are stuck in `agent:running`.

    Stuck issues mean a previous run died mid-flight. A human must resolve
    (relabel back to `agent:ready` or to `agent:failed`) before the daemon
    will dispatch new work.
    """
    stuck = list_issues(repo, LABEL_RUNNING)
    if not stuck:
        return True
    nums = ", ".join(f"#{i['number']}" for i in stuck)
    print(f"[safety] {len(stuck)} issue(s) still labeled {LABEL_RUNNING}: {nums}", file=sys.stderr)
    print("[safety] resolve manually before resuming.", file=sys.stderr)
    return False


def run_worker(config: dict, issue: dict) -> int:
    env = os.environ.copy()
    env["REPO"] = config["repo"]
    env["ISSUE_NUMBER"] = str(issue["number"])
    env["ISSUE_TITLE"] = issue["title"]
    env["ISSUE_BODY"] = issue.get("body") or ""
    env["WORKSPACE_ROOT"] = config["workspace_root"]
    env["MODEL"] = config.get("model", "openai/default")
    env["LITELLM_BASE"] = config.get("litellm_base", "http://127.0.0.1:4000")
    env["BRANCH_PREFIX"] = config.get("branch_prefix", "agent")
    proc = subprocess.run(["bash", str(WORKER)], env=env)
    return proc.returncode


def main() -> None:
    config = load_config()
    repo = config["repo"]

    if not safety_check(repo):
        sys.exit(2)

    ready = list_issues(repo, LABEL_READY)
    if not ready:
        return

    issue = ready[0]
    number = issue["number"]
    print(f"[claim] #{number}: {issue['title']}")
    replace_label(repo, number, LABEL_READY, LABEL_RUNNING)

    rc = run_worker(config, issue)
    if rc == 0:
        replace_label(repo, number, LABEL_RUNNING, LABEL_DONE)
        print(f"[done] #{number}")
    else:
        replace_label(repo, number, LABEL_RUNNING, LABEL_FAILED)
        comment(repo, number, f"Agent worker exited with code {rc}. Check daemon logs.")
        print(f"[fail] #{number} (rc={rc})")


if __name__ == "__main__":
    main()
