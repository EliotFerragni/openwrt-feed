#!/bin/sh
# Write key-archive.tar.gz, an archive that installs this feed's public keys
# through LuCI's own restore path, with no SSH access to the router.
#
# LuCI can already add the feed URL itself: System, Software, "Configure opkg"
# or "Configure apk" edits /etc/opkg/customfeeds.conf and
# /etc/apk/repositories.d/customfeeds.list, both of which that page is allowed
# to write. What it cannot write is the trusted key, and without the key the
# feed's index is refused.
#
# The way in is System, Backup / Flash Firmware, "Restore backup". It hands the
# uploaded archive to sysupgrade --restore-backup, which is a plain
# "tar -C / -xzf" with no filtering on the paths inside, so an archive laid out
# like the real filesystem puts the keys where they belong. The router reboots
# afterwards, which is sysupgrade's doing and not ours.
#
# What goes in is the public half of each key and nothing else. Adding one is
# still a real decision: it means this feed can install anything on that router
# without asking again, exactly as trusting OpenWrt's own key does. Read
# keys/openwrt-feed.pem and keys/usign.pub if you want to see what is in here.
#
# Both keys go in regardless of which package manager the router runs. The
# unused one is a few hundred bytes in a directory its package manager never
# reads, and it means a router later moved from 24.10 to 25.12 already trusts
# the feed.

set -e

cd "$(dirname "$0")/.."
OUT=$PWD/key-archive.tar.gz

USIGN=$("$PWD/tools/get-usign.sh")
FP=$("$USIGN" -F -p keys/usign.pub)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/etc/apk/keys" "$WORK/etc/opkg/keys"

# apk reads every file in its keys directory, so the name is free.
cp keys/openwrt-feed.pem "$WORK/etc/apk/keys/openwrt-feed.pem"

# usign looks the key up by the fingerprint recorded in the signature, so for
# opkg the filename is the fingerprint and nothing else will do. This is the
# one thing "opkg-key add" exists to get right.
cp keys/usign.pub "$WORK/etc/opkg/keys/$FP"

# Relative paths, owned by root, because it is unpacked with -C /.
( cd "$WORK" && tar --numeric-owner --owner=0 --group=0 -czf "$OUT" ./etc )

echo "wrote $OUT"
echo
echo "  apk  key -> /etc/apk/keys/openwrt-feed.pem"
echo "  opkg key -> /etc/opkg/keys/$FP"
echo
echo "On the router: System, Backup / Flash Firmware, Restore backup, and"
echo "upload this file. The router reboots. Then add the feed itself under"
echo "System, Software, Configure apk or Configure opkg."
