#!/usr/bin/env bash
#       ____  __  ______________
#      / __ \/ / / /  _/ ___/__ \
#     / / / / /_/ // / \__ \__/ /
#    / /_/ / __  // / ___/ / __/
#   /_____/_/ /_/___//____/____/
#
#   Install or update dhis2-tools from GitHub.
#
#   First install:
#     curl -fsSL https://raw.githubusercontent.com/redmondking/dhis2-tools-ng/master/install.sh | sudo bash
#   Update (installed as dhis2-tools-update):
#     sudo dhis2-tools-update [--check [--json]] [-y] [--rollback]
#
#   Exit codes: 0 done or already up to date, 1 error, 2 update available (--check only)

set -euo pipefail

REPO=redmondking/dhis2-tools-ng
BRANCH=${DHIS2_TOOLS_BRANCH:-master}          # override only to test another branch, eg develop
DEST=${DHIS2_TOOLS_DEST:-/opt/dhis2-tools}    # override only for testing
BIN=${DHIS2_TOOLS_BIN:-/usr/local/bin}        # override only for testing

usage() {
  echo "Usage: $(basename "$0") [--check [--json]] [-y] [--rollback]"
  echo "  (no option)  install, or update to the latest version of $REPO ($BRANCH)"
  echo "  --check      only report whether an update is available (exit 2 if it is)"
  echo "  --json       with --check: print {\"branch\", \"current\", \"latest\", \"update_available\"} (exit codes unchanged)"
  echo "  -y           do not ask for confirmation"
  echo "  --rollback   go back to the previously installed version"
}

die() { echo "Error: $*" >&2; exit 1; }

