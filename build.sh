#!/bin/bash
# shellcheck disable=SC2024,SC2154

set -o errexit -o pipefail -o nounset

# Inputs
pkgname=$INPUT_PKGNAME
pkgbuild=$INPUT_PKGBUILD
assets=$INPUT_ASSETS
asset_dir=$INPUT_ASSET_DIR
use_source_files=$INPUT_USE_SOURCE_FILES
updpkgsums=$INPUT_UPDPKGSUMS
auto_pkgver=$INPUT_AUTO_PKGVER
reset_pkgrel_on_autopkgver=$INPUT_RESET_PKGREL_ON_AUTOPKGV
test=$INPUT_TEST
auto_install_deps=$INPUT_AUTO_INSTALL_DEPS
read -r -a test_flags <<< "${INPUT_TEST_FLAGS:-}"
pre_script=$INPUT_PRE_SCRIPT
post_process=$INPUT_POST_PROCESS
commit_username=$INPUT_COMMIT_USERNAME
commit_email=$INPUT_COMMIT_EMAIL
ssh_private_key=$INPUT_SSH_PRIVATE_KEY
commit_message=$INPUT_COMMIT_MESSAGE
allow_empty_commits=$INPUT_ALLOW_EMPTY_COMMITS
force_push=$INPUT_FORCE_PUSH
ssh_keyscan_types=$INPUT_SSH_KEYSCAN_TYPES

export HOME=/home/builder
GLOBIGNORE=".:.."

err() { echo "::error::$*"; exit 1; }
note() { echo "::notice::$*"; }

assert_non_empty() {
  [[ -n "$2" ]] || err "Invalid Value: $1 is empty."
}

pkgbuild=${pkgbuild:-./PKGBUILD}
[[ -f "$pkgbuild" ]] || err "PKGBUILD not found at: $pkgbuild"

# Auto-detect pkgname (handles split packages too)
if [[ -z "$pkgname" ]]; then
  pkgname=$(
    bash -lc "
      set -eo pipefail
      source \"$pkgbuild\"
      if declare -p pkgname 2>/dev/null | grep -q 'declare -a'; then
        printf '%s' \"\${pkgname[0]}\"
      else
        printf '%s' \"\$pkgname\"
      fi
    "
  )
  [[ -n "$pkgname" ]] || err "Could not detect pkgname from $pkgbuild"
  note "Auto-detected pkgname=$pkgname"
fi

assert_non_empty inputs.commit_username "$commit_username"
assert_non_empty inputs.commit_email "$commit_email"
assert_non_empty inputs.ssh_private_key "$ssh_private_key"

# conflicting inputs
if [[ -n "$asset_dir" && -n "$assets" ]]; then
  err "inputs.asset_dir conflicts with inputs.assets. Please use only one."
fi

echo '::group::Adding aur.archlinux.org to known hosts'
mkdir -p ~/.ssh
ssh-keyscan -v -t "$ssh_keyscan_types" aur.archlinux.org >>~/.ssh/known_hosts
echo '::endgroup::'

echo '::group::Importing private key'
echo "$ssh_private_key" >~/.ssh/aur
chmod -vR 600 ~/.ssh/aur*
ssh-keygen -vy -f ~/.ssh/aur >~/.ssh/aur.pub
echo '::endgroup::'

echo '::group::Checksums of SSH keys'
sha512sum ~/.ssh/aur ~/.ssh/aur.pub
echo '::endgroup::'

echo '::group::Configuring Git'
git config --global user.name "$commit_username"
git config --global user.email "$commit_email"
echo '::endgroup::'

echo '::group::Cloning AUR package into /tmp/local-repo'
git clone -v "https://aur.archlinux.org/${pkgname}.git" /tmp/local-repo
echo '::endgroup::'

workspace=${GITHUB_WORKSPACE:-/github/workspace}

