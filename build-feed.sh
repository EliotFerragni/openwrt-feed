#!/bin/sh
# Build the signed package feed into site/, ready to be served as a static
# site. Reads sources.list, collects the latest release of each repository
# listed there, and writes two independently signed indexes:
#
#   site/opkg/Packages{,.gz,.sig}   opkg, OpenWrt 24.10 and older
#   site/apk/packages.adb           apk, OpenWrt 25.12 and newer
#
# The two formats share nothing, hence two of everything, including two keys.
#
# The package files themselves stay unsigned, and that is not an oversight.
# Trust flows through the index: the index is signed, and it carries a hash
# for every package in it, so a package fetched through a verified index is
# already accounted for. This is exactly how downloads.openwrt.org works, and
# why an official .apk downloaded by hand still needs --allow-untrusted.
#
# Needs curl, python3, tar, gzip, sha256sum and a C compiler. The apk index
# additionally needs apk-tools 3, which is borrowed from an alpine container
# when the host has none, the same way the package repositories build their
# .apk. No OpenWrt SDK.
#
#   ./build-feed.sh                 fetch and build everything
#   ./build-feed.sh --no-fetch      rebuild from what is already in downloads/

set -e

# Where the finished feed will be served from. Only used to write the setup
# instructions into the landing page, nothing fetches it.
FEED_URL="https://eliotferragni.github.io/openwrt-feed"

# The feed name opkg will file this under in its lists directory. It has to be
# unique among the feeds configured on the router.
OPKG_FEED_NAME="eliotferragni"

cd "$(dirname "$0")"
ROOT=$PWD
SITE=$ROOT/site
DL=$ROOT/downloads

