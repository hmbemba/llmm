# Prompt Caching Phase 1 - Observability Implementation

## Summary
Added comprehensive observability for OpenAI's prompt caching feature. The system now tracks and logs cache hit metrics for all API requests.

## Changes Made

### 1. `src/llmm/harness/providers/base.nim`
- Added `cachedTokens: int` field to the `Usage` object
- Updated `%` operator to include `cached_tokens` in JSON serialization

### 2. `src/llmm/harness/providers/openai_responses.nim`
- Updated `toProviderUsage()` to extract `cachedTokens` from `inputTokensDetails.cachedTokens`
- Falls back to 0 if no cache details are present

### 3. `src/llmm/harness/primitives/tick.nim`
- Added `cached` field to `totalTokensUsed` tracking tuple
- Accumulates cached tokens throughout the tool loop
- Logs cache hit rate at end of turn:
  ```
  === chatTurn DONE === 2500 tokens used, 2.5s elapsed, 1920 cached tokens (76.8% cache hit rate)
  ```

### 4. `src/llmm/harness/primitives/store.nim`
- Added `cachedTokens: int` field to `ChatHistoryRow` database type
- Added schema migration for existing databases (adds `cached_tokens` column)
- Updated `insertChatEntry()` procedure to accept and store `cachedTokens`
- Stores cached token count with each assistant message

## What This Enables

1. **Visibility**: You can now see cache hit rates in your agent logs
2. **Monitoring**: Cache metrics are persisted to the database for analysis
3. **Cost Tracking**: Calculate actual savings from prompt caching
4. **Optimization**: Identify opportunities to improve cache hit rates

## How to Use

No code changes required! The system automatically:
- Extracts cached token counts from OpenAI API responses
- Logs cache metrics at the end of each turn
- Stores cache data in the chat history database

## Next Steps (Phase 2)

To actually benefit from caching, you'll want to:

1. **Structure prompts** with static content (system prompt, tools) first, dynamic content (user queries, conversation history) last
2. **Add cache keys** to group related requests (e.g., by agent role or workflow)
3. **Enable extended retention** (`24h`) for long-running workflows
4. **Monitor hit rates** and adjust prompt structure accordingly

## Database Query Example

```sql
-- Get cache hit rates by session
SELECT 
    session_id,
    SUM(tokens_used) as total_tokens,
    SUM(cached_tokens) as cached_tokens,
    ROUND(100.0 * SUM(cached_tokens) / NULLIF(SUM(tokens_used), 0), 2) as cache_hit_rate
FROM chat_history_row
WHERE role = 'assistant'
GROUP BY session_id;
```
