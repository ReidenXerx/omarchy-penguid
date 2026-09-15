// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * pam_penguid: "Press Enter for face, or type your password", and the signals behind PenguID's face HUD.
 *
 * tools/privileged-pam.sh builds this module and wires it three times into sudo and polkit:
 *
 *   auth    [success=ignore default=2]  pam_penguid.so           before irlume
 *   auth    optional                    pam_penguid.so refused   right after irlume
 *   account optional                    pam_penguid.so           first in the account stack
 *
 * The first line asks once. An empty answer clears the cached token, tells the HUD "looking" and returns
 * PAM_SUCCESS, so the stack goes on to irlume; if face fails, the password module after it asks afresh. Any other
 * answer stays cached as the password and the module returns PAM_IGNORE, which the control field turns into a jump
 * over irlume and the "refused" line, so the password module uses it at once.
 *
 * The "refused" line is only reached when irlume did not grant, and tells the HUD so. The account hook runs after a
 * successful authentication: when face was tried and not refused, face is what granted it, and the HUD hears
 * "granted".
 *
 * The HUD listens on /run/user/UID/penguid/hud.sock of the user being authenticated. The module checks that path and
 * connects with that user's filesystem identity, never blocks, and ignores every failure: a missing HUD changes
 * nothing about authentication. It keeps, copies and logs no password; it only checks whether the answer is empty.
 */
#define _GNU_SOURCE
#define PAM_SM_AUTH
#define PAM_SM_ACCOUNT
#include <pwd.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/fsuid.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <security/pam_ext.h>
#include <security/pam_modules.h>

#define PROMPT "Press Enter for face, or type your password: "
#define ATTEMPT_KEY "penguid_face_attempt"

static const char STARTED[] = "started";
static const char REFUSED[] = "refused";

static const char *attempt_state(pam_handle_t *pamh)
{
	const void *data = NULL;

	if (pam_get_data(pamh, ATTEMPT_KEY, &data) != PAM_SUCCESS)
		return NULL;
	return data;
}

/* Tell the user's HUD about STATE. Best effort: every failure is ignored. */
static void notify_hud(pam_handle_t *pamh, const char *state)
{
	const char *user = NULL;
	const char *service = NULL;
	struct passwd pwbuf;
	struct passwd *pw = NULL;
	char pwstrings[4096];
	char dir[64];
	char line[128];
	struct sockaddr_un addr;
	struct stat st;
	int fd, len;
	int old_fsuid, old_fsgid;

	if (pam_get_item(pamh, PAM_USER, (const void **)&user) != PAM_SUCCESS || user == NULL)
		return;
	if (getpwnam_r(user, &pwbuf, pwstrings, sizeof(pwstrings), &pw) != 0 || pw == NULL || pw->pw_uid == 0)
		return;
	if (pam_get_item(pamh, PAM_SERVICE, (const void **)&service) != PAM_SUCCESS || service == NULL)
		service = "";

	snprintf(dir, sizeof(dir), "/run/user/%u/penguid", (unsigned)pw->pw_uid);
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	if (snprintf(addr.sun_path, sizeof(addr.sun_path), "%s/hud.sock", dir) >= (int)sizeof(addr.sun_path))
		return;
	len = snprintf(line, sizeof(line), "%s %s\n", state, service);
	if (len <= 0 || len >= (int)sizeof(line))
		return;

	/* Check the path and connect as the user, so a planted symlink reaches nothing the user could not. */
	old_fsuid = setfsuid(pw->pw_uid);
	old_fsgid = setfsgid(pw->pw_gid);
	if (lstat(dir, &st) == 0 && S_ISDIR(st.st_mode) && st.st_uid == pw->pw_uid &&
	    lstat(addr.sun_path, &st) == 0 && S_ISSOCK(st.st_mode) && st.st_uid == pw->pw_uid) {
		fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
		if (fd >= 0) {
			if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0)
				(void)send(fd, line, (size_t)len, MSG_NOSIGNAL | MSG_DONTWAIT);
			close(fd);
		}
	}
	(void)setfsgid((gid_t)old_fsgid);
	(void)setfsuid((uid_t)old_fsuid);
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
	const char *token = NULL;
	int rc;

	(void)flags;

	if (argc > 0 && strcmp(argv[0], "refused") == 0) {
		if (attempt_state(pamh) == STARTED) {
			(void)pam_set_data(pamh, ATTEMPT_KEY, (void *)REFUSED, NULL);
			notify_hud(pamh, "refused");
		}
		return PAM_IGNORE;
	}

	rc = pam_get_authtok(pamh, PAM_AUTHTOK, &token, PROMPT);
	if (rc != PAM_SUCCESS)
		return rc;
	if (token != NULL && token[0] != '\0')
		return PAM_IGNORE;

	/* Enter: forget the empty answer, or the password module would try it instead of asking. */
	if (pam_set_item(pamh, PAM_AUTHTOK, NULL) != PAM_SUCCESS)
		return PAM_AUTHINFO_UNAVAIL;
	(void)pam_set_data(pamh, ATTEMPT_KEY, (void *)STARTED, NULL);
	notify_hud(pamh, "looking");
	return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
	(void)pamh;
	(void)flags;
	(void)argc;
	(void)argv;
	return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
	(void)flags;
	(void)argc;
	(void)argv;

	if (attempt_state(pamh) == STARTED) {
		(void)pam_set_data(pamh, ATTEMPT_KEY, NULL, NULL);
		notify_hud(pamh, "granted");
	}
	return PAM_IGNORE;
}
