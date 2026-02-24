## jobs/types.nim — Core types for the agent scheduling system
##
## Jobs allow agents to be triggered on natural-language schedules
## ("every morning", "in 3 minutes", "every other tuesday").
## 
## A lightweight LLM call (gpt-4o-mini) parses the natural language
## into a ScheduleSpec, which is then executed via taskman.
##
## Jobs persist across restarts via the agent's SQLite store.

import std/[
    json
    ,times
    ,options
    ,oids
    ,tables
]

type
    JobStatus * = enum
        jsScheduled   ## Parsed and waiting for first run
        jsRunning     ## Agent is currently executing
        jsPaused      ## User paused
        jsCompleted   ## One-shot finished successfully
        jsFailed      ## Last run failed
        jsCancelled   ## User cancelled

    ScheduleKind * = enum
        skDelay       ## "in 3 minutes", "wait 3 hours" — one-shot after delay
        skCron        ## "every morning", "every other tuesday" — recurring cron
        skOnce        ## "at 3pm tomorrow" — one-shot at specific time

    ScheduleSpec * = object
        kind          * : ScheduleKind
        cronExpr      * : string        ## Cron expression string (for skCron)
        delaySeconds  * : int64         ## Delay in seconds (for skDelay)
        recurring     * : bool
        taskPrompt    * : string        ## Extracted task: "do research on latest ai models"
        rawInput      * : string        ## Original user input

    JobEventKind * = enum
        jekScheduled      ## Job registered and persisted
        jekStarting       ## About to run the agent
        jekCompleted      ## Agent finished successfully
        jekFailed         ## Agent run errored
        jekCancelled      ## User cancelled
        jekPaused         ## User paused
        jekResumed        ## User resumed

    JobEvent * = object
        timestamp * : DateTime
        jobId     * : string
        case kind * : JobEventKind
        of jekScheduled:
            scheduleDesc * : string
        of jekStarting:
            runNumber * : int
        of jekCompleted:
            resultText    * : string
            elapsedMs     * : int64
            tokensUsed    * : int
            cachedTokens  * : int
        of jekFailed:
            errorMessage * : string
        of jekCancelled, jekPaused, jekResumed:
            discard

    JobEventHandler * = proc(e: JobEvent) {.gcsafe.}

    JobEventDispatcher * = object
        handlers       : Table[JobEventKind, seq[JobEventHandler]]
        globalHandlers : seq[JobEventHandler]

    JobRow * = ref object
        ## SQLite-persisted job record
        id            * : int           ## debby auto-increment PK
        uid           * : string        ## OID-based identifier
        agentId       * : string        ## Which agent owns this job
        status        * : string        ## JobStatus as string
        scheduleKind  * : string        ## ScheduleKind as string
        cronExpr      * : string        ## Cron expression (if cron-based)
        delaySeconds  * : int64         ## Delay seconds (if delay-based)
        recurring     * : int           ## 1 = recurring, 0 = one-shot (SQLite bool)
        taskPrompt    * : string        ## What to run
        rawInput      * : string        ## Original natural language input
        createdAt     * : string        ## ISO datetime
        lastRunAt     * : string        ## ISO datetime of last execution
        nextRunAt     * : string        ## ISO datetime of next scheduled run
        runCount      * : int           ## Total times executed
        lastError     * : string        ## Last error message if any

# ============================================================================
# JobStatus helpers
# ============================================================================

proc toJobStatus*(s: string): JobStatus =
    case s
    of "scheduled"  : jsScheduled
    of "running"    : jsRunning
    of "paused"     : jsPaused
    of "completed"  : jsCompleted
    of "failed"     : jsFailed
    of "cancelled"  : jsCancelled
    else            : jsScheduled

proc toDbString*(s: JobStatus): string =
    case s
    of jsScheduled  : "scheduled"
    of jsRunning    : "running"
    of jsPaused     : "paused"
    of jsCompleted  : "completed"
    of jsFailed     : "failed"
    of jsCancelled  : "cancelled"

proc toScheduleKind*(s: string): ScheduleKind =
    case s
    of "delay" : skDelay
    of "cron"  : skCron
    of "once"  : skOnce
    else       : skDelay

proc toDbString*(s: ScheduleKind): string =
    case s
    of skDelay : "delay"
    of skCron  : "cron"
    of skOnce  : "once"

# ============================================================================
# JobEvent helpers
# ============================================================================

proc on*(d: var JobEventDispatcher, kind: JobEventKind, handler: JobEventHandler) =
    if not d.handlers.hasKey(kind):
        d.handlers[kind] = @[]
    d.handlers[kind].add(handler)

proc onAny*(d: var JobEventDispatcher, handler: JobEventHandler) =
    d.globalHandlers.add(handler)

proc emit*(d: JobEventDispatcher, event: JobEvent) =
    if d.handlers.hasKey(event.kind):
        for h in d.handlers[event.kind]:
            h(event)
    for h in d.globalHandlers:
        h(event)

proc clear*(d: var JobEventDispatcher) =
    d.handlers.clear()
    d.globalHandlers.setLen(0)

# ============================================================================
# JSON serialization
# ============================================================================

proc `%`*(spec: ScheduleSpec): JsonNode =
    %*{
        "kind"         : spec.kind.toDbString
        ,"cronExpr"    : spec.cronExpr
        ,"delaySeconds": spec.delaySeconds
        ,"recurring"   : spec.recurring
        ,"taskPrompt"  : spec.taskPrompt
        ,"rawInput"    : spec.rawInput
    }

proc `%`*(row: JobRow): JsonNode =
    %*{
        "uid"          : row.uid
        ,"agentId"     : row.agentId
        ,"status"      : row.status
        ,"scheduleKind": row.scheduleKind
        ,"cronExpr"    : row.cronExpr
        ,"delaySeconds": row.delaySeconds
        ,"recurring"   : row.recurring == 1
        ,"taskPrompt"  : row.taskPrompt
        ,"rawInput"    : row.rawInput
        ,"createdAt"   : row.createdAt
        ,"lastRunAt"   : row.lastRunAt
        ,"nextRunAt"   : row.nextRunAt
        ,"runCount"    : row.runCount
        ,"lastError"   : row.lastError
    }

proc `%`*(e: JobEvent): JsonNode =
    result = %*{
        "timestamp" : $e.timestamp
        ,"jobId"    : e.jobId
        ,"kind"     : $e.kind
    }
    case e.kind
    of jekScheduled:
        result["scheduleDesc"] = %e.scheduleDesc
    of jekStarting:
        result["runNumber"] = %e.runNumber
    of jekCompleted:
        result["resultText"] = %e.resultText
        result["elapsedMs"]  = %e.elapsedMs
        result["tokensUsed"] = %e.tokensUsed
        result["cachedTokens"] = %e.cachedTokens
    of jekFailed:
        result["errorMessage"] = %e.errorMessage
    else: discard