abspath() {
	case "$1" in
		/*) printf '%s\n' "$1" ;;
		*)  printf '%s\n' "$ROOT/$1" ;;
	esac
}

APK_KEY=$(abspath "${APK_KEY:-keys/private/apk.pem}")
USIGN_KEY=$(abspath "${USIGN_KEY:-keys/private/usign.sec}")

FETCH=1
[ "$1" = "--no-fetch" ] && FETCH=0

for k in "$APK_KEY" "$USIGN_KEY"; do
	[ -r "$k" ] || {
		echo "build-feed.sh: cannot read signing key $k" >&2
		echo "  Run tools/gen-keys.sh, or point APK_KEY and USIGN_KEY at them." >&2
		exit 1
	}
done

# ---------------------------------------------------------------- collect

# Asset names and URLs of a repository's latest release, one per line. A
# repository with no release yet is a warning and not an error, so that adding
# a line to sources.list before the first release does not break the feed.
list_assets() {
	python3 - "$1" <<'PY'
import json, os, sys, urllib.request

repo = sys.argv[1]
req = urllib.request.Request(
    "https://api.github.com/repos/%s/releases/latest" % repo,
    headers={"Accept": "application/vnd.github+json"})
token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
if token:
    req.add_header("Authorization", "Bearer " + token)

try:
    release = json.load(urllib.request.urlopen(req, timeout=30))
except Exception as err:
    sys.stderr.write("  %s: no usable release (%s)\n" % (repo, err))
    sys.exit(0)

found = False
for asset in release.get("assets", []):
    if asset["name"].endswith((".apk", ".ipk")):
        found = True
        print("%s\t%s" % (asset["name"], asset["browser_download_url"]))

if not found:
    sys.stderr.write("  %s: release %s has no .ipk or .apk attached\n"
                     % (repo, release.get("tag_name", "?")))
PY
}

if [ "$FETCH" = 1 ]; then
	rm -rf "$DL"
	mkdir -p "$DL"
	while read -r repo; do
		case "$repo" in ''|'#'*) continue ;; esac
		echo "$repo"
		list_assets "$repo" | while IFS='	' read -r name url; do
			[ -n "$name" ] || continue
			echo "  $name"
			curl -sSfL -o "$DL/$name" "$url"
		done
	done < sources.list
fi

# ------------------------------------------------------------------ stage

rm -rf "$SITE"
mkdir -p "$SITE/opkg" "$SITE/apk" "$SITE/keys"

for f in "$DL"/*.ipk; do [ -e "$f" ] && cp "$f" "$SITE/opkg/"; done
for f in "$DL"/*.apk; do [ -e "$f" ] && cp "$f" "$SITE/apk/"; done

cp "$ROOT/keys/openwrt-feed.pem" "$ROOT/keys/usign.pub" "$SITE/keys/"

n_ipk=$(ls -1 "$SITE/opkg"/*.ipk 2>/dev/null | wc -l)
n_apk=$(ls -1 "$SITE/apk"/*.apk 2>/dev/null | wc -l)

# An empty signed index is worse than no feed: it would tell every router that
# the packages it has installed no longer exist anywhere.
if [ "$n_ipk" = 0 ] && [ "$n_apk" = 0 ]; then
	echo "build-feed.sh: no packages collected, refusing to publish an empty feed." >&2
	exit 1
fi

# ------------------------------------------------------------- opkg index

if [ "$n_ipk" != 0 ]; then
	USIGN=$("$ROOT/tools/get-usign.sh")
	cd "$SITE/opkg"

	# What scripts/ipkg-make-index.sh does in the OpenWrt tree, minus its
	# bashisms and its use of OpenWrt's own mkhash. The index is the control
	# file of every package with the three fields opkg needs to fetch and
	# check it spliced in ahead of the description.
	for pkg in *.ipk; do
		size=$(stat -L -c%s "$pkg")
		sha=$(sha256sum "$pkg" | cut -d' ' -f1)
		tar -xzOf "$pkg" ./control.tar.gz | tar -xzOf - ./control | \
			sed -e "s|^Description:|Filename: $pkg\nSize: $size\nSHA256sum: $sha\nDescription:|"
		echo ""
	done > Packages.manifest

	grep -vE '^(Maintainer|LicenseFiles|Source|SourceName|Require|SourceDateEpoch)' \
		Packages.manifest > Packages
	rm -f Packages.manifest

	# Straight out of package/Makefile in the OpenWrt tree. usign mis-signs a
	# message whose length lands in this one residue class, so upstream pads
	# the index out of it rather than fix the signer. Two blank lines are
	# invisible to the index parser.
	case "$(( (64 + $(stat -L -c%s Packages)) % 128 ))" in
		110|111) printf '\n\n' >> Packages ;;
	esac

	gzip -9nc Packages > Packages.gz

	# Signed uncompressed, though opkg is configured to fetch Packages.gz.
	# That is not a mismatch: opkg-key pipes the list through zcat before
	# handing it to usign, so the signature covers the uncompressed bytes
	# either way.
	"$USIGN" -S -m Packages -s "$USIGN_KEY"
	cd "$ROOT"
fi

# -------------------------------------------------------------- apk index

# apk mkndx needs apk-tools 3, which is not the apk on a router: OpenWrt builds
# that one with -Dminimal=true and it has no mkndx. --allow-untrusted is about
# the input packages, which are unsigned by design, and does not weaken the
# signature this puts on the index.
if [ "$n_apk" != 0 ]; then
	set -- mkndx --allow-untrusted --sign-key "$APK_KEY" --output packages.adb

	if command -v apk >/dev/null 2>&1 && apk mkndx --help >/dev/null 2>&1; then
		( cd "$SITE/apk" && apk "$@" *.apk )
	elif command -v docker >/dev/null 2>&1; then
		# Mounted at the same paths so the arguments need no translation,
		# and the index is handed back to the calling user, or the next run
		# cannot overwrite a root owned file.
		docker run --rm \
			-v "$SITE/apk:$SITE/apk" \
			-v "$APK_KEY:$APK_KEY:ro" \
			-w "$SITE/apk" alpine:edge \
			sh -c "apk$(for a; do printf " '%s'" "$a"; done) *.apk \
			       && chown $(id -u):$(id -g) packages.adb"
	else
		echo "build-feed.sh: the apk index needs apk-tools 3 or docker." >&2
		echo "  See DEVELOPMENT.md for where to get one." >&2
		exit 1
	fi
fi

# ------------------------------------------------------------ landing page

# GitHub Pages answers a directory with a 404 and not a listing, so the root of
# the feed has to be a real page. It doubles as the setup instructions, which
# is the only place the exact key filenames are spelled out.
{
	cat <<HTML
<!DOCTYPE html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenWrt package feed</title>
<style>
  :root { color-scheme: light dark; }
  body { max-width: 46rem; margin: 3rem auto; padding: 0 1rem;
         font: 16px/1.6 system-ui, sans-serif; }
  pre { background: #8881; padding: .8rem 1rem; overflow-x: auto; border-radius: 4px; }
  table { border-collapse: collapse; margin: 1rem 0; }
  td, th { text-align: left; padding: .3rem 1.5rem .3rem 0; }
  footer { margin-top: 3rem; font-size: .9rem; opacity: .7; }
</style>

<h1>OpenWrt package feed</h1>
<p>A signed feed of my OpenWrt LuCI packages. Once a router trusts the key
below, these install and upgrade from
<em>System &rarr; Software</em> like any other package.</p>

<h2>OpenWrt 25.12 and newer (apk)</h2>
<pre>wget -O /etc/apk/keys/openwrt-feed.pem $FEED_URL/keys/openwrt-feed.pem
echo "$FEED_URL/apk/packages.adb" >> /etc/apk/repositories.d/customfeeds.list
apk update</pre>

<h2>OpenWrt 24.10 and older (opkg)</h2>
<pre>wget -O /tmp/feed.pub $FEED_URL/keys/usign.pub
opkg-key add /tmp/feed.pub
echo "src/gz $OPKG_FEED_NAME $FEED_URL/opkg" >> /etc/opkg/customfeeds.conf
opkg update</pre>

<h2>Packages</h2>
<table>
<tr><th>Package<th>Version<th>apk<th>ipk
HTML

	# Driven off the opkg index, which already holds the parsed control data.
	# The version glob is anchored on a digit so that a package whose name is a
	# prefix of another one does not claim its file.
	if [ -f "$SITE/opkg/Packages" ]; then
		awk '/^Package: /{p=$2} /^Version: /{v=$2} /^Filename: /{print p"\t"v"\t"$2}' \
			"$SITE/opkg/Packages" | \
		while IFS='	' read -r pkg ver ipk; do
			apk=$(cd "$SITE/apk" 2>/dev/null && ls "$pkg"-[0-9]*.apk 2>/dev/null | head -1)
			printf '<tr><td>%s<td>%s<td>' "$pkg" "$ver"
			if [ -n "$apk" ]; then
				printf '<a href="apk/%s">%s</a>' "$apk" "$apk"
			fi
			printf '<td><a href="opkg/%s">%s</a>\n' "$ipk" "$ipk"
		done
	fi

	cat <<HTML
</table>

<footer>
<p>Built $(date -u '+%Y-%m-%d %H:%M UTC'). The package files are not signed
individually; the index is, and it carries a checksum for each of them. That
is how OpenWrt's own feeds work.</p>
</footer>
HTML
} > "$SITE/index.html"

echo
echo "built site/ with $n_ipk ipk and $n_apk apk"
