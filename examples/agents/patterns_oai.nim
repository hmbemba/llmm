# agent_patterns.nim
#
# Run like:
#   nim r -d:oneshot agent_patterns.nim
#   nim r -d:retryLoop agent_patterns.nim
#   nim r -d:serialPipeline agent_patterns.nim
#   ...
#
# Notes:
# - This file assumes it lives inside your llmm repo (so relative imports resolve).
# - Patterns intentionally "lean on tools": file ops, web search, memory, HITL.

import std/[
    os
    ,strformat
    ,strutils
    ,sequtils
    ,options
    ,times
    ,asyncdispatch
    ,json
]

import mynimlib/[
    keys
]
from mynimlib.utils import dirExistsOrMk

import ic
,pretty
,oids

import
    ../../src/llmm
    ,../../src/llmm/tools


discard """
Patterns implemented:

1  oneshot
2  retryLoop
3  serialPipeline
4  pingPong
5  selfLoop
6  fanOutFanIn
7  supervisorWorker
8  escalation
9  guardWorkerValidator
10 accumulator
11 mapReduce
12 criticRewriter
13 routerSpecialist
14 consensus
15 hitlCheckpoint
16 memoryPassingChain
17 retryBackoff
18 streamingPipeline
19 forkingPaths
20 persistentState
"""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

type
    PatternAgents = object
        client       : OpenAIClient
        workspaceDir : string
        artifactsDir : string

proc mkWorkspace*(): tuple[workspaceDir: string, artifactsDir: string] =
    let
        workDir      = currentSourcePath.parentDir / "workspace"
        workspaceDir = dirExistsOrMk(workDir)
        artifactsDir = dirExistsOrMk(workDir / ".artifacts")
    (workspaceDir: workspaceDir, artifactsDir: artifactsDir)

proc printEvent*(label: string, e: AgentEvent) =
    case e.kind
    of aekThinking:
        echo &"[{label}] thinking: {e.thought}"
    of aekToolCall:
        echo &"[{label}] tool_call: {e.callToolName} args={e.callToolArgs}"
    of aekToolResult:
        echo &"[{label}] tool_result: ok={e.resultOk} id={e.resultToolId} payload={e.resultOutput}"
    of aekMessage:
        echo &"[{label}] message:\n{e.msgText}\n"
    of aekCheckpoint:
        echo &"[{label}] checkpoint: {e.checkpointReason} pending={e.checkpointPending}"
    of aekError:
        echo &"[{label}] error: {e.errorKind} {e.errorMessage} recoverable={e.errorRecoverable}"

proc attachLogger*(a: Agent, label: string) =
    a.onEvent = proc(e: AgentEvent) =
        printEvent(label, e)

proc mkAgent*(
    pa           : PatternAgents
    ,name        : string
    ,role        : string
    ,model       : string
    ,systemPrompt: string
    ,instructions: string = ""
)              : Agent =
    var agt = newAgent(
        client           = pa.client
        ,id              = $genOid()
        ,name            = name
        ,role            = role
        ,model           = model
        ,systemPrompt    = systemPrompt
        ,instructions    = instructions
        ,workspaceDir    = pa.workspaceDir
        ,artifactsDir    = pa.artifactsDir
        ,policy          = AgentPolicy(maxToolCalls : 20)
        ,tools           = addTools @[
            HITLTool()
            ,webSearchTool()
        ]
        ,enableReflection = true
    )

    # Give full FS toolkit so it can create/read/append/list, etc.
    agt.addTools FileFullToolkit(pa.workspaceDir)

    # Memory tool is auto-injected by chatTurn anyway, but we also ensure it exists early
    # so the model "sees" it from turn 1, even before auto-injection loads the store.
    if agt.memoryStore != nil:
        agt.addTools MemoryTool(agt.memoryStore)

    attachLogger(agt, name)
    agt

