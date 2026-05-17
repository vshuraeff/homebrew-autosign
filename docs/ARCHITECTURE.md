# Architecture

## Background: how macOS Keychain decides who can read a secret

When a secret is stored in the Keychain with an ACL (the default for `SecKeychainAddGenericPassword`, `security add-generic-password -T`, etc.), the system records, for every program permitted to access the item, a **designated requirement (DR)** derived from that program's code signature.

When some process later calls `SecKeychainFindGenericPassword`, `securityd` inspects the caller's code signature and checks whether it satisfies any ACL entry's DR. If it does, the secret is returned silently. If it does not, the user is shown a GUI prompt: *"<App> wants to use confidential information stored in <keychain-name>. To allow this, enter the keychain password."*

The DR for a properly signed program references a stable identity (e.g. team identifier, designated CN). For an **unsigned** program, the system has nothing to anchor identity to except the binary's raw hash, so the effective DR pins the exact bytes of the binary on disk.

## Why `brew upgrade` of an unsigned tool breaks Keychain

Homebrew installs binaries to `Cellar/<pkg>/<version>/bin/<binary>` and symlinks them from `<prefix>/bin/`. Every `brew upgrade <pkg>` produces a brand-new binary at a brand-new path with a brand-new hash. To `securityd`, this is a different program. None of the existing ACL entries match, so every protected item triggers a GUI prompt.

For tools that use the Keychain as their secret backend (e.g. `fnox --provider keychain`) and store many items, this is a usability disaster: dozens of password dialogs per upgrade.

## Fix: stable local code-signing identity

If a binary is **signed by a stable identity**, its DR references that identity rather than the file hash. Re-signing the new binary after each upgrade with the same identity therefore keeps the DR — and the Keychain ACL — valid.

`brew-autosign` automates this:

1. Once, at install time, a self-signed ECDSA P-521 cert is created (`CN=brew-autosign-local`, `extendedKeyUsage=codeSigning`, 10 years), imported into the user's login keychain, and trusted for the `codeSign` policy via user-level Trust Settings.
2. A LaunchAgent (`dev.brew-autosign`) watches `Cellar/<pkg>` for each configured package. On any change there (i.e. a brew upgrade has just deposited a new version subdirectory), the agent runs `codesign --force --sign brew-autosign-local <binary>` on the freshly-installed binary.
3. The DR of the new binary now reads "signed by brew-autosign-local", which is identical to the DR of the previous version, which is what the Keychain ACL already trusts. No prompt.

## Why a LaunchAgent (and not alternatives)

This was the most-considered design question. Other paths were rejected for the following reasons.

### Custom brew tap with `def post_install`

A formula's `post_install` block can call arbitrary code, including `codesign`. But this requires installing the package **from your local tap**, not from `homebrew-core` — which means re-publishing every package you want auto-signed, keeping it in sync with upstream, and re-syncing on every upstream bump. Operationally untenable.

### Shell wrapper around `brew`

A wrapper function in `.bashrc` / `.zshrc` / `config.nu` could run `codesign` after `command brew "$@"`. This breaks down because:

- Homebrew is invoked from many places that bypass your shell function: brew's own auto-update daemon, scripts that call `/usr/local/bin/brew` directly, `brew bundle`, etc.
- Users on Apple Silicon vs. Intel have different prefixes; the wrapper must paper over that.
- Most importantly: **users want to forget the workaround exists**. A wrapper requires remembering to use `brew` via the shell.

### Homebrew post-install hook

Homebrew exposes `post_install` per-formula but **no global post-install hook**. Verified against current brew source: there is a no-op `global_post_install` in the codebase, but no user-facing config or env var that ties into it. Discussed and confirmed with multiple LLM consultants and the Formula Cookbook.

### LaunchAgent + WatchPaths (chosen)

- Decoupled from Homebrew entirely. Survives `brew update`, brew self-updates, formula upgrades, tap changes, prefix moves between `/usr/local` and `/opt/homebrew`.
- Fires on any in-place change to `Cellar/<pkg>` — covers `brew upgrade <pkg>`, bulk `brew upgrade`, `brew reinstall`, and even out-of-band brew invocations.
- Zero ongoing user interaction.
- Standard, documented macOS mechanism (`launchd.plist(5)`).

Trade-offs:

- `WatchPaths` is **not recursive**: launchd watches the listed path itself for `vnode` change events, not its descendants. For our use case this is sufficient because brew creates and removes subdirectories of `Cellar/<pkg>` (one per version), which constitutes a modification of `Cellar/<pkg>` itself. We also include `<prefix>/opt/<pkg>` as a redundant trigger (it's a symlink that brew points at the active version).
- `WatchPaths` may coalesce or drop events under heavy churn; `RunAtLoad=true` ensures correctness at agent load time, and the script is idempotent so duplicate triggers are harmless.
- The watched paths must exist at agent-load time. If a package is added to `packages.conf` for a tool that's not yet installed, `brew-autosign reload` simply omits its path from `WatchPaths` until the package exists. Re-run `reload` after the first install.

## Why only unsigned binaries are touched

`brew-autosign sign` reads the existing signature with `codesign -dv` and classifies each binary into one of four states:

| State | Action |
|---|---|
| `Authority=brew-autosign-local` | skip (already ours, idempotent) |
| `code object is not signed at all` | sign |
| any other authority | skip — never overwrite a third-party signature |
| `codesign` returned an unexpected error | log and surface as failure |

This guarantees that signed-and-notarized binaries from official builds are never demoted to local-only trust, and that opaque codesign errors are no longer silently confused with "signed-by-other".

## Provenance gate

Before signing anything inside `Cellar/<pkg>/<ver>/bin/`, the agent verifies that `Cellar/<pkg>/<ver>/INSTALL_RECEIPT.json` exists. Homebrew writes this file when it installs a keg; any directory under `Cellar` that lacks it was not created by `brew install`. Refusing to sign in those directories closes the most realistic same-user escalation path: an attacker dropping a fake `Cellar/fnox/999/bin/fnox` and waiting for the agent to grant it trusted-signature status.

## One-time pain at install

Existing Keychain items installed *before* `brew-autosign setup` still have ACL entries whose DR references the **old unsigned-binary hash**. There is no documented CLI to bulk-rewrite a Keychain ACL's designated requirement; the standard `security set-generic-password-partition-list` updates only the partition list, not the DR.

In practice this means the first time the freshly-signed tool tries to read each pre-existing secret, the user gets one GUI prompt per secret. Clicking **"Always Allow"** binds the new (stable) DR to that ACL. Future upgrades that re-sign with the same identity satisfy the new DR silently.

This pain happens **once** for items created before `brew-autosign` was installed. Items created after install start with the stable DR from the outset.

## Components

```
~/.local/bin/brew-autosign            # the CLI (sign, reload, add, ...)
~/.config/brew-autosign/packages.conf # user-editable package list
~/.local/share/brew-autosign/         # mode 700
    codesign.crt                      # PUBLIC cert only (key + p12 are removed after import)
    log.txt                           # signing log
    .sign.lock, .config.lock          # flock targets
    .last_run                         # debounce timestamp
    agent.out.log, agent.err.log      # launchd stdio
~/Library/LaunchAgents/dev.brew-autosign.plist  # the agent (auto-generated)
```

## Cert details

| Field | Value |
|---|---|
| Algorithm | ECDSA over NIST P-521 (`secp521r1`) — **recommended** |
| Cert signature | `ecdsa-with-SHA512` |
| Validity | 10 years |
| Subject | `CN=brew-autosign-local` |
| Key usage | `digitalSignature` (critical) |
| Extended key usage | `codeSigning` (critical) |
| Basic constraints | `CA:FALSE` (critical) |
| Storage | `~/Library/Keychains/login.keychain-db` |
| ACL on private key | unrestricted (`-A`) — any local tool may sign with it |
| Trust setting | user-level, `codeSign` policy, via `security add-trusted-cert -p codeSign` |

### Why ECDSA P-521 (recommended)

Apple's Security framework accepts only RSA and NIST ECDSA (P-256 / P-384 / P-521) for code-signing identities. **Ed25519 is not accepted** for `codesign` despite being modern and compact. P-521 is the strongest curve in that set:

- **~256-bit security level** — comparable to RSA-15360, far beyond practical attack horizons. The cert can sit untouched for a decade and not become a worry.
- Cert signed with SHA-512 to match the curve's strength.
- Verified empirically with `codesign --verify --verbose`: `satisfies its Designated Requirement`.
- Still tiny on disk (~600 bytes DER) and the per-sign cost is negligible — the agent runs at most a few times per day after `brew upgrade`, not in a hot loop.

### Alternatives

| Curve / algo | Security | Notes |
|---|---|---|
| **P-521** (default) | ~256-bit | recommended; matches Apple's CryptoKit `SecureEnclave` strongest profile |
| P-384 | ~192-bit | lighter; reasonable middle ground |
| P-256 | ~128-bit | matches Apple's own Developer ID strength; smallest cert |
| RSA-3072+ | ~128-bit | legacy; works but no advantage |
| Ed25519 | ~128-bit | **rejected by Apple codesign**; do not use |

To downgrade for any reason (e.g. you want minimum cert size), edit `cmd_setup` in `bin/brew-autosign` and change `P-521` / `-sha512` to your chosen pair.

### Private key handling

After `security import`, **the private key file (`*.key`) and the PKCS12 (`*.p12`) are deleted from disk**. Only the public `codesign.crt` is retained in `~/.local/share/brew-autosign/` (used by `status` for fingerprint and expiry display). The private key lives only inside the user's login keychain from that point forward and cannot be re-extracted by any process that doesn't already hold the keychain unlock.

### ACL policy on the private key (`-A`)

`security import ... -A` makes the keychain ACL on the private key unrestricted: any process running as the user can call `/usr/bin/codesign --sign brew-autosign-local <anything>` without a per-use password prompt.

This is the system's necessary compromise for an unattended LaunchAgent: a per-use prompt would make the agent unusable. The compromise has a real cost — a local attacker who already has code-exec as the user can mint signatures satisfying our designated requirement, and thus poison any Keychain ACL bound to this identity.

The provenance gate above does **not** close that exact hole — it limits what *the agent* will sign, but `/usr/bin/codesign` itself is still callable by anyone. To reduce the gap further:

- **Threat scope** — this identity grants no system-wide trust (`-p codeSign` user-domain only, not `pkgSign`, `SSL`, or `S/MIME`), no Apple notarization, no Gatekeeper bypass. The blast radius is confined to user-keychain ACLs bound to this exact subject CN.
- **Roadmap** — a future version may introduce a dedicated signing helper as the sole ACL principal, with argv validation; that closes the direct-call vector at the cost of more code and more attack surface. The current trade-off is documented as deliberate rather than overlooked.

Users with strict threat models should not run `brew-autosign`; the keychain ACL inconvenience is preferable to widening the signing surface.

## Why not `unfetter`-style on-the-fly signing in a wrapper

An alternative design: replace `/usr/local/bin/<tool>` with a wrapper that re-signs on demand at exec time. Rejected because:

- It races: by the time the wrapper signs, the caller already has the old (unsigned) binary mapped if exec was already in progress.
- It runs `codesign` (slow) on every invocation rather than only after upgrades.
- It hides the underlying tool from `which`, `command -v`, completion installers, etc.

The LaunchAgent approach signs exactly once per upgrade — the natural inflection point.

## Concurrency

Multiple WatchPaths events can fire in quick succession (each subdirectory creation/deletion within `Cellar/<pkg>` counts). The script:

- Acquires an exclusive `flock(2)` on `~/.local/share/brew-autosign/.sign.lock` on fd 9; concurrent invocations exit silently after logging "another sign pass running, skipping".
- A second `flock` on `~/.local/share/brew-autosign/.config.lock` protects `add`/`remove` against racing config mutations.
- Debounces: if the previous successful pass was less than 2 seconds ago, exit. The `.last_run` timestamp is clamped if it sits in the future (clock skew, time-travel, Time Machine restore).
- For each candidate file, waits for the file's size to remain stable across two consecutive reads (up to 10 iterations × 200 ms) before signing. This avoids signing a half-written binary mid-`brew upgrade`, replacing the previous "sleep 1" heuristic.

## Backstop against WatchPaths drops

`launchd.plist(5)` notes that `WatchPaths` events can be coalesced or dropped under load. The plist therefore also sets `StartInterval` to 3600 seconds, causing an idempotent sign pass to run hourly regardless of WatchPaths activity. The pass is a no-op when nothing changed; when an upgrade was missed, it converges within at most an hour.

`LegacyTimers` is **not** set. Apple's default since macOS 10.13 is to coalesce wake-from-sleep timers across all daemons into a few wake events per hour to minimise battery impact. We accept that default deliberately — the agent does not require precise hourly firing, only "approximately hourly", and we prefer the battery-friendly behaviour. Setting `LegacyTimers=true` would force a precise wake every 3600 s, which is unnecessary for our use case.

## What if I want to know what was signed?

```sh
brew-autosign list      # tabular per-binary status across configured packages
brew-autosign status    # health summary, agent state, expiry, recent log + stderr
tail ~/.local/share/brew-autosign/log.txt
```

## Input validation

Lines in `packages.conf` are parsed defensively:

- Package names must match `^[a-z0-9][a-z0-9._+@-]{0,127}$` (Homebrew formula convention).
- Binary names must be plain basenames: no slashes, no `.`/`..`, no whitespace, no control characters.
- Invalid lines are rejected with a stderr warning and skipped.
- `add` validates its argument before writing; `remove` matches by literal package name only.

XML values in the generated LaunchAgent plist are escaped (`&`, `<`, `>`, `"`, `'`); the plist is also `plutil -lint`-validated before being moved into place. Together this prevents a maliciously crafted `packages.conf` from injecting LaunchAgent keys.

## Known limitations

- **Same-user attacker with code execution** still has the codesign-oracle path (see "ACL policy on the private key"). Provenance gating prevents the *agent* from helping, but the keychain ACL on the private key is `-A`.
- **Shared `Cellar` across multiple user accounts** is not supported: each user's keychain holds a different identity, so binaries signed by user A appear as "signed-by-other" to user B, and B's ACLs will not match. Either pick one user as the signer or have each user accept independent ACL re-binds.
- **Pre-existing Keychain items** created before install have ACLs anchored to the old (unsigned-binary or different-identity) DR. First post-install access prompts "Always Allow" once per item — this is unavoidable without privileged ACL rewrite, which macOS does not expose.
- **Only `bin/<...>` is signed.** Binaries living in `sbin/`, `libexec/`, or further nested dirs need explicit `pkg:relative/path` support, which is not implemented yet.
- **Cert expiry at 10 years.** `status` warns when fewer than 365 days remain. Rotation is manual: `brew-autosign uninstall --purge && brew-autosign setup`; this forces the one-time "Always Allow" cycle again.
