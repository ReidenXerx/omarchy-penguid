#!/bin/bash

# Compare the Omarchy plugins PenguID is based on (the lock screen and the polkit dialog) with the ones Omarchy ships
# now. Exit 0 when they match, 1 when Omarchy changed one (merge those changes into ours), 2 on errors.

set -u

root="$(dirname "$(readlink -f "$0")")/.."
base_version="4.0.3"
shell_plugins="${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins"
version=$(pacman -Q omarchy 2>/dev/null | awk '{print $2}')

echo "installed omarchy: ${version:-unknown}; plugins based on: $base_version"

status=0
compare() {
  local plugin="$1" file base installed
  shift
  for file in "$@"; do
    base="$root/upstream/omarchy-$base_version/$plugin/$file"
    installed="$shell_plugins/$plugin/$file"
    if [[ ! -f $installed ]]; then
      echo "missing in the installed shell: $installed"
      status=2
      continue
    fi
    if cmp -s "$base" "$installed"; then
      echo "unchanged: $plugin/$file"
    else
      echo "CHANGED: $plugin/$file"
      diff -u "$base" "$installed" | head -80
      (( status == 2 )) || status=1
    fi
  done
}

compare lock Service.qml LockView.qml manifest.json
compare polkit PolkitAgent.qml PolkitModel.js manifest.json

exit $status
