## jobs/scheduler.nim — Agent job scheduler
##
## The main orchestration layer that:
##   1. Parses natural language schedules via gpt-4o-mini
##   2. Registers them with taskman for async execution
##   3. Persists jobs to SQLite for restart recovery
##   4. Fires lifecycle events (starting, completed, failed, etc.)
##   5. Runs agent.chatTurn() when jobs trigger
##
## Usage:
##   let job = await agent.schedule("every morning do research on the latest ai models")
##   
##   job.onStarting:
##     echo "Job about to run"
##   
##   job.onCompleted:
##     echo "Done: ", e.resultText
##
##   # Control
##   job.cancel()
##   job.pause()
##   job.resume()
##
##   # Must start the scheduler (non-blocking)
##   agent.startScheduler()

import std/[
    json
    ,times
    ,options
    ,asyncdispatch
    ,strformat
    ,strutils
    ,tables
    ,oids
]

import taskman
import ic

import ./types
import ./store
import ./parse
import ./cron_parse

# Forward declaration — the actual Agent type is imported by the consumer
# We use a generic approach here to avoid circular imports.
# The consumer wires this up by importing both agent and scheduler.

type
    ## A handle to a scheduled job that the user can attach events to and control.
    Job * = ref object
        uid          * : string
        spec         * : ScheduleSpec
        row          * : JobRow
        events       * : JobEventDispatcher
        status       * : JobStatus
        taskName     * : string       ## taskman task name for del/control
        runCount     * : int

    ## The scheduler that manages all jobs for an agent.
    AgentScheduler * = ref object
        scheduler    * : AsyncScheduler
        jobStore     * : JobStore
        jobs         * : Table[string, Job]   ## uid → Job (in-memory handles)
        running      * : bool
        agentId      * : string

        ## Callback that executes the agent — set by the integration layer
        ## Signature: proc(taskPrompt: string): Future[tuple[text: string, tokensUsed: int, elapsedMs: int64, error: string]]
        executeAgent * : proc(prompt: string): Future[tuple[text: string, tokensUsed: int, elapsedMs: int64, error: string]] {.async, gcsafe.}

# ============================================================================
# Job event DSL templates
# ============================================================================

template onScheduled*(j: Job, body: untyped) =
    types.on(j.events,jekScheduled, proc(e {.inject.}: JobEvent) {.gcsafe.} = body)

template onStarting*(j: Job, body: untyped) =
    types.on(j.events,jekStarting, proc(e {.inject.}: JobEvent) {.gcsafe.} = body)

template onCompleted*(j: Job, body: untyped) =
    types.on(j.events,jekCompleted, proc(e {.inject.}: JobEvent) {.gcsafe.} = body)

template onFailed*(j: Job, body: untyped) =
    types.on(j.events,jekFailed, proc(e {.inject.}: JobEvent) {.gcsafe.} = body)

template onCancelled*(j: Job, body: untyped) =
    types.on(j.events,jekCancelled, proc(e {.inject.}: JobEvent) {.gcsafe.} = body)

template onPaused*(j: Job, body: untyped) =
    types.on(j.events,jekPaused, proc(e {.inject.}: JobEvent) {.gcsafe.} = body)

template onResumed*(j: Job, body: untyped) =
    types.on(j.events,jekResumed, proc(e {.inject.}: JobEvent) {.gcsafe.} = body)

# ============================================================================
# Scheduler construction
# ============================================================================

proc newAgentScheduler*(jobStore: JobStore, agentId: string): AgentScheduler =
    icb "=== Initializing AgentScheduler ==="
    result = AgentScheduler(
        scheduler : newAsyncScheduler()
        ,jobStore : jobStore
        ,jobs     : initTable[string, Job]()
        ,running  : false
        ,agentId  : agentId
    )

# ============================================================================
# Internal: execute a job
# ============================================================================

