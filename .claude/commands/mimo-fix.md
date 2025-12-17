# Mimo Fix Pattern

Use this when debugging or fixing issues.

## The Diagnostic-Fix-Verify Loop

### Step 1: Check Past Fixes
```
memory operation=search query="similar error [paste error text]"
memory operation=search query="fix for [module/function name]"
```
You may have solved this before.

### Step 2: Get Structured Diagnostics
```
code operation=diagnose path="."
```
This gives you compiler errors, linter warnings, and type issues in one call.

### Step 3: Locate the Problem
```
code operation=definition name="[failing_function]"
code operation=references name="[problematic_symbol]"
```

### Step 4: Understand Context
```
knowledge operation=query query="what calls [function]"
```

### Step 5: Make the Fix
Edit the code with full context.

### Step 6: Verify the Fix
```
code operation=diagnose path="."
terminal command="mix test [relevant_test_file]"
```

### Step 7: Store the Solution
```
memory operation=store content="Fixed [error]: [solution description]" category=action importance=0.8
```

## Why This Works

- Past fixes save time (memory search)
- Structured diagnostics catch all issues
- Code intelligence finds root causes
- Verification confirms the fix
- Storing helps future sessions