copy_pkgbuilder_files() {
  # Always copy PKGBUILD
  echo "Copying $pkgbuild"
  cp -v "$pkgbuild" /tmp/local-repo/PKGBUILD

  # Optionally copy local files referenced by source=()
  if [[ "$use_source_files" == "true" ]]; then
    echo "Collecting local source=() files"
    mapfile -t local_sources < <(bash -lc '
      set -eo pipefail
      shopt -s extglob nullglob
      source "'"$pkgbuild"'"
      for s in "${source[@]}"; do
        # strip "name::" prefix if present
        t=${s##*::}
        # copy if it looks like a local path (no scheme://)
        if [[ "$t" != *"://"* && "$t" != git+* && "$t" != hg+* && "$t" != svn+* ]]; then
          printf "%s\n" "$t"
        fi
      done
    ')
    if ((${#local_sources[@]})); then
      echo "Copying local sources: ${local_sources[*]}"
      # shellcheck disable=SC2086
      cp -rvt /tmp/local-repo/ ${local_sources[@]}
    fi
  fi

  # Legacy "assets" (glob expansion)
  if [[ -n "$assets" ]]; then
    echo 'Copying' $assets
    # shellcheck disable=SC2086
    cp -rvt /tmp/local-repo/ $assets
  fi
}

mirror_asset_dir() {
  local src="$asset_dir"
  [[ -d "$src" ]] || err "asset_dir does not exist: $src"

  echo "Mirroring $src -> /tmp/local-repo (respecting .gitignore)"
  pushd /tmp/local-repo >/dev/null

  # Stage deletions for files tracked in AUR repo but missing from asset_dir
  while IFS= read -r -d '' f; do
    if [[ ! -e "$workspace/$src/$f" ]]; then
      git rm -f -- "$f" || true
    fi
  done < <(git ls-tree -r --name-only -z HEAD)

  popd >/dev/null

  # Copy files included by the workspace Git index (respects .gitignore)
  # If the workspace is not a Git repo, fall back to rsync of all files.
  if git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
      dest="/tmp/local-repo/${f#"$src/"}"
      mkdir -p "$(dirname "$dest")"
      cp -av "$workspace/$f" "$dest"
    done < <(git -C "$workspace" ls-files -z -- "$src")
  else
    rsync -a --delete --exclude='.git/' "$src/" /tmp/local-repo/
  fi
}

maybe_update_pkgver() {
  [[ "$auto_pkgver" == "true" ]] || return 0
  echo '::group::Auto-updating pkgver via pkgver()'
  pushd /tmp/local-repo >/dev/null
  # Prepare sources so pkgver() can inspect them
  makepkg -od --noconfirm --nodeps
  # Run pkgver() in a subshell with expected env
  newver=$(bash -lc '
    set -eo pipefail
    srcdir="$PWD/src"; pkgdir="$PWD/pkg"
    source PKGBUILD
    if declare -F pkgver >/dev/null; then
      pkgver
    else
      printf "%s" "$pkgver"
    fi
  ')
  oldver=$(bash -lc 'source PKGBUILD; printf "%s" "$pkgver"')
  if [[ -n "$newver" && "$newver" != "$oldver" ]]; then
    sed -i -E "s/^pkgver=.*/pkgver=$newver/" PKGBUILD
    if [[ "$reset_pkgrel_on_autopkgver" == "true" ]]; then
      sed -i -E "s/^pkgrel=.*/pkgrel=1/" PKGBUILD
    fi
    echo "pkgver: $oldver -> $newver"
  else
    echo "pkgver unchanged ($oldver)"
  fi
  popd >/dev/null
  echo '::endgroup::'
}

maybe_updpkgsums() {
  if [[ "$updpkgsums" == "true" ]]; then
    echo '::group::Updating checksums'
    (cd /tmp/local-repo && updpkgsums)
    echo '::endgroup::'
  fi
}

install_build_deps() {
  echo '::group::Installing build dependencies (repo + AUR fallback)'
  cd /tmp/local-repo
  # Refresh package databases first
  sudo pacman -Syu --noconfirm --needed --ignore "" || true

  # Extract dep names from .SRCINFO (avoids sourcing arbitrary code)
  makepkg --printsrcinfo > .SRCINFO
  mapfile -t deps < <(awk -F' = ' '
    $1 ~ /^( +)?(depends|makedepends|checkdepends)$/ {print $2}
  ' .SRCINFO | sed -E 's/[<>=].*$//' | sed -E 's/:.*$//' | sort -u)

  for dep in "${deps[@]}"; do
    [[ -z "$dep" ]] && continue
    if pacman -Qi "$dep" >/dev/null 2>&1; then
      continue
    fi
    echo "::group::Installing dep: $dep"
    if sudo pacman -S --noconfirm --needed "$dep"; then
      :
    else
      echo "Falling back to AUR for $dep"
      tmp="/tmp/aurdeps/$dep"
      mkdir -p "$tmp"
      if git clone "https://aur.archlinux.org/${dep}.git" "$tmp"; then
        (cd "$tmp" && makepkg -si --noconfirm --needed --nocheck || err "Failed building AUR dep: $dep")
      else
        err "Unknown dep and not found on AUR: $dep"
      fi
    fi
    echo '::endgroup::'
  done
  echo '::endgroup::'
}

run_pre_script() {
  [[ -n "$pre_script" ]] || return 0
  echo "::group::Running pre_script: $pre_script"
  if [[ -x "$pre_script" ]]; then
    (cd /tmp/local-repo && "$workspace/$pre_script")
  else
    (cd /tmp/local-repo && bash "$workspace/$pre_script")
  fi
  echo "::endgroup::"
}

# Populate /tmp/local-repo
echo '::group::Copying files into /tmp/local-repo'
if [[ -n "$asset_dir" ]]; then
  mirror_asset_dir
else
  copy_pkgbuilder_files
fi
echo '::endgroup::'

maybe_update_pkgver
maybe_updpkgsums

if [[ "$test" == "true" ]]; then
  echo '::group::Testing build with makepkg'
  cd /tmp/local-repo/
  run_pre_script
  if [[ "$auto_install_deps" == "true" ]]; then
    install_build_deps
  fi
  if ((${#test_flags[@]})); then
    makepkg "${test_flags[@]}"
  else
    # Minimal default: no magic flags; user can pass their own
    makepkg
  fi
  echo '::endgroup::'
fi

echo '::group::Generating .SRCINFO'
(cd /tmp/local-repo && makepkg --printsrcinfo > .SRCINFO)
echo '::endgroup::'

if [[ -n "$post_process" ]]; then
  echo '::group::Executing post process commands'
  (cd /tmp/local-repo && eval "$post_process")
  echo '::endgroup::'
fi

echo '::group::Committing files to the repository'
cd /tmp/local-repo
if [[ -z "$assets" && -z "$asset_dir" && "$use_source_files" != "true" ]]; then
  git add -fv PKGBUILD .SRCINFO
else
  git add --all
fi

case "$allow_empty_commits" in
  true)  git commit --allow-empty -m "$commit_message" ;;
  false) git diff-index --quiet HEAD || git commit -m "$commit_message" ;;
  *)     err "Invalid Value: inputs.allow_empty_commits is neither 'true' nor 'false': '$allow_empty_commits'" ;;
esac
echo '::endgroup::'

echo '::group::Publishing the repository'
git remote add aur "ssh://aur@aur.archlinux.org/${pkgname}.git"
case "$force_push" in
  true)  git push -v --force aur master ;;
  false) git push -v aur master ;;
  *)     err "Invalid Value: inputs.force_push is neither 'true' nor 'false': '$force_push'" ;;
esac
echo '::endgroup::'