proc askStrictTools*(
    a     : Agent
    ,text : string
)           : Future[string] {.async.} =
    let tooly = """
IMPORTANT:
- Use tools aggressively.
- Prefer file tools to persist intermediate artifacts.
- Prefer memory tool to store a short lesson at the end.
- If you are uncertain at any point, ask_human.
"""
    let prompt = tooly & "\n\nTASK:\n" & text
    return await a.ask(prompt)

proc askInSessionStrictTools*(
    a     : Agent
    ,text : string
)           : Future[string] {.async.} =
    let tooly = """
IMPORTANT:
- Use tools aggressively.
- Prefer file tools to persist intermediate artifacts.
- Prefer memory tool to store a short lesson at the end.
- If you are uncertain at any point, ask_human.
"""
    let prompt = tooly & "\n\nTASK:\n" & text
    return await a.askInSession(prompt)

proc looksGood*(s: string): bool =
    let low = s.toLowerAscii()
    (low.contains("done") or low.contains("completed") or low.contains("✅") or low.contains("result:")) and s.len >= 120

proc splitIntoChunks*(text: string, maxChars: int): seq[string] =
    if text.len <= maxChars: return @[text]
    var i = 0
    while i < text.len:
        let j = min(text.len, i + maxChars)
        result.add text[i ..< j]
        i = j

# ---------------------------------------------------------------------------
# Pattern Implementations
# ---------------------------------------------------------------------------

proc patternOneshot*(pa: PatternAgents) {.async.} =
    var a = mkAgent(
        pa
        ,name         = "Oneshot"
        ,role         = "Generalist"
        ,model        = "gpt-4o"
        ,systemPrompt = "You are an agent that solves tasks quickly and uses tools heavily."
    )

    discard await askStrictTools(
        a
        ,"""
Use web_search to find 2-3 bullet facts about "moltbook" (if ambiguous, ask_human).
Then create a file `oneshot_result.md` with:
- what you found
- citations/urls in plaintext
"""
    )

proc patternRetryLoop*(pa: PatternAgents) {.async.} =
    var worker = mkAgent(
        pa
        ,name         = "RetryWorker"
        ,role         = "Writer"
        ,model        = "gpt-4o-mini"
        ,systemPrompt = "Generate an answer that must include a clear 'Result:' section. Use tools heavily."
    )

    var judge = mkAgent(
        pa
        ,name         = "RetryJudge"
        ,role         = "Validator"
        ,model        = "gpt-4o-mini"
        ,systemPrompt = "You are a strict validator. Decide pass/fail and write reasons. Use file_read when helpful."
    )

    var attempt = 0
    var lastText = ""
    while attempt < 4:
        attempt.inc
        lastText = await askStrictTools(
            worker
            ,&"""
Attempt {attempt}:
Create a short checklist for a 'tool-heavy agent run' and save it to `retry_loop_checklist.md`.
Rules:
- Must include 'Result:' section
- Must be at least 6 bullets
Use file_write to write it.
"""
        )

        let verdict = await askStrictTools(
            judge
            ,"""
Read `retry_loop_checklist.md` using file_read.
Then output:
- PASS or FAIL
- 2 reasons
- if FAIL: 2 concrete fixes the worker should apply
"""
        )

        if verdict.toLowerAscii().contains("pass"):
            echo "[retryLoop] PASS"
            break
        else:
            echo "[retryLoop] FAIL - retrying"

