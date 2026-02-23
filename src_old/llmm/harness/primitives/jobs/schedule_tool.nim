## jobs/schedule_tool.nim — LLM-facing scheduling tool
##
## Allows the agent to schedule jobs via tool calls during conversation.
## The LLM can say "I'll set up a recurring check for you" and call this tool.
##
## Commands:
##   - schedule: Create a new scheduled job from natural language
##   - list: List all jobs for this agent
##   - cancel: Cancel a job by ID
##   - pause: Pause a job by ID
##   - resume: Resume a paused job by ID

import std/[
    json
    ,asyncdispatch
    ,strutils
    ,strformat
    ,options
]

import ic
import ../../../harness/tools/base
import ./types
import ./scheduler

proc ScheduleTool*(sched: AgentScheduler, client: auto): Tool =
    ## Factory proc — captures the scheduler and client in the closure.
    let s = sched
    let c = client

    icb "ScheduleTool factory initialized"

    Tool(
        name        : "schedule"
        ,description: """Schedule agent tasks using natural language. Jobs persist across restarts.

Commands:
- schedule: Create a new job (e.g., "every morning do research on AI trends")
- list: List all scheduled jobs
- cancel: Cancel a job by its ID
- pause: Pause a recurring job
- resume: Resume a paused job"""

        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "command": {
                    "type"       : "string"
                    ,"enum"      : ["schedule", "list", "cancel", "pause", "resume"]
                    ,"description": "The scheduling operation to perform"
                }
                ,"instruction": {
                    "type"       : "string"
                    ,"description": "Natural language scheduling instruction. Required for 'schedule'. Examples: 'every morning do X', 'in 30 minutes do Y', 'every friday at 5pm do Z'"
                }
                ,"job_id": {
                    "type"       : "string"
                    ,"description": "Job ID. Required for 'cancel', 'pause', 'resume'."
                }
            }
            ,"required": ["command"]
        }

        ,handler: proc(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
            icb "schedule tool handler invoked", $args

            var parsedArgs = args
            if args.kind == JString:
                try:
                    parsedArgs = parseJson(args.getStr())
                except:
                    return toolError("Invalid JSON arguments: " & $args)

            if parsedArgs.kind != JObject:
                return toolError("Expected JSON object for arguments")

            let command = parsedArgs["command"].getStr()
            icb "schedule command", command

            case command

            # ---------------------------------------------------------
            # SCHEDULE
            # ---------------------------------------------------------
            of "schedule":
                let instruction = parsedArgs.getOrDefault("instruction").getStr("")
                if instruction.len == 0:
                    return toolError("'instruction' is required for schedule command")

                try:
                    let job = await s.scheduleJob(c, instruction)
                    return toolSuccess(%*{
                        "job_id"     : job.uid
                        ,"status"    : "scheduled"
                        ,"task"      : job.spec.taskPrompt
                        ,"kind"      : job.spec.kind.toDbString
                        ,"recurring" : job.spec.recurring
                        ,"cron_expr" : job.spec.cronExpr
                    }, message = &"Job scheduled: {job.spec.taskPrompt}")
                except CatchableError as ex:
                    return toolError("Failed to schedule: " & ex.msg)

            # ---------------------------------------------------------
            # LIST
            # ---------------------------------------------------------
            of "list":
                let jobs = s.listJobs()
                var arr = newJArray()
                for j in jobs:
                    arr.add(%*{
                        "job_id"    : j.uid
                        ,"status"   : j.status.toDbString
                        ,"task"     : j.spec.taskPrompt
                        ,"kind"     : j.spec.kind.toDbString
                        ,"recurring": j.spec.recurring
                        ,"runCount" : j.runCount
                    })
                return toolSuccess(%*{
                    "jobs"  : arr
                    ,"count": jobs.len
                })

            # ---------------------------------------------------------
            # CANCEL
            # ---------------------------------------------------------
            of "cancel":
                let jobId = parsedArgs.getOrDefault("job_id").getStr("")
                if jobId.len == 0:
                    return toolError("'job_id' is required for cancel command")
                let opt = s.getJob(jobId)
                if opt.isNone:
                    return toolError("Job not found: " & jobId)
                s.cancel(opt.get)
                return toolSuccess(message = "Job cancelled: " & jobId)

            # ---------------------------------------------------------
            # PAUSE
            # ---------------------------------------------------------
            of "pause":
                let jobId = parsedArgs.getOrDefault("job_id").getStr("")
                if jobId.len == 0:
                    return toolError("'job_id' is required for pause command")
                let opt = s.getJob(jobId)
                if opt.isNone:
                    return toolError("Job not found: " & jobId)
                s.pause(opt.get)
                return toolSuccess(message = "Job paused: " & jobId)

            # ---------------------------------------------------------
            # RESUME
            # ---------------------------------------------------------
            of "resume":
                let jobId = parsedArgs.getOrDefault("job_id").getStr("")
                if jobId.len == 0:
                    return toolError("'job_id' is required for resume command")
                let opt = s.getJob(jobId)
                if opt.isNone:
                    return toolError("Job not found: " & jobId)
                s.resume(opt.get)
                return toolSuccess(message = "Job resumed: " & jobId)

            else:
                return toolError("Unknown command: " & command & ". Use: schedule, list, cancel, pause, resume")
    )