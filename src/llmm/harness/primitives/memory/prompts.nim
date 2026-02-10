## memory_prompts.nim — Prompt fragments for memory-aware agents
##
## Contains:
## - System prompt additions to teach the LLM about memory
## - Reflection prompts for end-of-turn memory creation
## - Tool failure/recovery prompts for lesson extraction
## - Auto-injection formatting for retrieved memories

import std/[
    strutils
    ,strformat
    ,json
    ,sequtils
    ,times
]

import types

# ---------------------------------------------------------------------------
# System Prompt Fragment
# ---------------------------------------------------------------------------

const MemorySystemPrompt* = """
## Memory System

You have access to a persistent memory system via the `memory` tool. Use it to build up useful knowledge across conversations.

### When to STORE memories:
- **Facts**: User preferences, environment details, file paths, project structure, names, conventions
- **Lessons**: Tool call patterns that worked or failed, debugging insights, gotchas discovered
- **Summaries**: Condensed notes about what was accomplished in a session

### When to RECALL memories:
- At the start of a new task, if you think past context would help
- When you encounter something familiar — check if you've seen it before
- When the user references past work or decisions

### Source tags for context:
- `reflection`: End-of-task insight
- `correction`: User corrected you on something
- `tool_failure`: A tool call failed — what went wrong
- `tool_recovery`: A tool call succeeded after a failure — what you did differently
- `user_preference`: User expressed a preference
- `environment`: Something learned about the runtime environment

### Guidelines:
- Do NOT store trivial or obvious information
- Do NOT store exact conversation transcripts
- DO store things that would save time if you encountered the same situation again
- Keep memory content concise — 1-3 sentences max
- Use descriptive tags for easy retrieval later
"""


# ---------------------------------------------------------------------------
# Reflection Prompt (injected after task completion)
# ---------------------------------------------------------------------------

const ReflectionPrompt* = """
Task completed. Before finishing, reflect on this session:

1. Did you learn any **facts** worth remembering? (user preferences, file paths, project details)
2. Did you discover any **lessons**? (patterns that worked, gotchas, tool quirks)
3. Should you store a brief **summary** of what was accomplished?

If yes to any, use the `memory` tool with command "store" to save them. If nothing is worth storing, that's fine — skip it.
"""


# ---------------------------------------------------------------------------
# Tool Failure Reflection (injected after a tool call fails)
# ---------------------------------------------------------------------------

proc toolFailureReflectionPrompt*(toolName: string, errorMsg: string): string =
    &"""
The tool call to `{toolName}` failed with: {errorMsg}

After you resolve this, consider storing a lesson about what went wrong using the `memory` tool:
- command: "store"
- kind: "lesson"  
- source: "tool_failure"
- Include: what you tried, why it failed, and what to try instead
"""


# ---------------------------------------------------------------------------
# Tool Recovery Reflection (injected after failure → success)
# ---------------------------------------------------------------------------

proc toolRecoveryReflectionPrompt*(toolName: string): string =
    &"""
You successfully recovered from a previous `{toolName}` failure. Consider storing a lesson about the recovery:
- command: "store"
- kind: "lesson"
- source: "tool_recovery"
- Include: what initially failed, what you changed, and the pattern that worked
"""


# ---------------------------------------------------------------------------
# Format retrieved memories for injection into the system prompt
# ---------------------------------------------------------------------------

proc formatMemoriesForContext*(memories: seq[MemoryEntry]): string =
    ## Formats memories as a block to prepend to the conversation context
    if memories.len == 0:
        return ""

    var lines: seq[string] = @[]
    lines.add("## Relevant Memories from Past Sessions\n")

    for m in memories:
        let kindLabel = case m.kind
            of mkFact   : "FACT"
            of mkLesson : "LESSON"
            of mkSummary: "SUMMARY"
        
        let tagStr = if m.tags.len > 0: " [" & m.tags.join(", ") & "]" else: ""
        lines.add(&"- **{kindLabel}**{tagStr}: {m.content}")
    
    lines.add("")  # trailing newline
    return lines.join("\n")


proc formatMemoriesAsJson*(memories: seq[MemoryEntry]): JsonNode =
    ## Alternative: inject as structured JSON the LLM can reference
    result = newJArray()
    for m in memories:
        result.add(%*{
            "id"      : m.id
            ,"kind"   : $m.kind
            ,"content": m.content
            ,"tags"   : m.tags
        })