proc patternSerialPipeline*(pa: PatternAgents) {.async.} =
    var a1 = mkAgent(pa, "Agent1_Planner", "Planner", "gpt-4o-mini", "Plan work and persist a plan file. Use tools heavily.")
    var a2 = mkAgent(pa, "Agent2_Research", "Researcher", "gpt-4o-mini", "Research quickly via web_search, persist notes. Use tools heavily.")
    var a3 = mkAgent(pa, "Agent3_Writer", "Writer", "gpt-4o-mini", "Write clean markdown, use file tools heavily.")
    var a4 = mkAgent(pa, "Agent4_Validator", "Validator", "gpt-4o-mini", "Validate output, read files, suggest fixes. Use tools heavily.")

    discard await askStrictTools(a1, "Create `serial_plan.md` with a 5-step plan for: 'Explain what MapReduce is, with a tiny example'.")
    discard await askStrictTools(a2, "Use web_search: find 2 sources about MapReduce. Save notes to `serial_research.md` with plain urls.")
    discard await askStrictTools(a3, "Read `serial_plan.md` and `serial_research.md`, then write final to `serial_result.md`.")
    discard await askStrictTools(a4, "Read `serial_result.md` and output PASS/FAIL plus 3 improvements. If FAIL, write `serial_result_fix.md` with a corrected version.")

proc patternPingPong*(pa: PatternAgents) {.async.} =
    var a = mkAgent(pa, "Ping", "Analyst", "gpt-4o-mini", "You propose next step. Use tools heavily.")
    var b = mkAgent(pa, "Pong", "Reviewer", "gpt-4o-mini", "You challenge and refine. Use tools heavily.")

    var msg = "Topic: Design a minimal tool-heavy agent prompt template."
    var round = 0
    while round < 4:
        round.inc
        msg = await askInSessionStrictTools(a, &"Round {round}. Given prior discussion, propose an improved template. Save to `pingpong_round_{round}_ping.md`.")
        msg = await askInSessionStrictTools(b, &"Round {round}. Critique Ping's template and improve it. Save to `pingpong_round_{round}_pong.md`.")

proc patternSelfLoop*(pa: PatternAgents) {.async.} =
    var a = mkAgent(pa, "SelfLoop", "Writer", "gpt-4o-mini", "Write, then review your own output and rewrite. Use tools heavily.")

    var text = await askStrictTools(
        a
        ,"""
Draft `selfloop_v1.md`: a 10-line explanation of 'tool call loops' in an agent.
Then read it with file_read, critique it, and write `selfloop_v2.md` improved.
"""
    )
    discard text

proc patternFanOutFanIn*(pa: PatternAgents) {.async.} =
    var planner = mkAgent(pa, "Planner", "Planner", "gpt-4o-mini", "Plan fan-out tasks and write a task list file. Use tools heavily.")
    var agg     = mkAgent(pa, "Aggregator", "Aggregator", "gpt-4o-mini", "Combine worker outputs into one doc. Use tools heavily.")

    discard await askStrictTools(planner, "Create `fan_tasks.json` describing 3 micro-tasks about: (1) web_search, (2) file tools, (3) memory tool. Keep it short.")

    proc workerTask(workerName: string, focus: string): Future[string] {.async.} =
        var w = mkAgent(pa, workerName, "Worker", "gpt-4o-mini", "Do your assigned micro-task. Use tools heavily.")
        return await askStrictTools(w, &"""
Your focus: {focus}
Write `fan_{workerName}.md` with:
- 3 bullets of guidance
- 1 tiny pseudo-code snippet
Use file_write.
""")

    let fut1 = workerTask("Worker1", "web_search tool usage patterns")
    let fut2 = workerTask("Worker2", "filesystem tool usage patterns")
    let fut3 = workerTask("Worker3", "memory tool usage patterns")

    discard await fut1
    discard await fut2
    discard await fut3

    discard await askStrictTools(agg, """
Read `fan_Worker1.md`, `fan_Worker2.md`, `fan_Worker3.md` and combine into `fan_aggregated.md`
with headings and a final 'Result:' section.
""")

