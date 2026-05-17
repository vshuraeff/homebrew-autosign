# brew-autosign

Auto re-sign Homebrew-installed binaries with a **stable local code-signing identity** so macOS Keychain ACLs survive every `brew upgrade`.

## The problem

macOS Keychain identifies trusted apps by the **designated requirement** of their code signature. When a binary is unsigned, that identity falls back to the raw file hash.

Many Homebrew bottles ship **unsigned** (e.g. [`fnox`](https://fnox.jdx.dev/), `age`, various Rust/Go tools). For unsigned tools that use the Keychain — secret managers, password tools, anything calling `SecKeychainFindGenericPassword` with stored ACLs — every `brew upgrade` produces a new binary hash → Keychain sees a brand-new "stranger" → it pops a GUI password prompt for **every single stored secret**. Painful.

## The fix

`brew-autosign` runs a tiny LaunchAgent that watches the brew `Cellar/<pkg>` directories for configured packages and, on any change, immediately re-signs the freshly-installed binary with a **stable** self-signed certificate kept in your login keychain. The designated requirement therefore stays identical across upgrades, and Keychain ACLs remain valid forever.

Key properties:

- **Zero workflow change.** Triggers on both `brew upgrade <pkg>` and bulk `brew upgrade`. Nothing to remember after install. An hourly backstop catches anything WatchPaths might miss.
- **Survives Homebrew self-updates** (LaunchAgent does not depend on brew's machinery).
- **Survives upstream formula changes** (no local tap to keep in sync).
- **Safe by default.** Only **currently unsigned** Mach-O binaries are signed. Binaries already signed by someone else (Apple, the vendor) are never touched. Codesign errors are surfaced, never silently confused with "signed by other".
- **Provenance-gated.** Only signs binaries inside Homebrew-installed kegs (those with `INSTALL_RECEIPT.json`). Refuses to sign arbitrary files dropped into `Cellar` by anything other than `brew install`.
- **Private key never persists on disk** beyond the import moment. After `security import`, the `.key` and `.p12` files are deleted; only the public `.crt` is kept for diagnostics.
- **Idempotent.** Already-signed-by-us binaries are skipped.
- **Extensible.** Maintain a simple `packages.conf` to control which packages are auto-signed.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the threat model and a frank discussion of the one residual security trade-off (the `-A` keychain ACL, necessary for unattended signing).

## Install

```sh
brew tap vshuraeff/autosign
brew install vshuraeff/autosign/brew-autosign
brew-autosign setup
```

For the bleeding edge instead of the latest release:

```sh
brew install --HEAD vshuraeff/autosign/brew-autosign
```

`setup` is interactive once — it generates the cert, imports it into your login keychain, trusts it for the `codeSign` policy (one Keychain password prompt), creates a default config, and starts the LaunchAgent.

## Usage

```sh
brew-autosign add fnox             # auto-sign all unsigned binaries in fnox
brew-autosign add somepkg:bin1,bin2  # only specific binaries
brew-autosign list                 # show packages and current signing state
brew-autosign status               # health summary + agent state + expiry + log
brew-autosign remove fnox          # stop auto-signing
brew-autosign reload               # regenerate plist after editing config by hand
brew-autosign sign                 # run a sign pass now (non-zero exit on failures)
brew-autosign uninstall            # remove the agent (keeps cert/config)
brew-autosign uninstall --purge    # also delete cert + Keychain identity
```

Each subcommand also accepts `--help`.

After install, on first use of a Keychain-backed tool (e.g. `fnox`), macOS will prompt **once per existing secret** to bind the new stable signature to the ACL. Click **"Always Allow"** every time (it's per-secret, not per-invocation). Subsequent `brew upgrade`s are silent forever.

## Config

`~/.config/brew-autosign/packages.conf` — one entry per line, two forms:

```
# Form 1: sign every unsigned Mach-O executable in the package's bin/
fnox

# Form 2: only specific binaries inside the package
my-pkg:cli,daemon
```

Fields:

- **`<package>`** — exact Homebrew formula name as it appears under `Cellar/`. For tap-installed formulae use the leaf name (e.g. `fnox`, not `user/tap/fnox`).
- **`<binary>`** — file name inside the package's `bin/` directory.

`#` starts a comment. Whitespace is trimmed. After editing, run `brew-autosign reload`.

See [`share/packages.conf.example`](share/packages.conf.example) for the annotated template `setup` installs.

## How it works

1. A self-signed ECDSA P-521 cert (`CN=brew-autosign-local`, `codeSigning` EKU, SHA-512, 10 years) lives in your login keychain. ~256-bit security level — the strongest NIST curve Apple `codesign` accepts.
2. A LaunchAgent (`~/Library/LaunchAgents/dev.brew-autosign.plist`) is configured with `WatchPaths` covering each configured package's `Cellar/<pkg>` directory.
3. On any change inside those directories (brew upgrades create a new `Cellar/<pkg>/<new-version>/` subdirectory), launchd fires the agent.
4. The agent's `sign` pass walks each configured package, locates currently-unsigned Mach-O binaries, and re-signs them with the stable identity using `codesign --force --sign`.

Because the cert is fixed and the binary's designated requirement therefore stays the same, macOS Keychain ACLs remain valid no matter how many times brew swaps the binary.

For a deeper architectural rationale (including why a brew post-install hook is not viable), see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

Quick checks:

```sh
brew-autosign status                                       # agent state + recent log
launchctl print gui/$(id -u)/dev.brew-autosign             # raw launchd state
tail -f ~/.local/share/brew-autosign/log.txt               # signing log
codesign -dv --verbose=2 /usr/local/bin/<pkg>              # current signature
security find-identity -p codesigning -v                   # confirm cert is trusted
```

## Layout

```
/usr/local/bin/brew-autosign                       # CLI (symlink into Cellar)
~/.config/brew-autosign/packages.conf              # package list
~/.local/share/brew-autosign/                      # mode 700
    codesign.crt                                   # public cert ONLY (key + p12 deleted after import)
    log.txt                                        # signing log
~/Library/LaunchAgents/dev.brew-autosign.plist     # the agent (auto-generated)
```

## Requirements

- macOS (any version supported by current Homebrew).
- Homebrew at `/usr/local` (Intel) or `/opt/homebrew` (Apple Silicon).
- `util-linux` (provides `flock(1)`; pulled in automatically as a brew dependency).

## Release workflow (maintainers)

Dev-time dependencies are pinned in `Brewfile.dev`:

```sh
brew bundle install --file=Brewfile.dev
```

`scripts/bump.sh` then drives semantic-versioned releases using [Conventional Commits](https://www.conventionalcommits.org/):

```sh
scripts/bump.sh                 # dry-run, auto-detect bump from commits
scripts/bump.sh --patch         # force a patch bump
scripts/bump.sh --minor
scripts/bump.sh --major
scripts/bump.sh --apply         # commit + annotated tag
```

`svu` computes the next version from Conventional-Commit prefixes since the last tag (`feat:` → minor, `fix:` → patch, `feat!:`/`BREAKING CHANGE:` → major). `git-cliff` prepends a grouped CHANGELOG section. Non-conventional commits are preserved under an "Other" group so history is never lost.

After `--apply`:

```sh
git push origin master --follow-tags
```

The published GitHub release tarball's SHA-256 must then be pasted into `Formula/brew-autosign.rb`'s stable block (currently HEAD-only); see the comment block in the formula for the exact lines to add.

## License

MIT — see [LICENSE](LICENSE).
