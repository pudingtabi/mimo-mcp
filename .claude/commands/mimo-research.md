# Mimo Research Pattern

Use this when you need to understand something in the codebase before making changes.

## The Pattern: Memory → Code Intelligence → Knowledge Graph → Files

### Step 1: Check Memory First
```
memory operation=search query="[topic you're researching]"
```
If you find relevant context, you may not need to read files.

### Step 2: Use Code Intelligence
For function/class locations:
```
code operation=definition name="[function_name]"
code operation=references name="[class_name]"
code operation=symbols path="[file_path]"
```

For package documentation:
```
code operation=library_get name="[package]" ecosystem=hex
```

### Step 3: Check Knowledge Graph
For relationships and architecture:
```
knowledge operation=query query="what depends on [module]"
knowledge operation=traverse node_id="[node]" direction=both
```

### Step 4: Read Files (if still needed)
Only now, read specific files with purpose.

### Step 5: Store Findings
```
memory operation=store content="[key insight]" category=fact importance=0.7
knowledge operation=teach text="[A] depends on [B]"
```

## Why This Order?

1. Memory is instant - no file I/O
2. Code intelligence is indexed - faster than grep
3. Knowledge graph understands relationships - not just text
4. Files are last resort - slowest but most complete
5. Storing ensures future sessions benefit
