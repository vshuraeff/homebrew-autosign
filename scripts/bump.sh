#!/usr/bin/env bash
# bump.sh — semver release helper for brew-autosign.
#
# Computes the next version with `svu` (Conventional Commits), prepends a
# CHANGELOG entry with `git-cliff`, commits the result, and creates an
# annotated git tag. By default this is a DRY RUN — pass --apply to
# actually mutate the tree.
#
# Usage:
#   scripts/bump.sh                  # dry-run, auto-detect bump
#   scripts/bump.sh --patch          # force a patch bump
#   scripts/bump.sh --minor
#   scripts/bump.sh --major
#   scripts/bump.sh --apply          # commit + tag
#   scripts/bump.sh --apply --patch
#
# Requires (install via `brew bundle install --file=Brewfile.dev`):
#   - svu
#   - git-cliff

set -uo pipefail
umask 022

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die() { echo "bump: $*" >&2; exit 1; }
note() { echo "bump: $*"; }

command -v svu >/dev/null       || die "svu not installed; run: brew bundle install --file=Brewfile.dev"
command -v git-cliff >/dev/null || die "git-cliff not installed; run: brew bundle install --file=Brewfile.dev"

# ----- arg parsing -----

apply=0
mode=auto
for a in "$@"; do
  case "$a" in
    --apply)      apply=1 ;;
    --dry-run)    apply=0 ;;
    --patch)      mode=patch ;;
    --minor)      mode=minor ;;
    --major)      mode=major ;;
    --auto)       mode=auto ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown flag: $a" ;;
  esac
done

# ----- preconditions -----

# refuse to bump on a dirty tree (changes would land in the release commit)
if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is dirty; commit or stash before bumping"
fi

current_branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$current_branch" != "master" && "$current_branch" != "main" ]]; then
  note "warning: not on master/main (current: $current_branch)"
fi

current=$(svu current 2>/dev/null || echo "v0.0.0")

case "$mode" in
  auto)  next=$(svu next) ;;
  patch) next=$(svu patch) ;;
  minor) next=$(svu minor) ;;
  major) next=$(svu major) ;;
esac

if [[ "$next" == "$current" ]]; then
  # svu returns current when it doesn't see a bump-triggering conventional
  # commit since the last tag. In that case, force a patch bump.
  if [[ "$mode" == auto ]]; then
    note "no Conventional Commits since $current that imply a bump — defaulting to a patch"
    next=$(svu patch)
  fi
fi

if [[ "$next" == "$current" ]]; then
  die "next version computes to current ($current); pass --patch/--minor/--major explicitly"
fi

note "current: $current"
note "next:    $next  (mode=$mode)"

# ----- generate CHANGELOG snippet -----

# git-cliff --unreleased --tag <new-tag> emits only the new section.
new_entry=$(git-cliff --unreleased --tag "$next" --strip header 2>/dev/null)
if [[ -z "$new_entry" ]]; then
  die "git-cliff produced no content; aborting"
fi

note "----- CHANGELOG entry -----"
printf '%s\n' "$new_entry" | sed 's/^/  /'
note "---------------------------"

if (( apply == 0 )); then
  note "dry-run (no commit, no tag). Pass --apply to perform the bump."
  exit 0
fi

# ----- mutate -----

# Prepend the new entry into CHANGELOG.md, after the top-level header.
if [[ -f CHANGELOG.md ]]; then
  tmp=$(mktemp "CHANGELOG.md.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT
  # keep first heading line; insert new entry; then existing body.
  awk -v entry="$new_entry" '
    NR==1 { print; print ""; print entry; print ""; next }
    { print }
  ' CHANGELOG.md >"$tmp"
  mv "$tmp" CHANGELOG.md
  trap - EXIT
else
  printf '# Changelog\n\n%s\n' "$new_entry" >CHANGELOG.md
fi

# Pin the version in the Formula's stable block (uncomments + fills url/version
# placeholders left for release-time substitution). If the formula is still
# HEAD-only, we leave it alone; the user can switch when ready.
note "(skipping Formula stable-block edit — keep HEAD-only until first tagged release lands and you can compute the tarball sha256)"

git add CHANGELOG.md
git commit -q -m "chore(release): $next"
git tag -a "$next" -m "$next"

note "committed and tagged: $next"
note "next steps:"
note "  git push origin master --follow-tags"
note "  (after the tarball is published) compute the sha256 and update Formula/brew-autosign.rb"
