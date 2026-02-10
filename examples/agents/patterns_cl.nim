discard """
Agent Patterns — 20 composable patterns for LLM agent orchestration.

Each pattern is gated behind a -d:patternName compile flag.
Run any pattern with:

    nim r -d:oneshot agent_patterns.nim
    nim r -d:retryLoop agent_patterns.nim
    nim r -d:serialPipeline agent_patterns.nim
    ... etc

Requires:
    -d:ssl (for HTTPS)
    -d:ic  (for debug logging, optional)

All patterns assume you have an OpenAI-compatible API key
available via `keys.open_ai_api_key`.
"""

import std/[
json
,asyncdispatch
,strformat
,strutils
,options
,times
,os
,tables
,sequtils
,algorithm
,oids
]

import mynimlib/[keys]
from mynimlib/utils import dirExistsOrMk

import
    ../../src/llmm
    ,../../src/llmm/tools


# =============================================================================
# Shared Setup
# =============================================================================

let
    client       = OpenAIClient(apiKey : keys.open_ai_api_key)
    workDir      = currentSourcePath.parentDir / "workspace"
    workspaceDir = dirExistsOrMk workDir
    artifactsDir = dirExistsOrMk workDir / ".artifacts"

const
    cheapModel   = "gpt-4o-mini"
    premiumModel = "gpt-4o"


proc makeAgent(
    name          : string
    ,role         : string = ""
    ,systemPrompt : string = ""
    ,model        : string = cheapModel
    ,maxToolCalls : int = 10
    ,toolsList    : seq[Tool] = @[]
): Agent =
    var a = newAgent(
        client            = client
        ,id               = $genOid()
        ,name             = name
        ,role             = role
        ,model            = model
        ,systemPrompt     = systemPrompt
        ,workspaceDir     = workspaceDir
        ,artifactsDir     = artifactsDir
        ,policy           = AgentPolicy(maxToolCalls : maxToolCalls)
        ,enableReflection = false
    )
    if toolsList.len > 0:
        a.addTools(toolsList)
    a.onErr:
        echo &"  [ERR:{name}] {e.errorMessage}"
    a.onMessage:
        echo &"  [{name}] {e.msgText[0 ..< min(120, e.msgText.len)]}..."
    return a


# =============================================================================
# 1. ONESHOT
# [User] → [Agent] → [Result]
# =============================================================================

when defined(oneshot):
    proc main() {.async.} =
        echo "=== Pattern 1: ONESHOT ==="
        let agent = makeAgent(
            name          = "OneShotAgent"
            ,role         = "Helpful assistant"
            ,systemPrompt = "You are a concise, helpful assistant. Answer in 2-3 sentences max."
        )
        let result = await agent.ask("What are the three laws of thermodynamics?")
        echo "\n--- Result ---"
        echo result

    waitFor main()


# =============================================================================
# 2. RETRY LOOP
# [User] → [Agent] → good? → [Result]
#              ↑  │
#              └──┘ not good (loop N times)
# =============================================================================

when defined(retryLoop):
    proc main() {.async.} =
        echo "=== Pattern 2: RETRY LOOP ==="
        let agent = makeAgent(
            name          = "RetryAgent"
            ,systemPrompt = "You are a code generator. Output ONLY valid JSON. No markdown, no explanation."
        )
        let prompt = "Generate a JSON object with fields: name (string), age (int), hobbies (array of strings). Make up realistic data."

        var
            result   : string
            attempts = 0
            maxRetry = 3
            success  = false

        while attempts < maxRetry and not success:
            attempts.inc
            echo &"  Attempt {attempts}/{maxRetry}..."
            result = await agent.ask(prompt)

            try:
                let parsed = parseJson(result)
                if parsed.hasKey("name") and parsed.hasKey("age") and parsed.hasKey("hobbies"):
                    success = true
                    echo "  ✓ Valid JSON with required fields."
                else:
                    echo "  ✗ Missing required fields, retrying..."
            except JsonParsingError:
                echo "  ✗ Invalid JSON, retrying..."

        echo "\n--- Result ---"
        if success:
            echo pretty(parseJson(result))
        else:
            echo "Failed after ", maxRetry, " attempts."
            echo result

    waitFor main()


# =============================================================================
# 3. SERIAL PIPELINE
# [User] → [Agent1] → [Agent2] → [Agent3] → [Agent4] → [Result]
# =============================================================================

