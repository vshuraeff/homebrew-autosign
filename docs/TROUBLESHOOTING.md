# Troubleshooting

## Quick checks

```sh
brew-autosign status                                   # health summary — start here
brew-autosign list                                     # per-binary signing state
launchctl print gui/$(id -u)/dev.brew-autosign         # raw launchd state
tail -f ~/.local/share/brew-autosign/log.txt           # signing log (live)
cat ~/.local/share/brew-autosign/agent.err.log         # launchd-captured stderr
codesign -dv --verbose=2 /usr/local/bin/<tool>         # current signature on a binary
security find-identity -p codesigning -v               # confirm cert is trusted
```

The single command that answers "is everything working?" is `brew-autosign status`. It prints a `status: ok | degraded | not-set-up` line and surfaces any recent stderr from the agent.

## Symptom: Keychain still prompts on every secret after `brew upgrade`

1. Confirm the binary is actually being re-signed:
   ```sh
   codesign -dv --verbose=2 /usr/local/bin/<tool> 2>&1 | grep Authority
   ```
   Expect `Authority=brew-autosign-local`.

2. If you see `code object is not signed at all`:
   - Is the package in `packages.conf`?
     ```sh
     brew-autosign list
     ```
     If missing: `brew-autosign add <pkg>`.
   - Is the LaunchAgent loaded and the identity trusted?
     ```sh
     brew-autosign status
     ```
     A `status: not-set-up` means run `brew-autosign setup`. A `status: degraded` includes specific reasons.
   - Inspect the agent's stderr:
     ```sh
     cat ~/.local/share/brew-autosign/agent.err.log
     ```

3. If the binary **is** signed correctly but Keychain still prompts, the ACL on those pre-existing items still references the **old** designated requirement (an unsigned-binary hash or a different identity). Click "Always Allow" on each prompt; the ACL will be updated to trust the new stable identity. Future upgrades will be silent for **that secret**. See the next section if you find yourself re-prompted later for *different* secrets.

   ![macOS Keychain prompt — choose "Always Allow"](images/SCR-20260517-rtqv-2.png)

## Symptom: I clicked "Always Allow" yesterday and I'm being prompted again today

This is **expected** Keychain behavior, not a bug in `brew-autosign`. Keychain ACLs are **per-secret**, not per-binary. "Always Allow" binds the new signature only to the **specific item** that the prompt was for — every other secret still carries its old ACL until it is read and re-authorized.

If your tool stores many secrets (e.g. `fnox` users commonly have 20+ items with `svce=fnox`), the prompts trickle out over days as you happen to touch each one for the first time post-signing. Once a secret has been "Always Allow"'d, it stays silent across all future `brew upgrade` cycles.

To confirm the signing itself is stable (i.e. the designated requirement is the same as it was at the last "Always Allow"):

```sh
codesign -d --requirements - /usr/local/bin/<tool>
```

Expect:

```
designated => identifier <tool> and certificate leaf = H"<40-char-sha1>"
```

(With an Apple-issued identity the DR instead reads `identifier "<tool>" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: …"` — it matches by **common name**, not a fixed hash, and the `openssl … codesign.crt` cross-check below applies only to the managed self-signed cert.)

That `H"..."` is the SHA-1 fingerprint of your local cert. Cross-check:

```sh
openssl x509 -in ~/.local/share/brew-autosign/codesign.crt -fingerprint -sha1 -noout
```

If both fingerprints match, your designated requirement has not changed since previous signings — every prompt you see is for a secret whose ACL was set before this identity existed (or before your last `setup`). Click "Always Allow" once and that secret will be silent forever.

If the fingerprints **do not** match, your local cert was regenerated (e.g. someone re-ran `brew-autosign setup` after `uninstall --purge`) and every previously-allowed ACL is now obsolete. There is no recovery short of re-clicking "Always Allow" on each secret once more.

You can also reproduce the stable-DR check without waiting for a real upgrade:

```sh
brew reinstall <pkg>     # fresh binary at the same path
codesign -d --requirements - /usr/local/bin/<pkg>
```

The DR after reinstall must be byte-identical to the DR before reinstall. If it is, no further Always-Allow prompts should appear for already-authorized secrets.

## Symptom: prompts came back after I added an Apple Developer (or other) code-signing cert

The most common "it suddenly stopped working" cause. Keychain ACLs bind to the **designated requirement** of whatever signed the tool **at the moment you clicked "Always Allow"**. If a *second* codesigning identity enters the picture — e.g. you enrolled in Apple Developer and an `Apple Development: …` cert landed in your login keychain — and the tool was signed by *that* identity when you (re)authorized, your ACLs are now bound to it. The next `brew upgrade` yields an unsigned binary, brew-autosign re-signs it with **its** identity, the DR no longer matches what the ACLs expect, and every secret re-prompts at once.

