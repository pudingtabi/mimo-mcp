# Security Policy

## Reporting Security Issues

If you discover a security vulnerability in Mimo, please email the maintainers. **Do not create public GitHub issues for security vulnerabilities.**

---

## Security Measures

### 1. Secrets Management

**✅ What We Do:**
- All sensitive credentials loaded from environment variables
- `.env` file gitignored (never committed)
- `.env.example` contains only placeholders
- No hardcoded API keys, tokens, or passwords in code

**📋 Environment Variables:**
| Variable | Purpose | Security Level |
|----------|---------|----------------|
| `OPENROUTER_API_KEY` | LLM API access | **HIGH** - Keep secret |
| `MIMO_API_KEY` | HTTP API authentication | **HIGH** - Generate unique key |
| `MIMO_SECRET_KEY_BASE` | Phoenix session signing | **CRITICAL** - Use `mix phx.gen.secret` |
| `GITHUB_TOKEN` | GitHub API access | **HIGH** - Keep secret |
| `EXA_API_KEY` | Exa AI search | **MEDIUM** - Optional feature |
| `OLLAMA_URL` | Local embeddings | **LOW** - Usually localhost |

**🔐 Best Practices:**
```bash
# Generate secure keys
openssl rand -hex 32  # For MIMO_API_KEY
mix phx.gen.secret    # For MIMO_SECRET_KEY_BASE

# Never commit .env
git status  # Should NOT show .env

# Use different keys per environment
# Production keys ≠ Development keys ≠ Test keys
```

---

### 2. Database Security

**✅ What We Do:**
- Database files (`.db`, `.db-*`) gitignored
- User data never committed to repository
- SQLite files stored in `priv/` (outside web root)

**⚠️ Never Commit:**
- `priv/mimo_mcp.db` - Production database
- `priv/mimo_mcp_test.db` - Test database
- `*.db.backup-*` - Database backups
- `*.db.old` - Old database versions

**📦 Backup Safely:**
```bash
# Good: Backup to external location
cp priv/mimo_mcp.db ~/backups/mimo-$(date +%Y%m%d).db

# Bad: Backup in repository (will be committed!)
# cp priv/mimo_mcp.db priv/mimo_mcp.db.backup  ❌
```

---

### 3. File Exposure Prevention

**✅ What's Gitignored:**
```
✓ Environment files (.env, .env.*)
✓ Secrets directories (secrets/, credentials/)
✓ Cryptographic keys (*.pem, *.key, *.crt)
✓ Database files (*.db, *.db-*)
✓ Binary packages (*.deb, *.rpm, *.dmg)
✓ Large ML models (*.gguf, *.bin, models/)
✓ Logs (*.log, erl_crash.dump)
✓ IDE files (.vscode/, .idea/)
✓ Build artifacts (_build/, deps/)
```

**📝 Before Committing:**
```bash
# 1. Check what you're committing
git status
git diff --cached

# 2. Scan for accidental secrets
git diff --cached | grep -iE "(password|secret|api_key|token|bearer)"

# 3. Check file sizes
git ls-files -s | awk '{print $4, $2}' | numfmt --field=2 --to=iec-i | sort -hr | head -10

# 4. Use git hooks (optional)
# Install pre-commit hook to scan for secrets
```

---

### 4. API Security

**HTTP API Authentication:**
- Requires `MIMO_API_KEY` in production
- Validates via `Authorization: Bearer <token>` header
- Disabled in development (optional)

**MCP Protocol:**
- Stdio mode: No authentication (local only)
- HTTP mode: Requires API key

**WebSocket Security:**
- API key required for Cortex channel
- Channel scoped per agent ID
- Connections closed on authentication failure

---

### 5. Code Security Patterns

**✅ Safe Patterns:**
```elixir
# Good: Read from environment
api_key = System.get_env("OPENROUTER_API_KEY")

# Good: Use Application config
api_key = Application.get_env(:mimo_mcp, :api_key)

# Good: Conditional authentication
if Mix.env() == :prod do
  require_authentication()
end
```

