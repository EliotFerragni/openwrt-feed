# Development

Notes for working on the feed. See [README.md](README.md) for adding it to a
router.

## What this repository is

It holds no packages. It collects the `.ipk` and `.apk` files from the GitHub
releases of the repositories in [sources.list](sources.list), builds a signed
index over them in both formats, and publishes the result to GitHub Pages.

    sources.list                 which repositories to collect from
    build-feed.sh                collect, index, sign, write site/
    tools/gen-keys.sh            generate the two keypairs, once ever
    tools/get-usign.sh           build usign, which no distribution ships
    tools/verify-feed.sh         check site/ the way a router would
    tools/make-key-archive.sh    keys as a LuCI-restorable archive, for SSH-less setup
    keys/                        the public halves, committed
    keys/private/                the private halves, gitignored
    .github/workflows/publish.yml

## Adding a package to the feed

Add its `owner/repo` to [sources.list](sources.list) and push. That is the
whole procedure.

The package repository needs no changes and does not need to know this feed
exists. What it does need is a release with the built `.ipk` and `.apk`
attached as assets, which is what both current source repositories already do
from their own release workflow.

Anything that is neither `.ipk` nor `.apk` is ignored, so attaching source
archives or checksums to a release is harmless.

## Building locally

    tools/gen-keys.sh     # once, ever
    ./build-feed.sh       # collect and build into site/
    tools/verify-feed.sh  # check what came out

`build-feed.sh --no-fetch` rebuilds from whatever is already in `downloads/`,
which is the fast path when changing the index or the landing page.

To try the result without a router, serve `site/` and point apk at it:

    (cd site && python3 -m http.server 8099 --bind 127.0.0.1) &
    docker run --rm --network host -v "$PWD/keys:/k:ro" alpine:edge sh -c '
      mkdir -p /keys /t && cp /k/openwrt-feed.pem /keys/
      echo http://127.0.0.1:8099/apk/packages.adb > /repos
      apk add --root /t --initdb --keys-dir /keys --repositories-file /repos
      apk list --root /t --keys-dir /keys --repositories-file /repos --available'

That prints the feed's packages when the key is trusted. Point `--keys-dir` at
an empty directory instead and it prints `UNTRUSTED signature` and nothing
else, which is the check that matters.

Installing for real additionally needs the dependencies (`luci-base` and
friends) to be resolvable, so it wants OpenWrt's own repository in `/repos`
as well, or stand-in packages of those names.

## The two formats

OpenWrt replaced opkg with apk in 25.12 and the two share nothing, so the
script builds two indexes over the same set of packages.

**opkg**, in `site/opkg`:

- `Packages` is every package's control file with `Filename`, `Size` and
  `SHA256sum` spliced in ahead of the description. This mirrors
  `scripts/ipkg-make-index.sh` in the OpenWrt tree, minus its bashisms.
- `Packages.gz` is what the router actually downloads, because the feed is
  configured as `src/gz`.
- `Packages.sig` is a usign signature over the **uncompressed** `Packages`.
  That is not a mismatch with `src/gz`: `opkg-key` pipes the downloaded list
  through `zcat` before handing it to usign, so the signature covers the
  uncompressed bytes either way.
- The public key has to be filed on the router under its own **fingerprint**.
  `opkg-key add` does that; copying the file in by hand under another name
  silently does not work.
- There is a padding step lifted from `package/Makefile` upstream. usign
  mis-signs a message whose length falls in one residue class mod 128, and
  upstream pads the index out of it rather than fixing the signer.

**apk**, in `site/apk`:

- `packages.adb` is built by `apk mkndx` and signed with an EC prime256v1 key,
  the same kind OpenWrt generates for its own buildbot.
- `--allow-untrusted` is passed to `mkndx` because the input packages are
  unsigned. It has no effect on the signature that goes onto the index.
- The public key goes in `/etc/apk/keys/` on the router under any name at all.
  apk tries every key in the directory, unlike usign.

Neither format signs the package files. The index carries a hash for each of
them, which is what the signature ends up covering. This is exactly how
downloads.openwrt.org works, and it is why an official OpenWrt `.apk` fetched
by hand still needs `--allow-untrusted`: the buildbot builds with
`CONFIG_SIGN_EACH_PACKAGE` off.

## Tools that are not where you would expect

