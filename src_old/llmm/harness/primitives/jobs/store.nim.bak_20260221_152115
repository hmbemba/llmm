## jobs/store.nim — SQLite persistence for scheduled jobs
##
## Jobs are stored in the agent's unified SQLite database so they
## survive process restarts. On startup, the scheduler rehydrates
## active jobs from the database.

import std/[
    json
    ,times
    ,strutils
    ,oids
    ,options
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

    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_job_row_uid
        ON job_row (uid);
    """
    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_job_row_agent_id
        ON job_row (agent_id);
    """
    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_job_row_status
        ON job_row (status);
    """

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
    let nowStr = $now().utc
    var row = JobRow(
        uid           : $genOid()
        ,agentId      : agentId
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
    ## Get all jobs that should be rehydrated on startup
    s.db.query(JobRow,
        "SELECT * FROM job_row WHERE agent_id = ? AND status IN ('scheduled', 'paused', 'running', 'failed') ORDER BY id ASC",
        agentId)

proc getAllJobs*(s: JobStore, agentId: string, limit: int = 50): seq[JobRow] =
    s.db.query(JobRow,
        "SELECT * FROM job_row WHERE agent_id = ? ORDER BY id DESC LIMIT ?",
        agentId, limit)

proc updateStatus*(s: JobStore, uid: string, status: JobStatus) =
    let opt = s.getByUid(uid)
    if opt.isNone: return
    var row = opt.get
    row.status = status.toDbString
    s.db.update(row)
    ic "Job status updated", uid, status

proc recordRun*(s: JobStore, uid: string, success: bool, error: string = "", nextRunAt: DateTime = now()) =
    let opt = s.getByUid(uid)
    if opt.isNone: return
    var row = opt.get
    row.lastRunAt = $now().utc
    row.runCount  = row.runCount + 1
    row.nextRunAt = $nextRunAt.utc
    if success:
        row.lastError = ""
        # If non-recurring, mark completed
        if row.recurring == 0:
            row.status = jsCompleted.toDbString
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
    let rows = s.db.query(
        "SELECT count(*) as c FROM job_row WHERE agent_id = ?",
        agentId)
    if rows.len > 0: rows[0][0].parseInt else: 0