Diagnose — what's active vs. what's actually on the binary:

```sh
brew-autosign identity list                          # identities present; '*' = active
codesign -dv --verbose=2 /usr/local/bin/<tool> 2>&1 | grep Authority
```

Pick one canonical identity, make brew-autosign use it, then re-sign:

```sh
# Option A — standardize on your Apple Developer / Developer ID cert:
brew-autosign identity set "Apple Development: you@example.com (TEAMID)"

# Option B — standardize on the managed self-signed cert:
brew-autosign identity reset && brew-autosign sign --force
```

`identity set` runs a forced re-sign itself; `reset` does not, so chain `sign --force`. Then read each secret once and click **"Always Allow"** — from then on the ACLs are bound to a single identity that brew-autosign re-applies on every upgrade, so they stay valid.

`brew-autosign list` shows `by-other` for any configured binary signed by an identity other than the active one — a quick way to spot a third identity re-signing your tools.

## Symptom: `setup` says "MAC verification failed during PKCS12 import"

OpenSSL 3's default modern PKCS12 export format which the macOS `security` tool does not understand. `brew-autosign setup` already uses `-legacy`; if you somehow regenerated the p12 file manually without it, delete the cert material and re-run setup:

```sh
rm -f ~/.local/share/brew-autosign/codesign.crt
security delete-identity -c brew-autosign-local 2>/dev/null
brew-autosign setup
```

## Symptom: agent fires but log shows only "another sign pass running, skipping"

That is the intended behavior when WatchPaths emits a burst of events: the first invocation acquires the lock, the rest log and exit. Confirm the first pass actually did something:

```sh
grep -E 'signing|signed OK' ~/.local/share/brew-autosign/log.txt | tail
```

## Symptom: identity not visible to codesign

```sh
security find-identity -p codesigning -v
```

If the `brew-autosign-local` identity is not listed, the cert is in your keychain but is not **trusted** for the `codeSign` policy. Re-run setup; it is idempotent and re-attempts the trust step when the identity is not yet visible:

```sh
brew-autosign setup
```

If that still fails (e.g. the GUI password prompt was dismissed), re-add the trust manually:

```sh
security add-trusted-cert -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  ~/.local/share/brew-autosign/codesign.crt
```

## Symptom: `flock: command not found` in `agent.err.log`

`flock` is not installed. Install:

```sh
brew install util-linux
```

`brew-autosign` only resolves `flock` from `/usr/local/bin/flock` and `/opt/homebrew/bin/flock` — it deliberately does **not** fall back to `$PATH` to avoid the agent picking up a malicious flock placed earlier in PATH.

## Symptom: agent runs but binary stays unsigned, log says "skip ... no INSTALL_RECEIPT.json"

The provenance gate refused to sign because the version directory does not look like a brew-installed keg. This can happen if:

- the package was built from source via `brew install --HEAD` and brew did not emit a receipt (rare, but possible);
- you manually copied a binary into `Cellar/<pkg>/<ver>/bin/` outside of brew;
- something else dropped a fake keg into `Cellar` (this is exactly what the gate is supposed to catch).

If the package is legitimate, reinstall it via brew so a receipt is created:

```sh
brew reinstall <pkg>
```

## Symptom: agent runs but log says "preflight: identity not found"

The keychain identity is missing or untrusted. Causes:

- Login keychain was locked and the agent cannot resolve trusted identities. Unlock the keychain (log in, unlock screen, or `security unlock-keychain login.keychain-db`) and retry.
- Cert was deleted from the keychain (or never installed). Run `brew-autosign setup`.

## Symptom: I moved from Intel `/usr/local` to Apple Silicon `/opt/homebrew`

```sh
brew-autosign reload
```

The plist is regenerated from the current state of both prefixes; whichever has each configured package installed gets watched. The cert and identity persist (they live in the user keychain, not in either Homebrew prefix). If you also reinstalled the `brew-autosign` formula itself on the new prefix, `reload` picks up the new `ProgramArguments` path via `command -v brew-autosign`.

## Symptom: I restored from Time Machine

The cert (in keychain), config (in `~/.config`), and plist (in `~/Library/LaunchAgents`) are all restored. But the plist's `WatchPaths` reference brew prefixes that may not yet exist on the freshly-restored Mac.

```sh
brew install <whatever-was-in-packages.conf>
brew-autosign reload
brew-autosign status
```

## Symptom: I'm a different macOS user account on a Mac with a shared brew install

This is unsupported. Each user's login keychain holds an independent `brew-autosign-local` identity (different keys, different fingerprints), so binaries signed by user A appear as "signed-by-other" to user B's agent and B's Keychain ACLs do not match. Either:

- Pick one user as the "signing user" and have other users accept that their Keychain ACLs will not be auto-maintained, or
- Each user accepts the one-time "Always Allow" cycle independently after install.