**apk-tools 3** writes the apk index and is not the `apk` on a router: OpenWrt
builds that one with `-Dminimal=true` and it has no `mkndx`. `build-feed.sh`
uses apk-tools from the host if it finds one and otherwise runs `apk mkndx` in
an `alpine:edge` container, which is the same thing the package repositories do
to build their `.apk`. So the build needs either apk-tools 3 or docker.

**usign** signs the opkg index and is packaged by almost nobody.
`tools/get-usign.sh` clones and builds it, which takes a compiler and nothing
else: it is seven C files with no dependencies once libubox is left out.

## Getting the key onto a router without SSH

LuCI's package manager page can write the feed files themselves: its ACL grants
write on `/etc/opkg.conf`, `/etc/opkg/*.conf` and
`/etc/apk/repositories.d/customfeeds.list`, which is what the "Configure opkg"
and "Configure apk" button edits. The trusted key is not in that ACL, and it is
the part that actually gates the feed.

`tools/make-key-archive.sh` packs the two public keys at their real paths into
a tarball that LuCI's **Restore backup** accepts. That path works because
`sysupgrade --restore-backup` is a bare `tar -C / -xzf` with no filtering on
the member paths. It reboots the router, which is sysupgrade's behaviour and
not something the archive asks for.

An alternative worth knowing about for 24.10 only: opkg does not verify
signatures on a package installed from a local file, so a small keyring package
uploaded through **Software → Upload Package** could place the key and the feed
line from its postinst, with no reboot. That does not carry over to 25.12, where
apk does verify local files and the keyring package would itself be untrusted.

## Keys

`tools/gen-keys.sh` makes both keypairs and refuses to overwrite existing ones.
The public halves are committed. The private halves live in `keys/private/`,
which is gitignored, and in the repository secrets `FEED_APK_KEY` and
`FEED_USIGN_KEY`.

    gh secret set FEED_APK_KEY   < keys/private/apk.pem
    gh secret set FEED_USIGN_KEY < keys/private/usign.sec

Back `keys/private/` up somewhere that is not this repository. Losing it means
new keys, and every router that trusts the old ones has to be set up by hand
again. `tools/verify-feed.sh` checks the built feed against the *committed
public* keys, so a private key whose public half was never committed fails the
build rather than shipping a feed nobody can verify.

## Publishing

[The workflow](.github/workflows/publish.yml) rebuilds and deploys on a push to
`main`, on manual dispatch, and on a `repository_dispatch` of type `refresh`.
It needs Pages enabled with **GitHub Actions** as the source, under
Settings → Pages.

There is deliberately no schedule. Nothing here changes unless a package is
released or `sources.list` is edited, and a nightly rebuild of an unchanged
feed only burns Actions minutes. Run it from the Actions tab, or:

    gh workflow run publish.yml

The whole feed is a function of `sources.list` and the newest release of each
repository in it, so every run rebuilds from scratch and nothing is carried
between runs.

Because there is no schedule, a new release of a package does **not** appear in
the feed until the workflow is run. Either run it by hand after publishing a
release, or make the source repository ask for it by adding a step to its
release workflow:

    - name: Refresh the package feed
      env:
        GH_TOKEN: ${{ secrets.FEED_DISPATCH_TOKEN }}
      run: |
        gh api repos/EliotFerragni/openwrt-feed/dispatches \
          -f event_type=refresh

`FEED_DISPATCH_TOKEN` is a fine-grained PAT with **contents: read and write**
on this repository only. That token is the one piece of coupling between a
package repository and the feed, which is why it is optional.

## What is not tested here

Neither index is exercised against a real router in CI. `tools/verify-feed.sh`
checks the signatures and the checksums with the same tools the router uses
(`usign` for opkg, `apk verify` for apk), and an `apk add` against a locally
served copy of `site/` installs the packages with only the public key trusted.
What that cannot cover is opkg itself, which has no host build here, and LuCI's
package manager page.

## Built with Claude Code

This feed was built by [Claude Code](https://claude.com/claude-code): the build
and verification scripts, the workflow and the documentation. What to build and
what counted as correct came from the human side. Every commit written by Claude
carries a `Co-Authored-By: Claude` trailer, so the history says which is which.

The index formats were not taken on trust. Each detail here was read out of the
OpenWrt sources it mirrors (`package/Makefile`, `scripts/ipkg-make-index.sh`,
`package/system/opkg/files/opkg-key`, `package/system/openwrt-keyring/Makefile`)
and then checked by building a feed and installing from it: `apk add` against a
locally served copy of `site/` installs the packages with only the public key
trusted, and refuses them without it.

