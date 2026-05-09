#!/usr/bin/env bash
# Install agent-orchestrator config templates and systemd user units.
# Idempotent: existing config files are not overwritten.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-orchestrator"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

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

for unit in agent-orchestrator-litellm.service agent-orchestrator.service agent-orchestrator.timer; do
  sed "s|__REPO_DIR__|$REPO_DIR|g" "$REPO_DIR/systemd/$unit" > "$SYSTEMD_DIR/$unit"
  echo "installed: $SYSTEMD_DIR/$unit"
done

cat <<EOF

Next steps:
  1. Edit $CONFIG_DIR/.env       (set MINIMAX_API_KEY)
  2. Edit $CONFIG_DIR/config.toml (set repo and workspace_root)
  3. Install Python deps:
       pip install --user -r $REPO_DIR/requirements.txt
  4. Make sure 'gh' is authenticated:
       gh auth status
  5. Create the four labels on the pilot repo:
       for L in agent:ready agent:running agent:done agent:failed; do
         gh label create "\$L" --repo OWNER/REPO --force
       done
  6. Enable services:
       systemctl --user daemon-reload
       systemctl --user enable --now agent-orchestrator-litellm.service
       systemctl --user enable --now agent-orchestrator.timer
  7. Tail logs:
       journalctl --user -u agent-orchestrator.service -f
EOF
