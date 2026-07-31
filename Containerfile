# hecate-robo-rumbler
#
# A visiting tank genome arrives over the mesh, fights the resident field of 40
# champions, and the row is published.
#
# THE ARCHIVE IS A VOLUME AND THAT IS THE POINT. Every visiting genome is a
# sample from an independently trained population that the research cannot
# otherwise obtain. Losing it to a container recreate would defeat the reason
# this service exists, so /var/lib/hecate-robo-rumbler must outlive the image.

FROM docker.io/erlang:27-alpine AS builder
WORKDIR /build

# macula ships a QUIC NIF; MACULA_FORCE_SOURCE_BUILD makes it build here rather
# than fetch a prebuilt binary against a different libc (the recorded glibc trap).
RUN apk add --no-cache git curl bash build-base cmake perl linux-headers
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
ENV RUSTFLAGS="-C target-feature=-crt-static"
ENV MACULA_FORCE_SOURCE_BUILD=1

RUN curl -fsSL https://s3.amazonaws.com/rebar3/rebar3 -o /usr/local/bin/rebar3 \
    && chmod +x /usr/local/bin/rebar3

COPY rebar.config ./
RUN rebar3 get-deps

COPY config ./config
COPY apps ./apps
RUN rebar3 as prod release

FROM docker.io/alpine:3.22
RUN apk add --no-cache ncurses-libs libstdc++ libgcc openssl ca-certificates curl
WORKDIR /app
COPY --from=builder /build/_build/prod/rel/hecate_robo_rumbler ./
RUN mkdir -p /var/lib/hecate-robo-rumbler

ENV HOME=/app
ENV RELX_REPLACE_OS_VARS=true

ENV HECATE_NODE_NAME=hecate_robo_rumbler
ENV HECATE_NODE_HOST=127.0.0.1
ENV HECATE_COOKIE=hecate_robo_rumbler
ENV HECATE_HEALTH_PORT=8482
ENV HECATE_RUMBLE_ARCHIVE=/var/lib/hecate-robo-rumbler

VOLUME ["/etc/hecate/secrets", "/var/lib/hecate-robo-rumbler"]

EXPOSE 8482
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${HECATE_HEALTH_PORT}/health" || exit 1

CMD ["/app/bin/hecate_robo_rumbler", "foreground"]
