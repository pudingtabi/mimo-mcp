# Mimo Deep Thinking

Use this when facing complex decisions, architectural questions, or when you need to think harder.

## Two Reasoning Systems

### 1. Guided Reasoning (Flexible, 1+ steps)
For general complex questions:
```
reason operation=guided problem="[the question/problem]" strategy=auto
```

Then follow with:
```
reason operation=step session_id="[id]" thought="[your reasoning step]"
reason operation=conclude session_id="[id]"
```

### 2. Cognitive Amplifier (Strict, 3+ steps)
For when you need GUARANTEED depth:
```
reason operation=amplify_start problem="[the question]" level="deep"
```

Levels:
- `standard` - 3+ steps, 2 challenges, 2 perspectives
- `deep` - 5+ steps, 4 challenges, 3 perspectives, coherence validation
- `exhaustive` - 7+ steps, maximum amplification

Then follow the amplifier's requirements:
```
reason operation=amplify_think session_id="[id]" thought="[step]"
reason operation=amplify_challenge session_id="[id]" challenge_id="[id]" response="[address it]"
reason operation=amplify_perspective session_id="[id]" perspective="security" insights=["..."]
reason operation=amplify_conclude session_id="[id]"
```

## When to Use Each

**Use Guided for:**
- General exploration
- When you need flexibility
- Quick but structured thinking

**Use Amplifier for:**
- Critical decisions
- When explicitly asked to "think harder"
- Architectural choices
- When you catch yourself giving shallow answers

## The Key Insight

Without explicit invocation, LLMs give shallow "lawyer's defense" answers. These tools force genuine consideration of counter-arguments and verification.
