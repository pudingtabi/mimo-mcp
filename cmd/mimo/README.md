# mimo CLI

Shell-native interface to Mimo Memory OS via the Universal Aperture HTTP gateway.

## Building

```bash
# Build for current platform
go build -o mimo .

# Build static binary for Linux
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o mimo-linux-amd64 .

# Build for macOS
CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -ldflags="-s -w" -o mimo-darwin-amd64 .
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -o mimo-darwin-arm64 .

# Build for Windows
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -ldflags="-s -w" -o mimo-windows-amd64.exe .
```

## Installation

```bash
# Download and install
curl -LO https://github.com/pudingtabi/mimo-mcp/releases/latest/download/mimo-linux-amd64
chmod +x mimo-linux-amd64
sudo mv mimo-linux-amd64 /usr/local/bin/mimo

# Or build from source
go install github.com/pudingtabi/mimo-mcp/cmd/mimo@latest
```

## Usage

```bash
# Set up environment
export MIMO_API_KEY="your-api-key"  # Optional if no auth configured
export MIMO_ENDPOINT="http://localhost:4000"  # Default

# Natural language query
mimo ask "How do I center a div with Flexbox?"

# Vector similarity search
mimo run search_vibes --query "mysterious atmosphere" --limit 5

# Store a fact
mimo run store_fact --content "User prefers dark mode" --category fact

# Shell pipeline (git commit message generator)
git diff | mimo ask "Write a concise commit message" | git commit -F -

# Sandbox mode (safe for untrusted scripts)
mimo --sandbox ask "What are the best practices?"
```

## Shell Integration

### Git Commit Message Generator

```bash
# ~/.bashrc or ~/.zshrc
git-ai-commit() {
    local diff=$(git diff --cached)
    if [[ -z "$diff" ]]; then
        echo "No staged changes"
        return 1
    fi
    local msg=$(echo "$diff" | mimo ask "Write a concise commit message in present tense")
    git commit -m "$msg"
}
```

### Bash Completion

```bash
# Generate completion script
_mimo_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=($(compgen -W "ask run tools health version help" -- "$cur"))
    elif [[ ${COMP_WORDS[1]} == "run" && ${COMP_CWORD} -eq 2 ]]; then
        COMPREPLY=($(compgen -W "search_vibes store_fact recall_procedure mimo_reload_skills" -- "$cur"))
    fi
}
complete -F _mimo_completions mimo
```

### Zsh Completion

```zsh
# ~/.zshrc
_mimo() {
    local -a commands tools
    commands=(
        'ask:Query the Meta-Cognitive Router'
        'run:Execute a specific tool'
        'tools:List available tools'
        'health:Check system health'
        'version:Show version'
        'help:Show help'
    )
    tools=(
        'search_vibes:Vector similarity search'
        'store_fact:Store a fact'
        'recall_procedure:Retrieve a procedure'
        'mimo_reload_skills:Reload skills'
    )
    
    if (( CURRENT == 2 )); then
        _describe -t commands 'mimo commands' commands
    elif (( CURRENT == 3 )) && [[ ${words[2]} == "run" ]]; then
        _describe -t tools 'mimo tools' tools
    fi
}
compdef _mimo mimo
```
