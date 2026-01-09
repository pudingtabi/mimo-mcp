# Mimo Research Pattern

Understand something before making changes: Memory → Code Intelligence → Files.

## Steps

### 1. Check Memory First
```
memory operation=search query="[topic]"
```
If found, you may not need to read files.

### 2. Use Code Intelligence
```
code operation=definition name="[function_name]"
code operation=references name="[class_name]"
code operation=library_get name="[package]" ecosystem=hex
```

### 3. Check Knowledge Graph
```
memory operation=graph query="what depends on [module]"
```

### 4. Read Files (if still needed)
Only now, read specific files with purpose.

### 5. Store Findings
```
memory operation=store content="[key insight]" category=fact importance=0.7
```

## Why This Order?

1. **Memory** - instant, no I/O
2. **Code intelligence** - indexed, faster than grep
3. **Knowledge graph** - understands relationships
4. **Files** - last resort, slowest but complete
5. **Store** - future sessions benefit

ARGUMENTS: $ARGUMENTS
