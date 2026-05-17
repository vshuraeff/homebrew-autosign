# Changelog

## Unreleased — strict-review hardening pass

Major correctness, security, and UX hardening after a 5-axis review (security, robustness, UX, code quality, operations).

### Security

- **Private key + PKCS12 are now deleted from disk after `security import`.** Only the public `codesign.crt` remains, kept for fingerprint / expiry display in `status`. Removes the same-user key-exfiltration vector entirely.
- **Provenance gate.** The agent refuses to sign anything inside a `Cellar/<pkg>/<ver>/` that lacks `INSTALL_RECEIPT.json`. Closes the "drop a fake binary into Cellar and wait for the agent to bless it" escalation path.
- **Plist XML escaping** for every `<string>` value plus `plutil -lint` validation **before** the plist is moved into place. Prevents config-derived path metacharacters from injecting LaunchAgent keys.
- **Strict input validation.** Package names must match Homebrew formula naming (`^[a-z0-9][a-z0-9._+@-]{0,127}$`); binary names must be plain basenames with no slashes, traversal, control chars, or whitespace. Invalid lines are rejected with a warning. `cmd_remove` now compares package names as literal strings instead of regex — fixes a destructive bug where `remove` with regex-metachar package names could silently zero out `packages.conf`.
- **`flock` resolution** is restricted to fixed Homebrew paths (`/usr/local/bin/flock`, `/opt/homebrew/bin/flock`). The previous `command -v` fallback is removed to prevent the agent from running a malicious flock placed earlier in PATH.
- `~/.local/share/brew-autosign` is now created with mode `700`.
- Frank threat-model section added to `docs/ARCHITECTURE.md` explaining the residual `-A` ACL trade-off, why it's accepted for an unattended LaunchAgent, and what it does and does not cover.

### Correctness

- **`sig_state` now distinguishes four states**, not three: signed-by-us, unsigned, signed-by-other, codesign-error. Previously, opaque codesign errors were silently classified as "signed-by-other" and skipped.
- **Signing failures propagate.** Per-binary failures are counted; `cmd_sign` returns non-zero if any binary failed. Previously every `sign_one || true` made the command exit 0 regardless of how many failures occurred.
- **Config writes are atomic and locked.** `add`/`remove` acquire a separate `.config.lock` for the entire read-modify-write-reload cycle.
- **`mktemp` cleanup** via `trap … RETURN` in `cmd_remove` so failed/interrupted runs do not leak temp files.
- **`.last_run` debounce is clock-skew-safe.** Future timestamps (Time Machine restore, time travel, clock change) are clamped to zero instead of permanently suppressing all sign passes.
- **Stability check** replaces the fixed `sleep 1` before signing. The script waits until a binary's size is stable across two reads (up to 10 × 200 ms) before re-signing, avoiding signing of half-written files mid-`brew upgrade`.
- **WatchPaths backstop.** The generated plist now also sets `StartInterval=3600` so an idempotent sign pass runs hourly, recovering from any WatchPaths events that launchd may coalesce or drop.
- **Identity preflight.** Before signing, the script confirms `find-identity -p codesigning -v` lists our identity; if not, it logs a precise diagnostic instead of silently failing.
- **FAT64 Mach-O magic** (`bfbafeca`, `cafebabf`) added to the executable-detection magic set.
- **Custom `HOMEBREW_PREFIX`** is honored in addition to `/usr/local` and `/opt/homebrew`, and `brew --prefix` is also consulted when available.
- **macOS-only assertion** at startup — script aborts with a clear message on non-Darwin platforms.

### UX

- **`status`** now leads with a single `verdict: ok | degraded | not-set-up` line and surfaces recent agent stderr, cert fingerprint and days-until-expiry, and configured-but-not-installed packages.
- **`reload`** warns when packages in `packages.conf` are not installed in any known Homebrew prefix (no watch path emitted).
- **`add`** prints a warning when the package is not yet installed (the agent will start watching after a subsequent `brew install` + `reload`).
- **`setup` is fully idempotent and resumable.** Re-running after the trust prompt was dismissed re-attempts only the steps that did not complete, then verifies trust round-trip and aborts with a clear diagnostic if trust did not take.
- **`uninstall --purge`** now removes cert + Keychain identity + data dir, with a typed confirmation prompt; the previous version printed commands the user had to copy and run by hand.
- **Per-subcommand `--help`** for `add`, `remove`, `uninstall`.
- **`list`** has a `STATE` column with normalized casing (`ok-by-us`, `unsigned`, `by-other`, `error`, `absent`) and a `PATH (provenance)` column showing whether the keg has a brew receipt.
- **Cert expiry warning at 365 days** in `status`.

### Build / CI

- GitHub Actions workflow (`.github/workflows/ci.yml`): shellcheck on the script, syntax + help smoke test on macos-14, input-validation rejection tests, plist generation with `plutil -lint`, and `brew audit` of the formula.
- Formula caveat text updated from RSA-3072 to ECDSA P-521 (SHA-512); mentions cert + private-key deletion after import and the `--purge` uninstall variant.

### Behavioral incompatibilities with the previous unreleased revision

