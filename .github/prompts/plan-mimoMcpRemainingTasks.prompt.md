# MIMO-MCP Remaining Tasks: TODOs & Monitoring Deployment

Two minor tasks remaining. Neither blocks production deployment.

---

## TASK 1: Clean Up 8 TODOs (2-3 hours)

### Classification Summary
- **5 TODOs** return placeholder values (`"not_implemented"`, empty `[]`) — need stub implementations or v3.0 roadmap markers
- **3 TODOs** are enhancements — mark as roadmap items

### TODO Details & Actions

#### Group A: Store Integration Placeholders (Mark as v3.0 Roadmap)

These return empty/placeholder responses. Add explicit roadmap comments:

| File | Line | Current TODO | Action |
|------|------|--------------|--------|
| `lib/mimo/brain/classifier.ex` | 271 | `# TODO: Integrate with Semantic Store` | Add: `# v3.0 Roadmap: Full semantic store integration - currently returns []` |
| `lib/mimo/brain/classifier.ex` | 285 | `# TODO: Integrate with Procedural Store` | Add: `# v3.0 Roadmap: Full procedural store integration - currently returns []` |
| `lib/mimo/mcp/tools/procedures.ex` | 60 | `# TODO: Implement procedural store retrieval` | Add: `# v3.0 Roadmap: Procedural store retrieval - returns "not_implemented"` |
| `lib/mimo/store.ex` | 90 | `# TODO: Implement graph/JSON-LD semantic store` | Add: `# v3.0 Roadmap: Graph-based semantic store with JSON-LD support` |
| `lib/mimo/store.ex` | 97 | `# TODO: Implement rule engine procedural store` | Add: `# v3.0 Roadmap: Rule engine for procedural knowledge` |

#### Group B: Enhancement TODOs (Mark as v3.0 Roadmap)

These have working fallbacks but could be improved:

| File | Line | Current TODO | Action |
|------|------|--------------|--------|
| `lib/mimo/resource_monitor.ex` | 36 | `# TODO: Implement actual p99 tracking` | Add: `# v3.0 Roadmap: Real p99 tracking from telemetry (using scheduler utilization as proxy)` |
| `lib/mimo/mcp/tools/procedures.ex` | 384 | `# TODO: Validate against context_schema` | Add: `# v3.0 Roadmap: Context schema validation (currently passes through)` |
| `lib/mimo/fallback/graceful_degradation.ex` | 255 | `# TODO: Implement persistent retry queue` | Add: `# v3.0 Roadmap: Oban-based persistent retry queue (currently logs intent)` |

### Execution

For each TODO, update the comment to follow this pattern:

```elixir
# TODO: [Original description]
# v3.0 Roadmap: [Expanded explanation of what this enables]
# Current behavior: [What happens now - acceptable for v2.x]
```

**Example transformation:**
```elixir
# Before:
# TODO: Implement graph/JSON-LD semantic store

# After:
# TODO: Implement graph/JSON-LD semantic store
# v3.0 Roadmap: Replace ETS-based storage with graph database (Neo4j/Dgraph) 
#               supporting JSON-LD semantic web standards for richer knowledge representation
# Current behavior: Returns {:error, "not_implemented"} - semantic queries handled by episodic store fallback
```

### Verify

```bash
# Count remaining TODOs after cleanup
grep -rn "TODO:" lib/ --include="*.ex" | wc -l
# Should still be 8, but all marked with v3.0 Roadmap context
```

---

## TASK 2: Deploy Monitoring Stack (30 minutes)

### Prerequisites Verified ✅
- `docker-compose.yml` — prometheus, alertmanager, grafana services defined
- `priv/prometheus/prometheus.yml` — scrape config for mimo:4000/metrics
- `priv/prometheus/alertmanager.yml` — template (needs production endpoints)
- `priv/prometheus/mimo_alerts.rules` — 13 alert rules across 6 groups

### Deployment Steps

```bash
# 1. Start monitoring stack
docker-compose up -d prometheus grafana alertmanager

# 2. Verify services running
docker-compose ps | grep -E "prometheus|grafana|alertmanager"

# 3. Check Prometheus targets
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[].health'
# Expected: "up" for mimo-mcp target

# 4. Access Grafana
open http://localhost:3000
# Default: admin/admin (change on first login)

# 5. Import dashboard
# Navigate to: Dashboards → Import → Upload JSON
# File: priv/grafana/mimo-dashboard.json

# 6. Verify metrics flowing
curl -s http://localhost:4000/metrics | head -20
```

### Configure Alertmanager (Optional - Production Only)

Edit `priv/prometheus/alertmanager.yml` with actual endpoints:

```yaml
receivers:
  - name: 'slack-notifications'
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK'
        channel: '#alerts'
        
  - name: 'pagerduty-critical'
    pagerduty_configs:
      - service_key: 'YOUR_PAGERDUTY_KEY'
```

### Verify Deployment

| Check | Command | Expected |
|-------|---------|----------|
| Prometheus up | `curl -s localhost:9090/-/healthy` | `Prometheus Server is Healthy.` |
| Alertmanager up | `curl -s localhost:9093/-/healthy` | `OK` |
| Grafana up | `curl -s localhost:3000/api/health` | `{"database": "ok"}` |
| Metrics scraped | `curl -s localhost:9090/api/v1/targets \| jq` | mimo target "up" |
| Dashboard loads | Grafana UI | 10 panels with data |

---

## SUCCESS CRITERIA

| Task | Verification | Priority |
|------|-------------|----------|
| TODOs cleaned | All 8 TODOs have v3.0 Roadmap context | HIGH (code quality) |
| Monitoring deployed | All 3 services healthy | MEDIUM |
| Metrics flowing | Prometheus shows mimo target "up" | MEDIUM |
| Dashboard works | Grafana panels show live data | MEDIUM |

## TIMELINE

| Task | Time |
|------|------|
| TODO cleanup | 2-3 hours |
| Monitoring deploy | 30 minutes |
| **Total** | **2.5-3.5 hours** |

## NOT BLOCKING PRODUCTION ✅

Both tasks are quality-of-life improvements:
- TODOs: Code clarity for future developers
- Monitoring: Observability for operations team

Production can deploy without these if needed.
