#!/usr/bin/env bash
# One-line installer: downloads a pinned release of the sync and runs setup.sh.
#   bash <(curl -fsSL https://raw.githubusercontent.com/bitwarden-labs/bw-gws-scim-sync/v1.0.0/install.sh)
# Works in Google Cloud Shell or any terminal with gcloud, python3, curl and tar.
# Options (environment variables): BW_SYNC_REF (tag, branch or commit; default below),
# BW_SYNC_DIR (default ~/bw-gws-scim-sync), BW_SYNC_SKIP_SETUP=1 (download only).
# Everything is inside main(), which runs only once the whole file has downloaded.
set -euo pipefail

VERSION=v1.0.0
REPO=bitwarden-labs/bw-gws-scim-sync
TMP=""
trap '[[ -n "$TMP" ]] && rm -rf "$TMP"' EXIT

main() {
  local ref=${BW_SYNC_REF:-$VERSION}
  local dir=${BW_SYNC_DIR:-$HOME/bw-gws-scim-sync}
  dir=${dir%/}

  local missing=() cmd
  for cmd in gcloud python3 curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} )); then
    echo "Missing: ${missing[*]}. Install them, or run this in Google Cloud Shell, which has them." >&2
    exit 1
  fi

  # Only ever replace a folder that holds an earlier copy of this tool.
  if [[ -e "$dir" && ! ( -f "$dir/setup.sh" && -f "$dir/select-groups.sh" ) ]]; then
    echo "$dir exists and isn't a copy of this tool. Move it, or set BW_SYNC_DIR to another folder." >&2
    exit 1
  fi

  local parent
  parent=$(dirname "$dir")
  mkdir -p "$parent"
  TMP=$(mktemp -d "$parent/.bw-gws-scim-sync.XXXXXX")

  echo "Downloading $REPO ($ref)..."
  if ! download "$ref" "$TMP/src.tar.gz"; then
    cat >&2 <<MSG
Couldn't download $REPO at "$ref".
  - Check that the version exists: https://github.com/$REPO/tags
  - If the repository isn't public, sign in to GitHub first and run this again:  gh auth login
MSG
    exit 1
  fi
  mkdir "$TMP/new"
  tar -xzf "$TMP/src.tar.gz" -C "$TMP/new" --strip-components 1
  [[ -f "$TMP/new/setup.sh" ]] || { echo "The download doesn't contain setup.sh." >&2; exit 1; }

  if [[ -e "$dir" ]]; then
    # Keep the Python libraries select-groups.sh installed, so it doesn't reinstall them.
    if [[ -d "$dir/.venv" ]]; then mv "$dir/.venv" "$TMP/new/.venv"; fi
    rm -rf "$dir"
    echo "Updated $dir to $ref."
  else
    echo "Installed in $dir."
  fi
  mv "$TMP/new" "$dir"

  if [[ "${BW_SYNC_SKIP_SETUP:-}" == 1 ]]; then
    echo "Next: cd $dir && bash setup.sh"
    return
  fi

  echo
  cd "$dir"
  # With "curl ... | bash", standard input is the download, so read the answers from the terminal.
  if [[ -t 0 ]] || ! { : < /dev/tty; } 2>/dev/null; then
    bash setup.sh
  else
    bash setup.sh < /dev/tty
  fi
}

download() {  # download REF FILE: public download first, then the signed-in GitHub CLI
  local ref=$1 out=$2
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$ref" -o "$out" 2>/dev/null && return 0
  command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 || return 1
  echo "Public download failed; using your GitHub sign-in (gh)."
  gh api "repos/$REPO/tarball/$ref" > "$out"
}

main "$@"
