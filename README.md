# agent-orchestrator

A small daemon that polls GitHub Issues for selected repos, dispatches each "ready" issue to an isolated [Aider](https://aider.chat) worker running in a git worktree, and opens a pull request with the result. Multi-model routing via [LiteLLM](https://docs.litellm.ai) lets us balance price and quality across tiers.

Inspired by [OpenAI's Symphony](https://github.com/openai/symphony) but built from scratch — GitHub Issues instead of Linear, Aider instead of Codex, Python instead of Elixir.

## Status

Early scaffolding. v0 target: one repo, one model tier, end-to-end loop from `agent:ready` label to opened PR.

## How it works

```
GitHub Issue (label: agent:ready)
        │
        ▼
   daemon (systemd timer, every 60s)
        │  claim: agent:ready → agent:running
        ▼
   worker
        │  - git worktree add <workspace> <branch>
        │  - aider --message "<rendered prompt>" --yes-always
        │  - git push -u origin <branch>
        │  - gh pr create
        │  - mark: agent:running → agent:done | agent:failed
        ▼
   PR opened, linked to issue
```

### Label lifecycle

| Label | Meaning | Set by |
|---|---|---|
| `agent:ready` | Human says "go" | Human |
| `agent:running` | Daemon claimed it | Daemon (do not set manually) |
| `agent:done` | PR opened successfully | Daemon |
| `agent:failed` | Worker exited non-zero | Daemon |

## Tier routing (planned)

| Tier | Use case | Model |
|---|---|---|
| `tier:premium` | Architecture, hard bugs, security-sensitive | Opus 4.7 / GPT-5 |
| `tier:default` | Most feature work, refactors, tests | MiniMax M2.7 |
| `tier:janitor` | Typos, dep bumps, doc fixes | M2.7-highspeed / Haiku 4.5 |

## Layout

```
.
├── daemon.py             # poll → claim → spawn → mark (one issue per tick)
├── worker.sh             # worktree → aider → push → PR
├── litellm.yaml          # model tier → provider mapping
├── config.example.toml   # template for ~/.config/agent-orchestrator/config.toml
├── .env.example          # template for ~/.config/agent-orchestrator/.env
├── requirements.txt      # litellm[proxy], aider-chat
├── install.sh            # copies config templates + systemd units into place
└── systemd/              # user service + timer units (paths filled in by install.sh)
```

## Setup

Run from inside the repo:

```bash
./install.sh
```

That copies config templates to `~/.config/agent-orchestrator/`, installs systemd user units, and prints the next steps (edit env + config, install Python deps, create labels, enable services).

## Safety

- Worker runs inside a git worktree on a non-default branch; never on `main`.
- Daemon never pushes to `main`; only opens PRs.
- API keys live in `~/.config/agent-orchestrator/.env` (chmod 600), loaded by the systemd unit.
- On startup, the daemon refuses to take new work if any issues are still labeled `agent:running` — a human resolves first.
