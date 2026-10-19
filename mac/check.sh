#!/bin/bash
# Read-only check of a Mac. Changes nothing, needs no sudo. Run on the Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/n2solutionsio/fleet-bootstrap/main/mac/check.sh | bash
#
# Shows whether you can run the bootstrap here, whether the Mac is already
# prepared, and prints the lines to paste into your inventory and ~/.ssh/config.

main() {
  local USER_NAME="${AUTOMATION_USER:-ansible}"
  local READY=1
  ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
  bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; }
  warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
  hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

  local HOST OSV ARCH IFACE IP HWADDR
  HOST="$(scutil --get LocalHostName 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  OSV="$(sw_vers -productVersion)"
  ARCH="$(uname -m)"
  IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  IP="$(ipconfig getifaddr "${IFACE:-en0}" 2>/dev/null)"
  HWADDR="$(ifconfig "${IFACE:-en0}" 2>/dev/null | awk '/ether/{print $2}')"

  hdr "This Mac"
  echo "  Name:      $HOST"
  echo "  macOS:     $OSV ($ARCH)"
  echo "  Network:   ${IP:-no IP} on ${IFACE:-?}  MAC ${HWADDR:-?}"
  echo "  Logged in: $(id -un)"

  hdr "Can you run the bootstrap from this login?"
  if id -Gn | grep -qw admin; then
    ok "$(id -un) is an admin: run the bootstrap right here"
  else
    warn "$(id -un) is a Standard user: run the bootstrap from an admin login (or 'su - <admin>' first)"
  fi
  if xcode-select -p &>/dev/null; then ok "Command Line Tools installed"
  else warn "Command Line Tools missing (the bootstrap installs them)"; fi

  hdr "Ready for remote management?"
  if id "$USER_NAME" &>/dev/null; then
    ok "account '$USER_NAME' exists"
    if [[ "$(dscl . -read "/Users/$USER_NAME" IsHidden 2>/dev/null | awk '{print $2}')" == "1" ]]; then
      ok "'$USER_NAME' is hidden from the login window"
    else warn "'$USER_NAME' is not hidden"; fi
  else
    bad "account '$USER_NAME' missing"; READY=0
  fi
  if [[ -e "/etc/sudoers.d/$USER_NAME" ]]; then ok "passwordless sudo file present"
  else bad "passwordless sudo file missing"; READY=0; fi
  if netstat -an -p tcp 2>/dev/null | awk '$4 ~ /[.:]22$/ && $6 == "LISTEN"' | grep -q .; then
    ok "Remote Login (SSH) is on"
  else bad "Remote Login (SSH) is off"; READY=0; fi
  if [[ -e /etc/ssh/sshd_config.d/000-hardening.conf ]]; then ok "SSH is key-only"
  else warn "SSH hardening not applied"; fi
  if dseditgroup -o checkmember -m "$USER_NAME" com.apple.access_ssh &>/dev/null; then
    ok "'$USER_NAME' is allowed to SSH in"
  elif dseditgroup -o read com.apple.access_ssh &>/dev/null; then
    bad "SSH is limited to a list that does not include '$USER_NAME'"; READY=0
  fi

  hdr "Other"
  local BREW=""
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [[ -x "$b" ]] && BREW="$b"; done
  if [[ -n "$BREW" ]]; then echo "  Homebrew:  $BREW (owned by $(stat -f %Su "$(dirname "$(dirname "$BREW")")"))"
  else echo "  Homebrew:  not installed"; fi
  echo "  FileVault: $(fdesetup status 2>/dev/null | head -n1)"
  echo "  Firewall:  $(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | sed 's/^Firewall is //')"

  hdr "Result"
  if [[ "$READY" == "1" ]]; then
    ok "READY. Add it to your MacBook:"
    cat <<EOF

  # ~/.ssh/config
  Host $HOST
    HostName ${IP:-<ip>}
    User $USER_NAME
    IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"   # 1Password SSH agent; remove if unused
    IdentitiesOnly yes

  # inventory.yml  (under macs: hosts:)
        $HOST:
          ansible_host: $HOST
          ansible_user: $USER_NAME

  Tip: in UniFi, give MAC ${HWADDR:-?} a fixed IP. On Wi-Fi, set this network's
  "Private Wi-Fi address" to Fixed or Off so the MAC doesn't rotate.
EOF
  else
    bad "NOT READY. Run:  curl -fsSL <repo>/mac/bootstrap.sh | sudo bash"
  fi
  echo
}

main "$@"
