## jobs/store.nim — SQLite persistence for scheduled jobs
##
## Jobs are stored in the agent's unified SQLite database so they
## survive process restarts. On startup, the scheduler rehydrates
## active jobs from the database.

import std/[
    times
    ,strutils
    ,oids
    ,options
    ,algorithm
]

import debby/sqlite
import ic
import ./types
import ../../../debby_utils


# ============================================================================
# JobStore
# ============================================================================

type
    JobStore * = ref object
        db * : Db   ## Shared database handle (owned by AgentStore)

# ============================================================================
# Initialization
# ============================================================================

proc newJobStore*(db: Db): JobStore =
    icb "=== Initializing JobStore (shared Db) ==="
    result = JobStore(db: db)
    result.db.initTable JobRow

    # Be tolerant of different ORM naming conventions (snake_case vs camelCase)
    # across environments / debby versions.
    try:
        discard result.db.query """
            CREATE INDEX IF NOT EXISTS idx_job_row_uid
            ON job_row (uid);
        """
    except: discard

    try:
        discard result.db.query """
            CREATE INDEX IF NOT EXISTS idx_job_row_agent_id
            ON job_row (agent_id);
        """
    except:
        try:
            discard result.db.query """
                CREATE INDEX IF NOT EXISTS idx_job_row_agent_id
                ON job_row (agentId);
            """
        except: discard

    try:
        discard result.db.query """
            CREATE INDEX IF NOT EXISTS idx_job_row_status
            ON job_row (status);
        """
    except: discard

    let count = result.db.query("SELECT count(*) as c FROM job_row")[0][0].parseInt
    ic "JobStore ready", count, "jobs"

# ============================================================================
# CRUD
# ============================================================================

proc insertJob*(s: JobStore
    ,agentId       : string
    ,spec          : ScheduleSpec
    ,nextRunAt     : DateTime = now()
): JobRow =
    icb "insertJob()", agentId, spec.taskPrompt
    let 
        effectiveAgentId = if agentId.len == 0: "default" else: agentId
        nowStr = $now().utc
    var row = JobRow(
        uid           : $genOid()
        ,agentId      : effectiveAgentId
        ,status       : jsScheduled.toDbString
        ,scheduleKind : spec.kind.toDbString
        ,cronExpr     : spec.cronExpr
        ,delaySeconds : spec.delaySeconds
        ,recurring    : (if spec.recurring: 1 else: 0)
        ,taskPrompt   : spec.taskPrompt
        ,rawInput     : spec.rawInput
        ,createdAt    : nowStr
        ,lastRunAt    : ""
        ,nextRunAt    : $nextRunAt.utc
        ,runCount     : 0
        ,lastError    : ""
    )
    s.db.insert(row)
    ic "Inserted job", row.uid, row.taskPrompt
    return row

proc getByUid*(s: JobStore, uid: string): Option[JobRow] =
    let results = s.db.filter(JobRow, it.uid == uid)
    if results.len > 0: some(results[0]) else: none(JobRow)

proc getActiveJobs*(s: JobStore, agentId: string): seq[JobRow] =
    ## Get all jobs that should be rehydrated on startup.
    ##
    ## NOTE: Prefer debby filter() instead of raw SQL so we don't depend on
    ## the DB column naming convention.
    let all = s.db.filter(JobRow, it.agentId == agentId)
    let active = @[
        jsScheduled.toDbString,
        jsPaused.toDbString,
        jsRunning.toDbString,
        jsFailed.toDbString
    ]
    for row in all:
        if row.status in active:
            result.add(row)
    result.sort(proc(a, b: JobRow): int = cmp(a.id, b.id))

proc getAllJobs*(s: JobStore, agentId: string, limit: int = 50): seq[JobRow] =
    ## Get most recent jobs for this agent (including completed).
    ##
    ## NOTE: Prefer debby filter() so /jobs works regardless of column naming.
    result = s.db.filter(JobRow, it.agentId == agentId)
    result.sort(proc(a, b: JobRow): int = cmp(b.id, a.id))
    if limit > 0 and result.len > limit:
        result.setLen(limit)

proc updateStatus*(s: JobStore, uid: string, status: JobStatus) =
    let opt = s.getByUid(uid)
    if opt.isNone: return
    var row = opt.get
    row.status = status.toDbString
    s.db.update(row)
    ic "Job status updated", uid, status

proc recordRun*(s: JobStore, uid: string, success: bool, error: string = "", nextRunAt: DateTime = DateTime()) =
    let opt = s.getByUid(uid)
    if opt.isNone: return
    var row = opt.get

    row.lastRunAt = $now().utc
    row.runCount  = row.runCount + 1

    # Only overwrite nextRunAt if the caller provided one.
    # (DateTime() has year == 0; real timestamps are year >= 1)
    if nextRunAt.year >= 1:
        row.nextRunAt = $nextRunAt.utc

    if success:
        row.lastError = ""
        if row.recurring == 0:
            row.status = jsCompleted.toDbString
            # For one-shots, there is no next run.
            row.nextRunAt = ""
        else:
            row.status = jsScheduled.toDbString
    else:
        row.lastError = error
        row.status    = jsFailed.toDbString

    s.db.update(row)
    ic "Job run recorded", uid, success, row.runCount

proc deleteJob*(s: JobStore, uid: string): bool =
    let opt = s.getByUid(uid)
    if opt.isNone: return false
    s.db.delete(opt.get)
    ic "Job deleted", uid
    return true

proc count*(s: JobStore, agentId: string): int =
    s.db.filter(JobRow, it.agentId == agentId).len
