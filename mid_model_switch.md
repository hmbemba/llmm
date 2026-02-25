# Mid-Session Model Switching Feature Plan

## Overview
Add the ability for users to switch LLM models mid-session in `chat_repl_classic.nim` using a `/model` command (e.g., `/model k2` to switch to Kimi K2).

## Goals
- Allow seamless model switching without restarting the REPL
- Support convenient aliases (k2, g4, etc.) for common models
- Maintain conversation context across model switches
- Provide clear feedback about the current and switched models

## Implementation Plan

### 1. Add Model Registry and Aliases
**File**: `chat_repl_classic.nim`

Add a model alias mapping and a proc to resolve aliases:

```nim
const ModelAliases* = {
  "k2": "kimi-k2-xxx",      # Kimi K2
  "k2-latest": "kimi-k2-latest",
  "k1.5": "kimi-k1.5-xxx",  # Kimi K1.5
  "g4": "gpt-4",            # GPT-4
  "g4o": "gpt-4o",          # GPT-4o
  "g4om": "gpt-4o-mini",    # GPT-4o Mini
  "o1": "o1",               # O1
  "o3": "o3-mini",          # O3 Mini
  "c": "claude-3-xxx",      # Claude (if supported)
}.toTable()

proc resolveModelAlias*(input: string): string =
  ## Resolve a model alias to full model name
  let key = input.toLowerAscii().strip()
  if ModelAliases.hasKey(key):
    return ModelAliases[key]
  return input  # Return as-is if not an alias
```

### 2. Update AgentConfig Model at Runtime
**File**: `chat_repl_classic.nim`

Add a proc to update the model on the agent:

```nim
proc switchModel*(a: Agent, model: string): bool =
  ## Switch the agent to a different model
  ## Returns true if successful, false otherwise
  try:
    let resolved = resolveModelAlias(model)
    
    # Update the config
    a.cfg.model = resolved
    
    # Re-initialize the provider with new model
    # This depends on provider implementation details
    # For now, update the config - provider will use it on next turn
    
    return true
  except CatchableError as ex:
    icy &"Failed to switch model: {ex.msg}"
    return false
```

### 3. Add /model Command Processing
**File**: `chat_repl_classic.nim` in `processCommand` proc

Add case for `/model` command:

```nim
of "/model":
  if arg.len == 0:
    # Show current model
    printMeta(&"Current model: {a.cfg.model}", theme)
    echo $styled("    Available aliases:").fg(theme.metaText)
    for alias, full in ModelAliases.pairs:
      echo $styled(&"      {alias:12} → {full}").fg(theme.metaText).style(dim)
  else:
    let targetModel = resolveModelAlias(arg)
    let oldModel = a.cfg.model
    
    if targetModel == oldModel:
      printMeta(&"Already using model: {targetModel}", theme)
    else:
      if switchModel(a, arg):
        printMeta(&"Switched model: {oldModel} → {targetModel}", theme)
      else:
        printError(&"Failed to switch to model: {targetModel}", theme)
  return true
```

### 4. Update Help Text
**File**: `chat_repl_classic.nim` in `printHelp` proc

Add to the commands list:
```nim
("/model [alias|name]", "Show or switch to a different LLM model"),
```

Add new section for model aliases:
```nim
echo ""
echo $styled("  Model Aliases").fg(theme.headerAccent).style(bold, underline)
echo ""
let modelCmds = @[
  ("k2",     "Kimi K2"),
  ("k1.5",   "Kimi K1.5"),
  ("g4",     "GPT-4"),
  ("g4o",    "GPT-4o"),
  ("g4om",   "GPT-4o Mini"),
  ("o1",     "O1"),
  ("o3",     "O3 Mini"),
]
for (alias, desc) in modelCmds:
  let padded = alias & " ".repeat(max(1, 10 - alias.len))
  echo $styled("    ").fg(theme.metaText) &
       $styled(padded).fg(cyan).style(bold) &
       $styled(desc).fg(theme.metaText)
```

### 5. Update printCfg to Show Model
**File**: `chat_repl_classic.nim` in `printCfg` proc

Ensure model is displayed in config output (should already be there, verify it's visible).

### 6. Consider Provider Compatibility
**Note**: Model switching needs to consider:
- OpenAI-compatible providers support model switching per-request
- Some providers may need re-initialization
- Document any limitations in the help text

## Usage Examples

```
> /model
Current model: gpt-4o-mini
    Available aliases:
      k2           → kimi-k2-xxx
      k2-latest    → kimi-k2-latest
      ...

> /model k2
Switched model: gpt-4o-mini → kimi-k2-xxx

> write a poem
[Uses Kimi K2]

> /model g4o
Switched model: kimi-k2-xxx → gpt-4o

> analyze that poem
[Uses GPT-4o]
```

## Implementation Order
1. Add model alias table and resolver proc
2. Add `switchModel` proc to update agent config
3. Add `/model` case to `processCommand`
4. Update help text with model aliases section
5. Test switching between available models

## Edge Cases
- Unknown model names: Pass through as-is (provider may reject)
- Same model switch: Show "already using" message
- Provider doesn't support model: Will fail on next API call with appropriate error
- Aliases are case-insensitive
