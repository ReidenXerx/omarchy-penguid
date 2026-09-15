<h1 align="center"><img src="assets/penguid-wordmark.svg" alt="PenguID" width="420"></h1>

Face unlock for Omarchy. Open the lid, look at the screen, and you're in: a lock screen that recognizes you with the IR camera, plus face for sudo and polkit. The password always works, and it stays the first unlock after boot. Project page: https://duduphudu.app/omarchy-penguid/

It replaces the built-in lock screen (`clonedFrom: omarchy.lock`) and keeps its password and fingerprint lanes unchanged. Next to them it runs a third PAM service, `omarchy-lock-face`:

- A scan starts after fresh activity on the locked screen: a key, a click or tap, the pointer waking a blanked screen, or reopening the lid. It never starts right after you lock.
- Each activation gets three tries, then the camera stays off until the next activity.
- Closing the lid stops the scan.
- Typing your password works at any moment and never waits for the camera.
- Above the field, the PenguID mark shows what face unlock is doing: its corners breathe in amber while irlume looks, it winks in green on a match (the unlock waits 0.45 s so you see it), its eyes go flat in red after a refusal, and it dims while the password rules pause face. The field says "Looking for you…" during a scan, and the screen stays lit.

## Password rules

As with Face ID, face unlock pauses when:

- **48 hours without the password.** Your login at the login screen counts, and so does every password you type on the lock screen, in the PenguID panel, or at a sudo or polkit prompt. Fingerprint and face unlocks don't.
- **5 refusals in a row.** Only lock screen attempts where a face was seen and refused count; an empty view doesn't.