when defined(serialPipeline):
    proc main() {.async.} =
        echo "=== Pattern 3: SERIAL PIPELINE ==="
        let
            researcher = makeAgent(
                name          = "Researcher"
                ,systemPrompt = "You research topics and produce detailed bullet points of key facts. Output raw facts only."
            )
            outliner = makeAgent(
                name          = "Outliner"
                ,systemPrompt = "You take raw facts and organize them into a clear outline with sections and subsections."
            )
            writer = makeAgent(
                name          = "Writer"
                ,systemPrompt = "You take an outline and write a polished, engaging short article (3-4 paragraphs)."
            )
            editor = makeAgent(
                name          = "Editor"
                ,systemPrompt = "You edit text for clarity, grammar, and flow. Output the final polished version only."
            )

        let topic = "The history of the transistor"
        echo &"  Topic: {topic}"

        echo "\n  [Stage 1: Research]"
        var output = await researcher.ask(&"Research this topic and list key facts: {topic}")

        echo "\n  [Stage 2: Outline]"
        output = await outliner.ask(&"Organize these facts into an outline:\n{output}")

        echo "\n  [Stage 3: Write]"
        output = await writer.ask(&"Write a short article from this outline:\n{output}")

        echo "\n  [Stage 4: Edit]"
        output = await editor.ask(&"Edit and polish this article:\n{output}")

        echo "\n--- Final Result ---"
        echo output

    waitFor main()


# =============================================================================
# 4. PING-PONG
# [Agent1] ←──→ [Agent2]   (N rounds)
# =============================================================================

when defined(pingPong):
    proc main() {.async.} =
        echo "=== Pattern 4: PING-PONG ==="
        let
            debaterA = makeAgent(
                name          = "Proponent"
                ,systemPrompt = "You argue IN FAVOR of the given position. Be persuasive but concise (2-3 sentences). Address your opponent's last point directly."
            )
            debaterB = makeAgent(
                name          = "Opponent"
                ,systemPrompt = "You argue AGAINST the given position. Be persuasive but concise (2-3 sentences). Address your opponent's last point directly."
            )

        let topic   = "Remote work is better than office work"
        let rounds  = 3
        var lastMsg = &"Topic: {topic}. Make your opening argument."

        for round in 1 .. rounds:
            echo &"\n  --- Round {round} ---"

            echo &"\n  [Proponent]:"
            lastMsg = await debaterA.ask(&"Your opponent said: \"{lastMsg}\"\n\nRespond with your argument.")
            echo "  ", lastMsg

            echo &"\n  [Opponent]:"
            lastMsg = await debaterB.ask(&"Your opponent said: \"{lastMsg}\"\n\nRespond with your counter-argument.")
            echo "  ", lastMsg

        echo "\n--- Debate Complete ---"

    waitFor main()


# =============================================================================
# 5. SELF-LOOP
# [Agent] → reviews own output → rewrites
#    ↑                              │
#    └──────────────────────────────┘  (N times)
# =============================================================================

when defined(selfLoop):
    proc main() {.async.} =
        echo "=== Pattern 5: SELF-LOOP ==="
        let agent = makeAgent(
            name          = "SelfRefiner"
            ,systemPrompt = "You are a writing expert. When given text to improve, you critique it and rewrite it better. When asked to write initially, produce a first draft."
        )

        let task      = "Write a haiku about programming."
        let iterations = 3

        echo &"  Task: {task}"
        var output = await agent.ask(task)
        echo &"\n  [Draft 0]: {output}"

        for i in 1 .. iterations:
            output = await agent.ask(&"Review and improve this text. Output ONLY the improved version, nothing else:\n\n{output}")
            echo &"\n  [Draft {i}]: {output}"

        echo "\n--- Final Result ---"
        echo output

    waitFor main()


# =============================================================================
# 6. FAN-OUT / FAN-IN
#                 ┌→ [Worker1] ─┐
# [Planner] ──→  ├→ [Worker2] ─┤  → [Aggregator] → [Result]
#                 └→ [Worker3] ─┘
# =============================================================================

when defined(fanOutFanIn):
    proc main() {.async.} =
        echo "=== Pattern 6: FAN-OUT / FAN-IN ==="
        let
            planner = makeAgent(
                name          = "Planner"
                ,systemPrompt = "You break tasks into exactly 3 subtasks. Output ONLY a numbered list: 1. ... 2. ... 3. ..."
            )
            aggregator = makeAgent(
                name          = "Aggregator"
                ,systemPrompt = "You combine multiple results into a single cohesive summary. Be thorough but concise."
            )

        let task = "Explain the pros and cons of microservices architecture"
        echo &"  Task: {task}"

        echo "\n  [Planner]"
        let plan = await planner.ask(&"Break this task into 3 subtasks: {task}")
        echo "  ", plan

        discard """Parse the numbered list into subtasks"""
        let lines = plan.splitLines().filterIt(it.strip.len > 0 and it.strip[0] in {'1', '2', '3'})

        var workerResults : seq[string] = @[]
        for idx, subtask in lines:
            let worker = makeAgent(
                name          = &"Worker{idx+1}"
                ,systemPrompt = "You are an expert who answers questions thoroughly in 2-3 sentences."
            )
            echo &"\n  [Worker{idx+1}]: {subtask.strip}"
            let result = await worker.ask(subtask.strip)
            workerResults.add(&"## Subtask: {subtask.strip}\n{result}")

        echo "\n  [Aggregator]"
        let combined = workerResults.join("\n\n")
        let final = await aggregator.ask(&"Combine these results into a cohesive answer:\n\n{combined}")

        echo "\n--- Final Result ---"
        echo final

    waitFor main()


