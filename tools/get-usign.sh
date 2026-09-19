#!/bin/sh
# Make usign available and print the path to it on stdout.
#
# usign is OpenWrt's signing tool and the only thing that can produce a
# signature opkg will accept. It is not packaged for most distributions, but it
# is seven C files with no dependencies at all, so building it is cheaper than
# hunting for a binary. An already installed usign on PATH wins.

set -e

cd "$(dirname "$0")/.."
DEST=$PWD/.usign

if command -v usign >/dev/null 2>&1; then
	command -v usign
	exit 0
fi

if [ ! -x "$DEST/usign" ]; then
	mkdir -p "$DEST"
	if [ ! -d "$DEST/src" ]; then
		echo "building usign from source" >&2
		git clone --quiet --depth 1 https://github.com/openwrt/usign.git "$DEST/src" >&2
	fi
	# The upstream CMakeLists adds -Wall -Werror, which turns every new
	# compiler warning into a build failure on code that is not changing.
	# The file list is its SET(SOURCES ...) plus base64.c, which CMake only
	# includes when building without libubox. Building without libubox is
	# the point here: it is what keeps this dependency free.
	( cd "$DEST/src" && cc -O2 -std=gnu99 -o "$DEST/usign" \
		ed25519.c edsign.c f25519.c fprime.c sha512.c main.c base64.c ) >&2
fi

printf '%s\n' "$DEST/usign"
