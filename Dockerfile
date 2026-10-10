# Stage 1: Build the release
ARG ELIXIR_VERSION=1.18.2
ARG ERLANG_VERSION=27.2.4
ARG ALPINE_VERSION=3.21.3

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${ERLANG_VERSION}-alpine-${ALPINE_VERSION} AS builder

# Install build dependencies
RUN apk add --no-cache build-base git

WORKDIR /app

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV=prod

# Copy dependency files
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy application source
COPY config/ config/
COPY lib/ lib/

# Compile and assemble release
RUN mix compile
RUN mix release

# Stage 2: Minimal runtime image
FROM alpine:${ALPINE_VERSION} AS runner

RUN apk add --no-cache \
    libstdc++ \
    openssl \
    ncurses-libs \
    libgcc \
    ca-certificates

WORKDIR /app

# Create non-root user
RUN addgroup -g 1000 varco && \
    adduser -u 1000 -G varco -h /app -s /bin/sh -D varco

# Copy release artifact from builder
COPY --from=builder --chown=varco:varco /app/_build/prod/rel/varco ./

USER varco

ENV HOME=/app
ENV MIX_ENV=prod
ENV VARCO_HTTP_PORT=8080
ENV VARCO_HTTPS_PORT=8443
ENV VARCO_ADMIN_PORT=9000

# Public HTTP & HTTPS, plus Admin API & Dashboard
EXPOSE 8080 8443 9000

ENTRYPOINT ["/app/bin/varco"]
CMD ["start"]
