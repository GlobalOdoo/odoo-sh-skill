#!/usr/bin/env bash
# Set up the odoo-sh skill: install `osh` (odouche), make its login work with your browser,
# install the skill for Claude Code, and check keyring + SSH key. Safe to run again.
#
#   ./setup.sh                          auto-detect the browser
#   ./setup.sh --browser brave          or chrome, chromium, edge, vivaldi, opera, or a full path
#   ./setup.sh --claude-permissions     also let Claude Code run `osh` without being blocked
#
# Linux, macOS and WSL. Native Windows: see README.md ("Windows").
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_src="$(dirname "$here")"
skill_dst="$HOME/.claude/skills/odoo-sh"
browser_choice=""
claude_permissions=0

while [ $# -gt 0 ]; do
    case "$1" in
        --browser) browser_choice="${2:-}"; shift 2 ;;
        --browser=*) browser_choice="${1#*=}"; shift ;;
        --claude-permissions) claude_permissions=1; shift ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

export PATH="$HOME/.local/bin:$PATH"

step "1. uv"
if command -v uv >/dev/null 2>&1; then
    ok "uv $(uv --version | awk '{print $2}')"
else
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 || { fail "could not install uv — see https://docs.astral.sh/uv/"; exit 1; }
    ok "installed uv $(uv --version | awk '{print $2}')"
fi

step "2. osh (odouche-cli)"
if uv tool list 2>/dev/null | grep -q '^odouche-cli '; then
    uv tool upgrade odouche-cli >/dev/null 2>&1 || true
else
    uv tool install odouche-cli >/dev/null 2>&1 || { fail "uv tool install odouche-cli failed"; exit 1; }
fi
osh_py="$(uv tool dir)/odouche-cli/bin/python"
[ -x "$osh_py" ] || osh_py="$(uv tool dir)/odouche-cli/Scripts/python.exe"
if command -v osh >/dev/null 2>&1; then
    ok "$(osh --version)"
else
    warn "osh installed but not on PATH — run: uv tool update-shell, then open a new terminal"
fi

step "3. Login patch (any Chromium-family browser)"
"$osh_py" "$here/patch_odouche.py" | sed 's/^/  /'

step "4. Browser for the Odoo.sh login"
if [ -n "$browser_choice" ]; then
    case "$browser_choice" in
        chrome) browser_choice="google-chrome" ;;
        edge) browser_choice="microsoft-edge" ;;
    esac
    mkdir -p "$HOME/.config/odouche"
    printf '%s\n' "$browser_choice" > "$HOME/.config/odouche/browser"
    ok "saved choice '$browser_choice' in ~/.config/odouche/browser"
fi
read -r chosen found < <("$osh_py" - <<'PY' 2>/dev/null
import os
from odouche._upstream import browser
configured = getattr(browser, "_configured", lambda env: None)(os.environ)
print(configured or "-", browser.find() or "-")
PY
)
if [ -n "$browser_choice" ] && [ "${chosen:--}" = "-" ]; then
    warn "'$browser_choice' was not found or is not runnable — falling back to auto-detection"
fi
if [ "${found:--}" != "-" ]; then
    ok "login will open: $found"
else
    warn "no Chromium-family browser usable here (Firefox/Safari only, or no display)."
    warn "Login still works: osh asks you to paste the session_id cookie — see README.md, 'Login without a supported browser'."
fi

step "5. Keyring (where the Odoo.sh session is kept)"
case "$(uname -s)" in
    Darwin) ok "macOS Keychain" ;;
    Linux)
        if busctl --user list 2>/dev/null | grep -q org.freedesktop.secrets; then
            ok "Secret Service is running"
        else
            warn "no Secret Service. Install one (Ubuntu: sudo apt install gnome-keyring) or export ODOUCHE_SESSION for headless use."
        fi ;;
    *) warn "unknown OS — odouche accepts Secret Service, macOS Keychain or Windows Credential Locker" ;;
esac

step "6. SSH key (for osh ssh)"
command -v ssh >/dev/null 2>&1 && ok "ssh client present" || fail "no ssh client — install openssh-client"
pub=""
for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do
    [ -f "$k" ] && { pub="$k"; break; }
done
if [ -n "$pub" ]; then
    ok "key: $pub"
    echo "     Add it on Odoo.sh: your name (top right) → Profile → SSH Keys → Add a key manually."
    echo "     Odoo.sh does NOT pick up your GitHub keys by itself:"
    echo "     $(cat "$pub")"
else
    warn "no SSH key. Create one:  ssh-keygen -t ed25519 -C \"you@company\"  then re-run this script."
fi

step "7. Claude Code skill"
if [ "$skill_src" != "$skill_dst" ]; then
    mkdir -p "$HOME/.claude/skills"
    rm -rf "$skill_dst" && cp -r "$skill_src" "$skill_dst"
    ok "installed to $skill_dst"
else
    ok "already in place: $skill_dst"
fi

if [ "$claude_permissions" = 1 ]; then
    python3 - <<'EOF'
import json, os
path = os.path.expanduser("~/.claude/settings.json")
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
perms = data.setdefault("permissions", {})
allow = perms.setdefault("allow", [])
ask = perms.setdefault("ask", [])
for rule in ["Bash(osh *)"]:
    if rule not in allow:
        allow.append(rule)
for rule in ["Bash(osh *rebuild*)", "Bash(osh *backups create*)", "Bash(osh *backups download*)",
             "Bash(osh *backups pull*)", "Bash(osh *auth logout*)"]:
    if rule not in ask:
        ask.append(rule)
env = data.setdefault("autoMode", {}).setdefault("environment", [])
note = ("The `osh` command (odouche CLI) is the user's own sanctioned tool for their company's Odoo.sh "
        "projects. Listing projects/branches/builds/backups, reading build and server logs, and `osh ssh` "
        "into development and staging builds for read-only checks are routine, expected work. Writing on "
        "any build, and anything on a production branch, still needs the user's explicit go-ahead.")
if "$defaults" not in env:
    env.insert(0, "$defaults")
if not any("`osh` command (odouche CLI" in e for e in env):
    env.append(note)
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print("  \033[32m✓\033[0m ~/.claude/settings.json: osh allowed; rebuild/backups/logout still ask")
EOF
else
    echo "     (optional) re-run with --claude-permissions so Claude's auto mode does not block osh"
fi

step "8. Session"
if osh auth status >/dev/null 2>&1; then
    osh auth status | sed 's/^/  /'
else
    warn "not logged in. Run:  osh auth login   (sign in with GitHub in the window that opens, within 5 minutes)"
fi
echo
