#!/usr/bin/env bash
# Download an Unbound release from NLnet Labs and verify it before anything builds it.
#
#   scripts/fetch-unbound.sh <version> [outdir]      e.g. scripts/fetch-unbound.sh 1.26.1 src
#
# Two independent checks, both must pass:
#   1. SHA-256 against the .sha256 file NLnet Labs publishes next to the tarball.
#   2. OpenPGP signature (.asc), and the signing key's primary fingerprint must be on
#      TRUSTED_FPRS below. A valid signature from any other key is a failure.
#
# On success leaves <outdir>/unbound.tar.gz, which the Dockerfile COPYs. The Dockerfile never
# downloads source itself, so this script is the only place verification happens.
set -euo pipefail

VERSION="${1:?usage: fetch-unbound.sh <version> [outdir]}"
OUTDIR="${2:-src}"
BASE="https://nlnetlabs.nl/downloads/unbound"
FILE="unbound-${VERSION}.tar.gz"

# Keys allowed to sign Unbound release tarballs (primary-key fingerprints, no spaces).
# CONFIRM THESE AGAINST NLNET LABS YOURSELF before trusting a build; don't take them
# from a chat. Sources: the "signed with" note on https://github.com/NLnetLabs/unbound/releases
# and NLnet Labs' own pages. If a build fails with "signed by a key NOT in the trusted list",
# NLnet Labs has rotated keys: check upstream, then add the new fingerprint here.
TRUSTED_FPRS="
231018690C4D903EF419146AA144323DEAACDF45
"
#  EDFA…045F8D  Wouter Wijngaards (NLnet Labs), long-time Unbound release signer
#  2310…EAACDF45  "NLnet Labs releases signing key G2 <releases@nlnetlabs.nl>"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "Downloading ${FILE}"
curl -fsSLO "${BASE}/${FILE}"
curl -fsSLO "${BASE}/${FILE}.sha256"
curl -fsSLO "${BASE}/${FILE}.asc"

# 1. Checksum. The .sha256 file is either a bare hash or "hash  filename".
EXPECTED="$(awk '{print $1; exit}' "${FILE}.sha256")"
ACTUAL="$(sha256sum "${FILE}" | awk '{print $1}')"
if [ "${EXPECTED}" != "${ACTUAL}" ]; then
  echo "::error::SHA-256 mismatch for ${FILE}: expected ${EXPECTED}, got ${ACTUAL}"
  exit 1
fi
echo "SHA-256 OK: ${ACTUAL}"

# 2. Signature. Throwaway keyring, so nothing outside TRUSTED_FPRS is ever in it.
export GNUPGHOME="${WORK}/gnupg"
mkdir -m 700 "$GNUPGHOME"
for fpr in $TRUSTED_FPRS; do
  # keyserver.ubuntu.com first: keys.openpgp.org strips user IDs from keys whose owners
  # haven't verified an email there, and gpg refuses to import a key with no user ID.
  gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$fpr" 2>/dev/null \
    || gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$fpr" 2>/dev/null \
    || echo "warning: could not fetch key $fpr"
done

# --status-fd gives machine-readable output. VALIDSIG's last field is the primary key's
# fingerprint (also when a subkey made the signature). A signature from a key that has
# since expired still produces VALIDSIG, which is what we want for older releases.
STATUS="$(gpg --batch --status-fd 1 --verify "${FILE}.asc" "${FILE}" 2>"${WORK}/gpg.err")" || {
  cat "${WORK}/gpg.err"
  echo "::error::Signature verification failed for ${FILE}"
  exit 1
}
cat "${WORK}/gpg.err"
SIGNER="$(echo "$STATUS" | awk '$2=="VALIDSIG"{print $NF; exit}')"
if [ -z "$SIGNER" ]; then
  echo "::error::No valid signature found on ${FILE}"
  exit 1
fi
if ! echo "$TRUSTED_FPRS" | grep -qx "$SIGNER"; then
  echo "::error::${FILE} is signed by a key NOT in the trusted list: ${SIGNER}"
  exit 1
fi
echo "Signature OK: signed by trusted key ${SIGNER}"

cd - >/dev/null
mkdir -p "$OUTDIR"
cp "${WORK}/${FILE}" "${OUTDIR}/unbound.tar.gz"
echo "${VERSION}" > "${OUTDIR}/VERSION"
echo "Verified source written to ${OUTDIR}/unbound.tar.gz"