# =============================================================================
# 7. SUPERVISOR / WORKER
# [Supervisor] ──→ delegates ──→ [Coder] or [Writer]
#      ↑                              │
#      └──── sees result, decides ────┘
# =============================================================================

when defined(supervisorWorker):
    proc main() {.async.} =
        echo "=== Pattern 7: SUPERVISOR / WORKER ==="
        let
            supervisor = makeAgent(
                name          = "Supervisor"
                ,systemPrompt = """You are a task supervisor. Given a user request, decide who should handle it.
Reply with EXACTLY one of these on the first line:
DELEGATE:coder — for code/programming tasks
DELEGATE:writer — for writing/creative tasks
DONE — if the combined results are satisfactory

Then on subsequent lines, provide instructions for the delegate or your final summary."""
            )
            coder = makeAgent(
                name          = "Coder"
                ,systemPrompt = "You write clean, well-commented code. Output only code."
            )
            writer = makeAgent(
                name          = "Writer"
                ,systemPrompt = "You write clear, engaging prose. Output only the text."
            )

        let task = "Create a Python function that calculates Fibonacci numbers, and write a brief explanation of how it works."
        echo &"  Task: {task}"

        var
            context = task
            rounds  = 0
            maxRounds = 5

        while rounds < maxRounds:
            rounds.inc
            echo &"\n  [Supervisor round {rounds}]"
            let decision = await supervisor.ask(context)
            echo "  ", decision[0 ..< min(200, decision.len)]

            if decision.startsWith("DONE") or "DONE" in decision:
                echo "\n--- Supervisor says DONE ---"
                echo decision
                break
            elif "DELEGATE:coder" in decision or "coder" in decision.toLowerAscii:
                echo "\n  [Delegating to Coder]"
                let codeResult = await coder.ask(decision)
                context = &"The coder produced:\n{codeResult}\n\nIs this complete or do you need more work?"
            elif "DELEGATE:writer" in decision or "writer" in decision.toLowerAscii:
                echo "\n  [Delegating to Writer]"
                let writeResult = await writer.ask(decision)
                context = &"The writer produced:\n{writeResult}\n\nIs this complete or do you need more work?"
            else:
                context = &"Previous output:\n{decision}\n\nPlease delegate to coder or writer, or say DONE."

        echo "\n--- Supervisor/Worker Complete ---"

    waitFor main()


# =============================================================================
# 8. ESCALATION
# [Cheap Model] → not confident? → [Premium Model]
# =============================================================================

when defined(escalation):
    proc main() {.async.} =
        echo "=== Pattern 8: ESCALATION ==="
        let
            cheapAgent = makeAgent(
                name          = "CheapAgent"
                ,model        = cheapModel
                ,systemPrompt = """Answer the question. If you are not confident in your answer, start your response with "UNCERTAIN:" followed by your best guess. If you are confident, just answer directly."""
            )
            premiumAgent = makeAgent(
                name          = "PremiumAgent"
                ,model        = premiumModel
                ,systemPrompt = "You are an expert. Provide a thorough, accurate answer."
                ,toolsList    = @[webSearchTool()]
            )

        let question = "What is the exact population of Liechtenstein as of 2026?"
        echo &"  Question: {question}"

        echo "\n  [Cheap Model]"
        let cheapResult = await cheapAgent.ask(question)
        echo "  ", cheapResult

        if cheapResult.startsWith("UNCERTAIN") or "uncertain" in cheapResult.toLowerAscii or "not sure" in cheapResult.toLowerAscii:
            echo "\n  → Escalating to premium model..."
            let premiumResult = await premiumAgent.ask(question)
            echo "\n--- Premium Result ---"
            echo premiumResult
        else:
            echo "\n--- Cheap model was confident ---"
            echo cheapResult

    waitFor main()


# =============================================================================
# 9. GUARD → WORKER → VALIDATOR
# [Guard] → approved? → [Worker] → [Validator] → pass/fail
# =============================================================================

when defined(guardWorkerValidator):
    proc main() {.async.} =
        echo "=== Pattern 9: GUARD → WORKER → VALIDATOR ==="
        let
            guard = makeAgent(
                name          = "Guard"
                ,systemPrompt = """You are a safety guard. Evaluate if the request is safe and appropriate.
Reply with EXACTLY:
APPROVED — if the request is safe
REJECTED: <reason> — if the request is unsafe or inappropriate"""
            )
            worker = makeAgent(
                name          = "Worker"
                ,systemPrompt = "You complete tasks as requested. Be thorough and accurate."
            )
            validator = makeAgent(
                name          = "Validator"
                ,systemPrompt = """You validate output quality. Check for:
1. Correctness
2. Completeness
3. Clarity
Reply with EXACTLY:
PASS — if the output is good
FAIL: <reason> — if improvements are needed"""
            )

        let task = "Write a short poem about the beauty of mathematics."
        echo &"  Task: {task}"

        echo "\n  [Guard]"
        let guardResult = await guard.ask(&"Evaluate this request: {task}")
        echo "  ", guardResult

        if "REJECTED" in guardResult:
            echo "\n--- Request REJECTED by guard ---"
            echo guardResult
        else:
            echo "\n  [Worker]"
            let workerResult = await worker.ask(task)
            echo "  ", workerResult

            echo "\n  [Validator]"
            let validatorResult = await validator.ask(&"Validate this output for the task \"{task}\":\n\n{workerResult}")
            echo "  ", validatorResult

            if "FAIL" in validatorResult:
                echo "\n--- Validation FAILED ---"
                echo validatorResult
            else:
                echo "\n--- Final Validated Result ---"
                echo workerResult

    waitFor main()


