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

# Install runtime dependencies including Chromium for Puppeteer on Alpine
# Puppeteer works on Alpine with system Chromium; Playwright does not
RUN apk add --no-cache \
    sqlite \
    sqlite-libs \
    curl \
    nodejs \
    npm \
    # Chromium and dependencies for Puppeteer
    chromium \
    nss \
    freetype \
    harfbuzz \
    ca-certificates \
    ttf-freefont

# Configure Puppeteer to use Alpine's Chromium instead of downloading glibc-linked binary
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

# Install hex and rebar in runtime too
RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app

# Copy compiled app from builder
COPY --from=builder /app /app

# Copy Mix archives (hex, rebar) from builder
COPY --from=builder /root/.mix /root/.mix

# Create writable directories
RUN mkdir -p priv/repo && chmod -R 777 priv

# Expose MCP port (documentation only - MCP uses stdio)
EXPOSE 9000

# Health check - just verify the process is running
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD pgrep -f "beam.smp" || exit 1

# Run setup and start
CMD ["sh", "-c", "mix ecto.create && mix ecto.migrate && MIX_ENV=prod mix run --no-halt"]
