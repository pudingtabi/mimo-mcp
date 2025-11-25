#!/bin/bash
# Mimo-MCP Gateway Installer
# https://github.com/pudingtabi/mimo-mcp

set -e

REPO="https://github.com/pudingtabi/mimo-mcp.git"
INSTALL_DIR="${MIMO_INSTALL_DIR:-$HOME/mimo-mcp}"

echo "╔══════════════════════════════════════════╗"
echo "║     Mimo-MCP Gateway Installer v2.1      ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Check for Elixir
check_elixir() {
    if ! command -v elixir &> /dev/null; then
        echo "❌ Elixir is not installed."
        echo ""
        echo "Install Elixir first:"
        echo ""
        if [[ "$OSTYPE" == "darwin"* ]]; then
            echo "  brew install elixir"
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            echo "  # Ubuntu/Debian:"
            echo "  wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb"
            echo "  sudo dpkg -i erlang-solutions_2.0_all.deb"
            echo "  sudo apt-get update && sudo apt-get install esl-erlang elixir"
            echo ""
            echo "  # Or use asdf:"
            echo "  asdf plugin add erlang && asdf plugin add elixir"
            echo "  asdf install erlang latest && asdf install elixir latest"
        fi
        exit 1
    fi
    
    ELIXIR_VERSION=$(elixir --version | grep "Elixir" | cut -d' ' -f2)
    echo "✓ Elixir $ELIXIR_VERSION found"
}

# Check for Git
check_git() {
    if ! command -v git &> /dev/null; then
        echo "❌ Git is not installed. Please install git first."
        exit 1
    fi
    echo "✓ Git found"
}

# Clone or update repository
clone_repo() {
    if [ -d "$INSTALL_DIR" ]; then
        echo "→ Updating existing installation..."
        cd "$INSTALL_DIR"
        git pull origin main
    else
        echo "→ Cloning repository..."
        git clone "$REPO" "$INSTALL_DIR"
        cd "$INSTALL_DIR"
    fi
    echo "✓ Repository ready at $INSTALL_DIR"
}

# Install dependencies
install_deps() {
    echo "→ Installing Elixir dependencies..."
    cd "$INSTALL_DIR"
    mix local.hex --force
    mix local.rebar --force
    mix deps.get
    echo "✓ Dependencies installed"
}

# Setup database
setup_db() {
    echo "→ Setting up database..."
    cd "$INSTALL_DIR"
    mix ecto.create 2>/dev/null || true
    mix ecto.migrate
    echo "✓ Database ready"
}

# Create env file
setup_env() {
    if [ ! -f "$INSTALL_DIR/.env" ]; then
        echo "→ Creating .env file..."
        cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
        echo "✓ Created .env (edit with your API keys)"
    else
        echo "✓ .env already exists"
    fi
}

# Main installation
main() {
    echo "Checking prerequisites..."
    echo ""
    check_git
    check_elixir
    echo ""
    
    clone_repo
    echo ""
    
    install_deps
    echo ""
    
    setup_db
    echo ""
    
    setup_env
    echo ""
    
    echo "╔══════════════════════════════════════════╗"
    echo "║         Installation Complete!           ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Configure your API keys:"
    echo "     cd $INSTALL_DIR"
    echo "     nano .env"
    echo ""
    echo "  2. Run the server:"
    echo "     mix run --no-halt"
    echo ""
    echo "  3. Add to VS Code settings.json:"
    echo "     {\"mcp.servers\": {\"mimo\": {"
    echo "       \"command\": \"mix\","
    echo "       \"args\": [\"run\", \"--no-halt\"],"
    echo "       \"cwd\": \"$INSTALL_DIR\""
    echo "     }}}"
    echo ""
    echo "Documentation: https://github.com/pudingtabi/mimo-mcp"
}

main "$@"