proc executeJob(sched: AgentScheduler, job: Job) {.async.} =
    ## Run the agent for this job and handle lifecycle events.
    if job.status == jsPaused:
        ic "Job is paused, skipping", job.uid
        return

    if job.status == jsCancelled:
        ic "Job is cancelled, skipping", job.uid
        return

    if sched.executeAgent.isNil:
        icr "No executeAgent callback set on scheduler"
        return

    job.status = jsRunning
    job.runCount.inc
    sched.jobStore.updateStatus(job.uid, jsRunning)

    # Emit starting event
    let startEvent = JobEvent(
        timestamp : now()
        ,jobId    : job.uid
        ,kind     : jekStarting
        ,runNumber: job.runCount
    )
    job.events.emit(startEvent)

    icb "Executing job", job.uid, job.spec.taskPrompt, "run #", job.runCount

    let startTime = now()

    try:
        let result = await sched.executeAgent(job.spec.taskPrompt)

        if result.error.len > 0:
            # Agent returned an error
            icr "Job execution error", job.uid, result.error
            job.status = jsFailed

            let failEvent = JobEvent(
                timestamp    : now()
                ,jobId       : job.uid
                ,kind        : jekFailed
                ,errorMessage: result.error
            )
            job.events.emit(failEvent)

            sched.jobStore.recordRun(job.uid, success = false, error = result.error)
        else:
            # Success
            ic "Job completed", job.uid, result.text.len, "chars"
            job.status = if job.spec.recurring: jsScheduled else: jsCompleted

            let elapsed = (now() - startTime).inMilliseconds

            let completeEvent = JobEvent(
                timestamp  : now()
                ,jobId     : job.uid
                ,kind      : jekCompleted
                ,resultText: result.text
                ,elapsedMs : elapsed
                ,tokensUsed: result.tokensUsed
            )
            job.events.emit(completeEvent)

            sched.jobStore.recordRun(job.uid, success = true)

    except CatchableError as ex:
        icr "Job execution exception", job.uid, ex.msg
        job.status = jsFailed

        let failEvent = JobEvent(
            timestamp    : now()
            ,jobId       : job.uid
            ,kind        : jekFailed
            ,errorMessage: ex.msg
        )
        job.events.emit(failEvent)

        sched.jobStore.recordRun(job.uid, success = false, error = ex.msg)

# ============================================================================
# Register a job with taskman
# ============================================================================

proc registerWithTaskman(sched: AgentScheduler, job: Job) =
    ## Add the job to the taskman async scheduler.
    let
        s = sched
        j = job

    case job.spec.kind

    of skDelay:
        # One-shot after delay
        let interval = job.spec.delaySeconds.int.seconds
        ic "Registering delay job", job.uid, job.spec.delaySeconds, "seconds"

        s.scheduler.wait(interval, name = job.taskName) do () {.async.}:
            await s.executeJob(j)

    of skCron:
        # Recurring cron schedule
        ic "Registering cron job", job.uid, job.spec.cronExpr

        let cronSpec = parseCronString(job.spec.cronExpr)

        s.scheduler.every(cronSpec, name = job.taskName) do () {.async.}:
            await s.executeJob(j)

    of skOnce:
        # One-shot at computed delay (treated same as skDelay)
        let interval = max(job.spec.delaySeconds, 1).int.seconds
        ic "Registering one-shot job", job.uid, job.spec.delaySeconds, "seconds"

        s.scheduler.wait(interval, name = job.taskName) do () {.async.}:
            await s.executeJob(j)

# ============================================================================
# Public API: schedule a new job
# ============================================================================

proc scheduleJob*(sched: AgentScheduler, client: auto, instruction: string): Future[Job] {.async.} =
    ## Parse natural language instruction and schedule the job.
    ## `client` should be an OpenAIClient for calling gpt-4o-mini.
    icb "scheduleJob()", instruction

    # 1. Parse via LLM
    let spec = await parseSchedule(client, instruction)
    ic "Schedule parsed", spec.kind, spec.cronExpr, spec.delaySeconds, spec.taskPrompt

    # 2. Persist to SQLite
    let nextRun = case spec.kind
        of skDelay, skOnce: now() + spec.delaySeconds.int.seconds
        of skCron: now()  # taskman will compute next cron time

    let row = sched.jobStore.insertJob(
        agentId    = sched.agentId
        ,spec      = spec
        ,nextRunAt = nextRun
    )

    # 3. Create in-memory Job handle
    let job = Job(
        uid      : row.uid
        ,spec    : spec
        ,row     : row
        ,status  : jsScheduled
        ,taskName: "job_" & row.uid
    )

    sched.jobs[job.uid] = job

    # 4. Emit scheduled event
    let schedEvent = JobEvent(
        timestamp    : now()
        ,jobId       : job.uid
        ,kind        : jekScheduled
        ,scheduleDesc: instruction
    )
    job.events.emit(schedEvent)

    # 5. Register with taskman
    sched.registerWithTaskman(job)

    ic "Job scheduled", job.uid, job.taskName
    return job