# =============================================================================
# 10. ACCUMULATOR
# [Agent] → section 1 → section 2 → ... → section N → [Full Doc]
# =============================================================================

when defined(accumulator):
    proc main() {.async.} =
        echo "=== Pattern 10: ACCUMULATOR ==="
        let agent = makeAgent(
            name          = "Accumulator"
            ,systemPrompt = "You write one section at a time for a document. Output ONLY that section's content, no preamble."
        )

        let sections = @[
            "Introduction to Rust programming language"
            ,"Rust's ownership model and borrowing"
            ,"Pattern matching and enums in Rust"
            ,"Conclusion and when to use Rust"
        ]

        var fullDoc = ""

        for idx, section in sections:
            echo &"\n  [Section {idx+1}/{sections.len}]: {section}"
            let context = if fullDoc.len > 0:
                &"Document so far:\n{fullDoc}\n\nNow write the next section about: {section}"
            else:
                &"Write the first section about: {section}"

            let sectionText = await agent.ask(context)
            fullDoc.add(&"\n\n## {section}\n\n{sectionText}")
            echo "  ✓ Added ", sectionText.len, " chars"

        echo "\n--- Full Accumulated Document ---"
        echo fullDoc

    waitFor main()


# =============================================================================
# 11. MAP-REDUCE
# [Splitter] → [Mapper1, Mapper2, ...MapperN] → [Reducer]
# =============================================================================

when defined(mapReduce):
    proc main() {.async.} =
        echo "=== Pattern 11: MAP-REDUCE ==="

        let document = """
Paragraph 1: The Industrial Revolution began in Britain in the late 18th century. It transformed economies from agrarian to industrial. Key inventions included the spinning jenny and the steam engine.

Paragraph 2: The Digital Revolution started in the mid-20th century. Computers evolved from room-sized machines to pocket-sized devices. The internet connected billions of people worldwide.

Paragraph 3: Artificial Intelligence emerged as a field in the 1950s. Early AI focused on symbolic reasoning and expert systems. Modern AI leverages deep learning and massive datasets.

Paragraph 4: Quantum computing promises to solve problems beyond classical computers. Companies like IBM and Google are racing to build practical quantum machines. Applications include cryptography and drug discovery.
"""

        discard """Split into chunks"""
        let chunks = document.strip.split("\n\n").filterIt(it.strip.len > 0)
        echo &"  Split into {chunks.len} chunks"

        discard """Map phase: summarize each chunk"""
        var summaries : seq[string] = @[]
        for idx, chunk in chunks:
            let mapper = makeAgent(
                name          = &"Mapper{idx+1}"
                ,systemPrompt = "Summarize the given text in exactly one sentence."
            )
            echo &"\n  [Mapper{idx+1}]"
            let summary = await mapper.ask(&"Summarize this paragraph:\n{chunk}")
            summaries.add(summary)
            echo "  ", summary

        discard """Reduce phase: combine summaries"""
        let reducer = makeAgent(
            name          = "Reducer"
            ,systemPrompt = "Combine the given summaries into a single coherent paragraph."
        )
        echo "\n  [Reducer]"
        let combined = summaries.mapIt(&"- {it}").join("\n")
        let final = await reducer.ask(&"Combine these summaries into one coherent paragraph:\n{combined}")

        echo "\n--- Reduced Result ---"
        echo final

    waitFor main()


# =============================================================================
# 12. CRITIC / REWRITER PAIR
# [Generator] → [Critic] → feedback → [Generator] → [Critic] → ... → DONE
# =============================================================================

