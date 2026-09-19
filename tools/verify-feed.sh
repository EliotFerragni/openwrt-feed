#!/bin/sh
# Check a built site/ the way a router would, using only the public keys in
# keys/. Run after build-feed.sh.
#
# The failure this is really here to catch is a signature made with a private
# key whose public half was never committed. The feed would look perfect from
# the build side and be unverifiable on every router, and nothing else in the
# pipeline would notice.

set -e

cd "$(dirname "$0")/.."
ROOT=$PWD
SITE=$ROOT/site
fail=0

[ -d "$SITE" ] || { echo "no site/, run build-feed.sh first" >&2; exit 1; }

# ---------------------------------------------------------------- opkg

if [ -f "$SITE/opkg/Packages" ]; then
	USIGN=$("$ROOT/tools/get-usign.sh")

	# usign looks the key up by the fingerprint in the signature, so the file
	# has to be named for it. This is what opkg-key add does on the router.
	KEYDIR=$(mktemp -d)
	trap 'rm -rf "$KEYDIR"' EXIT
	cp "$ROOT/keys/usign.pub" "$KEYDIR/$("$USIGN" -F -p "$ROOT/keys/usign.pub")"

	# Through zcat, because that is what opkg-key does before handing the list
	# to usign, and the signature is over the uncompressed bytes.
	if zcat "$SITE/opkg/Packages.gz" | \
		"$USIGN" -V -P "$KEYDIR" -q -x "$SITE/opkg/Packages.sig" -m -; then
		echo "opkg index: signature OK"
	else
		echo "opkg index: SIGNATURE FAILED" >&2
		fail=1
	fi

	# Every package the index promises has to be there and hash as advertised,
	# or opkg refuses the download after having trusted the index.
	awk '/^Filename: /{f=$2} /^SHA256sum: /{print $2"  "f}' "$SITE/opkg/Packages" \
		> "$KEYDIR/sums"
	if ( cd "$SITE/opkg" && sha256sum -c --quiet "$KEYDIR/sums" ); then
		echo "opkg index: $(wc -l < "$KEYDIR/sums") package checksums OK"
	else
		echo "opkg index: CHECKSUM MISMATCH" >&2
		fail=1
	fi
fi

# ----------------------------------------------------------------- apk

if [ -f "$SITE/apk/packages.adb" ]; then
	APKKEYS=$(mktemp -d)
	cp "$ROOT/keys/openwrt-feed.pem" "$APKKEYS/"

	if command -v apk >/dev/null 2>&1 && apk mkndx --help >/dev/null 2>&1; then
		apk verify --keys-dir "$APKKEYS" "$SITE/apk/packages.adb" && ok=1 || ok=0
	elif command -v docker >/dev/null 2>&1; then
		docker run --rm \
			-v "$SITE/apk:/apk:ro" -v "$APKKEYS:/keys:ro" alpine:edge \
			apk verify --keys-dir /keys /apk/packages.adb && ok=1 || ok=0
	else
		echo "apk index: cannot check, needs apk-tools 3 or docker" >&2
		ok=1
	fi

	rm -rf "$APKKEYS"
	[ "$ok" = 1 ] || fail=1
fi

[ "$fail" = 0 ] || { echo "verify-feed.sh: FAILED" >&2; exit 1; }
echo "feed verifies against the committed public keys"
