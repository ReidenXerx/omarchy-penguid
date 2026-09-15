#!/bin/bash

# Wire face authentication (irlume) into sudo and polkit, or take it out again.
# Usage: tools/privileged-pam.sh status | sudo tools/privileged-pam.sh enable|disable
#
# It adds irlume's standard line (crates/irlume-cli/src/pamwire/stanzas.rs) above the existing password stack, which
# stays as it is, with PenguID's lines around it:
#   1. Omarchy's lid-closed check, as in Omarchy's fingerprint setup: with the lid shut, face is skipped.
#   2. The rules gate: while the password rules pause face (48 hours without the password, or 5 refused faces), it
#      says why and skips face.
#   3. pam_penguid.so asks "Press Enter for face, or type your password". Enter goes on to irlume and tells the face
#      HUD "looking"; a typed password skips face and goes straight to the password stack.
#   4. After irlume, pam_penguid.so tells the HUD "refused" when face did not grant; in the account stack it tells it
#      "granted" when face did.
# irlume's own "type yes" confirmation is switched off (irlume auth consent hands-free), because the Enter prompt now
# plays that part. A line after the password stack notes an accepted password, which turns face back on for 48
# hours. The login screens are left alone on purpose, so the password stays the first unlock after boot.
#
# polkit runs its PAM helper in a sandbox that hides /home and /run/user, so enable also adds a systemd drop-in that
# shows that helper PenguID's state folder and the HUD's socket folder, and nothing else from them.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
plugin_dir=$(dirname -- "$here")

# The "face-unlock" tag, backup suffix and note file keep the project's working name on purpose: files wired before
# the rename to PenguID carry it, and status/disable look for these exact strings.
marker="# face-unlock: face via irlume (press Enter); the password still works. Undo: tools/privileged-pam.sh disable"
gate_dir="/usr/local/lib/penguid"
gate_bin="$gate_dir/pam-gate"
module="/usr/lib/security/pam_penguid.so"
lid="auth       [success=4 default=ignore]  pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed"
rules="auth       [success=ignore ignore=ignore default=3]  pam_exec.so quiet stdout $gate_bin check"
enter="auth       [success=ignore default=2]  pam_penguid.so"
sudo_face="auth       sufficient                  pam_irlume.so"
polkit_face="auth       [success=done new_authtok_reqd=done abort=die default=ignore]   pam_irlume.so"
refused="auth       optional                    pam_penguid.so refused"
record="auth       optional                    pam_exec.so quiet $gate_bin record"
account="account    optional                    pam_penguid.so"
# Lines earlier versions wrote, removed on upgrade and by disable.
legacy=(
  "# face-unlock: face via irlume (type yes); the password still works. Undo: tools/privileged-pam.sh disable"
  "auth       [success=1 default=ignore]  pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed"
  "auth       [success=3 default=ignore]  pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed"
  "auth       [success=ignore ignore=ignore default=2]  pam_exec.so quiet stdout $gate_bin check"
  "auth       [success=ignore default=1]  pam_penguid.so"
)
backup_suffix=".pre-face-unlock"
polkit_vendor="/usr/lib/pam.d/polkit-1"
polkit_materialized_note="/etc/pam.d/.polkit-1.face-unlock-materialized"
helper_dropin_dir="/etc/systemd/system/polkit-agent-helper@.service.d"
helper_dropin="$helper_dropin_dir/penguid.conf"

# Wired by any version of this script.
wired() {
  grep -q -F -x -e "$marker" -e "${legacy[0]}" "$1" 2>/dev/null
}

# Wired by this version.
current() {
  local line
  for line in "$marker" "$lid" "$rules" "$enter" "$refused" "$record" "$account"; do
    grep -q -F -x -- "$line" "$1" 2>/dev/null || return 1
  done
}

need_root() {
  if (( EUID != 0 )); then
    echo "run this with sudo" >&2
    exit 1
  fi
}

