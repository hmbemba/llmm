# =============================================================================
# ralph.nim — Ralph Loop for llmm
# =============================================================================
#
# Ralph is a technique: run an agent in a loop with FRESH context each time.
# Progress persists in files. Failures evaporate with the context window.
#
# Core invariants:
#   - One task per loop iteration
#   - State lives on the filesystem, not in context
#   - Fresh agent each iteration (no context pollution)
#   - Guardrails are append-only (same mistake never twice)
#   - Tests/verification gate each iteration
#   - Git commit after each successful task
#
# Usage:
#   nim r -d:ssl -d:ic ralph.nim
#
# Or import and use programmatically:
#   import ralph
#   waitFor ralphLoop(config)
#
# =============================================================================

import std/[
    json
    ,times
    ,options
    ,asyncdispatch
    ,strformat
    ,strutils
    ,os
    ,osproc
    ,oids
    ,tables
    ,sugar
]

import
    llmm/harness/primitives/agent
    ,llmm/harness/primitives/tick
    ,llmm/harness/tools/base
    ,llmm/harness/tools/filesystem
    ,llmm/providers/oai/oai_client
    ,llmm/providers/oai/utils/builders
    ,llmm/providers/oai/responses/types

import mynimlib/[keys]
from mynimlib/utils import dirExistsOrMk
import ic


# =============================================================================
# Types
# =============================================================================

type
    RalphSignal * = enum
        rsOk             ## Iteration completed successfully
        rsComplete       ## All tasks done, PRD fulfilled
        rsError          ## Iteration failed
        rsGutter         ## Same failure repeating, needs intervention
        rsRotate         ## Context getting stale, forced rotation (always happens in ralph)
        rsAbort          ## Unrecoverable, stop the loop

    RalphIteration * = object
        number       * : int
        startedAt    * : DateTime
        elapsed      * : Duration
        signal       * : RalphSignal
        taskWorkedOn * : string
        commitHash   * : string
        tokensUsed   * : int
        error        * : string

    RalphConfig * = object
        ## ── Workspace ──
        workDir          * : string       ## Root project directory (where code lives)
        ralphDir         * : string       ## .ralph/ state directory (auto-created)

        ## ── Agent ──
        model            * : string       ## Model to use (default: gpt-4o-mini)
        escalationModel  * : string       ## Stronger model for retries (default: gpt-4o)
        maxToolCalls     * : int          ## Max tool calls per iteration

        ## ── Loop control ──
        maxIterations    * : int          ## Hard cap on loop iterations
        maxConsecErrors  * : int          ## Consecutive errors before abort
        pauseEachLoop    * : bool         ## If true, wait for Enter between iterations (HITL)
        autoCommit       * : bool         ## Git commit after each successful iteration

        ## ── Files ──
        prdFile          * : string       ## PRD / task file (relative to workDir)
        progressFile     * : string       ## Progress tracking file
        guardrailsFile   * : string       ## Learned constraints
        errorsLog        * : string       ## Error log
        activityLog      * : string       ## Activity / token log

        ## ── Verification ──
        testCommand      * : string       ## Command to run after each iteration (e.g. "nim c project.nim")
        completionSigil  * : string       ## String agent outputs when PRD is complete

        ## ── Tools ──
        extraTools       * : seq[Tool]    ## Additional tools beyond filesystem

    RalphState * = object
        config       * : RalphConfig
        iterations   * : seq[RalphIteration]
        totalTokens  * : int
        consecErrors * : int
        startedAt    * : DateTime
        complete     * : bool


# =============================================================================
# Defaults
# =============================================================================

proc defaultRalphConfig*(workDir: string): RalphConfig =
    RalphConfig(
        workDir          : workDir
        ,ralphDir        : workDir / ".ralph"
        ,model           : "gpt-4o-mini"
        ,escalationModel : "gpt-4o"
        ,maxToolCalls    : 15
        ,maxIterations   : 20
        ,maxConsecErrors : 3
        ,pauseEachLoop   : false
        ,autoCommit      : true
        ,prdFile         : "PRD.md"
        ,progressFile    : "progress.txt"
        ,guardrailsFile  : "guardrails.md"
        ,errorsLog       : "errors.log"
        ,activityLog     : "activity.log"
        ,testCommand     : ""
        ,completionSigil : "<RALPH_COMPLETE>"
    )


