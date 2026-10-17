#!/usr/bin/env python3
"""
Test the Gmail SMTP credential that `git send-email` uses, without involving
git.  It does what send-email does (STARTTLS on 587) and then sends AUTH PLAIN
itself, so you get the server's raw reply instead of git's one-liner.

    python3 ~/hda-mic-led/smtp-test.py
    python3 ~/hda-mic-led/smtp-test.py --login     # try AUTH LOGIN instead of PLAIN

The password is read with getpass() -- never echoed, never stored.  Spaces are
stripped, because Google displays app passwords as "abcd efgh ijkl mnop" but
the password itself contains no spaces.

Exit codes: 0 = accepted, 1 = rejected, 2 = connection/TLS problem.
"""
import base64
import getpass
import smtplib
import sys

HOST = "smtp.gmail.com"
PORT = 587
USER = "keanembae@gmail.com"

print(f"target: {HOST}:{PORT}  user: {USER}")
print("Paste the 16-character APP password (needs 2-Step Verification).")
print("It is not the Google account password.\n")

try:
    pw = getpass.getpass("app password: ")
except (EOFError, KeyboardInterrupt):
    print("\naborted", file=sys.stderr)
    sys.exit(2)

pw = "".join(pw.split())          # app passwords have no spaces, despite the display

if not pw:
    print("empty password -- did you hit Enter by accident?", file=sys.stderr)
    sys.exit(1)
if " " in pw:
    print("note: that still contains a space, which is wrong", file=sys.stderr)
if len(pw) != 16:
    print(f"note: an app password is 16 characters; this one is {len(pw)} -- "
          f"if it is your account password, that is the problem", file=sys.stderr)

try:
    s = smtplib.SMTP(HOST, PORT, timeout=20)
    s.ehlo()
    s.starttls()
    s.ehlo()
    print("STARTTLS ok; server advertises AUTH:", s.esmtp_features.get("auth", "?"))
    if "--login" in sys.argv:
        # AUTH LOGIN: send the username then the password as separate base64 lines
        code, resp = s.docmd("AUTH", "LOGIN")
        if code == 334:
            code, resp = s.docmd(base64.b64encode(USER.encode()).decode())
        if code == 334:
            code, resp = s.docmd(base64.b64encode(pw.encode()).decode())
        text = resp.decode(errors="replace")
        print(f"AUTH LOGIN -> {code} {text}")
    else:
        payload = base64.b64encode(b"\0" + USER.encode() + b"\0" + pw.encode()).decode()
        code, resp = s.docmd("AUTH", "PLAIN " + payload)
        text = resp.decode(errors="replace")
        print(f"AUTH PLAIN -> {code} {text}")
except smtplib.SMTPServerDisconnected:
    print("\nThe server closed the connection during AUTH.  Gmail does this on")
    print("repeated bad attempts as a throttle -- wait a few minutes and retry.")
    print("If it keeps happening with a brand new app password, the account is")
    print("probably blocked from app passwords (Workspace / Advanced Protection).")
    sys.exit(2)
except Exception as e:
    print(f"\nCONNECTION/TLS problem: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(2)

if code == 235:
    s.quit()
    print("\nACCEPTED -- these credentials work.")
    print("Re-run git send-email and paste the same password.")
    print("To avoid retyping it (held in memory only, expires):")
    print("  git config --global credential.helper 'cache --timeout=3600'")
    sys.exit(0)

print("""
REJECTED.  Causes, most likely first:
  1. 2-Step Verification is off -> Google has no app passwords at all, and the
     account password can never be used over SMTP.  Turn 2FA on:
       https://myaccount.google.com/security
  2. The app password is mistyped, or belongs to a different app, or was
     deleted.  Create a fresh one (shown only once):
       https://myaccount.google.com/apppasswords
  3. The account is managed (Workspace), or under Advanced Protection, which
     can block app passwords entirely.  Then use another account/provider.
""")
sys.exit(1)
