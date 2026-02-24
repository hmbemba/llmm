# Prompt Caching Phase 2 - Strategic Cache Keys Implementation

## Summary
Implemented strategic prompt cache key management to enable intelligent grouping of related requests for optimal cache hit rates. This is particularly valuable for subagent systems where multiple agents share similar prompts.

## Changes Made

### 1. `src/llmm/harness/primitives/agent.nim`
Added cache configuration fields to `AgentConfig`:
- `promptCacheKey: string` - Key for grouping related requests (e.g., "researcher_v1")
- `promptCacheRetention: string` - "in_memory" (5-10 min) or "24h" (extended)

### 2. `src/llmm/harness/providers/base.nim`
Updated `startTurn` method signature to accept cache parameters:
- `promptCacheKey: Option[string]`
- `promptCacheRetention: Option[string]`

### 3. `src/llmm/harness/providers/openai_responses.nim`
- Updated `startTurn` implementation to pass cache settings to `CreateResponseOptions`
- Cache key and retention are now forwarded to OpenAI API requests

### 4. `src/llmm/harness/providers/kimi_chat.nim`
- Updated method signature for compatibility (Kimi doesn't support prompt caching yet)
- Parameters are accepted but discarded with explicit comments

### 5. `src/llmm/harness/primitives/tick.nim`
- Extracts cache settings from agent config
- Passes them to provider's `startTurn` method
- Logs cache key info for observability

### 6. `src/llmm/harness/primitives/subagents.nim`
Added automatic cache key generation for subagents:
- New parameters in `createSubagent()`: `promptCacheKey` and `promptCacheRetention`
- Auto-generated keys follow pattern: `subagent_{parent}_{role}_v1`
- Groups similar subagents together for optimal cache hit rates
- Event emission includes cache configuration

## How It Works

### Cache Key Strategy
The key insight from OpenAI's docs: **requests >15/min with same prefix+key overflow to new machines**.

Subagents automatically generate cache keys hierarchically:
```
subagent_mainagent_researcher_v1
subagent_mainagent_coder_v1
subagent_mainagent_reviewer_v1
```

This groups similar subagents (same role) together while keeping each key's request rate under 15/min.

### Usage Examples

#### Manual Cache Key for Main Agent
```nim
var agent = new Agent(
  cfg: AgentConfig(
    name: "code_assistant",
    model: "gpt-4o",
    systemPrompt: systemPrompt,
    promptCacheKey: "code_assistant_prod_v1",  # Group all sessions
    promptCacheRetention: "24h"  # Extended retention for long workflows
  ),
  provider: provider
)
```

#### Subagent with Auto Cache Key (Default)
```nim
let researcher = await parent.createSubagent(
  name = "clinical_researcher",
  role = "Medical research specialist",
  instructions = "Research clinical trials..."
  # Cache key auto-generated: "subagent_parent_clinical-researcher_v1"
  # Retention: "in_memory" (default)
)
```

#### Subagent with Custom Cache Key
```nim
let coder = await parent.createSubagent(
  name = "security_reviewer",
  role = "Security code reviewer",
  instructions = "Review for security vulnerabilities...",
  promptCacheKey = "security_reviewers_v1",  # Custom grouping
  promptCacheRetention = "24h"  # Extended retention
)
```

## Benefits

1. **Automatic Optimization**: Subagents automatically share cache keys based on role
2. **Reduced Costs**: Higher cache hit rates = fewer tokens charged at full price
3. **Better Performance**: Cached prompts have lower latency
4. **Flexible Configuration**: Override defaults when needed for specific use cases

## Monitoring

Cache hit rates are automatically logged at the end of each turn:
```
=== chatTurn DONE === 2500 tokens used, 2.5s elapsed, 1920 cached tokens (76.8% cache hit rate)
```

Subagent creation logs include cache key:
```
Created subagent researcher with ID xyz, cacheKey: subagent_main_researcher_v1
```

## Database Integration

Cached token counts are stored in the database with each assistant message, allowing you to analyze cache performance over time:

```sql
-- Get cache hit rates by subagent role
SELECT 
    json_extract(content, '$.cacheKey') as cache_key,
    SUM(tokens_used) as total_tokens,
    SUM(cached_tokens) as cached_tokens,
    ROUND(100.0 * SUM(cached_tokens) / NULLIF(SUM(tokens_used), 0), 2) as hit_rate
FROM chat_history_row
WHERE role = 'assistant' AND cache_key LIKE 'subagent_%'
GROUP BY cache_key;
```

## Next Steps (Phase 3)

To maximize cache hit rates, consider restructuring prompts to put static content first:

```json
[
  # STATIC - CACHED (system, instructions, persona)
  {"role": "system", "content": "You are a code assistant..."},
  {"role": "developer", "content": "Tool definitions: [...large schema...]"},
  
  # VARIABLE - NOT CACHED (conversation history, user input)
  {"role": "user", "content": "current user query"}
]
```

This reordering would require changes to how messages are built in `tick.nim`.
