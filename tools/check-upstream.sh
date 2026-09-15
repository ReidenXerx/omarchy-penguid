#!/bin/bash

# Compare the Omarchy lock screen this plugin is based on with the one Omarchy ships now.
# Exit 0 when they match, 1 when Omarchy changed its lock screen (merge those changes into ours), 2 on errors.

set -u

root="$(dirname "$(readlink -f "$0")")/.."
base_version="4.0.3"
base="$root/upstream/omarchy-$base_version/lock"
installed="${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins/lock"
version=$(pacman -Q omarchy 2>/dev/null | awk '{print $2}')

echo "installed omarchy: ${version:-unknown}; plugin based on: $base_version"

status=0
for file in Service.qml LockView.qml manifest.json; do
  if [[ ! -f $installed/$file ]]; then
    echo "missing in the installed shell: $installed/$file"
    status=2
    continue
  fi
  if cmp -s "$base/$file" "$installed/$file"; then
    echo "unchanged: $file"
  else
    echo "CHANGED: $file"
    diff -u "$base/$file" "$installed/$file" | head -80
    (( status == 2 )) || status=1
  fi
done

exit $status