## Symptom: `status` says "cert expires in N days"

For the **managed self-signed** identity the warning window is 365 days — the cert is approaching its 10-year expiry. Plan a rotation: it forces the one-time "Always Allow" Keychain prompts again (the new identity has a different DR), so schedule it for a quiet moment.

```sh
brew-autosign uninstall --purge        # delete current identity + cert
brew-autosign setup                    # generate a fresh 10-year cert
brew-autosign reload                   # re-sign pass + agent reload
```

For an **external** identity (Apple Development / Developer ID) the window is 30 days. Renew the cert through your normal Apple workflow, then re-apply it:

```sh
brew-autosign sign --force             # re-sign configured binaries with the renewed cert
```

Because the DR matches by common name, a renewal that keeps the same CN needs no re-authorization. If the CN changed, the one-time "Always Allow" prompts return.

## Symptom: I want to start over from scratch

```sh
brew-autosign uninstall --purge        # interactive confirmation required
brew-autosign setup                    # fresh identity, fresh data dir
```

Doing this invalidates every Keychain ACL that was bound to the previous identity; the one-time "Always Allow" prompts return.

## Symptom: I rebuilt my Mac via Brewfile and the agent isn't signing

`brew bundle` reinstalls formulae but does not re-run any tool's setup. After the bundle finishes:

```sh
brew-autosign setup        # generates a fresh local identity in the new keychain
brew-autosign reload       # picks up newly-installed packages and watches them
brew-autosign status
```

The local identity is **not** carried over from your old Mac unless you actively restored the login keychain. iCloud Keychain does not sync local code-signing identities by design; treat each Mac as its own signer.

## Symptom: I want to use the same identity across two Macs

You cannot. The local cert lives only in each Mac's login keychain and iCloud Keychain explicitly does not sync identities. Each Mac runs `brew-autosign setup` independently and gets its own RSA/ECDSA key pair. The "Always Allow" one-time prompts must be accepted on each Mac after install.

## Symptom: After a major macOS upgrade, the agent stopped working

macOS major upgrades (e.g. 14 → 15) sometimes change `security`, `codesign`, or `launchctl` semantics. Run a verification pass:

```sh
brew-autosign status                    # check status
launchctl print gui/$(id -u)/dev.brew-autosign 2>&1 | head -20
codesign -dv --verbose=2 /usr/local/bin/<configured-tool>
```

If the agent's `state` is something other than `running` or `waiting`, reload:

```sh
brew-autosign reload
```

If signing still fails, regenerate the local trust setting (sometimes lost across upgrades):

```sh
security add-trusted-cert -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  ~/.local/share/brew-autosign/codesign.crt
```

## Symptom: I just upgraded brew-autosign itself and now the agent is mid-execution

`brew upgrade brew-autosign` replaces `/usr/local/Cellar/brew-autosign/<old>/bin/brew-autosign` and refreshes the `/usr/local/bin/brew-autosign` symlink. The LaunchAgent's `ProgramArguments` points at the symlink, so the next agent fire automatically uses the new version. An old `brew-autosign sign` process that was already mid-execution holds its own copy of the script (bash reads the file into memory before executing) and completes against the old version — no crash, no race, no need to manually restart the agent. If you want to verify the agent is using the new binary, `brew-autosign reload` will regenerate the plist with the current `command -v brew-autosign` result.

## Symptom: I want to inspect a binary by hand

```sh
# is it signed at all, and by whom?
codesign -dv --verbose=4 /usr/local/bin/fnox

# what is its designated requirement (this is what Keychain ACLs match against)?
codesign -dr - /usr/local/bin/fnox

# does the trust chain validate?
codesign --verify --verbose /usr/local/bin/fnox
```

`codesign --verify` for binaries signed by our local identity reports `valid on disk` and `satisfies its Designated Requirement`. Gatekeeper rejection messages (e.g. "not notarized") are **expected** for local identities and irrelevant — Keychain ACL matching does not use Gatekeeper.

## Symptom: launchd reports `Bootstrap failed: 5: Input/output error`

The plist references a path that doesn't exist (typically a `WatchPaths` entry whose package isn't installed). `brew-autosign reload` filters `WatchPaths` to currently-existing paths, so install the package first, then reload:

```sh
brew install <pkg>
brew-autosign reload
```

## Symptom: a configured package is silently not being watched

Likely it isn't installed in any known Homebrew prefix. `brew-autosign reload` prints a `configured but not installed` block in that case; `brew-autosign status` does too. Install the package then `reload`.

## Getting more verbose output

```sh
bash -x /usr/local/bin/brew-autosign sign 2>&1 | less
```

For deeper poking, the script's signing logic is in `sign_one` / `sign_package`; provenance gate is `is_brew_installed_keg`; identity preflight is `preflight_identity`.
