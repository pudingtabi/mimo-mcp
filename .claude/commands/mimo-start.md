# Mimo Session Start

Initialize a session with full context.

## Steps

1. **Get synthesized project context**:
```
memory operation=synthesize query="What context do you have about this project, ongoing work, and any pending issues?"
```

2. **Ensure project is indexed** (uses cache if unchanged):
```
onboard path="."
```

3. **Check for pre-computed context** (if background cognition is enabled):
```
memory operation=search query="precomputed_context active topics"
```

## Expected Outcome

You now have:
- Project context and accumulated wisdom
- Code symbols indexed
- Background insights (if available)

Proceed with the user's request.
