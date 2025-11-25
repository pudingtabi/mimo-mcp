FROM elixir:1.16-alpine AS builder

# Install system dependencies
RUN apk add --no-cache \
    build-base \
    sqlite-dev \
    git \
    curl

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# Copy dependency files first (cached layer)
COPY mix.exs mix.lock* ./
RUN mix deps.get --only prod
RUN MIX_ENV=prod mix deps.compile

# Copy source code
COPY config config
COPY lib lib
COPY priv priv

# Compile application
RUN MIX_ENV=prod mix compile

# ------- Runtime image -------
FROM elixir:1.16-alpine

# Install runtime dependencies
RUN apk add --no-cache \
    sqlite \
    sqlite-libs \
    curl \
    nodejs \
    npm

# Create non-root user
RUN addgroup -S mimo && adduser -S mimo -G mimo -h /app

WORKDIR /app

# Copy from builder
COPY --from=builder --chown=mimo:mimo /app /app

# Create writable directories
RUN mkdir -p priv/repo && chown -R mimo:mimo /app

# Switch to unprivileged user
USER mimo

# Expose MCP port
EXPOSE 9000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:9000 || exit 1

# Run setup and start
CMD ["sh", "-c", "mix ecto.create && mix ecto.migrate && mix run --no-halt"]
