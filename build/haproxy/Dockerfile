# syntax=docker/dockerfile:1

ARG ALPINE_VERSION=3.23
FROM alpine:${ALPINE_VERSION} AS build

ARG HAPROXY_VERSION
ARG HAPROXY_SOURCE_SHA256

RUN apk add --no-cache \
      build-base \
      curl \
      linux-headers \
      openssl-dev \
      pcre2-dev \
      zlib-dev \
    && branch="${HAPROXY_VERSION%.*}" \
    && tarball="haproxy-${HAPROXY_VERSION}.tar.gz" \
    && curl --fail --silent --show-error --location \
      "https://www.haproxy.org/download/${branch}/src/${tarball}" \
      --output "/tmp/${tarball}" \
    && echo "${HAPROXY_SOURCE_SHA256}  /tmp/${tarball}" | sha256sum -c \
    && tar -xzf "/tmp/${tarball}" -C /tmp \
    && make -C "/tmp/haproxy-${HAPROXY_VERSION}" -j"$(nproc)" \
      TARGET=linux-musl \
      USE_OPENSSL=1 \
      USE_PCRE2=1 \
      USE_ZLIB=1 \
      USE_PROMEX=1 \
    && make -C "/tmp/haproxy-${HAPROXY_VERSION}" install-bin PREFIX=/usr/local \
    && strip /usr/local/sbin/haproxy \
    && /usr/local/sbin/haproxy -vv \
    && /usr/local/sbin/haproxy -vv | grep -Fq 'Built with the Prometheus exporter as a service'

FROM scratch AS artifact
COPY --from=build /usr/local/sbin/haproxy /usr/local/sbin/haproxy
