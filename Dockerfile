# Unbound, compiled from NLnet Labs' signed source on Debian 13 (trixie).
#
# Drop-in for mvance/unbound and mvance/unbound-rpi: same paths (/opt/unbound/...), same
# start script (/unbound.sh), same _unbound user, same "generate a config only if none is
# mounted" behaviour. Differences from mvance's image:
#   - OpenSSL comes from Debian (libssl3t64) instead of being compiled in. Security fixes
#     arrive by rebuilding on a fresh base, which the weekly workflow does whenever
#     debian:trixie-slim changes. It also cuts out a 20+ minute QEMU build step.
#   - trixie-slim base instead of full bookworm.
#   - The healthcheck asks for "localhost" (answered from Unbound's built-in local zone)
#     instead of resolving cloudflare.com, so an internet outage doesn't mark it unhealthy.
#
# The source tarball is NOT downloaded here: scripts/fetch-unbound.sh verifies it (SHA-256 +
# pinned OpenPGP key) and puts it in src/, which is the build context's only input for it.
#
#   scripts/fetch-unbound.sh 1.26.1 src && docker build -t unbound:test .

ARG DEBIAN_IMAGE=debian:trixie-slim

FROM ${DEBIAN_IMAGE} AS build

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc \
      libc6-dev \
      make \
      libevent-dev \
      libexpat1-dev \
      libnghttp2-dev \
      libprotobuf-c-dev \
      libssl-dev \
      protobuf-c-compiler \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/src
COPY src/unbound.tar.gz .

# Same feature set as mvance's build.
RUN tar xzf unbound.tar.gz --strip-components=1 \
    && ./configure \
        --disable-dependency-tracking \
        --prefix=/opt/unbound \
        --with-pthreads \
        --with-username=_unbound \
        --with-ssl \
        --with-libevent \
        --with-libnghttp2 \
        --enable-dnstap \
        --enable-tfo-server \
        --enable-tfo-client \
        --enable-event-api \
        --enable-subnet \
    && make -j"$(nproc)" \
    && make install \
    && mv /opt/unbound/etc/unbound/unbound.conf /opt/unbound/etc/unbound/unbound.conf.example \
    && rm -rf /opt/unbound/share/man /opt/unbound/include /opt/unbound/lib/*.a /opt/unbound/lib/*.la


FROM ${DEBIAN_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
# ldnsutils provides drill (healthcheck, and handy for debugging inside the container).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      ldnsutils \
      libevent-2.1-7t64 \
      libexpat1 \
      libnghttp2-14 \
      libprotobuf-c1 \
      libssl3t64 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd _unbound \
    && useradd -g _unbound -s /usr/sbin/nologin -d /etc _unbound

COPY --from=build /opt/unbound /opt/unbound
COPY data/ /

# Fail the build here, not at 2am on a Pi, if Debian renamed a library package.
RUN chmod +x /unbound.sh \
    && if ldd /opt/unbound/sbin/unbound | grep -q 'not found'; then \
         ldd /opt/unbound/sbin/unbound; echo "missing shared libraries" >&2; exit 1; \
       fi \
    && /opt/unbound/sbin/unbound -V

WORKDIR /opt/unbound/
ENV PATH=/opt/unbound/sbin:$PATH

ARG DEBIAN_IMAGE
ARG UNBOUND_VERSION
ARG BASE_DIGEST
LABEL org.opencontainers.image.title="unbound" \
      org.opencontainers.image.description="Validating, recursive, caching DNS resolver (Unbound by NLnet Labs), built from signed source" \
      org.opencontainers.image.version="${UNBOUND_VERSION}" \
      org.opencontainers.image.licenses="BSD-3-Clause AND MIT" \
      org.opencontainers.image.base.name="${DEBIAN_IMAGE}" \
      org.opencontainers.image.base.digest="${BASE_DIGEST}"

EXPOSE 53/tcp 53/udp

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD drill @127.0.0.1 localhost > /dev/null || exit 1

CMD ["/unbound.sh"]
