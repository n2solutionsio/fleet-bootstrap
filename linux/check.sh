#!/bin/bash
# Read-only check of a Linux host. Changes nothing, needs no sudo. Run on the host:
#
#   curl -fsSL https://raw.githubusercontent.com/n2solutionsio/fleet-bootstrap/main/linux/check.sh | bash

main() {
  local USER_NAME="${AUTOMATION_USER:-ansible}"
  local READY=1
  ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
  bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; }
  warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
  hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

  local HOST OS ARCH IP IFACE HWADDR MODEL=""
  HOST="$(hostname -s | tr '[:upper:]' '[:lower:]')"
  OS="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  ARCH="$(uname -m)"
  [[ -r /proc/device-tree/model ]] && MODEL="$(tr -d '\0' < /proc/device-tree/model)"
  read -r IP IFACE < <(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<NF;i++){if($i=="src")s=$(i+1); if($i=="dev")d=$(i+1)}} END{print s, d}')
  [[ -n "$IP" ]] || IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  HWADDR="$(cat "/sys/class/net/${IFACE:-eth0}/address" 2>/dev/null)"

  hdr "This host"
  echo "  Name:      $HOST"
  echo "  OS:        $OS ($ARCH)${MODEL:+  [$MODEL]}"
  echo "  Network:   ${IP:-no IP} on ${IFACE:-?}  MAC ${HWADDR:-?}"
  echo "  Logged in: $(id -un)"

  hdr "Can you run the bootstrap from this login?"
  if [[ $EUID -eq 0 ]] || id -Gn | grep -qwE 'sudo|wheel|admin'; then ok "$(id -un) can sudo"
  else warn "$(id -un) is not in sudo/wheel: log in as a user who can sudo"; fi
  if command -v python3 >/dev/null; then ok "python3 $(python3 -V 2>&1 | awk '{print $2}')"
  else warn "python3 missing (the bootstrap installs it)"; fi

  hdr "Ready for remote management?"
  if id "$USER_NAME" &>/dev/null; then ok "account '$USER_NAME' exists"
  else bad "account '$USER_NAME' missing"; READY=0; fi
  if [[ -e "/etc/sudoers.d/$USER_NAME" ]]; then ok "passwordless sudo file present"
  else bad "passwordless sudo file missing"; READY=0; fi
  # ss if available, otherwise read the kernel's socket table (port 22 = 0016, LISTEN = 0A)
  if { command -v ss >/dev/null && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '[:.]22$'; } \
     || grep -qiE ':0016 [0-9a-f]+:[0-9a-f]+ 0A' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
    ok "SSH is listening on port 22"
  else bad "nothing listening on port 22"; READY=0; fi
  if [[ -e /etc/ssh/sshd_config.d/00-hardening.conf ]]; then ok "SSH is key-only"
  else warn "SSH hardening not applied"; fi

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

  # inventory.yml  (under linux: hosts:)
        $HOST:
          ansible_host: $HOST
          ansible_user: $USER_NAME

  Tip: in UniFi, give MAC ${HWADDR:-?} a fixed IP.
EOF
  else
    bad "NOT READY. Run:  curl -fsSL <repo>/linux/bootstrap.sh | sudo bash"
  fi
  echo
}

main "$@"
