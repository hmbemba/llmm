## jobs/cron_parse.nim — Runtime cron string parser
##
## Converts standard 5-field cron expression strings into taskman Cron objects.
## taskman's `cron()` macro works at compile time; we need runtime parsing
## because the LLM generates cron strings dynamically.
##
## Supports:
##   - Exact values: "5"
##   - Wildcards: "*"
##   - Ranges: "1-5"
##   - Steps: "*/2", "1-10/3"
##   - Lists: "1,3,5"
##   - Combinations: "1-5,10,15-20/2"
##
## Format: minute hour monthday month weekday
##   minute   : 0-59
##   hour     : 0-23
##   monthday : 1-31
##   month    : 1-12
##   weekday  : 0-6 (0=Sunday) or 1-7 (1=Monday, 7=Sunday)

import std/[
    strutils
    ,sequtils
    ,times
    ,sets
]

import taskman/cron

type
    CronParseError * = object of CatchableError

# ============================================================================
# Field parsers
# ============================================================================

proc parseMinuteField(field: string): set[MinuteRange] =
    ## Parse a cron minute field (0-59)
    if field == "*":
        return everyMinute

    # Handle step on wildcard: */N
    if field.startsWith("*/"):
        let step = field[2..^1].parseInt
        return everyMinute / step

    result = {}
    for part in field.split(","):
        let trimmed = part.strip()

        if "/" in trimmed:
            # Range with step: "1-30/5" or "*/5" (already handled above for *)
            let slashParts = trimmed.split("/")
            let step = slashParts[1].parseInt
            if "-" in slashParts[0]:
                let rangeParts = slashParts[0].split("-")
                let lo = rangeParts[0].parseInt.MinuteRange
                let hi = rangeParts[1].parseInt.MinuteRange
                result = result + ({lo .. hi} / step)
            else:
                let start = slashParts[0].parseInt.MinuteRange
                result = result + ({start .. 59.MinuteRange} / step)

        elif "-" in trimmed:
            let rangeParts = trimmed.split("-")
            let lo = rangeParts[0].parseInt.MinuteRange
            let hi = rangeParts[1].parseInt.MinuteRange
            for v in lo .. hi:
                result.incl v

        else:
            result.incl trimmed.parseInt.MinuteRange


proc parseHourField(field: string): set[HourRange] =
    if field == "*":
        return everyHour

    if field.startsWith("*/"):
        let step = field[2..^1].parseInt
        return everyHour / step

    result = {}
    for part in field.split(","):
        let trimmed = part.strip()

        if "/" in trimmed:
            let slashParts = trimmed.split("/")
            let step = slashParts[1].parseInt
            if "-" in slashParts[0]:
                let rangeParts = slashParts[0].split("-")
                let lo = rangeParts[0].parseInt.HourRange
                let hi = rangeParts[1].parseInt.HourRange
                result = result + ({lo .. hi} / step)
            else:
                let start = slashParts[0].parseInt.HourRange
                result = result + ({start .. 23.HourRange} / step)

        elif "-" in trimmed:
            let rangeParts = trimmed.split("-")
            let lo = rangeParts[0].parseInt.HourRange
            let hi = rangeParts[1].parseInt.HourRange
            for v in lo .. hi:
                result.incl v

        else:
            result.incl trimmed.parseInt.HourRange


proc parseMonthDayField(field: string): set[MonthDayRange] =
    if field == "*":
        return everyMonthDay

    if field.startsWith("*/"):
        let step = field[2..^1].parseInt
        return everyMonthDay / step

    result = {}
    for part in field.split(","):
        let trimmed = part.strip()

        if "/" in trimmed:
            let slashParts = trimmed.split("/")
            let step = slashParts[1].parseInt
            if "-" in slashParts[0]:
                let rangeParts = slashParts[0].split("-")
                let lo = rangeParts[0].parseInt.MonthDayRange
                let hi = rangeParts[1].parseInt.MonthDayRange
                result = result + ({lo .. hi} / step)
            else:
                let start = slashParts[0].parseInt.MonthDayRange
                result = result + ({start .. 31.MonthDayRange} / step)

        elif "-" in trimmed:
            let rangeParts = trimmed.split("-")
            let lo = rangeParts[0].parseInt.MonthDayRange
            let hi = rangeParts[1].parseInt.MonthDayRange
            for v in lo .. hi:
                result.incl v

        else:
            result.incl trimmed.parseInt.MonthDayRange


proc parseMonthField(field: string): set[Month] =
    if field == "*":
        return everyMonth

    result = {}
    for part in field.split(","):
        let trimmed = part.strip()
        let val = trimmed.parseInt  # 1-12
        result.incl Month(val - 1)  # Month enum is 0-indexed (mJan=0)

proc cronWeekDay*(val: int): WeekDay =
    ## Convert cron weekday (0=Sun or 7=Sun) to Nim WeekDay
    case val
    of 0, 7: dSun
    of 1: dMon
    of 2: dTue
    of 3: dWed
    of 4: dThu
    of 5: dFri
    of 6: dSat
    else: dSun


proc parseWeekDayField(field: string): set[WeekDay] =
    if field == "*":
        return everyWeekDay

    result = {}
    for part in field.split(","):
        let trimmed = part.strip()

        if "/" in trimmed:
            # Step on weekdays (e.g., "2/2" = every other starting from tuesday)
            # This is unusual but we handle it simply
            let slashParts = trimmed.split("/")
            let start = slashParts[0].parseInt
            let step  = slashParts[1].parseInt
            var current = start
            while current <= 6:
                result.incl cronWeekDay(current)
                current += step
            return result

        elif "-" in trimmed:
            let rangeParts = trimmed.split("-")
            let lo = rangeParts[0].parseInt
            let hi = rangeParts[1].parseInt
            for v in lo .. hi:
                result.incl cronWeekDay(v)

        else:
            result.incl cronWeekDay(trimmed.parseInt)




# ============================================================================
# Main parser
# ============================================================================

proc parseCronString*(expr: string): Cron =
    ## Parse a standard 5-field cron expression string into a taskman Cron.
    ##
    ## Format: "minute hour monthday month weekday"
    ## Example: "0 9 * * 1-5" = 9:00 AM, Monday through Friday
    let fields = expr.strip().splitWhitespace()

    if fields.len != 5:
        raise newException(CronParseError,
            "Cron expression must have exactly 5 fields (minute hour monthday month weekday), got " &
            $fields.len & ": " & expr)

    try:
        result = initCron(
            minutes   = parseMinuteField(fields[0])
            ,hours    = parseHourField(fields[1])
            ,monthDays = parseMonthDayField(fields[2])
            ,months   = parseMonthField(fields[3])
            ,weekDays = parseWeekDayField(fields[4])
        )
    except AssertionDefect as ex:
        raise newException(CronParseError, "Invalid cron expression '" & expr & "': " & ex.msg)
    except ValueError as ex:
        raise newException(CronParseError, "Invalid cron field value in '" & expr & "': " & ex.msg)