proc patternSupervisorWorker*(pa: PatternAgents) {.async.} =
    var sup = mkAgent(pa, "Supervisor", "Supervisor", "gpt-4o-mini", "Delegate, review, request fixes. Use tools heavily.")
    var cod = mkAgent(pa, "Coder", "Coder", "gpt-4o-mini", "Write Nim pseudo-code and persist it. Use tools heavily.")

    discard await askStrictTools(sup, """
Create `sup_task.md` describing a small deliverable:
- a Nim pseudo-code template for running an agent with tool loop and event logging
""")

    discard await askStrictTools(cod, """
Read `sup_task.md` and write `worker_output.nim` (pseudo-code is fine but must look like Nim).
Use file_write.
""")

    discard await askStrictTools(sup, """
Read `worker_output.nim`. If it's missing event logging or tool loop mention, rewrite it to `worker_output_fixed.nim`.
Return PASS/FAIL in your message.
""")

proc patternEscalation*(pa: PatternAgents) {.async.} =
    var cheap = mkAgent(pa, "CheapModel", "Generalist", "gpt-4o-mini", "Answer quickly and report confidence 0-100. Use tools heavily.")
    var prem  = mkAgent(pa, "PremiumModel", "Generalist", "gpt-4o", "Answer carefully and verify via tools. Use tools heavily.")

    let q = """
Question: What is 'moltbook'?
- Use web_search.
- If ambiguous, say so.
- Output must include: Confidence: N/100
- Save answer to `escalation_answer.md`.
"""

    let cheapAns = await askStrictTools(cheap, q)
    let loww = cheapAns.toLowerAscii()
    let lowConf = loww.contains("confidence:") and (
        loww.contains("confidence: 0") or loww.contains("confidence: 1") or loww.contains("confidence: 2") or loww.contains("confidence: 3") or loww.contains("confidence: 4") or loww.contains("confidence: 5") or loww.contains("confidence: 6")
    )

    if lowConf or loww.contains("ambiguous") or loww.contains("not sure"):
        echo "[escalation] Escalating to premium model"
        discard await askStrictTools(prem, q & "\nAlso: read `escalation_answer.md` and improve it into `escalation_answer_premium.md`.")
    else:
        echo "[escalation] Cheap model good enough"

proc patternGuardWorkerValidator*(pa: PatternAgents) {.async.} =
    var guard = mkAgent(pa, "Guard", "Guard", "gpt-4o-mini", "Approve or reject the task. Use tools heavily.")
    var work  = mkAgent(pa, "Worker", "Worker", "gpt-4o-mini", "Do the work. Use tools heavily.")
    var val   = mkAgent(pa, "Validator", "Validator", "gpt-4o-mini", "Validate work by reading files. Use tools heavily.")

    discard await askStrictTools(guard, """
Policy check:
- Only write into workspace files under current directory (no absolute paths).
- Create `guard_decision.json` with {approved: bool, reason: string}.
Use file_write.
""")

    discard await askStrictTools(work, """
Read `guard_decision.json`. If not approved, ask_human what to do.
If approved: create `guard_worker_output.md` explaining your file-sandbox rules in 6 bullets.
Use file_write and workspace_list at end.
""")

    discard await askStrictTools(val, """
Read `guard_worker_output.md`. Validate it has exactly 6 bullets.
Output PASS/FAIL and if FAIL write corrected file `guard_worker_output_fixed.md`.
""")

proc patternAccumulator*(pa: PatternAgents) {.async.} =
    var a = mkAgent(pa, "Accumulator", "Writer", "gpt-4o-mini", "Write a doc in sections and append. Use tools heavily.")

    discard await askStrictTools(a, """
Create `accumulator.md` with a title line only using file_write.
Then append 4 sections (Section 1..4) using file_append, one per tool call.
Finally, workspace_list.
""")