when defined(criticRewriter):
    proc main() {.async.} =
        echo "=== Pattern 12: CRITIC / REWRITER PAIR ==="
        let
            generator = makeAgent(
                name          = "Generator"
                ,systemPrompt = "You write and rewrite text based on feedback. Output ONLY the text, nothing else."
            )
            critic = makeAgent(
                name          = "Critic"
                ,systemPrompt = """You critique writing quality. Be specific and constructive.
If the writing is excellent and needs no changes, respond with exactly: APPROVED
Otherwise, provide 2-3 specific improvements needed."""
            )

        let task   = "Write a compelling opening paragraph for a sci-fi novel about first contact with aliens."
        let rounds = 3

        echo &"  Task: {task}"

        var draft = await generator.ask(task)
        echo &"\n  [Draft 0]: {draft}"

        for round in 1 .. rounds:
            echo &"\n  [Critic round {round}]"
            let critique = await critic.ask(&"Critique this text:\n\n{draft}")
            echo "  ", critique

            if "APPROVED" in critique:
                echo "\n  ✓ Critic approved!"
                break

            echo &"\n  [Rewrite round {round}]"
            draft = await generator.ask(&"Rewrite this text based on the feedback. Output ONLY the rewritten text.\n\nOriginal:\n{draft}\n\nFeedback:\n{critique}")
            echo "  ", draft

        echo "\n--- Final Result ---"
        echo draft

    waitFor main()


# =============================================================================
# 13. ROUTER / SPECIALIST POOL
#                 ┌→ [CodeAgent]
# [Router] ──→   ├→ [MathAgent]
#                 ├→ [WritingAgent]
#                 └→ [GeneralAgent]
# =============================================================================

when defined(routerSpecialist):
    proc main() {.async.} =
        echo "=== Pattern 13: ROUTER / SPECIALIST POOL ==="
        let
            router = makeAgent(
                name          = "Router"
                ,systemPrompt = """Classify the user's request into exactly ONE category.
Reply with ONLY one word:
CODE — for programming/code questions
MATH — for math/calculation questions
WRITING — for creative writing/editing
GENERAL — for anything else"""
            )
            codeAgent = makeAgent(
                name          = "CodeSpecialist"
                ,systemPrompt = "You are an expert programmer. Provide clean, well-explained code solutions."
            )
            mathAgent = makeAgent(
                name          = "MathSpecialist"
                ,systemPrompt = "You are a math expert. Show your work step by step."
            )
            writingAgent = makeAgent(
                name          = "WritingSpecialist"
                ,systemPrompt = "You are a creative writing expert. Produce engaging, polished prose."
            )
            generalAgent = makeAgent(
                name          = "GeneralSpecialist"
                ,systemPrompt = "You are a knowledgeable assistant. Provide clear, helpful answers."
            )

        let question = "Write a Python function to check if a number is prime."
        echo &"  Question: {question}"

        echo "\n  [Router]"
        let route = await router.ask(question)
        let category = route.strip.toUpperAscii

        echo &"  Routed to: {category}"

        let specialist = if "CODE" in category: codeAgent
            elif "MATH" in category: mathAgent
            elif "WRITING" in category: writingAgent
            else: generalAgent

        echo &"\n  [{specialist.name}]"
        let result = await specialist.ask(question)

        echo "\n--- Result ---"
        echo result

    waitFor main()


# =============================================================================
# 14. CONSENSUS (Multi-Agent Voting)
# [Agent1] ─┐
# [Agent2] ─┤→ [Voter/Judge] → best answer
# [Agent3] ─┘
# =============================================================================

when defined(consensus):
    proc main() {.async.} =
        echo "=== Pattern 14: CONSENSUS (Multi-Agent Voting) ==="

        let question = "What is the most important invention of the 20th century?"
        echo &"  Question: {question}"

        var answers : seq[string] = @[]
        for idx in 1 .. 3:
            let agent = makeAgent(
                name          = &"Voter{idx}"
                ,systemPrompt = &"You are expert #{idx}. Give your answer in 1-2 sentences. Be specific and pick ONE invention."
            )
            echo &"\n  [Voter{idx}]"
            let answer = await agent.ask(question)
            answers.add(&"Expert {idx}: {answer}")
            echo "  ", answer

        let judge = makeAgent(
            name          = "Judge"
            ,systemPrompt = "You evaluate multiple expert opinions. Determine which answer is best supported or find the consensus. Provide a brief final answer."
        )

        echo "\n  [Judge]"
        let combined = answers.join("\n\n")
        let verdict = await judge.ask(&"These experts answered the question \"{question}\":\n\n{combined}\n\nWhat is the consensus or best answer?")

        echo "\n--- Consensus Result ---"
        echo verdict

    waitFor main()


# =============================================================================
# 15. HUMAN-IN-THE-LOOP CHECKPOINT
# [Agent] → work → CHECKPOINT → human approves? → continue → ...
# =============================================================================

when defined(humanInTheLoop):
    proc main() {.async.} =
        echo "=== Pattern 15: HUMAN-IN-THE-LOOP CHECKPOINT ==="
        let agent = makeAgent(
            name          = "HITLAgent"
            ,systemPrompt = "You are a planning assistant. Create plans step by step. After each major step, use the ask_human tool to get approval before continuing."
            ,toolsList    = @[HITLTool()]
            ,maxToolCalls = 10
        )

        let result = await agent.ask("Help me plan a weekend trip to Chicago. Ask me for my preferences at each step.")

        echo "\n--- Final Plan ---"
        echo result

    waitFor main()


