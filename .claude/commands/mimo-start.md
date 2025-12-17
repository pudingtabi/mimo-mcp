# Mimo Session Start

Begin a new session with proper context gathering.

## Steps

1. First, query accumulated wisdom about this project:
```
ask_mimo query="What context do you have about this project and any ongoing work?"
```

2. Check memory for recent sessions:
```
memory operation=search query="recent session work progress"
```

3. If this is a new/unknown project, run onboarding:
```
onboard path="."
```

4. Check for any pending tasks or known issues:
```
memory operation=search query="pending tasks TODO issues"
```

## Expected Outcome

You should now have:
- Project context from Mimo's accumulated wisdom
- Recent session history if any
- Code symbols indexed (if onboarded)
- Known issues or pending work

Proceed with the user's request with full context.
