# Prompt Caching Phase 2 Implementation: Strategic Cache Keys

This document describes the implementation of Phase 2 (Strategic Cache Keys) for prompt caching in the llmm project.

## Overview

Phase 2 adds strategic cache key configuration to enable efficient prompt caching for:
- Subagent roles that spawn many instances
- Long-running conversation sessions
- Knowledge-heavy workflows

## Changes Made

### 1. Agent Configuration (`src/llmm/harness/primitives/agent.nim`)

Added two new fields to `AgentConfig`:

```nim
AgentConfig* = object
  # ... existing fields ...
  
  # Prompt Caching Configuration (Phase 2)
  promptCacheKey*       : string  ## Key for grouping related requests
  promptCacheRetention* : string  ## "in_memory" (5-10 min) or "24h" (extended)
```

### 2. OpenAI Responses Provider (`src/llmm/harness/providers/openai_responses.nim`)

Added cache configuration support to the provider:

```nim
OpenAIResponsesProvider* = ref object of LlmProvider
  client*: OpenAIClient
  promptCacheKey*: Option[string]       ## Cache key for prompt caching
  promptCacheRetention*: Option[string] ## "in_memory" or "24h"
```

New procedures added:

- `setPromptCacheConfig()` - Configure cache settings on an existing provider
- `withPromptCacheConfig()` - Create a new provider with different cache settings (shares the same client)

The `startTurn` method now applies cache configuration when creating responses:

```nim
# Apply prompt caching configuration if set
if p.promptCacheKey.isSome:
  opts.promptCacheKey = p.promptCacheKey
if p.promptCacheRetention.isSome:
  opts.promptCacheRetention = p.promptCacheRetention
```

### 3. Agent Initialization (`src/llmm/harness/primitives/agent.nim`)

Added automatic propagation of cache configuration from `AgentConfig` to the provider during agent initialization:

```nim
# Configure prompt caching on OpenAI Responses provider if cache settings are present
if a.provider of OpenAIResponsesProvider:
  if a.cfg.promptCacheKey.len > 0 or a.cfg.promptCacheRetention.len > 0:
    let openaiProv = OpenAIResponsesProvider(a.provider)
    openaiProv.setPromptCacheConfig(
      cacheKey = a.cfg.promptCacheKey,
      retention = a.cfg.promptCacheRetention
    )
```

### 4. Subagent Creation (`src/llmm/harness/primitives/subagents.nim`)

Subagents now get their own provider instances with strategic cache keys:

```nim
# Subagents get strategic cache keys based on their role/name for optimal caching
var subagentProvider = parent.provider
if parent.provider of OpenAIResponsesProvider:
  let openaiParentProv = OpenAIResponsesProvider(parent.provider)
  # Generate strategic cache key: subagent_{role}_{name}_{parent_id}
  let cacheKey = &"subagent_{role.toSlug()}_{name.toSlug()}_{parent.cfg.id[0..7]}"
  let retention = if parent.cfg.promptCacheRetention.len > 0: parent.cfg.promptCacheRetention else: "in_memory"
  subagentProvider = openaiParentProv.withPromptCacheConfig(
    cacheKey = cacheKey,
    retention = retention
  )
```

This ensures that:
- All subagents with the same role share cache keys (efficient for same-role subagents)
- The parent's retention policy is inherited
- Each subagent role type gets its own cache namespace

## Usage Examples

### Example 1: Configure Cache on Main Agent

```nim
import llmm
import llmm/providers/oai/oai_client

let client = newOpenAIClient(apiKey)
let provider = newOpenAIResponsesProvider(client)

var agent = new Agent(
  provider: provider,
  cfg: AgentConfig(
    id: "main-001",
    name: "coordinator",
    model: "gpt-4o",
    systemPrompt: "You are a task coordinator...",
    # Phase 2: Configure prompt caching
    promptCacheKey: "main_coordinator_v1",
    promptCacheRetention: "24h"  # Extended retention for long sessions
  )
)
```

### Example 2: Configure Cache on Existing Provider

```nim
let provider = newOpenAIResponsesProvider(client)
provider.setPromptCacheConfig(
  cacheKey = "research_session_001",
  retention = "in_memory"
)
```

### Example 3: Subagents Automatically Get Strategic Cache Keys

```nim
# Parent agent with caching enabled
var coordinator = new Agent(
  provider: provider,
  cfg: AgentConfig(
    id: "coord-001",
    name: "coordinator",
    model: "gpt-4o",
    promptCacheRetention: "24h"
  )
)
coordinator.enableSubagents(maxSubagents = 5)

# When subagents are created, they automatically get cache keys like:
# - "subagent_researcher_analyst_1a2b3c4d" (for a researcher role)
# - "subagent_coder_helper_1a2b3c4d" (for a coder role)
```

## Cache Key Strategy

The implementation follows these strategic principles:

1. **Main Agents**: Use explicit cache keys set in `AgentConfig`
2. **Subagents**: Automatically generate cache keys based on role and name
3. **Format**: `subagent_{role}_{name}_{parent_id_short}`
   - Groups same-role subagents under the same cache key
   - Includes parent ID to prevent cross-parent collisions
   - Uses slugs for URL-safe keys

## Benefits

1. **Efficiency**: Same-role subagents share cached prefixes (system prompts, tool definitions)
2. **Cost Savings**: Repeated tool definitions and instructions are cached
3. **Performance**: 5-10 min (in_memory) or 24h (extended) cache lifetime
4. **Automatic**: Subagents automatically get optimal cache configuration

## Downsides & Considerations

| Downside | Mitigation |
|----------|------------|
| Cache misses cost the same | Monitor hit rates via `cachedTokens` in usage |
| 5-10 min cache lifetime (in-memory) | Use `24h` retention for important workflows |
| >15 req/min overflow | Cache key design groups similar traffic |
| Zero Data Retention conflict | Use `in_memory` for ZDR compliance |
| Only exact prefix matches | Version cache keys when changing prompts |
| 1024 token minimum | Small prompts get no benefit (expected) |

## Migration Guide

### For Existing Code

No changes required. The implementation is backward compatible:
- Agents without cache config work as before
- Existing subagents continue to function
- Cache keys are only applied when explicitly configured

### To Enable Caching

Add cache configuration to your agent config:

```nim
cfg: AgentConfig(
  # ... existing config ...
  promptCacheKey: "my_agent_v1",      # Optional: group related requests
  promptCacheRetention: "in_memory"   # Optional: "in_memory" or "24h"
)
```

For subagents, caching is automatic when the parent has `promptCacheRetention` set.

## Future Work (Phase 3)

Phase 3 will focus on prompt reordering to maximize cacheable prefix:
1. Move all static content to the beginning of prompts
2. Group tool definitions, instructions, examples
3. Put dynamic conversation history at the end