# =============================================================================
# 16. MEMORY-PASSING CHAIN
# [Agent1] → updates memory → [Agent2] → reads + updates → [Agent3]
# =============================================================================

when defined(memoryPassingChain):
    proc main() {.async.} =
        echo "=== Pattern 16: MEMORY-PASSING CHAIN ==="

        discard """Shared scratchpad (simple string-based memory)"""
        var scratchpad = ""

        let tasks = @[
            ("Researcher"  , "Research the topic 'benefits of meditation' and write 3 key findings. Prefix each with FINDING:")
            ,("Analyst"    , "Analyze the findings and identify the strongest one. State it as STRONGEST:")
            ,("Writer"     , "Write a 2-sentence persuasive pitch based on the strongest finding.")
        ]

        for (name, task) in tasks:
            let agent = makeAgent(
                name          = name
                ,systemPrompt = &"You are a {name}. You have access to a shared scratchpad with notes from previous agents."
            )

            let prompt = if scratchpad.len > 0:
                &"Shared scratchpad:\n{scratchpad}\n\nYour task: {task}"
            else:
                &"Your task: {task}"

            echo &"\n  [{name}]"
            let result = await agent.ask(prompt)
            echo "  ", result[0 ..< min(200, result.len)]

            scratchpad.add(&"\n\n--- {name} ---\n{result}")

        echo "\n--- Final Scratchpad ---"
        echo scratchpad

    waitFor main()


# =============================================================================
# 17. RETRY WITH BACKOFF
# [Agent] → error → wait 1s → retry → error → wait 4s → retry → escalate
# =============================================================================

when defined(retryWithBackoff):
    proc main() {.async.} =
        echo "=== Pattern 17: RETRY WITH BACKOFF ==="

        let
            cheapAgent = makeAgent(
                name          = "CheapRetryAgent"
                ,model        = cheapModel
                ,systemPrompt = """You answer factual questions. Output ONLY valid JSON: {"answer": "...", "confidence": 0.0-1.0}
If you cannot answer, set confidence below 0.3."""
            )
            premiumAgent = makeAgent(
                name          = "PremiumFallback"
                ,model        = premiumModel
                ,systemPrompt = "You are an expert. Provide a thorough, accurate answer."
            )

        let question = "What year was the Treaty of Tordesillas signed and what did it do?"
        echo &"  Question: {question}"

        var
            attempts    = 0
            maxAttempts = 3
            backoffMs   = 1000
            success     = false
            finalResult = ""

        while attempts < maxAttempts and not success:
            attempts.inc
            echo &"\n  Attempt {attempts} (backoff: {backoffMs}ms)"

            let result = await cheapAgent.ask(question)

            try:
                let parsed = parseJson(result)
                let confidence = parsed.getOrDefault("confidence").getFloat(0.0)
                echo &"  Confidence: {confidence:.2f}"

                if confidence >= 0.5:
                    success     = true
                    finalResult = parsed["answer"].getStr
                else:
                    echo "  Low confidence, backing off..."
                    await sleepAsync(backoffMs)
                    backoffMs = backoffMs * 2
            except:
                echo "  Parse error, backing off..."
                await sleepAsync(backoffMs)
                backoffMs = backoffMs * 2

        if not success:
            echo "\n  → Escalating to premium model..."
            finalResult = await premiumAgent.ask(question)

        echo "\n--- Final Result ---"
        echo finalResult

    waitFor main()


# =============================================================================
# 18. STREAMING PIPELINE (Event-Driven)
# Wire agents through events — each agent's onMessage fires the next.
# =============================================================================

when defined(streamingPipeline):
    proc main() {.async.} =
        echo "=== Pattern 18: STREAMING PIPELINE (Event-Driven) ==="

        var
            finalOutput = ""
            stage2Done  = newFuture[void]("stage2")
            stage3Done  = newFuture[void]("stage3")

        let
            stage1 = makeAgent(
                name          = "Stage1_Extract"
                ,systemPrompt = "Extract the 3 most important keywords from the text. Output them comma-separated."
            )
            stage2 = makeAgent(
                name          = "Stage2_Expand"
                ,systemPrompt = "Take keywords and write one sentence about each. Output the sentences."
            )
            stage3 = makeAgent(
                name          = "Stage3_Format"
                ,systemPrompt = "Format the given sentences into a clean bulleted list with a title."
            )

        discard """Wire stage2's onMessage to trigger stage3"""
        stage2.onMessage:
            echo &"  [Stage2 done, triggering Stage3]"
            let s3result = waitFor stage3.ask(e.msgText)
            finalOutput = s3result
            stage3Done.complete()

        discard """Wire stage1's onMessage to trigger stage2"""
        stage1.onMessage:
            echo &"  [Stage1 done, triggering Stage2]"
            let s2result = waitFor stage2.ask(e.msgText)

        let inputText = "Quantum computing uses quantum bits or qubits. Unlike classical bits, qubits can exist in superposition. This allows quantum computers to solve certain problems exponentially faster than classical computers."

        echo &"  Input: {inputText[0..80]}..."
        echo "\n  [Stage1: Extract keywords]"
        let s1result = await stage1.ask(inputText)

        await stage3Done

        echo "\n--- Final Pipeline Output ---"
        echo finalOutput

    waitFor main()