# =============================================================================
# Filesystem helpers — state lives here, not in context
# =============================================================================

proc ensureDirs(config: RalphConfig) =
    discard dirExistsOrMk config.workDir
    discard dirExistsOrMk config.ralphDir

proc ralphPath(config: RalphConfig, filename: string): string =
    config.ralphDir / filename

proc readStateFile(config: RalphConfig, filename: string): string =
    let path = config.ralphPath(filename)
    if fileExists(path): readFile(path)
    else: ""

proc appendStateFile(config: RalphConfig, filename: string, content: string) =
    let path = config.ralphPath(filename)
    let f = open(path, fmAppend)
    defer: f.close()
    f.write(content & "\n")

proc writeStateFile(config: RalphConfig, filename: string, content: string) =
    writeFile(config.ralphPath(filename), content)

proc readPrd(config: RalphConfig): string =
    let path = config.workDir / config.prdFile
    if fileExists(path): readFile(path)
    else: ""

proc readProgress(config: RalphConfig): string =
    let path = config.workDir / config.progressFile
    if fileExists(path): readFile(path)
    else: ""

proc readGuardrails(config: RalphConfig): string =
    config.readStateFile(config.guardrailsFile)

proc addGuardrail(config: RalphConfig, sign: string, trigger: string, context: string, iteration: int) =
    let entry = &"""
### sign: {sign}
- trigger: {trigger}
- context: {context}
- added after: iteration {iteration}
"""
    config.appendStateFile(config.guardrailsFile, entry)

proc logError(config: RalphConfig, iteration: int, error: string) =
    let ts = now().format("yyyy-MM-dd HH:mm:ss")
    config.appendStateFile(config.errorsLog, &"[{ts}] iteration {iteration}: {error}")

proc logActivity(config: RalphConfig, iteration: int, model: string, tokens: int, signal: RalphSignal, task: string) =
    let ts = now().format("yyyy-MM-dd HH:mm:ss")
    config.appendStateFile(config.activityLog,
        &"[{ts}] iter={iteration} model={model} tokens={tokens} signal={signal} task={task}")


# =============================================================================
# Git helpers
# =============================================================================

proc gitExec(workDir: string, args: varargs[string]): tuple[output: string, exitCode: int] =
    let cmd = "git " & args.join(" ")
    let (output, exitCode) = execCmdEx(cmd, workingDir = workDir)
    (output.strip(), exitCode)

proc gitInit(workDir: string) =
    if not dirExists(workDir / ".git"):
        discard gitExec(workDir, "init")
        discard gitExec(workDir, "add", "-A")
        discard gitExec(workDir, "commit", "-m", "\"ralph: initial commit\"")

proc gitCommit(workDir: string, message: string): string =
    ## Stage all, commit, return short hash. Returns "" on failure.
    discard gitExec(workDir, "add", "-A")
    let (_, exitCode) = gitExec(workDir, "commit", "-m", &"\"{message}\"")
    if exitCode == 0:
        let (hash, _) = gitExec(workDir, "rev-parse", "--short", "HEAD")
        return hash
    return ""

proc gitDiffStat(workDir: string): string =
    let (output, _) = gitExec(workDir, "diff", "--stat")
    output


# =============================================================================
# Verification
# =============================================================================

proc runVerification(config: RalphConfig): tuple[ok: bool, output: string] =
    if config.testCommand.len == 0:
        return (true, "no test command configured")
    let (output, exitCode) = execCmdEx(config.testCommand, workingDir = config.workDir)
    (exitCode == 0, output.strip())


# =============================================================================
# Agent factory — FRESH agent each iteration (this is the whole point)
# =============================================================================

