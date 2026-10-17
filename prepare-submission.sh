#!/usr/bin/env bash
#
# prepare-submission.sh — regenerate the kernel patch with *your* identity, so
# nothing with a placeholder email ever reaches a mailing list.
#
# usage:
#   ./prepare-submission.sh -n "Your Real Name" -e you@example.com
#   ./prepare-submission.sh -n "Your Real Name" -e you@example.com -t
#   ./prepare-submission.sh -n "A" -e a@x -T "Tester <t@x>" -o /tmp/v2.patch
#
# options:
#   -n NAME          author name (default: git config user.name)
#   -e EMAIL         author email (default: git config user.email)
#   -t               add "Tested-by:" with the same identity — do this only
#                    after building/running the patched module (README 2b)
#   -T "Name <mail>" add a Tested-by trailer for someone else
#   -o FILE          output patch (default: 0001-* in this directory)
#   -c PATH          path to a kernel tree's scripts/checkpatch.pl
#
# What it does: takes the commit message out of the existing patch, strips the
# placeholder trailers, rebuilds the commit from src/alc269.c.upstream +
# apply-quirk.py with your author identity, regenerates the mailbox patch and
# runs checkpatch.pl --strict on the result.
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_PATCH="$(ls "$DIR"/0001-ALSA-hda-realtek-*.patch | head -1)"
OUT="$SRC_PATCH"
NAME="$(git config --get user.name || true)"
EMAIL="$(git config --get user.email || true)"
TESTED_SELF=0
TESTED_OTHER=""
CHECKPATCH=""

while getopts ":n:e:tT:o:c:h" opt; do
	case "$opt" in
	n) NAME="$OPTARG" ;;
	e) EMAIL="$OPTARG" ;;
	t) TESTED_SELF=1 ;;
	T) TESTED_OTHER="$OPTARG" ;;
	o) OUT="$OPTARG" ;;
	c) CHECKPATCH="$OPTARG" ;;
	h) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "unknown option; -h for help" >&2; exit 2 ;;
	esac
done

[[ -n "$NAME"  ]] || { echo "no author name: pass -n or set git config user.name" >&2; exit 1; }
[[ -n "$EMAIL" ]] || { echo "no author email: pass -e or set git config user.email" >&2; exit 1; }
case "$EMAIL" in
*REPLACE-ME*|*example.com|*example.org|*example.net)
	echo "refusing placeholder email '$EMAIL'" >&2; exit 1 ;;
esac
[[ -f "$DIR/src/alc269.c.upstream" ]] || { echo "src/alc269.c.upstream missing" >&2; exit 1; }

IDENTITY="$NAME <$EMAIL>"

# commit message = subject (de-folded, without "[PATCH] ") + blank + body,
# minus any existing trailers
MSG="$(awk '
	/^Subject:/ {
		sub(/^Subject: /, ""); sub(/^\[PATCH[^]]*\] /, "");
		subj = $0; state = 1; next
	}
	state == 1 {
		if ($0 == "") { state = 2; next }
		subj = subj $0; next
	}
	state == 2 {
		if ($0 == "---") exit
		n++; body[n] = $0
	}
	END {
		printf "%s\n\n", subj
		for (i = 1; i <= n; i++) print body[i]
	}
' "$SRC_PATCH" | sed -e '/^Signed-off-by:/d' -e '/^Tested-by:/d' -e '/^Reviewed-by:/d')"
[[ -n "$MSG" ]] || { echo "could not extract the commit message from $SRC_PATCH" >&2; exit 1; }
MSG="$(printf '%s\n' "$MSG" | awk '{ l[NR] = $0 } END {
	last = NR; while (last > 0 && l[last] == "") last--
	for (i = 1; i <= last; i++) print l[i] }')"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/sound/hda/codecs/realtek"
SRC_FILE="$WORK/sound/hda/codecs/realtek/alc269.c"
cp "$DIR/src/alc269.c.upstream" "$SRC_FILE"
git -C "$WORK" init -q .
git -C "$WORK" add -A
git -C "$WORK" -c user.name=base -c user.email=base@invalid commit -qm base

python3 "$DIR/apply-quirk.py" "$SRC_FILE" >/dev/null
if ! diff -q "$DIR/src/alc269.c" "$SRC_FILE" >/dev/null; then
	echo "!! patched file differs from src/alc269.c — investigate before sending" >&2
	exit 1
fi

{
	printf '%s\n' "$MSG"
	printf '\nSigned-off-by: %s\n' "$IDENTITY"
	[[ -n "$TESTED_OTHER" ]] && printf 'Tested-by: %s\n' "$TESTED_OTHER"
	(( TESTED_SELF )) && printf 'Tested-by: %s\n' "$IDENTITY"
} > "$WORK/.git/msg"

git -C "$WORK" add -A
git -C "$WORK" -c user.name="$NAME" -c user.email="$EMAIL" commit -qF "$WORK/.git/msg"
git -C "$WORK" format-patch -1 --stdout > "$WORK/out.patch"
cp "$WORK/out.patch" "$OUT"

echo "==> wrote $OUT"
echo "    from  : $(git -C "$WORK" log -1 --format='%an <%ae>')"
echo "    subject: $(git -C "$WORK" log -1 --format='%s')"
echo "    stat  : $(git -C "$WORK" show --stat --oneline HEAD | tail -1 | sed 's/^ *//')"
echo "==> trailers"
git -C "$WORK" log -1 --format='%b' | grep -E '^(Signed-off-by|Tested-by|Reviewed-by|Acked-by):' | sed 's/^/    /' || true

if [[ -z "$CHECKPATCH" ]]; then
	for c in "$DIR/checkpatch.pl" "$HOME/linux/scripts/checkpatch.pl" \
		 "$HOME/src/linux/scripts/checkpatch.pl" /tmp/ksubmit/checkpatch.pl; do
		[[ -f "$c" ]] && { CHECKPATCH="$c"; break; }
	done
fi
if [[ -n "$CHECKPATCH" ]]; then
	echo
	echo "==> checkpatch.pl --strict"
	perl "$CHECKPATCH" --no-tree --strict --patch "$OUT" 2>&1 | tail -6 | sed 's/^/    /'
else
	echo
	echo "!! no checkpatch.pl found — run it inside a kernel tree:"
	echo "   perl ~/linux/scripts/checkpatch.pl --strict $OUT"
fi

cat <<EOF

==> next: send it to the sound maintainers

  git clone --filter=blob:none https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git ~/linux
  cd ~/linux
  git am $OUT                       # sanity: must apply cleanly on master
  scripts/get_maintainer.pl --no-rolestats $OUT   # authoritative To/Cc list
  git send-email --to-cmd='scripts/get_maintainer.pl --no-rolestats --no-git-fallback' $OUT
EOF
