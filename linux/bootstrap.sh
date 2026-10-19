#!/bin/bash
# Prepare a Linux host (Raspberry Pi OS, Debian/Ubuntu, Fedora/RHEL) for remote management.
# Run on the host as a user who can sudo:
#
#   curl -fsSL https://raw.githubusercontent.com/n2solutionsio/fleet-bootstrap/main/linux/bootstrap.sh | sudo bash
#
# What it does (safe to re-run):
#   1. Installs openssh-server, python3, sudo, curl
#   2. Creates user 'ansible' (no password; SSH key login only)
#   3. Sets its authorized_keys to keys/authorized_keys from this repo
#   4. Gives it passwordless sudo
#   5. Makes SSH key-only and disables root login
#      (set HARDEN_SSH=0 to skip:  ... | sudo HARDEN_SSH=0 bash)
#      WARNING: if you currently SSH into this host with a password, that stops working.
#   6. Enables and reloads the SSH service
set -euo pipefail

main() {
  local REPO_RAW="${FLEET_REPO_RAW:-https://raw.githubusercontent.com/n2solutionsio/fleet-bootstrap/main}"
  local USER_NAME="${AUTOMATION_USER:-ansible}"
  local HARDEN_SSH="${HARDEN_SSH:-1}"

  die()  { echo "ERROR: $*" >&2; exit 1; }
  step() { echo "• $*"; }

  [[ $EUID -eq 0 ]] || die "run with sudo:  curl -fsSL <url> | sudo bash"
  [[ "$(uname -s)" == "Linux" ]] || die "this is the Linux script; use mac/bootstrap.sh"

  # -------------------------------------------------------------------------
  # 1. Packages
  # -------------------------------------------------------------------------
  if command -v apt-get >/dev/null; then
    step "Installing packages (apt)..."
    apt-get update -qq </dev/null >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server python3 sudo curl </dev/null >/dev/null
  elif command -v dnf >/dev/null; then
    step "Installing packages (dnf)..."
    dnf -y -q install openssh-server python3 sudo curl </dev/null >/dev/null
  else
    step "Unknown package manager: make sure openssh-server, python3 and sudo are installed"
  fi
  command -v ssh-keygen >/dev/null || die "ssh-keygen missing (openssh not installed)"
  command -v visudo >/dev/null || die "visudo missing (sudo not installed)"

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
  # 2. Account
  # -------------------------------------------------------------------------
  if id "$USER_NAME" &>/dev/null; then
    step "User $USER_NAME already exists"
  else
    useradd -m -s /bin/bash -c "Automation" "$USER_NAME"
    step "Created user $USER_NAME"
  fi
  # '*' = no usable password (key-only), but not "locked", so sshd still allows key login
  usermod -p '*' "$USER_NAME"

  local HOME_DIR GROUP
  HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
  GROUP="$(id -gn "$USER_NAME")"

  # -------------------------------------------------------------------------
  # 3. Keys (repo is source of truth)
  # -------------------------------------------------------------------------
  install -d -m 700 -o "$USER_NAME" -g "$GROUP" "$HOME_DIR/.ssh"
  install -m 600 -o "$USER_NAME" -g "$GROUP" "$KEYS" "$HOME_DIR/.ssh/authorized_keys"
  rm -f "$RAW" "$KEYS"
  command -v restorecon >/dev/null && restorecon -R "$HOME_DIR/.ssh" || true
  step "Installed authorized keys (compare with your password manager):"
  ssh-keygen -l -f "$HOME_DIR/.ssh/authorized_keys" | sed 's/^/    /'

  # -------------------------------------------------------------------------
  # 4. Passwordless sudo
  # -------------------------------------------------------------------------
  local TMP_SUDO
  TMP_SUDO="$(mktemp)"
  echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > "$TMP_SUDO"
  visudo -cf "$TMP_SUDO" >/dev/null || die "sudoers validation failed"
  install -m 440 -o root -g root "$TMP_SUDO" "/etc/sudoers.d/$USER_NAME"
  rm -f "$TMP_SUDO"
  step "Passwordless sudo configured"

  # -------------------------------------------------------------------------
  # 5. SSH hardening
  # -------------------------------------------------------------------------
  local SSHD
  SSHD="$(command -v sshd || echo /usr/sbin/sshd)"
  if [[ "$HARDEN_SSH" == "1" ]]; then
    install -d -m 755 /etc/ssh/sshd_config.d
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
      sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    fi
    cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
# Managed by fleet-bootstrap
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
EOF
    step "SSH is key-only (password logins disabled)"
  else
    step "HARDEN_SSH=0: leaving sshd settings unchanged"
  fi
  [[ -e /etc/ssh/ssh_host_ed25519_key ]] || ssh-keygen -A >/dev/null
  mkdir -p /run/sshd
  "$SSHD" -t || die "sshd config test failed"

  # -------------------------------------------------------------------------
  # 6. SSH service
  # -------------------------------------------------------------------------
  local SVC=""
  if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    for s in ssh sshd; do
      if systemctl list-unit-files "$s.service" 2>/dev/null | grep -q "^$s.service"; then SVC="$s"; break; fi
    done
  fi
  if [[ -n "$SVC" ]]; then
    systemctl enable --now "$SVC" >/dev/null 2>&1 || true
    systemctl reload-or-restart "$SVC"
    step "SSH service '$SVC' enabled and reloaded"
  else
    echo "! No systemd SSH service found: start/reload sshd yourself"
  fi

  # -------------------------------------------------------------------------
  local IP HOST
  IP="$( { ip -4 route get 1.1.1.1 2>/dev/null || true; } | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ -n "$IP" ]] || IP="$( { hostname -I 2>/dev/null || true; } | awk '{print $1}')"
  HOST="$(hostname -s | tr '[:upper:]' '[:lower:]')"
  echo
  echo "Done: $HOST  (${IP:-<ip>})"
  echo "From your MacBook:  ssh $USER_NAME@${IP:-<ip>} 'sudo -n whoami'   -> should print: root"
}

main "$@"
