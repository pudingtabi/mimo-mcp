# Mimo Deep Thinking

For complex decisions, architectural questions, or when you need to think harder.

## Two Systems

### 1. Guided Reasoning (Flexible)
```
reason operation=guided problem="[the question]" strategy=auto
reason operation=step session_id="[id]" thought="[reasoning]"
reason operation=conclude session_id="[id]"
```

### 2. Cognitive Amplifier (Strict, 3+ steps)

| Level | Steps | Challenges | Use Case |
|-------|-------|------------|----------|
| `standard` | 3+ | 2 | Most cases |
| `deep` | 5+ | 4 | Critical decisions |
| `exhaustive` | 7+ | max | Use sparingly |

```
reason operation=amplify_start problem="[question]" level="standard"
reason operation=amplify_think session_id="[id]" thought="[step]"
reason operation=amplify_challenge session_id="[id]" challenge_id="[id]" response="[address it]"
reason operation=amplify_conclude session_id="[id]"
```

## When to Use

| Guided | Amplifier |
|--------|-----------|
| General exploration | Critical decisions |
| Quick structured thinking | "Think harder" requests |
| Flexible multi-step | Architectural choices |

**Key insight**: Without explicit invocation, LLMs give shallow answers. These tools force genuine consideration.

ARGUMENTS: $ARGUMENTS
