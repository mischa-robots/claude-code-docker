#!/bin/bash
# init-ssh.sh
# Generates an Ed25519 SSH key pair on first run and prints the public key.
# The key is stored in a named Docker volume, so it survives container
# rebuilds. Run once, add the public key to GitHub, done.
#
# Subsequent starts are silent — the key already exists.

SSH_DIR="$HOME/.ssh"
KEY="$SSH_DIR/id_ed25519"

# ── Nothing to do if key already exists ──────────────────────────────────────
if [ -f "$KEY" ]; then
    exit 0
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║              SSH KEY SETUP (first run only)                     ║"
echo "╚══════════════════════════════════════════════════════════════════╝"

# ── Generate key ──────────────────────────────────────────────────────────────
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

ssh-keygen -t ed25519 -C "claude-code-container" -f "$KEY" -N ""

chmod 600 "$KEY"
chmod 644 "$KEY.pub"

# ── Configure SSH for GitHub ──────────────────────────────────────────────────
cat > "$SSH_DIR/config" <<'SSHCONFIG'
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
SSHCONFIG
chmod 600 "$SSH_DIR/config"

# ── Print the public key ──────────────────────────────────────────────────────
echo ""
echo "A new SSH key has been generated. Add this public key to GitHub:"
echo "  → https://github.com/settings/ssh/new"
echo ""
echo "──────────────────────────────────────────────────────────────────"
cat "$KEY.pub"
echo "──────────────────────────────────────────────────────────────────"
echo ""
echo "To print this key again at any time, run:"
echo "  cat ~/.ssh/id_ed25519.pub"
echo ""
echo "To verify GitHub connectivity after adding the key, run:"
echo "  ssh -T git@github.com"
echo ""
