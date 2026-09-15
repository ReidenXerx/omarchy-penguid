#!/bin/bash

# Wire face authentication (irlume) into sudo and polkit, or take it out again.
# Usage: tools/privileged-pam.sh status | sudo tools/privileged-pam.sh enable|disable
#
# It adds irlume's standard lines (crates/irlume-cli/src/pamwire/stanzas.rs) above the existing password stack, which
# stays as it is. Omarchy's lid-closed check comes first, the same way its fingerprint setup does it: with the lid shut
# the face line is skipped. irlume asks you to type "yes" for one face attempt; any other input is used as your
# password. The login screens are left alone on purpose, so the password stays the first unlock after boot.

set -euo pipefail

# The "face-unlock" tag, backup suffix and note file keep the project's working name on purpose: files wired before
# the rename to PenguID carry it, and status/disable look for these exact strings.
marker="# face-unlock: face via irlume (type yes); the password still works. Undo: tools/privileged-pam.sh disable"
gate="auth       [success=1 default=ignore]  pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed"
sudo_face="auth       sufficient                  pam_irlume.so"
polkit_face="auth       [success=done new_authtok_reqd=done abort=die default=ignore]   pam_irlume.so"
backup_suffix=".pre-face-unlock"
polkit_vendor="/usr/lib/pam.d/polkit-1"
polkit_materialized_note="/etc/pam.d/.polkit-1.face-unlock-materialized"

wired() {
  grep -q -F -x "$marker" "$1" 2>/dev/null
}

need_root() {
  if (( EUID != 0 )); then
    echo "run this with sudo" >&2
    exit 1
  fi
}

# Write TARGET as SOURCE with the marker, gate and FACE line placed before its first auth line.
write_wired() {
  local target="$1" source="$2" face="$3" tmp
  tmp=$(mktemp "/etc/pam.d/.face-unlock.XXXXXX")
  if ! awk -v marker="$marker" -v gate="$gate" -v face="$face" '
    !done && /^[[:space:]]*auth[[:space:]]/ { print marker; print gate; print face; done = 1 }
    { print }
    END { if (!done) exit 3 }
  ' "$source" > "$tmp"; then
    rm -f "$tmp"
    echo "no auth line found in $source; nothing changed" >&2
    exit 1
  fi
  chmod 0644 "$tmp"
  mv -f "$tmp" "$target"
}

# Remove exactly the three lines this script adds, keeping anything else changed since.
write_unwired() {
  local target="$1" tmp
  tmp=$(mktemp "/etc/pam.d/.face-unlock.XXXXXX")
  grep -v -F -x -e "$marker" -e "$gate" -e "$sudo_face" -e "$polkit_face" "$target" > "$tmp" || true
  chmod 0644 "$tmp"
  mv -f "$tmp" "$target"
}

status() {
  local file
  for file in /etc/pam.d/sudo /etc/pam.d/polkit-1; do
    if wired "$file"; then
      echo "$file: face wired"
    elif [[ -f $file ]]; then
      echo "$file: not wired"
    else
      echo "$file: absent (the vendor copy applies)"
    fi
  done
}

enable() {
  need_root
  [[ -f /usr/lib/security/pam_irlume.so ]] || { echo "pam_irlume.so is not installed" >&2; exit 1; }

  if wired /etc/pam.d/sudo; then
    echo "sudo: already wired"
  else
    cp -a /etc/pam.d/sudo "/etc/pam.d/sudo$backup_suffix"
    write_wired /etc/pam.d/sudo "/etc/pam.d/sudo$backup_suffix" "$sudo_face"
    echo "sudo: wired (backup /etc/pam.d/sudo$backup_suffix)"
  fi

  if wired /etc/pam.d/polkit-1; then
    echo "polkit-1: already wired"
  elif [[ -f /etc/pam.d/polkit-1 ]]; then
    cp -a /etc/pam.d/polkit-1 "/etc/pam.d/polkit-1$backup_suffix"
    write_wired /etc/pam.d/polkit-1 "/etc/pam.d/polkit-1$backup_suffix" "$polkit_face"
    echo "polkit-1: wired (backup /etc/pam.d/polkit-1$backup_suffix)"
  else
    write_wired /etc/pam.d/polkit-1 "$polkit_vendor" "$polkit_face"
    : > "$polkit_materialized_note"
    echo "polkit-1: wired (override created from $polkit_vendor)"
  fi
}

disable() {
  need_root

  if wired /etc/pam.d/sudo; then
    write_unwired /etc/pam.d/sudo
    echo "sudo: face lines removed"
  else
    echo "sudo: not wired"
  fi

  if wired /etc/pam.d/polkit-1; then
    write_unwired /etc/pam.d/polkit-1
    if [[ -f $polkit_materialized_note ]] && cmp -s /etc/pam.d/polkit-1 "$polkit_vendor"; then
      rm -f /etc/pam.d/polkit-1 "$polkit_materialized_note"
      echo "polkit-1: override removed (the vendor copy applies again)"
    else
      echo "polkit-1: face lines removed"
    fi
  else
    echo "polkit-1: not wired"
  fi
}

case "${1:-}" in
  status) status ;;
  enable) enable ;;
  disable) disable ;;
  *)
    echo "usage: $0 status|enable|disable" >&2
    exit 2
    ;;
esac
