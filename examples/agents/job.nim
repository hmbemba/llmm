## example_jobs.nim — Full usage example for the agent scheduling system
##
## Shows how to:
##   1. Initialize an agent with scheduling
##   2. Schedule jobs from natural language
##   3. Attach lifecycle hooks
##   4. Control jobs (pause/resume/cancel)
##   5. Auto-rehydrate on restart

import std/[asyncdispatch, json, times, options, strformat]

import ../../src/llmm
import ../../src/llmm/tools

import mynimlib/keys

proc main() {.async.} =
    # -----------------------------------------------------------------------
    # 1. Create the agent (your existing setup)
    # -----------------------------------------------------------------------

    var agent             = new Agent(
            client        : OpenAIClient(apiKey: keys.open_ai_api_key)
            ,cfg          : AgentConfig(
                model     : "gpt-4o"
                ,name     : "cli-agent"
                ,policy   : AgentPolicy(maxToolCalls  : 150)
                ,tools    : addTools @[HITLTool(), webSearchTool()]
        ))

    # -----------------------------------------------------------------------
    # 2. Initialize the scheduler
    # -----------------------------------------------------------------------
    let sched = initScheduler(agent)

    # Optionally register the schedule tool so the LLM can self-schedule
    agent.addTools ScheduleTool(sched, agent.client)
    agent.addTools @[
        CodeExecToolkit(agent.cfg.workspaceDir)
        ,FileCrudToolkit(agent.cfg.workspaceDir)

    ]

    # -----------------------------------------------------------------------
    # 3. Start the scheduler (non-blocking)
    # -----------------------------------------------------------------------
    asyncCheck sched.startScheduler(periodicCheckMs = 500)

    # -----------------------------------------------------------------------
    # 4. Schedule jobs from natural language
    # -----------------------------------------------------------------------

    # One-shot delayed job
    # let job1 = await agent.schedule(sched, "in 20 seconds do research on the latest ai models")

    # job1.onStarting:
    #     echo &"🚀 Job {e.jobId} starting (run #{e.runNumber})"

    # job1.onCompleted:
    #     echo &"✅ Job {e.jobId} completed in {e.elapsedMs}ms"
    #     echo &"   Result: {e.resultText[0..min(200, e.resultText.len-1)]}..."

    # job1.onFailed:
    #     echo &"❌ Job {e.jobId} failed: {e.errorMessage}"


    # # Recurring job
    # let job2 = await agent.schedule(sched, "every morning do research on the latest ai models")

    # job2.onCompleted:
    #     echo &"📰 Morning research done: {e.resultText.len} chars"


    # # Another recurring job
    # let job3 = await agent.schedule(sched, "every other tuesday do research on the latest ai models")

    # job3.onCompleted:
    #     echo &"📅 Tuesday research done"


    # # Wait-style job
    # let job4 = await agent.schedule(sched, "wait 3 hours then do research on the latest ai models")

    # # -----------------------------------------------------------------------
    # # 5. Job control
    # # -----------------------------------------------------------------------

    # # Pause a recurring job
    # sched.pause(job2)
    # echo "⏸  Morning job paused"

    # # Resume it later
    # sched.resume(job2)
    # echo "▶  Morning job resumed"

    # # Cancel a job
    # sched.cancel(job4)
    # echo "🗑  Wait job cancelled"

    # # List all jobs
    # let allJobs = sched.listJobs()
    # for j in allJobs:
    #     echo &"  [{j.status}] {j.uid}: {j.spec.taskPrompt}"

    # # -----------------------------------------------------------------------
    # # 6. The agent can also schedule via conversation
    # # -----------------------------------------------------------------------

    # Because we registered ScheduleTool, the LLM can do this:
    let response = await agent.chat(
        "Please remind me to take out the trash in 1 minutes by creating windows notiffication using powershell"
    )
    echo response
    # The LLM would call the schedule tool internally

    # # -----------------------------------------------------------------------
    # # 7. Keep running (scheduler is in the background)
    # # -----------------------------------------------------------------------
    # echo "\nScheduler running. Press Ctrl+C to stop."
    # echo &"Active jobs: {sched.listJobs().len}"

    # Block forever (or until all one-shot tasks complete)
    while true:
        await sleepAsync(1000)

waitFor main()


discard """
=============================================================================
ARCHITECTURE OVERVIEW
=============================================================================

User Input (natural language)
    │
    ▼
agent.schedule("every morning do research on AI")
    │
    ▼
parseSchedule() ──► gpt-4o-mini ──► ScheduleSpec
    │                                    │
    │   { kind: "cron",                  │
    │     cronExpr: "0 9 * * *",         │
    │     taskPrompt: "do research on AI" │
    │     recurring: true }              │
    │                                    │
    ▼                                    ▼
JobStore.insertJob()              parseCronString()
    │  (SQLite persist)                  │
    │                                    ▼
    ▼                              taskman Cron object
Job handle returned                      │
    │                                    ▼
    │                        taskman.scheduler.every(cron)
    │                                    │
    ▼                                    ▼
job.onCompleted:                  [taskman fires at 9am]
  echo "done"                            │
                                         ▼
                                  executeJob(job)
                                         │
                                         ▼
                                  agent.ask(taskPrompt)
                                         │
                                         ▼
                                  [LLM runs, tools fire]
                                         │
                                         ▼
                                  JobEvent(jekCompleted)
                                         │
                                         ▼
                                  user callbacks fire

=============================================================================
RESTART RECOVERY
=============================================================================

Process starts
    │
    ▼
initScheduler(agent)
    │
    ▼
newJobStore(db) ──► reads job_row table
    │
    ▼
sched.rehydrate()
    │
    ├── For each active job in SQLite:
    │   ├── Rebuild ScheduleSpec from row
    │   ├── For delay jobs: compute remaining time
    │   ├── Create Job handle
    │   └── Register with taskman
    │
    ▼
asyncCheck sched.startScheduler()
    │
    ▼
Jobs resume running on their schedules

=============================================================================
FILE LAYOUT
=============================================================================

llmm/harness/primitives/jobs/
├── types.nim          # Core types: Job, JobRow, ScheduleSpec, events
├── store.nim          # SQLite CRUD for job persistence
├── parse.nim          # LLM proxy: natural language → ScheduleSpec
├── cron_parse.nim     # Runtime "0 9 * * *" string → taskman Cron
├── scheduler.nim      # Orchestration: taskman + execution + lifecycle
├── integration.nim    # High-level agent.schedule() API
└── schedule_tool.nim  # LLM-facing tool for self-scheduling
"""