- Identity name is now strictly `brew-autosign-local`; the legacy `<legacy-identity>` detection path is gone (was removed in the prior commit).
- `cmd_remove` no longer accepts regex — package name argument is a literal match.
- `.lock` is split into `.sign.lock` and `.config.lock`; an `identity` file in `DATA_DIR` is no longer used.

### Second-pass review hardening

After the initial hardening commit, a second codex review surfaced these residual issues — all addressed in the follow-up commit:

- **`cmd_setup` cleanup trap.** Previously the temp dir holding generated key material was only removed on the success path (inline `rm -rf` after the cert was copied). Switched to `trap "rm -rf $tmp" EXIT` so private-key material is wiped on signal-driven termination or any mid-setup `die()` too. Setup also sweeps stale `.setup.*` dirs at start.
- **`uninstall --purge` deletes by fingerprint.** `security delete-identity -c "$IDENTITY"` would match any cert with the same CN, so a name-colliding cert (Apple Developer cert, an old copy) could be deleted as collateral. Now uses `security delete-{identity,certificate} -Z <SHA-1>` computed from the local cert file. Falls back to CN match with a warning only when no local cert file is available.
- **Provenance gate hardened.** Existence-only check on `INSTALL_RECEIPT.json` was satisfiable by `touch`. Now requires the file to be ≥32 bytes AND contain `"homebrew_version"` AND one of `"poured_from_bottle"` / `"built_as_bottle"` / `"installed_on_request"`. Verified end-to-end against three corpora.
- **`-T /usr/bin/codesign` dropped from `security import`.** It was redundant with `-A` and could mislead readers into thinking it gated key access.
- **find-certificate export refuses multi-cert PEM bundles.** If the keychain holds more than one cert with the same CN, we now die with a clear remediation message instead of silently picking one.
- **`wait_for_stable_file` checks size AND mtime.** Defeats a pathological writer that pauses at a constant size between flushes.
- **`cert_days_left` forced `LC_ALL=C`.** Non-English locales would silently break the expiry-warning logic.
- **`_cmd_remove_inner` temp file lives next to `$CONFIG`.** Guarantees `mv` is a same-filesystem atomic rename.
- **`warn()` routes to `log.txt` when stderr is non-tty.** Prevents a malformed config from inflating `agent.err.log` unboundedly via the hourly StartInterval backstop.
- **Exit codes checked**: `cmd_reload` checks `generate_plist`; `cmd_setup` checks `cp`/`chmod` on the cert file.
- **`_cmd_remove_inner` clears RETURN trap on no-op return** so the cleanup doesn't fire pointlessly when nothing was changed.
- **Comments added** to document the policy on `read_config` warn-and-skip and the `die`-inside-command-substitution convention used by `parse_entry`.

### Bash 3.2 portability

The LaunchAgent invokes `/bin/bash`, which on macOS is bash 3.2.57. The initial hardening pass used `mapfile -t` (bash 4+) in five places; the agent would have failed at runtime with `mapfile: command not found`. Replaced all with portable `while IFS= read -r line; do arr+=("$line"); done` loops. Verified end-to-end against `/bin/bash`.

### Lifecycle and operations docs

`docs/TROUBLESHOOTING.md` now covers Brewfile rebuild, "I want to share my identity across two Macs" (you can't — iCloud Keychain doesn't sync local identities), macOS major-version upgrade verification, and `brew upgrade brew-autosign` mid-execution safety. `docs/ARCHITECTURE.md` documents why `LegacyTimers=true` is intentionally omitted on the hourly `StartInterval` (battery-friendly coalescing).

### CI tightening

The validation test now exercises six bad-input shapes (path traversal, XML metachar, whitespace, traversal inside bin, uppercase package name, shell metachar) and asserts `packages.conf` is **unchanged** after each rejected `add`. The `brew formula` step now hard-fails CI on parse errors; the strict audit is informational until the placeholder sha256 is replaced at v0.1.0 release.

## v0.1.0 — initial release

- `brew-autosign` CLI (bash, single file) with subcommands:
  `setup`, `sign`, `reload`, `add`, `remove`, `list`, `status`, `uninstall`, `help`.
- Self-signed ECDSA P-521 code-signing cert with SHA-512 (`CN=brew-autosign-local`, codeSigning EKU, 10-year validity), generated and imported by `setup`. P-521 is the strongest NIST curve Apple `codesign` accepts (~256-bit security level); Ed25519 is rejected by Apple. P-256 / P-384 remain trivially selectable in `cmd_setup` if a smaller cert is preferred.
- LaunchAgent (`dev.brew-autosign`) with `WatchPaths` over each configured package's `Cellar/<pkg>` and `opt/<pkg>` for both `/usr/local` and `/opt/homebrew` prefixes; auto-generated by `reload`.
- Only unsigned Mach-O binaries are signed; third-party signatures are never overwritten; idempotent on repeat runs.
- `flock`-based serialization + 2-second debounce against bursty WatchPaths events.
- Homebrew formula in `Formula/brew-autosign.rb`; depends on `util-linux` for `flock`.
