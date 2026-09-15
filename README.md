<h1 align="center"><img src="assets/penguid-wordmark.svg" alt="PenguID" width="420"></h1>

Face unlock for Omarchy. Open the lid, look at the screen, and you're in: a lock screen that recognizes you with the IR camera, plus face for sudo and polkit. The password always works, and it stays the first unlock after boot. The plan lives at https://claude.ai/code/artifact/462ec7f8-0a86-4c3c-9462-faae5548e959.

It replaces the built-in lock screen (`clonedFrom: omarchy.lock`) and keeps its password and fingerprint lanes unchanged. Next to them it runs a third PAM service, `omarchy-lock-face`:

- A scan starts after fresh activity on the locked screen: a key, a click or tap, the pointer waking a blanked screen, or reopening the lid. It never starts right after you lock.
- Each activation gets three tries, then the camera stays off until the next activity.
- Closing the lid stops the scan.
- Typing your password works at any moment and never waits for the camera.
- The password field shows "Looking for you…" and the face icon pulses while a scan runs. The screen stays lit during a scan.

## Password rules

As with Face ID, face unlock pauses and the field says "Password required" when:

- **48 hours without the password.** Your login at the login screen and every password unlock on the lock screen count. Fingerprint and face unlocks don't.
- **5 refusals in a row.** Only attempts where a face was seen and refused count; an empty view doesn't.

Typing the password resets both. If the last password use can't be established (for example, the session's login time is unreadable and no state file exists yet), face stays off until the password is typed. The state lives in `~/.local/state/penguid/state.json`; it only protects against someone at the locked screen, not against software already running as you.

`tools/check-upstream.sh` compares the Omarchy lock screen this plugin is based on (`upstream/omarchy-4.0.3/`) with the one Omarchy ships now. Run it after Omarchy updates, and merge any changes it reports.

## sudo and polkit

`tools/privileged-pam.sh` adds face to sudo and polkit prompts, or takes it out again:

```
tools/privileged-pam.sh status
sudo tools/privileged-pam.sh enable
sudo tools/privileged-pam.sh disable
```

It puts irlume's standard lines above the unchanged password stacks, behind Omarchy's lid-closed check. At a prompt you see "Type yes to use face authentication": type `yes` and look at the screen, or type your password as usual. With the lid closed, face is skipped. The login screens are left alone on purpose.

## Requirements

- [irlume](https://github.com/archledger/irlume) installed, with your face enrolled (`irlume enroll`). On this laptop it runs in IR-only mode (`sudo irlume auth sensor ir-only --yes`), which takes about 3.6 s per attempt.
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

`omarchy-shell lock status` (or `qs ipc call lock status`) reports `impl`, `face`, `faceAuthenticating` and `faceAttempts`. The lock log lines (`omarchy lock … face-attempt 1`, `face-granted`, `face-refused`, `face-stop: …`) go to the shell's log.

## Credits

See NOTICE. The lock screen is Omarchy's (MIT). The face lane comes from Omarchy PR #6863 by @mateuszkowalczyk. Face authentication is done by irlume. This plugin is GPL-3.0-or-later.
