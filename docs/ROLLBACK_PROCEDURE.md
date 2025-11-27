# Production Rollback Procedure

This document outlines the procedures for rolling back Mimo-MCP in production.

## Table of Contents
- [Quick Rollback](#quick-rollback)
- [Database Rollback](#database-rollback)
- [Full Rollback Checklist](#full-rollback-checklist)
- [Verification Steps](#verification-steps)
- [Communication Protocol](#communication-protocol)
- [Post-Rollback Actions](#post-rollback-actions)

---

## Quick Rollback (< 5 minutes)

### Docker Compose Deployment

```bash
# 1. Stop the current container
docker-compose down mimo

# 2. Tag the current (failed) image for debugging
docker tag mimo:current mimo:failed-$(date +%Y%m%d_%H%M%S)

# 3. Restore the previous working image
docker tag mimo:previous mimo:current

# 4. Start with the previous version
docker-compose up -d mimo

# 5. Verify the rollback
curl http://localhost:4000/health
```

### Docker Swarm Deployment

```bash
# Rollback service to previous version
docker service rollback mimo-mcp_mimo

# Or specify exact version
docker service update --image mimo:v2.3.0 mimo-mcp_mimo
```

### Kubernetes Deployment

```bash
# Rollback to previous revision
kubectl rollout undo deployment/mimo-mcp

# Or rollback to specific revision
kubectl rollout undo deployment/mimo-mcp --to-revision=2

# Check rollout status
kubectl rollout status deployment/mimo-mcp
```

---

## Database Rollback

### Ecto Migrations

```bash
# Rollback the last migration
mix ecto.rollback --step 1

# Rollback multiple migrations
mix ecto.rollback --step 3

# Rollback to specific version
mix ecto.rollback --to 20251127000000

# Check current migration status
mix ecto.migrations
```

### SQLite Database Backup Restore

```bash
# Stop the application
docker-compose stop mimo

# Restore from backup
cp /backups/mimo_db_$(date +%Y%m%d).sqlite priv/repo/mimo.db

# Restart application
docker-compose start mimo
```

### Data Recovery from Backup

If data was corrupted:

```bash
# 1. Stop the application
docker-compose stop mimo

# 2. Identify available backups
ls -la /backups/

# 3. Restore the most recent good backup
cp /backups/mimo_backup_YYYYMMDD_HHMMSS.tar.gz /tmp/
cd /tmp && tar -xzf mimo_backup_*.tar.gz

# 4. Replace current data
cp -r /tmp/mimo_data/* /var/lib/mimo/

# 5. Restart
docker-compose start mimo
```

---

## Full Rollback Checklist

### Pre-Rollback (2 minutes)

- [ ] Identify the issue and confirm rollback is necessary
- [ ] Note the current version: `docker inspect mimo:current | grep version`
- [ ] Check if database migrations need reverting
- [ ] Notify on-call engineer
- [ ] Enable detailed logging if not already active

### Execute Rollback (3-5 minutes)

- [ ] Stop incoming traffic (if load balancer available)
- [ ] Stop current container
- [ ] Rollback database if needed
- [ ] Start previous version
- [ ] Verify health endpoints
- [ ] Re-enable traffic

### Post-Rollback Verification (5 minutes)

- [ ] Health check passes: `curl localhost:4000/health`
- [ ] Basic functionality works: run smoke tests
- [ ] Error rates normalized in Grafana
- [ ] No new errors in logs
- [ ] Circuit breakers closed

---

## Verification Steps

### Health Check

```bash
# Basic health
curl -s http://localhost:4000/health | jq .

# Expected response:
# {
#   "status": "ok",
#   "version": "2.3.0",
#   "services": {
#     "database": "healthy",
#     "ollama": "healthy"
#   }
# }
```

### Smoke Tests

```bash
# Run smoke test suite
./test_skills.sh

# Or manually test critical endpoints:

# 1. Test ask endpoint
curl -X POST http://localhost:4000/api/ask \
  -H "Content-Type: application/json" \
  -d '{"query": "What time is it?"}'

# 2. Test tools listing
curl http://localhost:4000/api/tools

# 3. Test metrics endpoint
curl http://localhost:4000/metrics | head -20
```

### Monitor Metrics

Check Grafana dashboards at http://localhost:3000:

1. **Error Rate Panel**: Should drop below 1%
2. **Response Time Panel**: p95 should be under 500ms
3. **Circuit Breaker Panel**: All circuits should be closed
4. **Memory Usage Panel**: Should be stable, no unbounded growth

### Log Analysis

```bash
# Check for errors in last 5 minutes
docker logs mimo-mcp --since 5m 2>&1 | grep -i error

# Check circuit breaker state
docker logs mimo-mcp --since 5m 2>&1 | grep -i "circuit"

# Check for panics or crashes
docker logs mimo-mcp --since 5m 2>&1 | grep -E "(panic|crash|SIGTERM)"
```

---

## Communication Protocol

### During Incident

1. **Slack Channel**: Post to #engineering-incidents
   ```
   🚨 INCIDENT: Mimo-MCP production issue detected
   Status: Investigating
   Impact: [describe user impact]
   Current action: [rolling back / investigating]
   ETA: [time estimate]
   ```

2. **Status Page**: Update status.yourcompany.com if user-facing

### After Rollback

1. **Slack Update**:
   ```
   ✅ RESOLVED: Mimo-MCP rolled back to v2.3.0
   Duration: [X minutes]
   Impact: [description]
   Root cause: [brief summary, detailed in post-mortem]
   ```

2. **Create Incident Ticket**: Document in issue tracker

---

## Post-Rollback Actions

### Immediate (within 1 hour)

1. **Create Incident Report**
   - Timeline of events
   - Actions taken
   - Preliminary root cause

2. **Prevent Re-deployment**
   - Block the problematic version in CI/CD
   - Add warning to deployment pipeline

3. **Monitor Closely**
   - Watch error rates for 1 hour
   - Check for cascading failures

### Short-term (within 24 hours)

1. **Root Cause Analysis**
   - Review logs and metrics
   - Identify the failing component
   - Document findings

2. **Post-Mortem Meeting**
   - Schedule with stakeholders
   - Prepare incident timeline
   - Identify action items

3. **Fix Development**
   - Create fix in development branch
   - Add tests covering the failure scenario
   - Plan careful re-deployment

### Long-term Improvements

- [ ] Add monitoring for the failure scenario
- [ ] Improve test coverage
- [ ] Update runbooks if needed
- [ ] Consider architectural improvements

---

## Emergency Contacts

| Role | Contact |
|------|---------|
| On-call Engineer | Check PagerDuty rotation |
| Platform Lead | [name@company.com] |
| Database Admin | [dba@company.com] |
| Security | security@company.com |

---

## Appendix: Common Issues and Fixes

### Issue: High Memory Usage After Rollback

```bash
# Force garbage collection
docker exec mimo-mcp /bin/sh -c "curl localhost:4000/admin/gc"

# If still high, restart container
docker-compose restart mimo
```

### Issue: Database Connection Pool Exhausted

```bash
# Check connection count
docker exec mimo-mcp /bin/sh -c "curl localhost:4000/health | jq .db_pool"

# Restart to reset pool
docker-compose restart mimo
```

### Issue: Circuit Breakers Stuck Open

```bash
# Reset all circuit breakers via admin endpoint
curl -X POST http://localhost:4000/admin/circuit-breakers/reset

# Or restart the service
docker-compose restart mimo
```

### Issue: Ollama Service Unavailable

```bash
# Check Ollama status
docker-compose logs ollama --tail 50

# Restart Ollama
docker-compose restart ollama

# Mimo will auto-recover with hash-based embeddings
```
