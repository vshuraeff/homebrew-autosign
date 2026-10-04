#!/usr/bin/env bash
# Fixture test for path entries: runs brew-autosign under a throwaway HOME whose
# Library/Keychains links to the real one (the signing identity is only read),
# with launchctl faked so the real agent is never touched.
# Needs a configured or managed signing identity; skips (exit 0) without one.
# Run: tests/path-entries.sh
# shellcheck disable=SC2088  # a literal ~/ is the config syntax under test, never a shell path
set -u
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/brew-autosign"
REAL_HOME=$HOME
identity_file="$REAL_HOME/.config/brew-autosign/identity"
if [[ ! -s "$identity_file" ]] && ! /usr/bin/security find-identity -p codesigning -v 2>/dev/null | grep -q 'brew-autosign'; then
  echo "skip: no brew-autosign signing identity on this machine"
  exit 0
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/bas-test.XXXXXX")
trap 'rm -rf -- "$T"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }
CONF="$T/.config/brew-autosign/packages.conf"
LOG="$T/.local/share/brew-autosign/log.txt"
# every pass bypasses the debounce, so a pass that does nothing proves something
run_sign() { rm -f "$T/.local/share/brew-autosign/.last_run"; bash "$S" sign; }
ident() { /usr/bin/codesign -dv "$1" 2>&1 | sed -n 's/^Identifier=//p'; }
apple_signed() { /usr/bin/codesign -dv --verbose=2 "$1" 2>&1 | grep -q '^Authority=Software Signing'; }
tool() { cp /usr/bin/true "$1"; chmod 755 "$1"; }   # Apple-signed: a foreign signature

mkdir -p "$T/.config/brew-autosign" "$T/bin" "$T/fakebin" "$T/links" "$T/Library" "$T/opt/versions"
ln -s "$REAL_HOME/Library/Keychains" "$T/Library/Keychains"
[[ -s "$identity_file" ]] && cp "$identity_file" "$T/.config/brew-autosign/identity"
printf '#!/bin/bash\necho "launchctl $*" >> "%s/launchctl.log"\n' "$T" > "$T/fakebin/launchctl"
# sleep runs inside the stability wait; with $T/swap present its first call
# replaces bin/racetool by a symlink to bin/unlisted, mid-pass
printf '#!/bin/bash\nif [[ -f "%s/swap" ]]; then rm -f "%s/swap" "%s/bin/racetool"; ln -s "%s/bin/unlisted" "%s/bin/racetool"; fi\nexec /bin/sleep "$@"\n' "$T" "$T" "$T" "$T" "$T" > "$T/fakebin/sleep"
chmod 755 "$T/fakebin/launchctl" "$T/fakebin/sleep"
tool "$T/bin/vendortool"
tool "$T/bin/adhoctool"
/usr/bin/codesign --force --sign - "$T/bin/adhoctool" 2>/dev/null   # ad-hoc, like a local build
tool "$T/bin/linked-real"
ln -s "$T/bin/linked-real" "$T/links/viasymlink"
cat > "$CONF" <<EOF
~/bin/vendortool
$T/links/viasymlink
~/bin/adhoctool
~/bin/missing
~/bin/../escape
EOF

export HOME="$T" PATH="$T/fakebin:$PATH"
run_sign > "$T/sign.out" 2>&1; rc=$?
(( rc == 0 )) && ok "sign pass exits 0" || { bad "sign pass rc=$rc"; sed 's/^/  /' "$LOG" 2>/dev/null | tail -5; }
for f in vendortool adhoctool; do
  if [[ "$(ident "$T/bin/$f")" == "$f" ]] && ! apple_signed "$T/bin/$f" && ! /usr/bin/codesign -dv "$T/bin/$f" 2>&1 | grep -q '^Signature=adhoc'; then
    ok "$f re-signed with identifier $f"
  else
    bad "$f not re-signed: $(/usr/bin/codesign -dv --verbose=2 "$T/bin/$f" 2>&1 | grep -E '^(Identifier|Authority|Signature)' | tr '\n' ' ')"
  fi
done
[[ -L "$T/links/viasymlink" && "$(ident "$T/bin/linked-real")" == viasymlink ]] && ok "symlink entry signs its target with the entry's name" || bad "symlink target identifier: $(ident "$T/bin/linked-real")"
left=("$T"/bin/.*.autosign.*)
[[ -e "${left[0]}" ]] && bad "temp copy left behind" || ok "no temp copy left behind"
grep -qF "invalid path entry '~/bin/../escape'" "$LOG" "$T/sign.out" 2>/dev/null && ok "'..' entry rejected" || bad "'..' entry not rejected"
grep -qF 'skip: ~/bin/missing not present' "$LOG" && ok "missing path skipped" || bad "missing path not reported"