**❌ Unsafe Patterns:**
```elixir
# Bad: Hardcoded secret
api_key = "sk-proj-abc123..."  # ❌ NEVER DO THIS

# Bad: Secret in config file
config :mimo_mcp, api_key: "sk-..."  # ❌ NEVER

# Bad: Secret in version control
# Even in config/prod.secret.exs  # ❌ NEVER
```

---

### 6. Dependency Security

**NPM Dependencies:**
```bash
# Audit for vulnerabilities
npm audit

# Fix automatically
npm audit fix
```

**Hex Dependencies:**
```bash
# Check for security advisories
mix hex.audit

# Update dependencies
mix deps.update --all
```

---

### 7. Production Deployment

**Environment Checklist:**
- [ ] `MIMO_API_KEY` set to strong random value (≥32 chars)
- [ ] `MIMO_SECRET_KEY_BASE` set to strong secret (≥64 chars)
- [ ] `OPENROUTER_API_KEY` set (if using LLM features)
- [ ] `LOGGER_LEVEL=error` or `warn` (not `debug`)
- [ ] Database backups stored securely (not in repository)
- [ ] Firewall configured (only expose necessary ports)
- [ ] HTTPS enabled for web interface
- [ ] Rate limiting configured
- [ ] Monitor logs for suspicious activity

**Production .env Template:**
```bash
# Critical production settings
MIMO_API_KEY=<generate-with-openssl-rand-hex-32>
MIMO_SECRET_KEY_BASE=<generate-with-mix-phx-gen-secret>
OPENROUTER_API_KEY=<your-key>
LOGGER_LEVEL=warn
MIX_ENV=prod
```

---

### 8. Incident Response

**If You Accidentally Commit Secrets:**

1. **Rotate immediately** - Generate new keys/tokens
2. **Remove from history:**
   ```bash
   # Use git-filter-repo (recommended)
   git filter-repo --path .env --invert-paths
   
   # Or BFG Repo Cleaner
   bfg --delete-files .env
   
   # Force push (coordinate with team!)
   git push origin --force --all
   ```
3. **Notify affected services** - Revoke compromised tokens
4. **Update documentation** - Record incident and remediation

**If Database Was Committed:**
1. Delete from git history (see above)
2. Assess data exposure risk
3. Notify affected users if PII was exposed
4. Review backup procedures

---

### 9. CI/CD Security

**GitHub Actions:**
- Use repository secrets for sensitive values
- Never echo secrets in logs
- Use minimal permissions (GITHUB_TOKEN)
- Scan for secrets in PRs

**Example Secret Usage:**
```yaml
env:
  MIMO_API_KEY: ${{ secrets.MIMO_API_KEY }}
  
steps:
  - name: Run tests
    run: mix test
    # Secrets automatically masked in logs
```

---

### 10. Security Scanning

**Automated Tools:**
```bash
# Scan for secrets in git history
git log -p | grep -iE "(password|secret|api_key|token)" || echo "Clean"

# Check for large files
git rev-list --objects --all | \
  git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' | \
  awk '/^blob/ {print substr($0,6)}' | sort --numeric-sort --key=2 | tail -10

# Find committed .env files
git log --all --full-history -- .env
```

**Manual Review:**
- Review `.gitignore` quarterly
- Audit environment variables
- Check for hardcoded IPs/domains
- Review authentication logic

---

## Security Contacts

For security issues, contact the maintainers via:
- **Email:** [To be added]
- **Security Advisory:** Use GitHub Security Advisory feature

---

## Compliance

This project follows:
- OWASP Top 10 security practices
- CWE/SANS Top 25 mitigation strategies
- Secure coding standards for Elixir/Phoenix

---

**Last Updated:** December 11, 2025
