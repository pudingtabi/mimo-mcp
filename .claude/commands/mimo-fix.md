# Mimo Fix Pattern

Diagnostic-fix-verify loop for debugging issues.

## Steps

### 1. Check Past Fixes
```
memory operation=search query="fix for [error text or module name]"
```

### 2. Diagnose + Locate
```
code operation=diagnose path="."
code operation=definition name="[failing_function]"
memory operation=graph query="what calls [function]"
```

### 3. Make the Fix
Edit with full context from steps 1-2.

### 4. Verify
```
code operation=diagnose path="."
terminal command="mix test [relevant_test_file]"
```

### 5. Store Solution
```
memory operation=store content="Fixed [error]: [solution]" category=action importance=0.8
```

## Why This Works

- Past fixes save time
- Structured diagnostics catch all issues
- Code intelligence finds root causes
- Verification confirms the fix
- Storing helps future sessions

ARGUMENTS: $ARGUMENTS