proc patternMapReduce*(pa: PatternAgents) {.async.} =
    var splitter = mkAgent(pa, "Splitter", "Splitter", "gpt-4o-mini", "Split input into chunks and write them to files. Use tools heavily.")
    var reducer  = mkAgent(pa, "Reducer", "Reducer", "gpt-4o-mini", "Reduce summaries into final. Use tools heavily.")

    let bigText = """
MapReduce is a programming model for processing large datasets with a parallel, distributed algorithm.
A 'map' step transforms input key/value pairs into intermediate key/value pairs.
A 'reduce' step merges all intermediate values associated with the same intermediate key.
Classic examples include word count, inverted index, and log aggregation.
In practice, frameworks handle data distribution, fault tolerance, and scheduling.
"""

    discard await askStrictTools(splitter, &"""
Take this text, split into 3 chunks, and write:
- `mr_chunk_1.txt`
- `mr_chunk_2.txt`
- `mr_chunk_3.txt`
Use file_write for each.
Text:
{bigText}
""")

    proc mapper(i: int): Future[string] {.async.} =
        var m = mkAgent(pa, &"Mapper{i}", "Mapper", "gpt-4o-mini", "Summarize your chunk. Use tools heavily.")
        return await askStrictTools(m, &"""
Read `mr_chunk_{i}.txt` and write `mr_map_{i}.md` containing:
- 3 bullet summary
- 1 key quote (<= 25 words)
Use file_write.
""")

    discard await mapper(1)
    discard await mapper(2)
    discard await mapper(3)

    discard await askStrictTools(reducer, """
Read `mr_map_1.md`, `mr_map_2.md`, `mr_map_3.md` and write `mr_reduced.md`:
- unified summary
- 'Result:' section
Use file_write.
""")

proc patternCriticRewriter*(pa: PatternAgents) {.async.} =
    var gen = mkAgent(pa, "Generator", "Generator", "gpt-4o-mini", "Generate content fast. Use tools heavily.")
    var cri = mkAgent(pa, "Critic", "Critic", "gpt-4o-mini", "Critique harshly. Use tools heavily.")

    discard await askStrictTools(gen, "Write `cr_v1.md`: a compact explanation of 'tool loop' with 1 example. Use file_write.")
    discard await askStrictTools(cri, "Read `cr_v1.md` and write `cr_feedback.md` with 5 specific critiques. Use file_write.")
    discard await askStrictTools(gen, "Read `cr_feedback.md` and rewrite into `cr_v2.md` addressing every critique. Use file_write.")
    discard await askStrictTools(cri, "Read `cr_v2.md` and output PASS/FAIL. If FAIL, write `cr_v3_suggested.md`.")

proc patternRouterSpecialist*(pa: PatternAgents) {.async.} =
    var router = mkAgent(pa, "Router", "Router", "gpt-4o-mini", "Classify task and choose a specialist. Use tools heavily.")
    var codeA  = mkAgent(pa, "CodeAgent", "Code", "gpt-4o-mini", "Handle code-ish tasks. Use tools heavily.")
    var writA  = mkAgent(pa, "WritingAgent", "Writing", "gpt-4o-mini", "Handle writing tasks. Use tools heavily.")
    var genA   = mkAgent(pa, "GeneralAgent", "General", "gpt-4o-mini", "Handle general tasks. Use tools heavily.")

    let userTask = "Create a Nim-like pseudo-code snippet showing a tool loop and event log."
    discard await askStrictTools(router, &"""
Task: {userTask}
Decide route: code | writing | general
Write decision to `router_decision.json` using file_write.
""")

    # simple route: read decision in Nim (not via agent) to choose specialist
    let decisionPath = pa.workspaceDir / "router_decision.json"
    var route = "general"
    if fileExists(decisionPath):
        try:
            let j = parseJson(readFile(decisionPath))
            if j.hasKey("route"): route = j["route"].getStr("general")
        except:
            discard

    case route
    of "code":
        discard await askStrictTools(codeA, &"{userTask}\nWrite to `router_result.md` with file_write.")
    of "writing":
        discard await askStrictTools(writA, &"{userTask}\nExplain it in prose and save `router_result.md`.")
    else:
        discard await askStrictTools(genA, &"{userTask}\nSave `router_result.md`.")

