# fleet-bootstrap

One command, run at the machine, that gets a macOS or Linux host ready to be
managed remotely with SSH and Ansible.

Every host gets a dedicated `ansible` account with:

- SSH login by **key only**, using the public keys in [`keys/authorized_keys`](keys/authorized_keys)
- passwordless `sudo`
- SSH hardened (no password logins, no root login)

Everything after that (packages, updates, configuration) is done remotely.

> This repository contains **public keys and scripts only**. It holds no secrets,
> hostnames or network details. Inventory, playbooks and anything environment-specific
> belong in a private repository.

---

## Usage

**macOS.** Open Terminal while logged in as an administrator.

```bash
# 1. Check (read-only, no sudo)
curl -fsSL https://raw.githubusercontent.com/n2solutionsio/fleet-bootstrap/main/mac/check.sh | bash

# 2. Prepare
curl -fsSL https://raw.githubusercontent.com/n2solutionsio/fleet-bootstrap/main/mac/bootstrap.sh | sudo bash

# 3. Check again; when ready it prints the ~/.ssh/config and inventory lines to add
curl -fsSL https://raw.githubusercontent.com/n2solutionsio/fleet-bootstrap/main/mac/check.sh | bash
```

**Linux** (Raspberry Pi OS, Debian, Ubuntu, Fedora/RHEL). Log in as a user who can `sudo`.

```bash
curl -fsSL https://raw.githubusercontent.com/n2solutionsio/fleet-bootstrap/main/linux/check.sh | bash
curl -fsSL https://raw.githubusercontent.com/n2solutionsio/fleet-bootstrap/main/linux/bootstrap.sh | sudo bash
curl -fsSL https://raw.githubusercontent.com/n2solutionsio/fleet-bootstrap/main/linux/check.sh | bash
```

On macOS the bootstrap prints a one-time break-glass password for the `ansible`
account. Store it in your password manager; it is not saved anywhere else.

Then, from your workstation:

```bash
ssh <host> 'sudo -n whoami'   # prints: root
ansible all -m ping
```

Prefer to read before you run? Download, inspect, then execute:

```bash
curl -fsSLO https://raw.githubusercontent.com/n2solutionsio/fleet-bootstrap/main/mac/bootstrap.sh
less bootstrap.sh && sudo bash bootstrap.sh
```

## Options

Pass these after `sudo`, e.g. `curl -fsSL <url> | sudo HARDEN_SSH=0 bash`.

| Variable | Default | Effect |
|---|---|---|
| `HARDEN_SSH=0` | `1` | Leave sshd settings alone (and on macOS, the SSH access list). Use on hosts where you still log in with a password. |
| `AUTOMATION_USER=name` | `ansible` | Name of the automation account |
| `FLEET_REPO_RAW=url` | this repo, `main` | Fetch keys from a fork or a pinned tag |

## What changes on the host

| | macOS | Linux |
|---|---|---|
| Account | hidden admin `ansible`, random password, no Secure Token (not shown at FileVault unlock) | `ansible`, no password |
| Keys | `~ansible/.ssh/authorized_keys` (replaced on every run) | same |
| sudo | `/etc/sudoers.d/ansible` (NOPASSWD, validated with `visudo`) | same |
| SSH | `/etc/ssh/sshd_config.d/000-hardening.conf`; only `ansible` may SSH in (`com.apple.access_ssh`); Remote Login on | `/etc/ssh/sshd_config.d/00-hardening.conf`; SSH service enabled |
| Packages | Xcode Command Line Tools | `openssh-server`, `python3`, `sudo`, `curl` |

**Linux:** with hardening on, password SSH logins stop working for **every** user on the
host. Make sure you can log in with a key first, or use `HARDEN_SSH=0`.

**macOS:** afterwards only `ansible` can SSH in. To allow another user:
`sudo dseditgroup -o edit -a <user> -t user com.apple.access_ssh`

**Troubleshooting:** web filters and parental-control software can block the downloads
Homebrew needs later (`raw.githubusercontent.com`, `ghcr.io`, `formulae.brew.sh`).

## Keys

Keys are added, rotated and removed by editing [`keys/authorized_keys`](keys/authorized_keys).
Re-running the bootstrap (or an Ansible task that deploys the same file) makes each host
match it exactly. GitHub's raw URLs can serve the old version for a few minutes after a push.

## Security

`curl | sudo bash` means whoever can change this repository can get root on the next
host that runs it. See [SECURITY.md](SECURITY.md) for how this repository is protected
and how to report a problem.

## License

[MIT](LICENSE)