# The account that ran sudo, whose face, state and HUD the lines serve: prints "HOME UID".
target_user() {
  local user="${SUDO_USER:-}" home uid
  if [[ -z $user || $user == root ]]; then
    echo "run this with sudo from your own account" >&2
    exit 1
  fi
  home=$(getent passwd "$user" | cut -d: -f6)
  uid=$(id -u "$user")
  if [[ ! $home =~ ^/[A-Za-z0-9._/-]+$ || ! $uid =~ ^[0-9]+$ ]]; then
    echo "unexpected home directory or uid for $user: $home $uid" >&2
    exit 1
  fi
  printf '%s %s\n' "$home" "$uid"
}

# Write TARGET as SOURCE with PenguID's auth lines around FACE before its first auth line, the record line after its
# last auth line, and the account line before its first account line.
write_wired() {
  local target="$1" source="$2" face="$3" tmp
  tmp=$(mktemp "/etc/pam.d/.face-unlock.XXXXXX")
  if ! awk -v marker="$marker" -v lid="$lid" -v rules="$rules" -v enter="$enter" -v face="$face" -v refused="$refused" \
      -v record="$record" -v account="$account" '
    NR == FNR { if (/^[[:space:]]*-?auth[[:space:]]/) last = FNR; next }
    !first && /^[[:space:]]*-?auth[[:space:]]/ { print marker; print lid; print rules; print enter; print face; print refused; first = 1 }
    !acct && /^[[:space:]]*-?account[[:space:]]/ { print account; acct = 1 }
    { print }
    FNR == last { print record }
    END { if (!first || !acct) exit 3 }
  ' "$source" "$source" > "$tmp"; then
    rm -f "$tmp"
    echo "no auth or account line found in $source; nothing changed" >&2
    exit 1
  fi
  chmod 0644 "$tmp"
  mv -f "$tmp" "$target"
}

# Remove exactly the lines any version of this script adds, keeping anything else changed since.
write_unwired() {
  local target="$1" tmp line args=()
  for line in "$marker" "${legacy[@]}" "$lid" "$rules" "$enter" "$sudo_face" "$polkit_face" "$refused" "$record" "$account"; do
    args+=(-e "$line")
  done
  tmp=$(mktemp "/etc/pam.d/.face-unlock.XXXXXX")
  grep -v -F -x "${args[@]}" "$target" > "$tmp" || true
  chmod 0644 "$tmp"
  mv -f "$tmp" "$target"
}

# Wire /etc/pam.d/NAME, upgrading a stanza from an older version of this script in place.
wire() {
  local name="$1" face="$2" file="/etc/pam.d/$1"
  if current "$file"; then
    echo "$name: already wired"
  elif wired "$file"; then
    write_unwired "$file"
    write_wired "$file" "$file" "$face"
    echo "$name: rewired (Enter prompt and HUD signals)"
  elif [[ -f $file ]]; then
    cp -a "$file" "$file$backup_suffix"
    write_wired "$file" "$file$backup_suffix" "$face"
    echo "$name: wired (backup $file$backup_suffix)"
  elif [[ $name == polkit-1 && -f $polkit_vendor ]]; then
    write_wired "$file" "$polkit_vendor" "$face"
    : > "$polkit_materialized_note"
    echo "$name: wired (override created from $polkit_vendor)"
  else
    echo "$file is missing; nothing changed" >&2
    exit 1
  fi
}

# Build pam_penguid.so in a private temporary directory and install it.
install_module() {
  local work
  command -v cc >/dev/null || { echo "cc is missing: install base-devel to build pam_penguid.so" >&2; exit 1; }
  work=$(mktemp -d)
  if ! cc -O2 -fPIC -shared -Wall -Wextra -Werror -fstack-protector-strong -D_FORTIFY_SOURCE=3 \
      -Wl,-z,relro,-z,now -o "$work/pam_penguid.so" "$plugin_dir/pam/pam_penguid.c" -lpam; then
    rm -rf "$work"
    echo "pam_penguid.so did not build; nothing changed" >&2
    exit 1
  fi
  install -o root -g root -m 0755 "$work/pam_penguid.so" "$module"
  rm -rf "$work"
}

# irlume's machine-wide switch for the "type yes" confirmation on privileged prompts.
irlume_consent() {
  env -u IRLUME_PRIVILEGED_FACE_CONSENT /usr/bin/irlume auth consent "$@"
}