proc patternConsensus*(pa: PatternAgents) {.async.} =
    var judge = mkAgent(pa, "Voter", "Judge", "gpt-4o-mini", "Pick best answer. Use tools heavily.")

    proc candidate(i: int): Future[string] {.async.} =
        var a = mkAgent(pa, &"Candidate{i}", "Candidate", "gpt-4o-mini", "Answer and persist answer. Use tools heavily.")
        return await askStrictTools(a, &"""
Answer: 'What are the core components of a tool-using agent loop?'
Save to `consensus_{i}.md` (file_write).
Include a 'Result:' section.
""")

    discard await candidate(1)
    discard await candidate(2)
    discard await candidate(3)

    discard await askStrictTools(judge, """
Read `consensus_1.md`, `consensus_2.md`, `consensus_3.md`.
Pick the best and write `consensus_winner.md`:
- Winner: N
- Why
- Final combined answer (may merge ideas)
Use file_write.
""")

proc patternHitlCheckpoint*(pa: PatternAgents) {.async.} =
    var a = mkAgent(pa, "HITL", "Operator", "gpt-4o-mini", "Use ask_human as a checkpoint before finalizing. Use tools heavily.")

    discard await askInSessionStrictTools(a, """
Draft a short file `hitl_draft.md` describing a 3-step agent workflow.
Then call ask_human asking: 'Approve this draft? Reply APPROVE or REJECT and optional notes.'
If approved, write `hitl_final.md` improved using notes.
If rejected, ask_human what to change, then write `hitl_final.md`.
Use file tools throughout.
""")

proc patternMemoryPassingChain*(pa: PatternAgents) {.async.} =
    var a1 = mkAgent(pa, "MemAgent1", "Writer", "gpt-4o-mini", "Store a fact in memory and write a scratch file. Use tools heavily.")
    var a2 = mkAgent(pa, "MemAgent2", "Reader", "gpt-4o-mini", "Recall memory and extend. Use tools heavily.")
    var a3 = mkAgent(pa, "MemAgent3", "Finisher", "gpt-4o-mini", "Recall memory and produce final. Use tools heavily.")

    discard await askStrictTools(a1, """
Use memory tool to store:
- kind: fact
- content: 'In llmm, chatTurn runs a tool loop until no function calls.'
- tags: ["llmm","tool_loop"]
Also write `mem_chain_1.md` with same sentence (file_write).
""")

    discard await askStrictTools(a2, """
Use memory tool recall query: 'tool loop'
Then write `mem_chain_2.md` expanding with 3 bullets about implications.
Use file_write.
""")

    discard await askStrictTools(a3, """
Recall memory again (query: llmm tool loop).
Read `mem_chain_1.md` and `mem_chain_2.md`.
Write `mem_chain_final.md` with a short explanation + Result section.
Use file_write.
""")

proc patternRetryBackoff*(pa: PatternAgents) {.async.} =
    var a = mkAgent(pa, "BackoffAgent", "Worker", "gpt-4o-mini", "Do work; if tool fails, adapt. Use tools heavily.")

    var attempt = 0
    var backoffMs = 250
    while attempt < 4:
        attempt.inc

        # Intentionally ask it to do something that might fail if file missing on first attempt,
        # to exercise recovery. It should then create it.
        let text = await askStrictTools(a, &"""
Attempt {attempt}:
1) Try to file_read `backoff_input.txt`.
2) If missing, create it with file_write containing: 'hello from attempt {attempt}'.
3) Then read it again and write `backoff_output.md` summarizing what happened.
""")

        if text.toLowerAscii().contains("error:"):
            echo &"[retryBackoff] agent surfaced error; sleeping {backoffMs}ms"
            await sleepAsync(backoffMs)
            backoffMs = min(4000, backoffMs * 2)
        else:
            # also accept tool-driven success even if message doesn't say "done"
            let ok = fileExists(pa.workspaceDir / "backoff_output.md")
            if ok:
                echo "[retryBackoff] success"
                break
            echo &"[retryBackoff] not done; sleeping {backoffMs}ms"
            await sleepAsync(backoffMs)
            backoffMs = min(4000, backoffMs * 2)