/bin/sleep 1
before=$(stat -f '%i:%m' "$T/bin/vendortool")
run_sign > /dev/null 2>&1
[[ $(stat -f '%i:%m' "$T/bin/vendortool") == "$before" ]] && ok "second pass leaves an already-signed file alone" || bad "second pass rewrote the file"

bash "$S" list > "$T/list.out" 2>&1
grep -q 'vendortool .*ok-by-us' "$T/list.out" && ok "list shows the path entry as ok-by-us" || { bad "list output"; cat "$T/list.out"; }
grep -q 'missing .*absent' "$T/list.out" && ok "list shows the missing path as absent" || bad "list does not show the missing path"

# versioned symlink: one configured name, a new physical file per update
tool "$T/opt/versions/fnox-1.0"
ln -s versions/fnox-1.0 "$T/opt/fnox"
printf '~/opt/fnox\n' > "$CONF"
run_sign > /dev/null 2>&1
tool "$T/opt/versions/fnox-2.0"
ln -sfn versions/fnox-2.0 "$T/opt/fnox"
run_sign > /dev/null 2>&1
[[ "$(ident "$T/opt/versions/fnox-1.0")" == fnox && "$(ident "$T/opt/versions/fnox-2.0")" == fnox ]] \
  && ok "versioned symlink keeps identifier fnox across an update" \
  || bad "versioned identifiers: $(ident "$T/opt/versions/fnox-1.0") / $(ident "$T/opt/versions/fnox-2.0")"

# refusals: each fixture must come out with its Apple signature untouched
refused() {   # <label> <config line> <file that must stay unsigned by us>
  printf '%s\n' "$2" > "$CONF"
  run_sign > /dev/null 2>&1
  apple_signed "$3" && ok "$1 refused" || bad "$1 was signed"
}
tool "$T/bin/gw"; chmod 775 "$T/bin/gw"
refused "group-writable file" '~/bin/gw' "$T/bin/gw"
tool "$T/bin/acltool"; chmod +a "everyone allow write" "$T/bin/acltool"
refused "file with an ACL write grant" '~/bin/acltool' "$T/bin/acltool"
mkdir "$T/acldir"; tool "$T/acldir/tool"; chmod +a "everyone allow add_file,delete_child" "$T/acldir"
refused "directory with an ACL add_file grant" '~/acldir/tool' "$T/acldir/tool"
mkdir "$T/gwlinks"; chmod 775 "$T/gwlinks"; tool "$T/bin/behind-gw"; ln -s "$T/bin/behind-gw" "$T/gwlinks/tool"
refused "symlink in a group-writable directory" '~/gwlinks/tool' "$T/bin/behind-gw"

# replacement during the stability wait: the swapped-in file is never signed
tool "$T/bin/racetool"; tool "$T/bin/unlisted"
printf '~/bin/racetool\n' > "$CONF"
: > "$T/swap"
run_sign > /dev/null 2>&1
[[ ! -e "$T/swap" && -L "$T/bin/racetool" ]] || bad "race fixture did not swap"
apple_signed "$T/bin/unlisted" && ok "file swapped in during the wait is not signed" || bad "swapped-in file was signed"
grep -qF 'skip ~/bin/racetool: it changed during the pass' "$LOG" && ok "the change is logged" || bad "the change is not logged"

: > "$CONF"
bash "$S" add '~/bin/adhoctool' > "$T/add.out" 2>&1
grep -qx '~/bin/adhoctool' "$CONF" && ok "add writes the path entry" || { bad "add"; cat "$T/add.out"; }
bash "$S" add '~/bin/adhoctool' 2>&1 | grep -q 'already present' && ok "add is idempotent" || bad "add wrote a duplicate"
grep -q "$T/bin" "$T/Library/LaunchAgents/dev.brew-autosign.plist" && ok "plist watches the entry's directory" || bad "plist WatchPaths lack the directory"
bash "$S" add '~/a b' > /dev/null 2>&1 && bad "path with a space accepted" || ok "path with a space rejected"
bash "$S" remove '~/bin/adhoctool' > /dev/null 2>&1
grep -q 'adhoctool' "$CONF" && bad "remove left the entry" || ok "remove deletes the path entry"

echo "fails=$fails"
(( fails == 0 ))