proc buildRalphPrompt(config: RalphConfig, iteration: int): string =
    ## Build the system prompt from current filesystem state.
    ## This is reconstructed FRESH each iteration — no stale context.
    let
        prd        = config.readPrd()
        progress   = config.readProgress()
        guardrails = config.readGuardrails()

    var prompt = &"""You are a software engineer working on a project. You operate in a ralph loop.

## RULES
- Do ONE task per iteration. Not two. Not zero. ONE.
- Read the PRD to understand what needs building.
- Read progress.txt to see what's already done.
- Read guardrails to avoid known mistakes.
- After completing the task, update progress.txt with what you did.
- If ALL tasks in the PRD are complete, output exactly: {config.completionSigil}
- Write clean, working code. Run tests if a test command is available.
- If you encounter a problem that future iterations should avoid, create a guardrail.

## PRD
{prd}

## PROGRESS SO FAR
{progress}
"""

    if guardrails.len > 0:
        prompt.add &"""

## GUARDRAILS (learned constraints — read these FIRST)
{guardrails}
"""

    if config.testCommand.len > 0:
        prompt.add &"""

## VERIFICATION
After implementing, run this command to verify: `{config.testCommand}`
If it fails, fix the issue before finishing.
"""

    prompt.add &"""

## ITERATION
This is iteration {iteration}. You have fresh context. Trust the files, not any memory.
"""

    return prompt


proc spawnFreshAgent(config: RalphConfig, iteration: int, client: OpenAIClient, escalate = false): Agent =
    ## Create a brand new agent. No history. No prior context.
    ## State comes from the filesystem via the system prompt.
    let model = if escalate: config.escalationModel else: config.model

    var agt = Agent(
        id            : &"ralph-iter-{iteration}-{$genOid()}"
        ,name         : &"Ralph-{iteration}"
        ,role         : "Software Engineer"
        ,model        : model
        ,systemPrompt : buildRalphPrompt(config, iteration)
        ,workspaceDir : config.workDir
        ,artifactsDir : config.ralphDir / ".artifacts"
        ,client       : client
        ,policy       : AgentPolicy(maxToolCalls: config.maxToolCalls)
        ,tools        : addTools @[
            FileCrudToolkit(config.workDir)
        ]
    )

    # Add any extra tools
    for tool in config.extraTools:
        agt.addTools tool

    return agt


# =============================================================================
# Single Ralph iteration
# =============================================================================

proc ralphOnce(
    config    : RalphConfig,
    client    : OpenAIClient,
    iteration : int,
    escalate  : bool = false
): Future[RalphIteration] {.async.} =
    ## Execute one ralph iteration:
    ##   1. Spawn fresh agent (no context pollution)
    ##   2. Agent reads state from files, picks next task, implements it
    ##   3. Run verification (tests)
    ##   4. Git commit if successful
    ##   5. Return signal

    let startTime = now()
    var result = RalphIteration(
        number    : iteration
        ,startedAt : startTime
        ,signal    : rsOk
    )

    # ── 1. Fresh agent ──
    let model = if escalate: config.escalationModel else: config.model
    echo &"\n{'─'.repeat(60)}"
    echo &"  🔄 Ralph iteration {iteration}  |  model: {model}  |  {startTime.format(\"HH:mm:ss\")}"
    echo &"{'─'.repeat(60)}"

    var agent = spawnFreshAgent(config, iteration, client, escalate)

    # Wire up event logging
    agent.onMessage:
        echo &"  📝 Agent output: {e.msgText[0..min(120, e.msgText.len-1)]}..."

    # ── 2. Run the agent ──
    let taskPrompt = "Read the PRD and progress file. Find the next incomplete task. Implement it. " &
                     "Update progress.txt. Do ONE task only."

    let tickResult = await client.run(agent,
        input = some userMessage(taskPrompt))

    result.elapsed = now() - startTime
    result.tokensUsed = tickResult.tokensUsed

    # ── Check for errors ──
    if tickResult.error.isSome:
        result.signal = rsError
        result.error = tickResult.error.get()
        config.logError(iteration, result.error)
        echo &"  ❌ Error: {result.error}"
        return result

    # ── Check for completion sigil ──
    if config.completionSigil in tickResult.text:
        result.signal = rsComplete
        echo &"  🎉 Agent signals COMPLETE"
        return result

    # ── 3. Verification ──
    let (testOk, testOutput) = runVerification(config)
    if not testOk:
        result.signal = rsError
        result.error = &"Verification failed: {testOutput[0..min(200, testOutput.len-1)]}"
        config.logError(iteration, result.error)

        # Add guardrail so next iteration knows about this failure
        config.addGuardrail(
            sign    = "verification failed",
            trigger = "after implementation",
            context = testOutput[0..min(150, testOutput.len-1)],
            iteration = iteration
        )
        echo &"  ❌ Tests failed. Guardrail added."
        return result

    echo &"  ✅ Verification passed"

    # ── 4. Determine what task was worked on ──
    # Extract first line of agent output as a rough task description
    let lines = tickResult.text.strip().splitLines()
    result.taskWorkedOn = if lines.len > 0: lines[0][0..min(80, lines[0].len-1)] else: "unknown"

    # ── 5. Git commit ──
    if config.autoCommit:
        let diff = gitDiffStat(config.workDir)
        if diff.len > 0:
            let hash = gitCommit(config.workDir,
                &"ralph: iteration {iteration} — {result.taskWorkedOn}")
            result.commitHash = hash
            echo &"  📦 Committed: {hash}"
        else:
            echo &"  📦 No changes to commit"

    # ── 6. Log activity ──
    config.logActivity(iteration, model, result.tokensUsed, result.signal, result.taskWorkedOn)

    echo &"  ⏱️  {result.elapsed}  |  🪙 {result.tokensUsed} tokens"

    return result


