## jobs/parse.nim — LLM-powered natural language schedule parser
##
## Calls gpt-4o-mini to translate human-readable scheduling instructions
## into structured ScheduleSpec objects. This is the "proxy layer" that
## makes the magic happen.
##
## Examples:
##   "in 3 minutes do research on the latest ai models"
##   "every morning do research on the latest ai models"
##   "every other tuesday do research on the latest ai models"
##   "wait 3 hours then do research on the latest ai models"

import std/[
    json
    ,strutils
    ,asyncdispatch
    ,options
]

import ic
import ./types
import ../../../providers/oai/oai
#import ../../providers/oai/responses/types
#import ../../providers/oai/responses/api

const ScheduleParserModel * = "gpt-4o-mini"

const ScheduleParserSystemPrompt = """You are a scheduling parser. You convert natural language scheduling instructions into structured JSON.

You MUST respond with ONLY valid JSON, no markdown, no backticks, no explanation.

Output format:
{
  "kind": "delay" | "cron" | "once",
  "cron_expr": "<standard 5-field cron expression, empty string if not cron-based>",
  "delay_seconds": <integer seconds to wait, 0 if cron-based>,
  "recurring": true | false,
  "task": "<the task/action to perform, extracted from the input>"
}

Rules:
- "in X minutes/hours/days" → kind="delay", compute delay_seconds, recurring=false
- "wait X then..." → kind="delay", compute delay_seconds, recurring=false
- "every morning" → kind="cron", cron_expr="0 9 * * *", recurring=true
- "every evening" → kind="cron", cron_expr="0 18 * * *", recurring=true
- "every hour" → kind="cron", cron_expr="0 * * * *", recurring=true
- "every X minutes" → kind="cron", cron_expr="*/X * * * *", recurring=true
- "every day at Xpm" → kind="cron", cron_expr="0 X * * *" (24hr), recurring=true
- "every monday" → kind="cron", cron_expr="0 9 * * 1", recurring=true
- "every other tuesday" → kind="cron", cron_expr="0 9 * * 2", recurring=true (note: cron can't do "every other", set recurring=true and add "skip_interval": 2)
- "at 3pm tomorrow" → kind="once", delay_seconds=<computed>, recurring=false
- "daily" → kind="cron", cron_expr="0 9 * * *", recurring=true
- "weekly" → kind="cron", cron_expr="0 9 * * 1", recurring=true

For "every other X" patterns, use the base cron for that day/time and set recurring=true.
The system will handle the skip logic separately.

Time conversions:
- 1 minute = 60 seconds
- 1 hour = 3600 seconds
- 1 day = 86400 seconds
- 1 week = 604800 seconds

Extract the TASK portion by removing the scheduling prefix. 
"in 3 minutes do research on AI" → task = "do research on AI"
"every morning check the weather" → task = "check the weather"
"wait 2 hours then summarize news" → task = "summarize news"

Examples:
Input: "in 3 minutes do research on the latest ai models"
Output: {"kind":"delay","cron_expr":"","delay_seconds":180,"recurring":false,"task":"do research on the latest ai models"}

Input: "every morning do research on the latest ai models"
Output: {"kind":"cron","cron_expr":"0 9 * * *","delay_seconds":0,"recurring":true,"task":"do research on the latest ai models"}

Input: "every other tuesday do research on the latest ai models"
Output: {"kind":"cron","cron_expr":"0 9 * * 2","delay_seconds":0,"recurring":true,"task":"do research on the latest ai models"}

Input: "wait 3 hours then do research on the latest ai models"
Output: {"kind":"delay","cron_expr":"","delay_seconds":10800,"recurring":false,"task":"do research on the latest ai models"}

Input: "every 30 minutes check server health"
Output: {"kind":"cron","cron_expr":"*/30 * * * *","delay_seconds":0,"recurring":true,"task":"check server health"}

Input: "daily at 6am summarize the news"
Output: {"kind":"cron","cron_expr":"0 6 * * *","delay_seconds":0,"recurring":true,"task":"summarize the news"}
"""

proc parseSchedule*(client: OpenAIClient, input: string): Future[ScheduleSpec] {.async.} =
    ## Calls gpt-4o-mini to parse natural language scheduling into a ScheduleSpec.
    icb "parseSchedule()", input

    let opts = CreateResponseOptions(
        model : ScheduleParserModel
        ,input : some %*[
            {"role": "system", "content": ScheduleParserSystemPrompt}
            ,{"role": "user", "content": input}
        ]
    )

    let resp = await client.createResponse(opts)

    if not resp.ok:
        icr "Schedule parse API error", resp.err
        raise newException(ValueError, "Failed to parse schedule: " & resp.err)

    let text = resp.val.extractText().strip()
    ic "Raw LLM response", text

    # Strip markdown code fences if present
    var jsonText = text
    if jsonText.startsWith("```"):
        let lines = jsonText.splitLines()
        var cleaned: seq[string]
        for line in lines:
            if line.startsWith("```"): continue
            cleaned.add(line)
        jsonText = cleaned.join("\n")

    var parsed: JsonNode
    try:
        parsed = parseJson(jsonText)
    except JsonParsingError as ex:
        icr "Failed to parse LLM JSON response", jsonText, ex.msg
        raise newException(ValueError, "LLM returned invalid JSON for schedule parsing: " & ex.msg)

    let kindStr = parsed.getOrDefault("kind").getStr("delay")
    
    result = ScheduleSpec(
        kind         : kindStr.toScheduleKind
        ,cronExpr    : parsed.getOrDefault("cron_expr").getStr("")
        ,delaySeconds: parsed.getOrDefault("delay_seconds").getInt(0).int64
        ,recurring   : parsed.getOrDefault("recurring").getBool(false)
        ,taskPrompt  : parsed.getOrDefault("task").getStr("")
        ,rawInput    : input
    )

    ic "Parsed schedule", result.kind, result.cronExpr, result.delaySeconds, result.recurring, result.taskPrompt

    # Validation
    if result.taskPrompt.len == 0:
        raise newException(ValueError, "Could not extract task from scheduling instruction: " & input)

    if result.kind == skCron and result.cronExpr.len == 0:
        raise newException(ValueError, "Cron schedule parsed but no cron expression generated for: " & input)

    if result.kind == skDelay and result.delaySeconds <= 0:
        raise newException(ValueError, "Delay schedule parsed but no delay computed for: " & input)