# ============================================================================
# Public API: job control
# ============================================================================

proc cancel*(sched: AgentScheduler, job: Job) =
    ## Cancel a job — removes from taskman and marks as cancelled in db.
    icb "Cancelling job", job.uid
    job.status = jsCancelled
    sched.jobStore.updateStatus(job.uid, jsCancelled)

    try:
        sched.scheduler.del job.taskName
    except:
        discard  # Task may have already been removed

    let ev = JobEvent(timestamp: now(), jobId: job.uid, kind: jekCancelled)
    job.events.emit(ev)
    ic "Job cancelled", job.uid

proc cancel*(job: Job, sched: AgentScheduler) =
    ## Convenience: job.cancel(scheduler)
    sched.cancel(job)

proc pause*(sched: AgentScheduler, job: Job) =
    ## Pause a job — it stays in taskman but executeJob skips it.
    icb "Pausing job", job.uid
    job.status = jsPaused
    sched.jobStore.updateStatus(job.uid, jsPaused)
    let ev = JobEvent(timestamp: now(), jobId: job.uid, kind: jekPaused)
    job.events.emit(ev)

proc resume*(sched: AgentScheduler, job: Job) =
    ## Resume a paused job.
    icb "Resuming job", job.uid
    job.status = jsScheduled
    sched.jobStore.updateStatus(job.uid, jsScheduled)
    let ev = JobEvent(timestamp: now(), jobId: job.uid, kind: jekResumed)
    job.events.emit(ev)

# ============================================================================
# Rehydration: restore jobs from SQLite on restart
# ============================================================================

proc rehydrate*(sched: AgentScheduler) =
    ## Reload active jobs from SQLite and re-register them with taskman.
    ## Call this on startup after creating the scheduler.
    icb "Rehydrating jobs from database"

    let activeRows = sched.jobStore.getActiveJobs(sched.agentId)
    ic "Found", activeRows.len, "active jobs to rehydrate"

    for row in activeRows:
        let spec = ScheduleSpec(
            kind         : row.scheduleKind.toScheduleKind
            ,cronExpr    : row.cronExpr
            ,delaySeconds: row.delaySeconds
            ,recurring   : row.recurring == 1
            ,taskPrompt  : row.taskPrompt
            ,rawInput    : row.rawInput
        )

        # For delay jobs that haven't run yet, compute remaining delay
        var adjustedSpec = spec
        if spec.kind in {skDelay, skOnce} and row.runCount == 0:
            try:
                let nextRun   = parse(row.nextRunAt, "yyyy-MM-dd'T'HH:mm:sszzz")
                let remaining = (nextRun.toTime - getTime()).inSeconds
                if remaining > 0:
                    adjustedSpec.delaySeconds = remaining
                else:
                    # Past due — run immediately (1 second delay)
                    adjustedSpec.delaySeconds = 1
            except:
                # If we can't parse the time, run with original delay
                discard

        elif spec.kind in {skDelay, skOnce} and row.runCount > 0:
            # Already ran, skip (one-shot)
            ic "Skipping already-completed one-shot job", row.uid
            continue

        let job = Job(
            uid      : row.uid
            ,spec    : adjustedSpec
            ,row     : row
            ,status  : row.status.toJobStatus
            ,taskName: "job_" & row.uid
            ,runCount: row.runCount
        )

        sched.jobs[job.uid] = job

        # Only register if not paused (paused jobs stay in memory but don't trigger)
        if job.status != jsPaused:
            sched.registerWithTaskman(job)

        ic "Rehydrated job", job.uid, job.spec.taskPrompt, job.status

    ic "Rehydration complete", sched.jobs.len, "jobs active"

# ============================================================================
# Start / Stop
# ============================================================================

proc start*(sched: AgentScheduler, periodicCheckMs: int = 500) {.async.} =
    ## Start the taskman scheduler loop.
    ## This should be run with asyncCheck so it doesn't block.
    icb "Starting AgentScheduler"
    sched.running = true
    await sched.scheduler.start(periodicCheckMs)
    sched.running = false
    ic "AgentScheduler stopped"

# ============================================================================
# Listing
# ============================================================================

proc listJobs*(sched: AgentScheduler): seq[Job] =
    for uid, job in sched.jobs:
        result.add(job)

proc getJob*(sched: AgentScheduler, uid: string): Option[Job] =
    if sched.jobs.hasKey(uid): some(sched.jobs[uid]) else: none(Job)