While face is paused, the lock screen's field says "Password required", the panel asks for your password, and sudo and polkit skip face and pass on a short note saying why. Typing the password resets both rules. If the last password use can't be established (for example, the session's login time is unreadable and no state file exists yet), face stays off until the password is typed. The state lives in `~/.local/state/penguid/state.json`; it only protects against someone at the locked screen, not against software already running as you.

`tools/check-upstream.sh` compares the Omarchy lock screen and polkit dialog PenguID is based on (`upstream/omarchy-4.0.3/`) with the ones Omarchy ships now. Run it after Omarchy updates, and merge any changes it reports.

## sudo and polkit

`tools/privileged-pam.sh` adds face to sudo and polkit prompts, or takes it out again:

```
tools/privileged-pam.sh status
sudo tools/privileged-pam.sh enable
sudo tools/privileged-pam.sh disable
```

At a prompt you see "Press Enter for face, or type your password". Press Enter and look at the screen, or type your password as usual; if face doesn't match, the password prompt follows. While face runs, the face HUD (below) shows the mark above every window. With the lid closed or face paused, you get the plain password prompt. After an accepted password, one more line notes the time, which turns face back on for 48 hours. The login screens are left alone on purpose.

`enable` does four things:

- builds `pam/pam_penguid.c` into `/usr/lib/security/pam_penguid.so`, the small module behind the Enter prompt, which only checks whether the answer is empty, and which tells the face HUD when face starts, matches or is refused;
- installs the rules check as `/usr/local/lib/penguid/pam-gate`, owned by root because PAM runs it as root; it switches to your account before it reads or writes your state;
- adds `/etc/systemd/system/polkit-agent-helper@.service.d/penguid.conf`, because polkit runs its password step in a sandbox that hides `/home`; the drop-in shows that sandbox only `~/.local/state/penguid` and the HUD's socket folder `/run/user/UID/penguid`;
- wires sudo and polkit-1, then turns irlume's own "type yes" confirmation off (`irlume auth consent hands-free`), since the Enter prompt now asks first.

`disable` turns irlume's confirmation back on first, then removes the rest.

Three limits to know. Faces refused at sudo or polkit don't count toward the 5, because irlume reports every miss to PAM the same way. Anything that answers the prompt can press Enter, including software already running as you, so a face here proves you're at the screen, not that you meant to approve. And irlume's consent switch is machine-wide: a privileged PAM stack that runs irlume without PenguID's Enter prompt would scan straight away.

## Face HUD

Face unlock shows itself the way Face ID does on iOS: a small card with the PenguID mark, above every window and fullscreen app. It appears whenever face runs outside the lock screen, at a sudo or polkit prompt or with the panel's Test my face. The corners breathe in amber while irlume looks, a match winks in green, and a refusal shows flat red eyes with a shake, before the card fades. It never takes a click or a key, and it stays away while the lock screen, which has its own mark, is up.

The HUD listens on `/run/user/UID/penguid/hud.sock`, in a folder only you can open. `pam_penguid.so` writes one line per step there (`looking sudo`, `granted polkit-1`, `refused sudo`), checking the path and connecting with your file permissions, and without ever blocking the login step. `omarchy-shell penguid hud looking` (or `granted`, `refused`, `hide`) shows a state by hand.

## The polkit dialog

`polkit/` holds a second plugin, `reidenxerx.penguid-polkit`: Omarchy's polkit dialog (`clonedFrom: omarchy.polkit`) that words each step: "Press Enter for face", "Looking for you...", and "Type your password" when face didn't match. The face HUD draws the mark above it. PAM's notes, such as irlume's "look at the camera" or why face is paused, show under the card.

```
cp -r polkit ~/.config/omarchy/plugins/reidenxerx.penguid-polkit
cp LICENSE NOTICE ~/.config/omarchy/plugins/reidenxerx.penguid-polkit/
omarchy-shell shell rescanPlugins
omarchy plugin enable reidenxerx.penguid-polkit    # replaces Omarchy's polkit dialog
```

Only one polkit agent can register per session. If another one starts first, such as hyprpolkitagent, the shell logs "An authentication agent already exists" and the other dialog keeps showing: stop that agent and restart the shell.

## Requirements

- [irlume](https://github.com/archledger/irlume) installed, with your face enrolled (`irlume enroll`). PenguID was developed with irlume's IR-only mode (`sudo irlume auth sensor ir-only --yes`), where an attempt takes about 3.6 s.
- `/etc/pam.d/omarchy-lock-face`. The face indicator and the lane only appear while this file exists:

```
#%PAM-1.0
auth       sufficient                  pam_irlume.so
auth       required                    pam_deny.so
account    include                     system-local-login
```

## Enable, disable, recover

```
omarchy-shell shell rescanPlugins
omarchy plugin enable reidenxerx.penguid     # replaces the built-in lock screen
omarchy plugin disable reidenxerx.penguid    # brings the built-in lock screen back
```

Restart the shell (`omarchy restart shell`) after changing QML files; hot reload does not apply them.

If the lock screen ever fails to show or won't unlock:

1. Switch to a TTY (Ctrl+Alt+F3) and log in.
2. Run `omarchy plugin disable reidenxerx.penguid --yes`.
3. Switch back (Ctrl+Alt+F1 or F2). Omarchy's stranded-lock recovery locks again with the built-in screen after a shell restart, and your password unlocks it.

`omarchy-shell lock previewFace looking` shows the lock preview with the mark in one mood (ready, looking, granted, refused or paused); `omarchy-shell lock hidePreview` closes it. `omarchy-shell lock status` (or `qs ipc call lock status`) reports `impl`, `face`, `faceAuthenticating` and `faceAttempts`. The lock log lines (`omarchy lock … face-attempt 1`, `face-granted`, `face-refused`, `face-stop: …`) go to the shell's log.

## Tests

```
node tests/model-test.js
node tests/polkit-test.js
python3 tests/pam-gate-test.py
```

## Credits

See NOTICE. The lock screen and the polkit dialog are Omarchy's (MIT). The face lane comes from Omarchy PR #6863 by @mateuszkowalczyk. Face authentication is done by irlume. This plugin is GPL-3.0-or-later.

## Support

Like PenguID? Support its development: https://donatello.to/DuduPhudu