# =============================================================================
# 19. FORKING PATHS
# [Generator] → option A → [ExplorerA] ─┐
#             → option B → [ExplorerB] ─┤→ [Judge] → best result
#             → option C → [ExplorerC] ─┘
# =============================================================================

when defined(forkingPaths):
    proc main() {.async.} =
        echo "=== Pattern 19: FORKING PATHS ==="
        let generator = makeAgent(
            name          = "Generator"
            ,systemPrompt = """Generate exactly 3 different approaches to solve the given problem.
Format as:
OPTION A: <approach>
OPTION B: <approach>
OPTION C: <approach>"""
        )

        let problem = "Design a notification system for a mobile app"
        echo &"  Problem: {problem}"

        echo "\n  [Generator]"
        let options = await generator.ask(problem)
        echo "  ", options

        discard """Parse options"""
        let lines = options.splitLines()
        var optionTexts : seq[string] = @[]
        var currentOpt  = ""
        for line in lines:
            if line.strip.startsWith("OPTION"):
                if currentOpt.len > 0: optionTexts.add(currentOpt.strip)
                currentOpt = line
            elif currentOpt.len > 0:
                currentOpt.add(" " & line.strip)
        if currentOpt.len > 0: optionTexts.add(currentOpt.strip)

        discard """If parsing failed, just split into 3"""
        if optionTexts.len == 0:
            let chunks = options.split("OPTION")
            for c in chunks:
                if c.strip.len > 10:
                    optionTexts.add(c.strip)

        discard """Explore each option"""
        var explorations : seq[string] = @[]
        for idx, opt in optionTexts:
            if idx >= 3: break
            let explorer = makeAgent(
                name          = &"Explorer{chr(ord('A') + idx)}"
                ,systemPrompt = "You explore and develop an idea into a concrete plan. List 3 specific implementation steps."
            )
            echo &"\n  [Explorer{chr(ord('A') + idx)}]"
            let explored = await explorer.ask(&"Develop this approach in detail:\n{opt}")
            explorations.add(&"=== Option {chr(ord('A') + idx)} ===\n{opt}\n\nExploration:\n{explored}")
            echo "  ", explored[0 ..< min(150, explored.len)], "..."

        discard """Judge picks the best"""
        let judge = makeAgent(
            name          = "Judge"
            ,systemPrompt = "You evaluate approaches and pick the best one. Explain your choice clearly."
        )
        echo "\n  [Judge]"
        let allExplorations = explorations.join("\n\n")
        let verdict = await judge.ask(&"Pick the best approach for: {problem}\n\n{allExplorations}")

        echo "\n--- Judge's Verdict ---"
        echo verdict

    waitFor main()


# =============================================================================
# 20. AGENT WITH PERSISTENT STATE ACROSS RUNS
# Run 1: user says X → agent learns fact A
# Run 2: agent recalls fact A → user says Y → agent learns fact B
# =============================================================================

when defined(persistentState):
    proc main() {.async.} =
        echo "=== Pattern 20: PERSISTENT STATE ACROSS RUNS ==="

        let memPath = artifactsDir / "persistent_agent_memory.json"
        let memStore = newMemoryStore(memPath)

        echo &"  Memory file: {memPath}"
        echo &"  Existing memories: {memStore.count()}"

        let agent = makeAgent(
            name          = "PersistentAgent"
            ,systemPrompt = """You are a personal assistant with persistent memory.
At the start of each conversation, review any existing memories.
During conversation, store important facts using the memory tool.
Always acknowledge what you remember from past sessions."""
            ,toolsList    = @[MemoryTool(memStore)]
            ,maxToolCalls = 10
        )

        discard """Show existing memories"""
        if memStore.count() > 0:
            echo "\n  Existing memories:"
            let existing = memStore.list(limit = 10)
            for m in existing:
                echo &"    [{m.kind}] {m.content}"

        discard """Interactive loop"""
        echo "\n  Type messages (or 'quit' to exit):"
        echo "  Each message is a new 'run' — the agent persists facts between them."

        var runCount = 0
        while true:
            runCount.inc
            echo &"\n  --- Run {runCount} ---"
            stdout.write("  You: ")
            stdout.flushFile()

            let userInput = stdin.readLine().strip
            if userInput.toLowerAscii in ["quit", "exit", "q"]:
                break

            let memContext = if memStore.count() > 0:
                let mems = memStore.list(limit = 5)
                let memStr = mems.mapIt(&"- [{it.kind}] {it.content}").join("\n")
                &"Your memories from past interactions:\n{memStr}\n\nUser says: {userInput}"
            else:
                userInput

            let result = await agent.ask(memContext)
            echo &"\n  Agent: {result}"
            echo &"  [Memories stored: {memStore.count()}]"

    waitFor main()