# polkit's helper unit sets ProtectHome=yes, which also hides /run/user. Replace that with empty folders that show only
# PenguID's state folder and the HUD's socket folder.
write_helper_dropin() {
  local home="$1" uid="$2" tmp
  install -d -o root -g root -m 0755 "$helper_dropin_dir"
  tmp=$(mktemp "$helper_dropin_dir/.penguid.XXXXXX")
  printf '%s\n' \
    "# PenguID: polkit's PAM helper hides /home and /run/user. Show it only PenguID's state folder, so the password" \
    "# rules gate can read it and note an accepted password there, and the face HUD's socket folder, so face attempts" \
    "# show on screen. Undo: tools/privileged-pam.sh disable" \
    "[Service]" \
    "ProtectHome=tmpfs" \
    "BindPaths=-$home/.local/state/penguid" \
    "BindPaths=-/run/user/$uid/penguid" > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$helper_dropin"
  systemctl daemon-reload
}

status() {
  local file
  for file in /etc/pam.d/sudo /etc/pam.d/polkit-1; do
    if current "$file"; then
      echo "$file: face wired (press Enter), with the password rules and HUD signals"
    elif wired "$file"; then
      echo "$file: face wired by an older version (run enable again)"
    elif [[ -f $file ]]; then
      echo "$file: not wired"
    else
      echo "$file: absent (the vendor copy applies)"
    fi
  done
  if [[ ! -f $gate_bin ]]; then
    echo "$gate_bin: not installed"
  elif cmp -s "$gate_bin" "$here/penguid-pam-gate"; then
    echo "$gate_bin: installed"
  else
    echo "$gate_bin: differs from $here/penguid-pam-gate (run enable again)"
  fi
  if [[ -f $module ]]; then echo "$module: installed"; else echo "$module: not installed"; fi
  if [[ -f $helper_dropin ]]; then echo "$helper_dropin: present"; else echo "$helper_dropin: absent"; fi
  if (( EUID == 0 )); then
    irlume_consent status | head -n 1
  else
    echo "irlume consent: run status with sudo to read it"
  fi
}

enable() {
  need_root
  [[ -f /usr/lib/security/pam_irlume.so ]] || { echo "pam_irlume.so is not installed" >&2; exit 1; }
  [[ -f $here/penguid-pam-gate && -f $plugin_dir/pam/pam_penguid.c ]] || { echo "penguid-pam-gate or pam/pam_penguid.c is missing" >&2; exit 1; }
  local who home uid
  who=$(target_user)
  home=${who% *}
  uid=${who##* }

  # Everything the PAM lines point at goes in before the lines do.
  install -d -o root -g root -m 0755 "$gate_dir"
  install -o root -g root -m 0755 "$here/penguid-pam-gate" "$gate_bin"
  echo "rules gate: installed as $gate_bin"
  install_module
  echo "Enter prompt and HUD signals: installed as $module"
  runuser -u "$SUDO_USER" -- mkdir -p "$home/.local/state/penguid"
  write_helper_dropin "$home" "$uid"
  echo "polkit helper: sees only $home/.local/state/penguid and /run/user/$uid/penguid"

  wire sudo "$sudo_face"
  wire polkit-1 "$polkit_face"

  # Only once both stacks ask for Enter first may irlume skip its own confirmation.
  irlume_consent hands-free --yes >/dev/null
  echo "irlume consent: hands-free, because the Enter prompt comes first"
}

disable() {
  need_root

  # Put irlume's own confirmation back before the Enter prompt goes away.
  if irlume_consent required >/dev/null; then
    echo "irlume consent: type yes again (the default)"
  else
    echo "irlume consent: could not restore it; run: sudo irlume auth consent required" >&2
  fi

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

  if [[ -f $helper_dropin ]]; then
    rm -f "$helper_dropin"
    rmdir "$helper_dropin_dir" 2>/dev/null || true
    systemctl daemon-reload
    echo "polkit helper: sandbox back to normal"
  fi
  rm -f "$gate_bin" "$module"
  rmdir "$gate_dir" 2>/dev/null || true
  echo "rules gate, Enter prompt and HUD signals: removed"
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