proc patternStreamingPipeline*(pa: PatternAgents) {.async.} =
    # Event-driven chaining: when AgentA emits message, trigger AgentB, etc.
    var a1 = mkAgent(pa, "StreamA", "A", "gpt-4o-mini", "Produce an outline and write it. Use tools heavily.")
    var a2 = mkAgent(pa, "StreamB", "B", "gpt-4o-mini", "Expand outline into draft and write it. Use tools heavily.")
    var a3 = mkAgent(pa, "StreamC", "C", "gpt-4o-mini", "Validate and finalize. Use tools heavily.")

    var done2 = false
    var done3 = false

    a1.onEvent = proc(e: AgentEvent) =
        printEvent("StreamA", e)
        if e.kind == aekMessage and not done2:
            done2 = true
            asyncCheck (
                proc() {.async.} =
                    discard await askStrictTools(a2, "Read `stream_outline.md` and write `stream_draft.md` with 2 short sections.")
            )()

    a2.onEvent = proc(e: AgentEvent) =
        printEvent("StreamB", e)
        if e.kind == aekMessage and not done3:
            done3 = true
            asyncCheck (
                proc() {.async.} =
                    discard await askStrictTools(a3, "Read `stream_draft.md` and write `stream_final.md` improved with a Result section.")
            )()

    discard await askStrictTools(a1, """
Create `stream_outline.md`:
- Title
- 5 bullets
Topic: 'Event-driven agent pipelines'
Use file_write.
""")

    # Wait a bit for chained async tasks to complete.
    await sleepAsync(2000)

proc patternForkingPaths*(pa: PatternAgents) {.async.} =
    var gen   = mkAgent(pa, "ForkGen", "Generator", "gpt-4o-mini", "Generate multiple options. Use tools heavily.")
    var judge = mkAgent(pa, "ForkJudge", "Judge", "gpt-4o-mini", "Pick best. Use tools heavily.")

    discard await askStrictTools(gen, """
Generate 3 different prompt templates for a tool-using agent.
Write:
- `fork_option_a.md`
- `fork_option_b.md`
- `fork_option_c.md`
Use file_write.
""")

    proc explorer(name: string, filename: string): Future[string] {.async.} =
        var ex = mkAgent(pa, name, "Explorer", "gpt-4o-mini", "Improve one option by adding tool-usage specifics. Use tools heavily.")
        return await askStrictTools(ex, &"""
Read `{filename}` and produce an improved version to `{filename}` (overwrite) using file_write.
Add explicit instructions to use: workspace_list, file_write, memory store.
""")

    discard await explorer("ExplorerA", "fork_option_a.md")
    discard await explorer("ExplorerB", "fork_option_b.md")
    discard await explorer("ExplorerC", "fork_option_c.md")

    discard await askStrictTools(judge, """
Read the three fork options.
Pick best and write `fork_winner.md` containing:
- Winner (A/B/C)
- Why
- Final template
Use file_write.
""")

proc patternPersistentState*(pa: PatternAgents) {.async.} =
    var a = mkAgent(pa, "Persistent", "Assistant", "gpt-4o-mini", "Accumulate facts across runs using memory tool. Use tools heavily.")

    discard await askInSessionStrictTools(a, """
Use memory tool store:
- kind: fact
- content: 'User prefers Nim imports with leading commas and 4-space indentation.'
- tags: ['nim_style']
Also write `persistent_step1.md` with that fact.
""")

    discard await askInSessionStrictTools(a, """
Recall memory with query 'nim_style'.
Then write `persistent_step2.md` with:
- the recalled fact
- 2 consequences for codegen
Use file_write.
""")

    discard await askInSessionStrictTools(a, """
Recall again (query 'indentation').
Then write `persistent_step3.md` with a short 'Do/Don't' list.
Use file_write and memory store one short lesson about why persistence helps.
""")

