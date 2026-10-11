# unbound-build

Builds [Unbound](https://nlnetlabs.nl/projects/unbound/) (NLnet Labs) from its signed source
into a multi-arch container image, `ghcr.io/thevoltagesource/unbound`, for **linux/amd64**
(Sandyman) and **linux/arm64** (the Raspberry Pis). One tag works on both; Docker/containerd
picks the right architecture.

It replaces `mvance/unbound` / `mvance/unbound-rpi`
([MatthewVance/unbound-docker](https://github.com/MatthewVance/unbound-docker)), which stopped
at 1.22.0 in October 2024. This is a **drop-in**: same paths under `/opt/unbound`, same
`/unbound.sh` start script (MIT, kept with attribution), same `_unbound` user, and the same
"generate a config only when none is mounted" behaviour. Existing `unbound.conf` files and
volume layouts work unchanged.

## How the pipeline works

`.github/workflows/build-unbound.yml`, same shape as `yubihsm-connector-build`:

1. **Triggers:** weekly (Mon 07:00 UTC), manual (`version` and `force` inputs), pushes to
   `main` that touch the build files, and pull requests (build + test only, never push).
2. **Version:** the newest `unbound-X.Y.Z.tar.gz` in
   `https://nlnetlabs.nl/downloads/unbound/` (release candidates are skipped).
3. **Build or skip:** builds if that version isn't in GHCR yet, **or** if `debian:trixie-slim`
   has a new digest since the published image was built. The second case matters because
   OpenSSL and the other libraries come from Debian, so their security fixes only reach the
   image through a rebuild. The base digest is stored in the image label
   `org.opencontainers.image.base.digest`.
4. **Verify:** `scripts/fetch-unbound.sh` checks the tarball's SHA-256 against NLnet Labs'
   `.sha256` file **and** its OpenPGP signature. The signing key's primary fingerprint must be
   on the pinned `TRUSTED_FPRS` list, or the build fails. The Dockerfile never downloads
   source.
5. **Test:** builds amd64 and arm64 locally (arm64 through QEMU), then for each one checks
   the version and that the generated default config passes `unbound-checkconf`. A full run
   on amd64 uses `test/unbound.conf` (recursive, chroot, DNSSEC, like the real deployments) and checks:
   - it answers on 127.0.0.1;
   - `nlnetlabs.nl` validates (`ad` flag);
   - `dnssec-failed.org` is **rejected** with SERVFAIL;
   - the daemon runs as `_unbound`.
6. **Push:** `<version>`, `<version>-<YYYYMMDD>` and `latest`, with an SBOM and a provenance
   attestation.

### Tags

| Tag | Moves? | Use |
|---|---|---|
| `1.26.1` | Yes, when the Debian base is refreshed | Normal pin. A `docker compose pull` / pod restart picks up library fixes |
| `1.26.1-20261012` | Never | Exact, reproducible pin |
| `latest` | Yes | Don't deploy from it |

## Differences from mvance's image

- **OpenSSL from Debian** (`libssl3t64`, OpenSSL 3.5 LTS on trixie) instead of compiled
  in. That means one less upstream to track by hand, and the arm64 build is about 20+ minutes
  shorter under QEMU.
- **Base is `debian:trixie-slim`** (Debian 13), pinned by digest at build time. mvance used
  full `bookworm`.
- **The healthcheck asks for `localhost`.** Unbound's built-in local zone answers that, so an
  internet outage no longer marks the container unhealthy. mvance resolved `cloudflare.com`,
  the same thing the k8s probe comments warn against.
- **`unbound.sh` reads cgroup v2 memory limits** (`/sys/fs/cgroup/memory.max`). This only
  matters when no config is mounted and the script sizes the caches itself.
- **Same compile options** otherwise: libevent, nghttp2 (DoH), dnstap, TCP Fast Open, subnet,
  event API.

## First-time setup

1. **Check the signing keys yourself.** Compare `TRUSTED_FPRS` in
   `scripts/fetch-unbound.sh` against NLnet Labs: the "signed with" key on the
   [GitHub release page](https://github.com/NLnetLabs/unbound/releases) and their own site.
   The first run's log prints which key actually signed the tarball.
2. Create the GitHub repo `thevoltagesource/unbound-build`, then push this directory to it.
3. Go to **Settings → Actions → General → Workflow permissions** and choose **Read and write**.
   Without this, the GHCR push fails.
4. Run the workflow from **Actions → Build unbound image → Run workflow**. Expect roughly
   15–25 minutes, mostly the arm64 compile under QEMU.
5. In GHCR, set the `unbound` package to **public** so the hosts can pull it without a login.
   This is the same as the yubihsm-connector package.

## Validate before committing workflow changes

A YAML error in the workflow hides the "Run workflow" button without any error message. Check
the file before pushing:

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-unbound.yml'))"
actionlint .github/workflows/build-unbound.yml   # if installed; also runs shellcheck on run: blocks
```

## Building locally

```bash
scripts/fetch-unbound.sh 1.26.1 src
docker build -t unbound:local .
docker run --rm unbound:local unbound -V
# multi-arch (must push, --load can't hold two platforms):
docker buildx build --platform linux/amd64,linux/arm64 -t <registry>/unbound:test --push .
```

`src/` is git-ignored.
