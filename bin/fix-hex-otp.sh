#!/bin/bash
# Fix Hex OTP version mismatch
# Run this script in the mimo-mcp directory when you see:
#   "Error loading function 'Elixir.Hex.State'"
#   "please re-compile this module with an Erlang/OTP 28 compiler"

set -e

echo "🔧 Fixing Hex OTP version mismatch..."

# Find Elixir installation
ELIXIR_PATH=""
if [ -d "$HOME/.elixir-install/installs" ]; then
  ELIXIR_DIR="$HOME/.elixir-install/installs/elixir"
  OTP_DIR="$HOME/.elixir-install/installs/otp"
  
  if [ -d "$ELIXIR_DIR" ]; then
    ELIXIR_VERSION=$(ls -1 "$ELIXIR_DIR" | tail -1)
    ELIXIR_PATH="$ELIXIR_DIR/$ELIXIR_VERSION/bin"
  fi
  
  if [ -d "$OTP_DIR" ]; then
    OTP_VERSION=$(ls -1 "$OTP_DIR" | tail -1)
    ELIXIR_PATH="$OTP_DIR/$OTP_VERSION/bin:$ELIXIR_PATH"
  fi
fi

# Also check asdf
if [ -d "$HOME/.asdf" ]; then
  source "$HOME/.asdf/asdf.sh" 2>/dev/null || true
fi

# Add to PATH
export PATH="$ELIXIR_PATH:$PATH"

echo "📍 Using Elixir from: $(which elixir 2>/dev/null || echo 'not found')"
echo "📍 Using mix from: $(which mix 2>/dev/null || echo 'not found')"

# Check current OTP version
echo ""
echo "📊 Current OTP version:"
erl -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null || echo "Could not detect OTP version"

echo ""
echo "📊 Current Elixir version:"
elixir --version 2>/dev/null || echo "Could not detect Elixir version"

echo ""
echo "🔄 Reinstalling Hex for current OTP version..."
mix local.hex --force

echo ""
echo "🔄 Reinstalling Rebar for current OTP version..."
mix local.rebar --force

echo ""
echo "🧹 Cleaning build artifacts..."
rm -rf _build/dev/lib/mimo_mcp 2>/dev/null || true

echo ""
echo "🔨 Recompiling project..."
mix deps.get
mix compile

echo ""
echo "✅ Fix complete! Please restart the MCP server in VS Code."
echo ""
echo "If you still see errors, try:"
echo "  1. Close VS Code completely"
echo "  2. Run: rm -rf ~/.mix/archives/hex-*"
echo "  3. Run this script again"
echo "  4. Reopen VS Code"
