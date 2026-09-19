#!/bin/sh
# Generate the feed's two signing keypairs. Run this once, ever.
#
# Two keypairs are needed because the two package managers share no crypto:
#
#   apk  (25.12 and newer)  an EC prime256v1 key, the same kind and curve
#                           OpenWrt generates for its own buildbot
#   opkg (24.10 and older)  a usign key, which is ed25519 in OpenWrt's own
#                           container format
#
# The public halves land in keys/ and are committed: they are what a router
# has to trust, so they need to be downloadable. The private halves land in
# keys/private/, which is gitignored, and belong in the repository secrets.
#
# Rotating a key means every router that already trusts the old one has to be
# visited again, so this is worth doing once and keeping.

set -e

cd "$(dirname "$0")/.."
mkdir -p keys/private
chmod 700 keys/private

if [ -e keys/private/apk.pem ] || [ -e keys/private/usign.sec ]; then
	echo "keys/private already has keys. Refusing to overwrite them." >&2
	echo "Rotating a key strands every router that trusts the old one, so if" >&2
	echo "that is really what you want, delete keys/private by hand first." >&2
	exit 1
fi

COMMENT=${1:-"OpenWrt package feed"}

openssl ecparam -name prime256v1 -genkey -noout -out keys/private/apk.pem
openssl ec -in keys/private/apk.pem -pubout -out keys/openwrt-feed.pem 2>/dev/null

USIGN=$(tools/get-usign.sh)
"$USIGN" -G -s keys/private/usign.sec -p keys/usign.pub -c "$COMMENT"

chmod 600 keys/private/apk.pem keys/private/usign.sec

cat <<MSG

Generated.

  keys/openwrt-feed.pem     apk public key, commit this
  keys/usign.pub            opkg public key, commit this
                            fingerprint $("$USIGN" -F -p keys/usign.pub)
  keys/private/             both private keys, never commit these

Set these two repository secrets, under Settings, Secrets and variables,
Actions:

  FEED_APK_KEY     the contents of keys/private/apk.pem
  FEED_USIGN_KEY   the contents of keys/private/usign.sec

  gh secret set FEED_APK_KEY   < keys/private/apk.pem
  gh secret set FEED_USIGN_KEY < keys/private/usign.sec

Keep keys/private backed up somewhere safe. Losing it means generating new
keys, and every router that already trusts these has to be set up again.
MSG
