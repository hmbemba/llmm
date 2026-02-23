## jobs/integration.nim — Agent integration for the scheduling system
##
## This module provides the high-level API that makes scheduling
## feel native to the agent framework:
##
##   let job = await agent.schedule("every morning do research on the latest ai models")
##
##   job.onCompleted:
##     echo "Done: ", e.resultText
##
## It wires together: Agent ↔ AgentScheduler ↔ JobStore ↔ taskman
##
## Setup:
##   # During agent initialization (in agent.new or after):
##   agent.initScheduler()
##
##   # Start the scheduler loop (non-blocking):
##   asyncCheck agent.startScheduler()
##
##   # Schedule jobs:
##   let job = await agent.schedule("in 5 minutes summarize the news")

import std/[
    asyncdispatch
    ,options
    ,json
    ,times
    ,tables
    ,strutils
]

import ic

import ./types      
import ./store      
import ./scheduler  

# We assume the consumer imports both this module and the agent module.
# To avoid circular imports, we use a duck-typed approach via generics.
# The Agent type just needs: .client, .cfg.id, .cfg.name, .state.agentStore.db,
# and a chatTurn/ask proc.

type
    ## Mixin object that gets attached to AgentState
    SchedulerState * = object
        scheduler * : AgentScheduler
        jobStore  * : JobStore

# ============================================================================
# Initialization
# ============================================================================

proc initScheduler*[A](agent: A): AgentScheduler =
    ## Initialize the scheduling subsystem for an agent.
    ## Creates the JobStore (uses agent's shared SQLite db) and AgentScheduler.
    ## 
    ## Call this during or after agent.new().
    let agentId = if agent.cfg.id.len == 0: "default" else: agent.cfg.id

    icb "Initializing scheduler for agent", agent.cfg.name, agentId

    # Create the job store using the agent's shared db
    let jobStore = newJobStore(agent.state.agentStore.db)

    # Create the scheduler
    let sched = newAgentScheduler(jobStore, agentId)

    # Wire up the execution callback — this is what runs the agent when a job fires.
    # We need {.gcsafe.} because taskman runs handlers in an async context.
    # The cast is safe here because the agent ref is long-lived and pinned.
    let a = agent
    sched.executeAgent = cast[typeof(sched.executeAgent)](
        proc(prompt: string): Future[tuple[text: string, tokensUsed: int, elapsedMs: int64, error: string]] {.async.} =
            icb "Job executing agent.ask", prompt
            try:
                let startTime = now()
                let response = await a.ask(prompt)
                let elapsed = (now() - startTime).inMilliseconds
                
                # Check for error prefix (ask() returns "Error: ..." on failure)
                if response.startsWith("Error: "):
                    return (text: "", tokensUsed: 0, elapsedMs: elapsed, error: response)
                
                return (
                    text       : response
                    ,tokensUsed: a.state.totalTokensUsed.combined
                    ,elapsedMs : elapsed
                    ,error     : ""
                )
            except CatchableError as ex:
                icr "Job agent execution failed", ex.msg
                return (text: "", tokensUsed: 0, elapsedMs: 0'i64, error: ex.msg)
    )

    # Rehydrate persisted jobs
    sched.rehydrate()

    ic "Scheduler initialized", sched.jobs.len, "jobs rehydrated"
    return sched

# ============================================================================
# High-level API
# ============================================================================

proc schedule*[A](agent: A, sched: AgentScheduler, instruction: string): Future[Job] {.async.} =
    ## Parse a natural language scheduling instruction and register the job.
    ##
    ## Example:
    ##   let job = await agent.schedule(scheduler, "every morning do research on AI")
    icb "agent.schedule()", instruction
    return await sched.scheduleJob(agent.client, instruction)

proc startScheduler*(sched: AgentScheduler, periodicCheckMs: int = 500): Future[void] {.async.} =
    ## Start the scheduler event loop. Use with asyncCheck for non-blocking:
    ##   asyncCheck scheduler.startScheduler()
    await sched.start(periodicCheckMs)

# ============================================================================
# Convenience: list/get/cancel via agent
# ============================================================================

proc listJobs*(sched: AgentScheduler): seq[Job] =
    sched.listJobs()

proc getJob*(sched: AgentScheduler, uid: string): Option[Job] =
    if sched.jobs.hasKey(uid): some(sched.jobs[uid]) else: none(Job)

proc cancelJob*(sched: AgentScheduler, uid: string) =
    let opt = sched.getJob(uid)
    if opt.isSome:
        sched.cancel(opt.get)

proc pauseJob*(sched: AgentScheduler, uid: string) =
    let opt = sched.getJob(uid)
    if opt.isSome:
        sched.pause(opt.get)

proc resumeJob*(sched: AgentScheduler, uid: string) =
    let opt = sched.getJob(uid)
    if opt.isSome:
        sched.resume(opt.get)