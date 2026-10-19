#!/bin/bash
# Prepare a Mac for remote management. Run on the Mac, from an admin login:
#
#   curl -fsSL https://raw.githubusercontent.com/n2solutionsio/fleet-bootstrap/main/mac/bootstrap.sh | sudo bash
#
# What it does (safe to re-run):
#   0. Installs Xcode Command Line Tools (python3 for Ansible, git/compilers for Homebrew)
#   1. Creates a hidden admin account 'ansible' (no Secure Token, not on FileVault screen)
#   2. Sets its authorized_keys to keys/authorized_keys from this repo
#   3. Gives it passwordless sudo
#   4. Makes SSH key-only and limits SSH logins to the 'ansible' account
#      (set HARDEN_SSH=0 to skip:  ... | sudo HARDEN_SSH=0 bash)
#   5. Turns on Remote Login
set -euo pipefail

# Everything lives inside main() so the whole script is read before anything runs
# (required for 'curl | bash': no command can accidentally swallow the rest of it).
main() {
  local REPO_RAW="${FLEET_REPO_RAW:-https://raw.githubusercontent.com/n2solutionsio/fleet-bootstrap/main}"
  local USER_NAME="${AUTOMATION_USER:-ansible}"
  local HARDEN_SSH="${HARDEN_SSH:-1}"

  die()  { echo "ERROR: $*" >&2; exit 1; }
  step() { echo "• $*"; }

  [[ $EUID -eq 0 ]] || die "run with sudo:  curl -fsSL <url> | sudo bash"
  [[ "$(uname -s)" == "Darwin" ]] || die "this is the macOS script; use linux/bootstrap.sh"

  # -------------------------------------------------------------------------
  # Fetch and validate keys from the repo
  # -------------------------------------------------------------------------
  local KEYS RAW
  RAW="$(mktemp)"; KEYS="$(mktemp)"
  curl -fsSL "$REPO_RAW/keys/authorized_keys" -o "$RAW" || die "could not download keys from $REPO_RAW"
  grep -Ev '^[[:space:]]*(#|$)' "$RAW" > "$KEYS" || true
  [[ -s "$KEYS" ]] || die "keys/authorized_keys in the repo has no keys yet"
  while IFS= read -r line; do
    [[ "$line" =~ (^|[[:space:]])(ssh-ed25519|sk-ssh-ed25519@openssh\.com)[[:space:]] ]] \
      || die "not an ed25519 key line: $line"
    printf '%s\n' "$line" | ssh-keygen -l -f /dev/stdin >/dev/null 2>&1 \
      || die "invalid key line: $line"
  done < "$KEYS"
  step "Downloaded $(wc -l < "$KEYS" | tr -d ' ') key(s) from the repo"

  # -------------------------------------------------------------------------
  # 0. Command Line Tools
  # -------------------------------------------------------------------------
  if xcode-select -p &>/dev/null; then
    step "Command Line Tools already installed"
  else
    step "Installing Command Line Tools (can take several minutes)..."
    local CLT_FLAG=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress CLT_LABEL
    touch "$CLT_FLAG"
    CLT_LABEL="$(softwareupdate -l 2>/dev/null \
      | awk -F'Label: ' '/Label: Command Line Tools/{print $2}' | sort -V | tail -n1)"
    if [[ -n "$CLT_LABEL" ]]; then softwareupdate -i "$CLT_LABEL" </dev/null >/dev/null 2>&1 || true; fi
    rm -f "$CLT_FLAG"
    xcode-select -p &>/dev/null \
      || die "CLT install failed. Run 'xcode-select --install', click Install, then run this again."
    step "Command Line Tools installed"
  fi

  # -------------------------------------------------------------------------
  # 1. Account
  # -------------------------------------------------------------------------
  local GENERATED_PW=""
  if id "$USER_NAME" &>/dev/null; then
    step "User $USER_NAME already exists"
  else
    GENERATED_PW="$(openssl rand -base64 30 | tr -d '/+=' | cut -c1-32)"
    # No -adminUser/-adminPassword => no Secure Token
    sysadminctl -addUser "$USER_NAME" -fullName "Automation" \
      -password "$GENERATED_PW" -admin </dev/null >/dev/null 2>&1
    id "$USER_NAME" &>/dev/null || die "failed to create $USER_NAME"
    step "Created hidden admin user $USER_NAME"
  fi
  dscl . -create "/Users/$USER_NAME" IsHidden 1
  dscl . -create "/Users/$USER_NAME" UserShell /bin/zsh

  local HOME_DIR
  HOME_DIR="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"
  createhomedir -c -u "$USER_NAME" </dev/null >/dev/null 2>&1 || true
  [[ -d "$HOME_DIR" ]] || die "home directory $HOME_DIR was not created"
  chflags hidden "$HOME_DIR"

  if sysadminctl -secureTokenStatus "$USER_NAME" 2>&1 | grep -q "ENABLED"; then
    echo "! WARNING: $USER_NAME has a Secure Token and will appear on the FileVault unlock screen"
  fi

  # -------------------------------------------------------------------------
  # 2. Keys (repo is source of truth)
  # -------------------------------------------------------------------------
  install -d -m 700 -o "$USER_NAME" -g staff "$HOME_DIR/.ssh"
  install -m 600 -o "$USER_NAME" -g staff "$KEYS" "$HOME_DIR/.ssh/authorized_keys"
  rm -f "$RAW" "$KEYS"
  step "Installed authorized keys (compare with your password manager):"
  ssh-keygen -l -f "$HOME_DIR/.ssh/authorized_keys" | sed 's/^/    /'

  # Homebrew on PATH for non-interactive SSH sessions
  cat > "$HOME_DIR/.zshenv" <<'EOF'
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi
EOF
  chown "$USER_NAME":staff "$HOME_DIR/.zshenv"

  # -------------------------------------------------------------------------
  # 3. Passwordless sudo
  # -------------------------------------------------------------------------
  local TMP_SUDO
  TMP_SUDO="$(mktemp)"
  echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > "$TMP_SUDO"
  visudo -cf "$TMP_SUDO" >/dev/null || die "sudoers validation failed"
  install -m 440 -o root -g wheel "$TMP_SUDO" "/etc/sudoers.d/$USER_NAME"
  rm -f "$TMP_SUDO"
  step "Passwordless sudo configured"

  # -------------------------------------------------------------------------
  # 4. SSH hardening + restrict logins to the automation account
  # -------------------------------------------------------------------------
  if [[ "$HARDEN_SSH" == "1" ]]; then
    install -d -m 755 /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/000-hardening.conf <<'EOF'
# Managed by fleet-bootstrap
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
EOF
    sshd -t || die "sshd config test failed"
    step "SSH is key-only"

    dseditgroup -o read com.apple.access_ssh &>/dev/null \
      || dseditgroup -o create -q com.apple.access_ssh
    dseditgroup -o edit -a "$USER_NAME" -t user com.apple.access_ssh
    step "SSH logins limited to members of com.apple.access_ssh"
  else
    step "HARDEN_SSH=0: leaving sshd settings and SSH access list unchanged"
  fi

  # -------------------------------------------------------------------------
  # 5. Remote Login
  # -------------------------------------------------------------------------
  if systemsetup -setremotelogin on </dev/null &>/dev/null; then
    step "Remote Login enabled"
  else
    echo "! Could not turn on Remote Login from Terminal."
    echo "  Turn it on in System Settings > General > Sharing > Remote Login."
  fi

  # -------------------------------------------------------------------------
  local IFACE IP HOST
  IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  IP="$(ipconfig getifaddr "${IFACE:-en0}" 2>/dev/null || echo '<ip>')"
  HOST="$(scutil --get LocalHostName | tr '[:upper:]' '[:lower:]')"
  echo
  echo "Done: $HOST  ($IP)"
  echo "From your MacBook:  ssh $USER_NAME@$IP 'sudo -n whoami'   -> should print: root"
  if [[ -n "$GENERATED_PW" ]]; then
    echo
    echo "Break-glass password for $USER_NAME (save it in your password manager now; it is not stored anywhere):"
    echo "  $GENERATED_PW"
  fi
}

main "$@"
