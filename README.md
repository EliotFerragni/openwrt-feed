# OpenWrt package feed

[![publish](https://github.com/EliotFerragni/openwrt-feed/actions/workflows/publish.yml/badge.svg?branch=main)](https://github.com/EliotFerragni/openwrt-feed/actions/workflows/publish.yml)
![Claude Code](https://img.shields.io/badge/Claude%20Code-%23D97757.svg?style=for-the-badge&logo=claudecode&logoColor=white)

A signed package feed for my OpenWrt LuCI apps, served from GitHub Pages:

    https://eliotferragni.github.io/openwrt-feed/

Once a router trusts the key, the packages in it install and upgrade from
**System → Software** in LuCI like any other package, and new releases show up
on their own.

Currently in the feed:

| package | what it is |
| --- | --- |
| [luci-app-nlbw-history](https://github.com/EliotFerragni/luci-app-nlbw-history) | per-device and per-protocol bandwidth history from nlbwmon |
| [luci-app-fw-live](https://github.com/EliotFerragni/luci-app-fw-live) | live view of what the firewall is accepting and refusing |

## Setting it up

Two things have to reach the router: the feed URL, and the key that says the
feed's index can be trusted. Both can be done from LuCI, or both over SSH.

### Over SSH

Once per router. Shorter, and nothing reboots.

**OpenWrt 25.12 and newer**, which use apk:

    wget -O /etc/apk/keys/openwrt-feed.pem \
        https://eliotferragni.github.io/openwrt-feed/keys/openwrt-feed.pem
    echo "https://eliotferragni.github.io/openwrt-feed/apk/packages.adb" \
        >> /etc/apk/repositories.d/customfeeds.list
    apk update

**OpenWrt 24.10 and older**, which use opkg:

    wget -O /tmp/feed.pub https://eliotferragni.github.io/openwrt-feed/keys/usign.pub
    opkg-key add /tmp/feed.pub
    echo "src/gz eliotferragni https://eliotferragni.github.io/openwrt-feed/opkg" \
        >> /etc/opkg/customfeeds.conf
    opkg update

### From LuCI, without SSH

The feed URL is the easy half. **System → Software → Configure apk** (or
**Configure opkg**) edits the feed files directly in the browser. Add one line:

    https://eliotferragni.github.io/openwrt-feed/apk/packages.adb     # 25.12 and newer

    src/gz eliotferragni https://eliotferragni.github.io/openwrt-feed/opkg   # 24.10 and older

The key is the half that page cannot write, and until it is in place the feed's
index is refused. It goes in through the restore path instead. Run
`tools/make-key-archive.sh` in this repository to build `key-archive.tar.gz`,
then on the router: **System → Backup / Flash Firmware → Restore backup**,
upload it. The router reboots, and comes back trusting the feed.

That archive contains nothing but the two public keys below, at the paths they
have to live at. It is an ordinary restore archive, and
`sysupgrade --restore-backup` unpacks it with `tar -C /`.

### Installing

Either way, once `apk update` or `opkg update` has run, both packages are in
**System → Software** by name, and upgrades appear there when a new release is
published. From a shell:

    apk add luci-app-nlbw-history      # 25.12 and newer
    opkg install luci-app-nlbw-history # 24.10 and older

Both `customfeeds` files are config files, so the feed survives a sysupgrade
that keeps settings.

## The keys

| file | used by | fingerprint |
| --- | --- | --- |
| [keys/openwrt-feed.pem](keys/openwrt-feed.pem) | apk, 25.12 and newer | EC prime256v1 |
| [keys/usign.pub](keys/usign.pub) | opkg, 24.10 and older | `828c916b47eb7bf9` |

Two keys because the two package managers share no crypto at all. The public
halves are in this repository and on the feed; the private halves exist only as
repository secrets.

Trusting a key is not a small thing: it means this feed can install anything on
that router without a further question. Everything here is built in public by
[the workflow](.github/workflows/publish.yml) from the releases of the
repositories in [sources.list](sources.list), and nothing else can be signed
without the private keys.

## Why the packages themselves are not signed

They are not, and that is how OpenWrt does it too. Trust flows through the
**index**: the index is signed, and it carries a SHA256 for every package in
it, so a package fetched through a verified index is already accounted for.

This is why an official OpenWrt `.apk` downloaded by hand still needs
`--allow-untrusted`, while the same file installs silently through a feed. The
OpenWrt buildbot leaves `CONFIG_SIGN_EACH_PACKAGE` off.

## Troubleshooting

**`wget` fails on the https URL.** The stock `wget` is busybox's and needs TLS
support to fetch https. Install it, or fetch over a machine you already have:

    opkg install libustream-mbedtls ca-bundle   # or: apk add ...

**`opkg update` says "Signature check failed".** The key is missing or filed
under the wrong name. `opkg-key add` names it by fingerprint, which is what
opkg looks for; copying the file into `/etc/opkg/keys/` by hand under any other
name does not work. Check that `/etc/opkg/keys/828c916b47eb7bf9` exists.

**`apk update` says "UNTRUSTED signature".** The key is not in
`/etc/apk/keys/`. Unlike opkg, the filename there does not matter, only that
the file is in the directory.

**The package installs but the LuCI page is missing.** Log out of LuCI and back
in. A stale session hides a freshly installed page.

## Building it yourself

See [DEVELOPMENT.md](DEVELOPMENT.md).

---

This feed was built by [Claude Code](https://claude.com/claude-code); see
[DEVELOPMENT.md](DEVELOPMENT.md#built-with-claude-code).

Trusting this feed's key on a router lets it install anything there without
asking again, which is the same deal you already have with OpenWrt's own key.
Before you take it, read `build-feed.sh` and the four scripts in `tools/`. They
are short on purpose, and everything they do is checkable against the OpenWrt
sources they are quoting.
