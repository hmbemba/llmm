## memory_integration.nim — Hooks memory into the agent tick loop
##
## This module provides the glue between the memory system and the agent.
## It handles:
##   1. Auto-injection: retrieving relevant memories before each turn
##   2. Post-turn reflection: prompting the LLM to store learnings
##   3. Tool failure/recovery tracking: detecting failure→success patterns
##
## Usage in tick.nim:
##   - Call `injectMemoryContext` before building the request
##   - Call `handleToolFailureMemory` when a tool call fails
##   - Call `handleToolRecoveryMemory` when a tool succeeds after a failure  
##   - Call `triggerReflection` after a successful task completion

import std/[
json
,strutils
,sequtils
,tables
,sets
,strformat
,asyncdispatch
,options
]

import types
,store
,prompts
,ic

import ../../../general_helpers


# ---------------------------------------------------------------------------
# Agent memory state tracking (for failure→recovery detection)
# ---------------------------------------------------------------------------

type
    ToolFailureTracker* = object
        ## Tracks which tools have failed in the current turn
        ## so we can detect recovery (failure → success)
        failedTools*   : HashSet[string]    ## tool names that failed this turn
        failureErrors* : Table[string, string]  ## toolName → error message


proc newToolFailureTracker*(): ToolFailureTracker =
    ToolFailureTracker(
        failedTools    : initHashSet[string]()
        ,failureErrors : initTable[string, string]()
    )

proc recordFailure*(tracker: var ToolFailureTracker, toolName: string, error: string) =
    tracker.failedTools.incl(toolName)
    tracker.failureErrors[toolName] = error

proc checkRecovery*(tracker: var ToolFailureTracker, toolName: string): bool =
    ## Returns true if this tool previously failed this turn
    return toolName in tracker.failedTools

proc clearRecovery*(tracker: var ToolFailureTracker, toolName: string) =
    tracker.failedTools.excl(toolName)
    tracker.failureErrors.del(toolName)


# ---------------------------------------------------------------------------
# 1. Auto-injection: retrieve relevant memories before a turn
# ---------------------------------------------------------------------------

proc injectMemoryContext*(
    store        : MemoryStore
    ,userMessage : string
    ,systemPrompt: string
    ,maxMemories : int = 5
): string =
    ## Searches memory for entries relevant to the user's message,
    ## formats them, and prepends to the system prompt.
    ## Returns the augmented system prompt.
    
    if store.entries.len == 0:
        icb "No memories found, skipping injection"
        # No memories yet — just add the memory system instructions
        return systemPrompt & "\n\n" & MemorySystemPrompt

    # Extract query terms from user message (simple: just use the words)
    let queryTerms = userMessage.splitWhitespace().filterIt(it.len > 2)
    
    # Recall with empty tags (pure content match) 
    let memories = store.recall(
        query    = userMessage
        ,limit   = maxMemories
    )
    
    let memoryBlock = formatMemoriesForContext(memories)
    
    if memoryBlock.len > 0:
        return systemPrompt & "\n\n" & MemorySystemPrompt & "\n" & memoryBlock
    else:
        return systemPrompt & "\n\n" & MemorySystemPrompt


# ---------------------------------------------------------------------------
# 2. Tool failure memory nudge
# ---------------------------------------------------------------------------

proc buildToolFailureNudge*(toolName: string, errorMsg: string): JsonNode =
    ## Returns a developer/system message nudging the LLM to 
    ## remember what went wrong. Inject this into the conversation
    ## after a tool failure result.
    %*{
        "type"    : "message"
        ,"role"   : "developer"
        ,"content": toolFailureReflectionPrompt(toolName, errorMsg)
    }


# ---------------------------------------------------------------------------
# 3. Tool recovery memory nudge
# ---------------------------------------------------------------------------

proc buildToolRecoveryNudge*(toolName: string): JsonNode =
    ## Returns a developer message nudging the LLM to store
    ## a lesson about recovering from failure.
    %*{
        "type"    : "message"
        ,"role"   : "developer"
        ,"content": toolRecoveryReflectionPrompt(toolName)
    }


# ---------------------------------------------------------------------------
# 4. End-of-turn reflection
# ---------------------------------------------------------------------------

proc buildReflectionMessages*(): seq[JsonNode] =
    ## Returns messages to append for a reflection turn.
    ## The agent loop should send these as a follow-up request
    ## to let the LLM store memories before closing.
    @[
        %*{
            "type"    : "message"
            ,"role"   : "developer"  
            ,"content": ReflectionPrompt
        }
    ]


# ---------------------------------------------------------------------------
# 5. Memory initialization helper
# ---------------------------------------------------------------------------

proc initAgentMemoryStore*(artifactsDir: string, agentName: string, agentId: string): MemoryStore =
    ## Create or load the memory store for a specific agent.
    ## Path: {artifactsDir}/agent_{name}_{id}/memory.json
    let memPath = artifactsDir / ("agent_" & agentName & "_" & agentId) / "memory.json"
    return newMemoryStore(memPath)