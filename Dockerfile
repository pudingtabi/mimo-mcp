FROM hexpm/elixir:1.16.2-erlang-26.2.5-debian-bullseye-20240513 AS builder

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    sqlite3 \
    libsqlite3-dev \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

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
FROM hexpm/elixir:1.16.2-erlang-26.2.5-debian-bullseye-20240513-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    sqlite3 \
    libsqlite3-0 \
    curl \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r mimo && useradd -r -g mimo -d /app mimo

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
