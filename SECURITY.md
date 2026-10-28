# Security

## Reporting a vulnerability

Use GitHub private vulnerability reporting: the repository's Security tab, "Report a vulnerability"
(a private security advisory). Please do not open a public issue for a vulnerability. Include the
commit, macOS version, a reproduction, and what an attacker gains.

Repository: `megasoft1978/strim-engine`, Security tab. If that is unavailable, email the
maintainer at megasoft78@gmail.com.

Strim is pre-1.0 and only `main` is supported. There is no bug bounty.

## Threat model (summary)

Details: `docs/CONTROL-API.md`, `docs/MCP.md`, `docs/APP.md`.

- **Loopback only.** The server binds to 127.0.0.1. Requests are also checked for a loopback `Host`
  and, when present, `Origin`; `Sec-Fetch-Site: cross-site` is refused. Strim is not designed to be
  exposed to a network.
- **Two tokens.** `~/.strim/token` (API and MCP clients) and `~/.strim/control-token` (the menu-bar
  app and other control clients), both 0600 files with 32 random bytes. Each is refused on the
  other's routes; the API token only reads `GET /v1/strim/status` on the control routes. Tokens are
  compared in constant time and are redacted from tool output. `strim serve --no-auth` opens only
  the API side; control routes still require the control token.
- **The local model is untrusted.** File contents can prompt-inject it. Its Bash tool runs under
  `sandbox-exec` (no network, writes only to the job worktree and job temp dir, no reads of
  credentials such as `~/.ssh`, `~/.aws` and `~/.strim/token`), with a scrubbed environment and
  timeouts. File tools are contained to the job workspace (realpath checks, deny list for `.env*`,
  keys, `.git/config` and hooks). Jobs run in an isolated git worktree, so your tree is not written.
- **Patch approval.** A job produces a patch and does not change your tree. Applying it requires an
  explicit approval that carries the SHA-256 of the exact patch bytes the reviewer saw; a changed
  patch is refused. Apply also refuses repositories whose git config, attributes or includes could
  run code.
- **Out of scope.** A process running as the same macOS user can read the token files and your
  files, and Strim does not defend against it. Model output quality is not a security property.
