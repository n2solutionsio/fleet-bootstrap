# Security

## Reporting a vulnerability

Please report security issues privately using GitHub's
[private vulnerability reporting](https://github.com/n2solutionsio/fleet-bootstrap/security/advisories/new)
rather than opening a public issue.

## How this repository is protected

These scripts run as root on the machines that use them, so changes to this
repository are treated as privileged.

- **No secrets.** Only public keys and scripts are committed. CI fails if a private
  key, an `authorized_keys` option, or a private (RFC 1918) IP address appears.
- **Protected `main`.** Force pushes and branch deletion are blocked; changes land
  through pull requests that must pass CI.
- **Account security.** Maintainers use hardware-key two-factor authentication.
- **Secret scanning and push protection** are enabled.
- **Minimal CI.** The workflow has read-only permissions and uses actions pinned to
  a full commit SHA.

## Running safely

- Read a script before running it (see "Prefer to read before you run?" in the README).
- For a fixed version, use a tag instead of `main` in the URL, and set
  `FLEET_REPO_RAW` to the same tag so keys are fetched from that version too.
- Check the key fingerprints the bootstrap prints against the ones in your password manager.