# ---------------------------------------------------------------------------
# Main / Pattern Selector
# ---------------------------------------------------------------------------

when isMainModule:
    let ws = mkWorkspace()
    let pa = PatternAgents(
        client       : OpenAIClient(apiKey : keys.open_ai_api_key)
        ,workspaceDir: ws.workspaceDir
        ,artifactsDir: ws.artifactsDir
    )

    when defined(oneshot):
        waitFor patternOneshot(pa)

    elif defined(retryLoop):
        waitFor patternRetryLoop(pa)

    elif defined(serialPipeline):
        waitFor patternSerialPipeline(pa)

    elif defined(pingPong):
        waitFor patternPingPong(pa)

    elif defined(selfLoop):
        waitFor patternSelfLoop(pa)

    elif defined(fanOutFanIn):
        waitFor patternFanOutFanIn(pa)

    elif defined(supervisorWorker):
        waitFor patternSupervisorWorker(pa)

    elif defined(escalation):
        waitFor patternEscalation(pa)

    elif defined(guardWorkerValidator):
        waitFor patternGuardWorkerValidator(pa)

    elif defined(accumulator):
        waitFor patternAccumulator(pa)

    elif defined(mapReduce):
        waitFor patternMapReduce(pa)

    elif defined(criticRewriter):
        waitFor patternCriticRewriter(pa)

    elif defined(routerSpecialist):
        waitFor patternRouterSpecialist(pa)

    elif defined(consensus):
        waitFor patternConsensus(pa)

    elif defined(hitlCheckpoint):
        waitFor patternHitlCheckpoint(pa)

    elif defined(memoryPassingChain):
        waitFor patternMemoryPassingChain(pa)

    elif defined(retryBackoff):
        waitFor patternRetryBackoff(pa)

    elif defined(streamingPipeline):
        waitFor patternStreamingPipeline(pa)

    elif defined(forkingPaths):
        waitFor patternForkingPaths(pa)

    elif defined(persistentState):
        waitFor patternPersistentState(pa)

    else:
        echo "No pattern selected."
        echo "Run with one of:"
        echo "  -d:oneshot"
        echo "  -d:retryLoop"
        echo "  -d:serialPipeline"
        echo "  -d:pingPong"
        echo "  -d:selfLoop"
        echo "  -d:fanOutFanIn"
        echo "  -d:supervisorWorker"
        echo "  -d:escalation"
        echo "  -d:guardWorkerValidator"
        echo "  -d:accumulator"
        echo "  -d:mapReduce"
        echo "  -d:criticRewriter"
        echo "  -d:routerSpecialist"
        echo "  -d:consensus"
        echo "  -d:hitlCheckpoint"
        echo "  -d:memoryPassingChain"
        echo "  -d:retryBackoff"
        echo "  -d:streamingPipeline"
        echo "  -d:forkingPaths"
        echo "  -d:persistentState"


discard """
Compile examples (adjust path as needed):

nim r -d:ssl -d:oneshot               ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:retryLoop             ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:serialPipeline        ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:pingPong              ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:selfLoop              ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:fanOutFanIn           ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:supervisorWorker      ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:escalation            ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:guardWorkerValidator  ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:accumulator           ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:mapReduce             ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:criticRewriter        ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:routerSpecialist      ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:consensus             ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:hitlCheckpoint        ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:memoryPassingChain    ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:retryBackoff          ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:streamingPipeline     ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:forkingPaths          ./examples/agents/patterns_oai.nim
nim r -d:ssl -d:persistentState       ./examples/agents/patterns_oai.nim
"""