# =============================================================================
# No pattern selected
# =============================================================================

when not defined(oneshot) and
     not defined(retryLoop) and
     not defined(serialPipeline) and
     not defined(pingPong) and
     not defined(selfLoop) and
     not defined(fanOutFanIn) and
     not defined(supervisorWorker) and
     not defined(escalation) and
     not defined(guardWorkerValidator) and
     not defined(accumulator) and
     not defined(mapReduce) and
     not defined(criticRewriter) and
     not defined(routerSpecialist) and
     not defined(consensus) and
     not defined(humanInTheLoop) and
     not defined(memoryPassingChain) and
     not defined(retryWithBackoff) and
     not defined(streamingPipeline) and
     not defined(forkingPaths) and
     not defined(persistentState):

    echo """
Agent Patterns — Pick one to run:

  nim r -d:ic -d:ssl -d:oneshot             agent_patterns.nim   #  1. One-shot
  nim r -d:ic -d:ssl -d:retryLoop           agent_patterns.nim   #  2. Retry Loop
  nim r -d:ic -d:ssl -d:serialPipeline      agent_patterns.nim   #  3. Serial Pipeline
  nim r -d:ic -d:ssl -d:pingPong            agent_patterns.nim   #  4. Ping-Pong
  nim r -d:ic -d:ssl -d:selfLoop            agent_patterns.nim   #  5. Self-Loop
  nim r -d:ic -d:ssl -d:fanOutFanIn         agent_patterns.nim   #  6. Fan-Out / Fan-In
  nim r -d:ic -d:ssl -d:supervisorWorker    agent_patterns.nim   #  7. Supervisor / Worker
  nim r -d:ic -d:ssl -d:escalation          agent_patterns.nim   #  8. Escalation
  nim r -d:ic -d:ssl -d:guardWorkerValidator agent_patterns.nim  #  9. Guard / Worker / Validator
  nim r -d:ic -d:ssl -d:accumulator         agent_patterns.nim   # 10. Accumulator
  nim r -d:ic -d:ssl -d:mapReduce           agent_patterns.nim   # 11. Map-Reduce
  nim r -d:ic -d:ssl -d:criticRewriter      agent_patterns.nim   # 12. Critic / Rewriter
  nim r -d:ic -d:ssl -d:routerSpecialist    agent_patterns.nim   # 13. Router / Specialist
  nim r -d:ic -d:ssl -d:consensus           agent_patterns.nim   # 14. Consensus
  nim r -d:ic -d:ssl -d:humanInTheLoop      agent_patterns.nim   # 15. Human-in-the-Loop
  nim r -d:ic -d:ssl -d:memoryPassingChain  agent_patterns.nim   # 16. Memory-Passing Chain
  nim r -d:ic -d:ssl -d:retryWithBackoff    agent_patterns.nim   # 17. Retry with Backoff
  nim r -d:ic -d:ssl -d:streamingPipeline   agent_patterns.nim   # 18. Streaming Pipeline
  nim r -d:ic -d:ssl -d:forkingPaths        agent_patterns.nim   # 19. Forking Paths
  nim r -d:ic -d:ssl -d:persistentState     agent_patterns.nim   # 20. Persistent State
"""


discard """
nim r -d:ssl -d:oneshot              ./examples/agents/patterns.nim
nim r -d:ssl -d:retryLoop            ./examples/agents/patterns.nim
nim r -d:ssl -d:serialPipeline       ./examples/agents/patterns.nim
nim r -d:ssl -d:pingPong             ./examples/agents/patterns.nim
nim r -d:ssl -d:selfLoop             ./examples/agents/patterns.nim
nim r -d:ssl -d:fanOutFanIn          ./examples/agents/patterns.nim
nim r -d:ssl -d:supervisorWorker     ./examples/agents/patterns.nim
nim r -d:ssl -d:escalation           ./examples/agents/patterns.nim
nim r -d:ssl -d:guardWorkerValidator ./examples/agents/patterns.nim
nim r -d:ssl -d:accumulator          ./examples/agents/patterns.nim
nim r -d:ssl -d:mapReduce            ./examples/agents/patterns.nim
nim r -d:ssl -d:criticRewriter       ./examples/agents/patterns.nim
nim r -d:ssl -d:routerSpecialist     ./examples/agents/patterns.nim
nim r -d:ssl -d:consensus            ./examples/agents/patterns.nim
nim r -d:ssl -d:humanInTheLoop       ./examples/agents/patterns.nim
nim r -d:ssl -d:memoryPassingChain   ./examples/agents/patterns.nim
nim r -d:ssl -d:retryWithBackoff     ./examples/agents/patterns.nim
nim r -d:ssl -d:streamingPipeline    ./examples/agents/patterns.nim
nim r -d:ssl -d:forkingPaths         ./examples/agents/patterns.nim
nim r -d:ssl -d:persistentState      ./examples/agents/patterns.nim
"""