# =============================================================================
# The Ralph Loop
# =============================================================================

proc ralphLoop*(
    config : RalphConfig,
    client : OpenAIClient
): Future[RalphState] {.async.} =
    ## The main ralph loop. Fresh context each iteration.
    ## Progress persists. Failures evaporate.

    config.ensureDirs()
    gitInit(config.workDir)

    var state = RalphState(
        config    : config
        ,startedAt : now()
    )

    # ── Validate PRD exists ──
    let prd = config.readPrd()
    if prd.len == 0:
        echo &"❌ No PRD found at {config.workDir / config.prdFile}"
        echo "  Create a PRD.md with your task checklist first."
        state.complete = false
        return state

    echo &"\n{'═'.repeat(60)}"
    echo &"  🏭 RALPH LOOP STARTING"
    echo &"  📁 Work dir:    {config.workDir}"
    echo &"  📋 PRD:         {config.prdFile}"
    echo &"  🤖 Model:       {config.model}"
    echo &"  🔁 Max iters:   {config.maxIterations}"
    echo &"  🧪 Test cmd:    {(if config.testCommand.len > 0: config.testCommand else: \"(none)\")}"
    echo &"  ⏸️  HITL pause:  {config.pauseEachLoop}"
    echo &"{'═'.repeat(60)}"

    for i in 1..config.maxIterations:
        # ── HITL pause ──
        if config.pauseEachLoop and i > 1:
            echo &"\n  ⏸️  Press Enter to continue (Ctrl+C to stop)..."
            discard stdin.readLine()

        # ── Decide if we should escalate ──
        let escalate = state.consecErrors >= 2  # Two failures → try stronger model

        # ── Run one iteration ──
        let iterResult = await ralphOnce(config, client, i, escalate)
        state.iterations.add iterResult
        state.totalTokens += iterResult.tokensUsed

        case iterResult.signal
        of rsComplete:
            state.complete = true
            echo &"\n  🎉 PRD COMPLETE after {i} iterations!"
            break

        of rsOk:
            state.consecErrors = 0

        of rsError:
            state.consecErrors.inc
            if state.consecErrors >= config.maxConsecErrors:
                echo &"\n  🛑 {config.maxConsecErrors} consecutive errors. Aborting."
                break
            elif escalate:
                echo &"  ⬆️  Next iteration will use escalation model: {config.escalationModel}"

        of rsGutter:
            echo &"\n  🕳️  Gutter detected — same failure repeating. Adding guardrail and continuing."
            state.consecErrors.inc

        of rsAbort:
            echo &"\n  💀 Abort signal received."
            break

        of rsRotate:
            discard  # In ralph, we ALWAYS rotate — fresh context is the default

    # ── Summary ──
    let totalElapsed = now() - state.startedAt
    echo &"\n{'═'.repeat(60)}"
    echo &"  🏁 RALPH LOOP COMPLETE"
    echo &"  📊 Iterations:  {state.iterations.len}"
    echo &"  ✅ Successful:  {state.iterations.filterIt(it.signal == rsOk).len}"
    echo &"  ❌ Errors:      {state.iterations.filterIt(it.signal == rsError).len}"
    echo &"  🪙 Total tokens: {state.totalTokens}"
    echo &"  ⏱️  Total time:  {totalElapsed}"
    echo &"  🎯 Complete:    {state.complete}"
    echo &"{'═'.repeat(60)}"

    return state


