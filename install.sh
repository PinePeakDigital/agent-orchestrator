#!/usr/bin/env bash
# Install agent-orchestrator: runtime deps, config templates, systemd user units.
# Idempotent: existing config files are not overwritten and existing tools are skipped.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-orchestrator"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# --- Runtime deps -----------------------------------------------------------
# Aider pins numpy==1.24.3 which won't build on Python 3.13+, so we install it
# via `uv tool` (which provides its own Python). LiteLLM has no such issue, so
# pipx is fine.

if ! command -v pipx >/dev/null 2>&1; then
  echo "error: pipx not found. Install with your package manager (e.g. apt install pipx)." >&2
  exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "[deps] installing uv via pipx"
  pipx install uv
fi

if ! command -v aider >/dev/null 2>&1; then
  echo "[deps] installing aider-chat via uv (Python 3.12)"
  uv tool install --python 3.12 aider-chat
else
  echo "[deps] aider already installed"
fi

if ! command -v litellm >/dev/null 2>&1; then
  echo "[deps] installing litellm[proxy] via pipx"
  pipx install 'litellm[proxy]'
else
  echo "[deps] litellm already installed"
fi

# --- Config -----------------------------------------------------------------

mkdir -p "$CONFIG_DIR" "$SYSTEMD_DIR"

install_config() {
  local src="$1" dest="$2"
  if [[ -e "$dest" ]]; then
    echo "skipped (exists): $dest"
  else
    cp "$src" "$dest"
    chmod 600 "$dest"
    echo "installed: $dest (edit before starting)"
  fi
}

install_config "$REPO_DIR/litellm.yaml"        "$CONFIG_DIR/litellm.yaml"
install_config "$REPO_DIR/config.example.toml" "$CONFIG_DIR/config.toml"
install_config "$REPO_DIR/.env.example"        "$CONFIG_DIR/.env"

# --- Systemd units ----------------------------------------------------------

for unit in agent-orchestrator-litellm.service agent-orchestrator.service agent-orchestrator.timer; do
  sed "s|__REPO_DIR__|$REPO_DIR|g" "$REPO_DIR/systemd/$unit" > "$SYSTEMD_DIR/$unit"
  echo "installed: $SYSTEMD_DIR/$unit"
done

cat <<EOF

Next steps:
  1. Edit $CONFIG_DIR/.env       (set MINIMAX_API_KEY)
  2. Edit $CONFIG_DIR/config.toml (set repo and workspace_root)
  3. Make sure 'gh' is authenticated:
       gh auth status
  4. Create the four labels on the pilot repo:
       for L in agent:ready agent:running agent:done agent:failed; do
         gh label create "\$L" --repo OWNER/REPO --force
       done
  5. Smoke test: open a tiny issue, label it agent:ready, then run once manually:
       systemctl --user start agent-orchestrator-litellm.service
       python3 $REPO_DIR/daemon.py
  6. Once smoke test passes, enable the timer:
       systemctl --user daemon-reload
       systemctl --user enable --now agent-orchestrator-litellm.service
       systemctl --user enable --now agent-orchestrator.timer
  7. Tail logs:
       journalctl --user -u agent-orchestrator.service -f
EOF