# Create /usr/local/bin links for the admin commands, and drop links whose target is gone.
# Existing regular files (copies made by older versions) are left alone: dhis2-upgrade-setup replaces them.
link_commands() {
  local NAME TARGET L
  mkdir -p "$BIN"
  while read -r NAME TARGET; do
    if [[ -e $BIN/$NAME && ! -L $BIN/$NAME ]]; then
      echo "Note: $BIN/$NAME is an old copy, dhis2-upgrade-setup will replace it"
      continue
    fi
    ln -sfn "$DEST/$TARGET" "$BIN/$NAME"
  done < <(
    printf '%s %s\n' dhis2-setup lxd_setup.sh dhis2-ssl-setup ssl_setup.sh \
      dhis2-upgrade-setup upgrade_setup.sh dhis2-tools-update install.sh
    for F in "$DEST"/service/*; do printf '%s service/%s\n' "$(basename "$F")" "$(basename "$F")"; done
  )
  for L in "$BIN"/dhis2-*; do
    [[ -L $L && ! -e $L && $(readlink "$L") == "$DEST"/* ]] && rm "$L"
  done
  return 0
}

main() {
  local CHECK=false YES=false ROLLBACK=false JSON=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --check) CHECK=true ;;
      --json) JSON=true ;;
      -y|--yes) YES=true ;;
      --rollback) ROLLBACK=true ;;
      --relink) link_commands; exit 0 ;;   # used by dhis2-upgrade-setup
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 1 ;;
    esac
    shift
  done

  [[ $JSON == false || $CHECK == true ]] || die "--json is only for --check"
  [[ $EUID -eq 0 || -n ${DHIS2_TOOLS_DEST:-} ]] || die "please run with sudo"

  # When piped from curl, stdin is this script: take answers from the terminal if there is one
  if [[ ! -t 0 ]]; then
    if (exec </dev/tty) 2>/dev/null; then exec </dev/tty; else exec </dev/null; fi
  fi

  if [[ $ROLLBACK == true ]]; then
    [[ -d $DEST.old ]] || die "no previous version in $DEST.old"
    mv "$DEST" "$DEST.rollback" && mv "$DEST.old" "$DEST" && mv "$DEST.rollback" "$DEST.old"
    link_commands
    echo "Rolled back to $(cut -c1-7 "$DEST/VERSION"). Run it again to undo the rollback."
    exit 0
  fi

  local LATEST CURRENT=""
  LATEST=$(curl -fsSL -H 'Accept: application/vnd.github.sha' \
    "https://api.github.com/repos/$REPO/commits/$BRANCH") || die "could not reach GitHub"
  [[ $LATEST =~ ^[0-9a-f]{40}$ ]] || die "unexpected answer from GitHub: $LATEST"
  [[ -f $DEST/VERSION ]] && CURRENT=$(cut -d' ' -f1 "$DEST/VERSION")

  if [[ $JSON == true ]]; then
    local AVAILABLE=true
    [[ $CURRENT == "$LATEST" ]] && AVAILABLE=false
    printf '{"branch": "%s", "current": %s, "latest": "%s", "update_available": %s}\n' \
      "$BRANCH" "$( [[ -n $CURRENT ]] && echo "\"$CURRENT\"" || echo null )" "$LATEST" "$AVAILABLE"
    [[ $AVAILABLE == true ]] && exit 2
    exit 0
  fi

  if [[ $CURRENT == "$LATEST" ]]; then
    echo "dhis2-tools is up to date (${LATEST:0:7}, $BRANCH)"
    exit 0
  fi

  if [[ -n $CURRENT ]]; then
    echo "Update available: ${CURRENT:0:7} -> ${LATEST:0:7} ($BRANCH)"
    if command -v jq >/dev/null; then
      curl -fsSL "https://api.github.com/repos/$REPO/compare/$CURRENT...$LATEST" 2>/dev/null \
        | jq -r '.commits[]? | "  " + .sha[0:7] + " " + (.commit.message | split("\n")[0])' || true
    fi
  else
    echo "Installing dhis2-tools ${LATEST:0:7} ($BRANCH) into $DEST"
  fi
  [[ $CHECK == true ]] && exit 2

  if [[ -n $CURRENT && $YES == false ]]; then
    [[ -t 0 ]] || die "no terminal to confirm the update: run with -y"
    local ANSWER
    read -r -p "Install this update? [Y/n] " ANSWER
    [[ $ANSWER =~ ^[Nn] ]] && { echo "Aborted"; exit 1; }
  fi

  # download and unpack into $DEST.new; nothing in $DEST changes until it is complete
  local SRC
  TMP=$(mktemp -d)   # global: the EXIT trap runs after main returns
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL "https://github.com/$REPO/archive/$LATEST.tar.gz" -o "$TMP/src.tar.gz" || die "download failed"
  tar -xzf "$TMP/src.tar.gz" -C "$TMP" --no-same-owner
  SRC=$(find "$TMP" -mindepth 1 -maxdepth 1 -type d)
  [[ -f $SRC/install.sh && -f $SRC/setup/lxd_setup.sh && -d $SRC/setup/service ]] || die "download is incomplete"

  rm -rf "$DEST.new"
  mkdir -p "$DEST.new"
  cp -a "$SRC/setup/." "$DEST.new/"
  cp "$SRC/install.sh" "$DEST.new/"
  rm -rf "$DEST.new/misc"
  echo "$LATEST $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DEST.new/VERSION"

  if [[ -d $DEST ]]; then
    rm -rf "$DEST.old"
    mv "$DEST" "$DEST.old"
  fi
  mv "$DEST.new" "$DEST"
  link_commands
  echo "Installed ${LATEST:0:7}"

  # a server that is already set up gets any migrations the new version brings
  if [[ -f /usr/local/etc/dhis/containers.json && -z ${DHIS2_TOOLS_DEST:-} ]]; then
    echo "Applying updates to this server's setup"
    if [[ $YES == true ]]; then "$DEST/upgrade_setup.sh" -y; else "$DEST/upgrade_setup.sh"; fi
  elif [[ -z $CURRENT ]]; then
    echo
    echo "Next: describe this server in /usr/local/etc/dhis/containers.json"
    echo "(start from $DEST/configs/containers.json.sample), then run: sudo dhis2-setup"
  fi
}

# everything runs from main, so bash has read the whole script before it starts (safe with curl | bash)
main "$@"