# =============================================================================
# Convenience: ralph-once (human-in-the-loop, run one iteration)
# =============================================================================

proc ralphOnceHITL*(
    workDir      : string,
    client       : OpenAIClient,
    model        : string = "gpt-4o-mini",
    testCommand  : string = "",
    extraTools   : seq[Tool] = @[]
): Future[RalphIteration] {.async.} =
    ## Run a single ralph iteration. Equivalent to ralph-once.sh.
    ## Good for building intuition before going AFK.
    var config = defaultRalphConfig(workDir)
    config.model = model
    config.testCommand = testCommand
    config.extraTools = extraTools
    config.ensureDirs()
    gitInit(workDir)

    return await ralphOnce(config, client, iteration = 1)


# =============================================================================
# Convenience: ralph-afk (autonomous loop)
# =============================================================================

proc ralphAfk*(
    workDir       : string,
    client        : OpenAIClient,
    maxIterations : int = 20,
    model         : string = "gpt-4o-mini",
    testCommand   : string = "",
    extraTools    : seq[Tool] = @[]
): Future[RalphState] {.async.} =
    ## Run ralph autonomously for up to maxIterations.
    ## Go make coffee. Come back to commits.
    var config = defaultRalphConfig(workDir)
    config.model = model
    config.maxIterations = maxIterations
    config.testCommand = testCommand
    config.extraTools = extraTools
    config.pauseEachLoop = false
    config.autoCommit = true

    return await ralphLoop(config, client)


# =============================================================================
# Main — Example usage
# =============================================================================

when isMainModule:
    discard """
    nim r -d:ssl -d:ic ralph.nim [workdir]

    Before running:
      1. Create a project directory with your code
      2. Create PRD.md with a task checklist
      3. Create progress.txt (can be empty)
      4. Run this
    """

    proc main() {.async.} =
        let
            client = OpenAIClient(apiKey: keys.open_ai_api_key)
            workDir = if paramCount() > 0: paramStr(1)
                      else: getCurrentDir() / "ralph_workspace"

        # Ensure workspace exists with a sample PRD if none
        discard dirExistsOrMk workDir
        if not fileExists(workDir / "PRD.md"):
            writeFile(workDir / "PRD.md", """# PRD: Sample Project

## Goal
Build a simple Nim CLI tool that converts temperatures between Celsius and Fahrenheit.

## Success Criteria
- [ ] Create a `temp_converter.nim` file
- [ ] Implement `celsiusToFahrenheit(c: float): float` proc
- [ ] Implement `fahrenheitToCelsius(f: float): float` proc
- [ ] Add a `when isMainModule` block that parses CLI args
- [ ] Handle invalid input gracefully with error messages
- [ ] Add a `--help` flag that prints usage
- [ ] All procs should have doc comments
""")
            writeFile(workDir / "progress.txt", "# Progress\n\n")
            echo &"📝 Created sample PRD at {workDir}/PRD.md"
            echo "  Edit it with your actual tasks, then run again.\n"

        # ── Choose mode ──
        echo "Ralph Loop — choose mode:"
        echo "  1. Human-in-the-loop (one iteration, you watch)"
        echo "  2. AFK loop (autonomous, max 20 iterations)"
        echo "  3. AFK loop with pause (press Enter between iterations)"
        stdout.write "Choice [1/2/3]: "
        stdout.flushFile()
        let choice = stdin.readLine().strip()

        case choice
        of "1":
            let result = await ralphOnceHITL(workDir, client)
            echo &"\nResult: signal={result.signal}, tokens={result.tokensUsed}"

        of "2":
            let state = await ralphAfk(workDir, client)
            if state.complete:
                echo "\n✅ All done! Check your git log."
            else:
                echo "\n⚠️  Loop ended before completion. Check .ralph/errors.log"

        of "3":
            var config = defaultRalphConfig(workDir)
            config.pauseEachLoop = true
            config.autoCommit = true
            let state = await ralphLoop(config, client)
            if state.complete:
                echo "\n✅ All done!"

        else:
            echo "Invalid choice."

    waitFor main()