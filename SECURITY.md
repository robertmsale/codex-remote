# Security Policy

FieldExec is a client app that connects to a machine you control and runs the **Codex CLI** there.
Because it can execute arbitrary commands (via Codex), treat it like you would treat SSH access
and a terminal on that machine.

## Best practices (recommended)

### Network & access control

- Prefer placing your remote host behind a private network (for example **WireGuard**) and only
  exposing SSH over the VPN.
- If you must expose SSH to the internet, restrict it:
  - Limit inbound IPs (firewall / security groups).
  - Use a non-root account and least privilege.
  - Consider disabling password auth on the server once key-based auth is working.
- Keep SSH host key verification enabled and verify host keys when connecting to a new host.

### SSH keys

- Use modern keys (Ed25519 recommended) and protect private keys with a passphrase when possible.
- Prefer per-device keys and rotate/revoke keys when a device is lost or decommissioned.
- Keep `~/.ssh` permissions tight (`700` for the directory, `600` for private keys).

### Codex + repository safety

- Only run Codex against projects you trust; Codex can run commands, modify files, and access secrets
  that your user account can access.
- Use separate OS users / separate machines for higher-risk work.
- Treat `.field_exec/` logs as sensitive: they can include prompts, code, commands, and outputs.

## How FieldExec handles remote access

### Remote mode

- FieldExec connects to `username@host` over SSH and runs `codex exec` inside your project directory.
- The remote machine **does not need FieldExec installed**. It only needs:
  - an SSH server
  - Codex CLI
  - optionally `tmux` (recommended) for background-friendly execution
- FieldExec “bootstraps” per-project state by creating `.field_exec/` artifacts in the project:
  - `.field_exec/sessions/<tabId>.log` (JSONL session log)
  - `.field_exec/output-schema.json` (structured output schema)
  - other small tracking files (PIDs/job ids) depending on execution mode

### Key storage

- Private keys are stored in platform secure storage (Keychain / Android Keystore) when provided.
- On desktop (macOS/Linux), FieldExec can also use existing keys from `~/.ssh` (so you don’t have to
  paste keys into the app).
- Passwords are **never stored**; password prompts are only used for explicit bootstrapping flows
  (for example installing a public key into `~/.ssh/authorized_keys`).

## Reporting vulnerabilities

We welcome security reports and audits.

- Please **do not** open a public issue with exploit details.
- Prefer using GitHub’s private vulnerability reporting / Security Advisories for this repository.
- If that isn’t available, open a minimal public issue (“security report: please contact me”) and we
  will follow up to continue privately.

## Contributing security improvements

Security-focused PRs are welcome:

- Hardening defaults (safer SSH behavior, stricter input validation)
- Improvements to key handling / storage
- Better logging redaction controls
- Documentation and threat-model clarifications

