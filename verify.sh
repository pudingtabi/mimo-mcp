#!/bin/bash
set -e

echo "🔍 Verifying Mimo-MCP Gateway v2.1..."
echo "======================================"

# Check if Elixir is available
if ! command -v elixir &> /dev/null; then
    echo "❌ Elixir not found. Please install Elixir first:"
    echo "   https://elixir-lang.org/install.html"
    exit 1
fi

echo "✓ Elixir found: $(elixir --version | head -1)"

# Check if mix is available
if ! command -v mix &> /dev/null; then
    echo "❌ Mix not found"
    exit 1
fi

# Check Elixir version
ELIXIR_VERSION=$(elixir --version | grep "Elixir" | cut -d' ' -f2)
echo "✓ Elixir version: $ELIXIR_VERSION"

# Check dependencies
echo ""
echo "📦 Checking dependencies..."
if [ ! -d "deps" ]; then
    echo "Installing dependencies..."
    mix deps.get
fi

# Check if hermes_mcp is available
echo ""
echo "🔍 Checking hermes_mcp availability..."
if mix deps | grep -q "hermes_mcp"; then
    echo "✓ hermes_mcp dependency configured"
else
    echo "⚠️  hermes_mcp not found - using fallback MCP server"
fi

# Try to compile
echo ""
echo "🔨 Compiling project..."
if mix compile; then
    echo "✓ Compilation successful"
else
    echo "❌ Compilation failed"
    exit 1
fi

# Check database
echo ""
echo "💾 Setting up database..."
mix ecto.create 2>/dev/null || true
mix ecto.migrate

# Run a simple compilation test
echo ""
echo "🧪 Running basic tests..."
mix run -e '
IO.puts("Testing compilation...")
IO.puts("✓ All modules compiled successfully")

IO.puts("Testing tool definitions...")
tools = Mimo.Registry.list_all_tools()
IO.puts("✓ Found " <> Integer.to_string(length(tools)) <> " internal tools")

IO.puts("")
IO.puts("✅ Basic tests passed!")
'

echo ""
echo "🎉 Verification complete!"
echo ""
echo "Next steps:"
echo "1. Copy .env.example to .env and configure your API keys (optional)"
echo "2. Run: mix run --no-halt"
echo "3. Connect with VS Code/Cursor using mcp.json"
echo ""
echo "For Docker deployment:"
echo "  docker-compose up -d"
