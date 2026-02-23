discard """
Time and date tools for temporal operations.

Tools:
    - CurrentTimeTool: Get current time in various formats/timezones
    - TimestampTool: Convert between timestamps and human-readable dates
    - DateParseTool: Parse human-readable date strings
    - DateDiffTool: Calculate difference between two dates
    - DateAddTool: Add/subtract time from a date
    - DateFormatTool: Format a date/timestamp in various formats
    - TimezoneTool: Convert between timezones
    - DurationParseTool: Parse duration strings (e.g., "2h30m", "1d")
    - SleepTool: Pause execution for a duration
    - CronParseTool: Parse and explain cron expressions

Toolkits:
    - TimeBasicToolkit: Current time, timestamp, date diff
    - TimeFullToolkit: All time operations

Example:
    import oai/tools/timetools

    var reg = newToolRegistry()
    reg.addTools TimeFullToolkit()
"""

import
    std/asyncdispatch
    ,std/json
    ,std/times
    ,std/strformat
    ,std/strutils
    ,std/os
    ,std/parseutils
    ,sequtils

import
    base


# -----------------------------------------------------------------------------
# Time Format Constants
# -----------------------------------------------------------------------------

const
    ISO8601_FORMAT = "yyyy-MM-dd'T'HH:mm:sszzz"
    ISO8601_FORMAT_UTC = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    DATE_FORMAT = "yyyy-MM-dd"
    TIME_FORMAT = "HH:mm:ss"
    DATETIME_FORMAT = "yyyy-MM-dd HH:mm:ss"
    FRIENDLY_FORMAT = "MMMM d, yyyy 'at' h:mm tt"
    RFC2822_FORMAT = "ddd, dd MMM yyyy HH:mm:ss zzz"


# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

proc parseFlexibleDate(s: string): DateTime =
    ## Try multiple formats to parse a date string.
    let formats = @[
        ISO8601_FORMAT,
        ISO8601_FORMAT_UTC,
        DATETIME_FORMAT,
        DATE_FORMAT,
        "MM/dd/yyyy",
        "dd/MM/yyyy",
        "yyyy/MM/dd",
        "MM-dd-yyyy",
        "dd-MM-yyyy",
        "MMMM d, yyyy",
        "MMM d, yyyy",
        "d MMMM yyyy",
        "d MMM yyyy"
    ]
    
    for fmt in formats:
        try:
            return parse(s, fmt)
        except:
            discard
    
    # Try Unix timestamp
    try:
        let ts = parseInt(s)
        return fromUnix(ts).utc
    except:
        discard
    
    raise newException(ValueError, &"Could not parse date: {s}")


proc parseDuration(s: string): Duration =
    ## Parse duration strings like "2h30m", "1d", "90s", "1w2d3h".
    var total = initDuration()
    var i = 0
    var numStr = ""
    
    let input = s.strip.toLower
    
    while i < input.len:
        let c = input[i]
        if c in {'0'..'9', '.'}:
            numStr.add(c)
        elif c in {'w', 'd', 'h', 'm', 's'}:
            if numStr.len > 0:
                let num = parseFloat(numStr)
                numStr = ""
                case c
                of 'w': total += initDuration(weeks = num.int)
                of 'd': total += initDuration(days = num.int)
                of 'h': total += initDuration(hours = num.int)
                of 'm': total += initDuration(minutes = num.int)
                of 's': total += initDuration(seconds = num.int)
                else: discard
        elif c == ' ':
            discard  # Skip spaces
        else:
            raise newException(ValueError, &"Invalid duration character: {c}")
        inc i
    
    # Handle trailing number (assume seconds)
    if numStr.len > 0:
        total += initDuration(seconds = parseFloat(numStr).int)
    
    return total


proc formatDuration(d: Duration): string =
    ## Format a duration as human-readable string.
    let totalSecs = d.inSeconds
    let days = totalSecs div 86400
    let hours = (totalSecs mod 86400) div 3600
    let mins = (totalSecs mod 3600) div 60
    let secs = totalSecs mod 60
    
    var parts: seq[string] = @[]
    if days > 0: parts.add(&"{days}d")
    if hours > 0: parts.add(&"{hours}h")
    if mins > 0: parts.add(&"{mins}m")
    if secs > 0 or parts.len == 0: parts.add(&"{secs}s")
    
    return parts.join(" ")


proc getCronFieldDescription(field: string, fieldType: string): string =
    ## Describe a single cron field.
    if field == "*":
        return &"every {fieldType}"
    elif field.contains("/"):
        let parts = field.split("/")
        return &"every {parts[1]} {fieldType}s"
    elif field.contains("-"):
        let parts = field.split("-")
        return &"{fieldType}s {parts[0]} through {parts[1]}"
    elif field.contains(","):
        return &"{fieldType}s {field.replace(\",\", \", \")}"
    else:
        return &"{fieldType} {field}"


# -----------------------------------------------------------------------------
# Time Tools
# -----------------------------------------------------------------------------

proc CurrentTimeTool*(): Tool =
    ## Get the current time in various formats.
    Tool(
        name        : "current_time"
        ,description: "Get the current date and time. Supports presets (iso8601, unix, us, eu, friendly, all) or custom format strings using: yyyy=year, MM=month, dd=day, HH=24hr, hh=12hr, mm=min, ss=sec, tt=AM/PM. Example: 'MM/dd/yyyy hh:mm tt' gives '02/03/2026 04:30 PM'."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "format": {
                    "type": "string"
                    ,"description": "Preset (iso8601, unix, date, time, datetime, us, eu, friendly, rfc2822, all) OR custom format string like 'MM/dd/yyyy hh:mm tt'"
                }
            }
            ,"additionalProperties": false
        }
        ,strict     : false
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let 
                nowLocal = now()
                nowUtc = nowLocal.utc
                format = if args.hasKey("format") and args["format"].getStr.len > 0: 
                    args["format"].getStr 
                else: 
                    "all"
            
            # Preset formats
            case format
            of "iso8601":
                return toolSuccess(%*{"time": nowUtc.format(ISO8601_FORMAT_UTC)})
            of "unix":
                return toolSuccess(%*{"timestamp": nowUtc.toTime.toUnix})
            of "date":
                return toolSuccess(%*{"date": nowLocal.format(DATE_FORMAT)})
            of "time":
                return toolSuccess(%*{"time": nowLocal.format(TIME_FORMAT)})
            of "datetime":
                return toolSuccess(%*{"datetime": nowLocal.format(DATETIME_FORMAT)})
            of "friendly":
                return toolSuccess(%*{"time": nowLocal.format(FRIENDLY_FORMAT)})
            of "rfc2822":
                return toolSuccess(%*{"time": nowLocal.format(RFC2822_FORMAT)})
            of "us":
                # US format: MM/dd/yyyy hh:mm:ss tt
                return toolSuccess(%*{"time": nowLocal.format("MM/dd/yyyy hh:mm:ss tt")})
            of "eu":
                # EU format: dd/MM/yyyy HH:mm:ss
                return toolSuccess(%*{"time": nowLocal.format("dd/MM/yyyy HH:mm:ss")})
            of "all":
                return toolSuccess(%*{
                    "iso8601": nowUtc.format(ISO8601_FORMAT_UTC)
                    ,"unix_timestamp": nowUtc.toTime.toUnix
                    ,"date": nowLocal.format(DATE_FORMAT)
                    ,"time_24h": nowLocal.format(TIME_FORMAT)
                    ,"time_12h": nowLocal.format("hh:mm:ss tt")
                    ,"datetime": nowLocal.format(DATETIME_FORMAT)
                    ,"us_format": nowLocal.format("MM/dd/yyyy hh:mm:ss tt")
                    ,"eu_format": nowLocal.format("dd/MM/yyyy HH:mm:ss")
                    ,"friendly": nowLocal.format(FRIENDLY_FORMAT)
                    ,"timezone": $nowLocal.timezone
                    ,"utc_offset_hours": nowLocal.utcOffset div 3600
                })
            else:
                # Treat as custom format string
                try:
                    return toolSuccess(%*{
                        "time": nowLocal.format(format)
                        ,"format_used": format
                    })
                except:
                    return toolError(&"Invalid format string: {format}. Use patterns like: yyyy, MM, dd, HH (24h), hh (12h), mm, ss, tt (AM/PM)")
    )


proc TimestampTool*(): Tool =
    ## Convert between Unix timestamps and human-readable dates.
    Tool(
        name        : "timestamp_convert"
        ,description: "Convert a Unix timestamp to human-readable date, or a date string to Unix timestamp."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "value": {
                    "type": "string"
                    ,"description": "Unix timestamp (number) or date string to convert"
                }
                ,"direction": {
                    "type": "string"
                    ,"enum": ["to_date", "to_timestamp", "auto"]
                    ,"description": "Conversion direction (default: auto-detect)"
                }
            }
            ,"required": ["value"]
            ,"additionalProperties": false
        }
        ,strict     : false
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let 
                value = args["value"].getStr
                direction = if args.hasKey("direction"): args["direction"].getStr else: "auto"
            
            var isTimestamp = false
            var timestamp: int64
            
            # Auto-detect or follow direction
            if direction == "auto":
                try:
                    timestamp = parseBiggestInt(value)
                    isTimestamp = true
                except:
                    isTimestamp = false
            else:
                isTimestamp = (direction == "to_date")
                if isTimestamp:
                    try:
                        timestamp = parseBiggestInt(value)
                    except:
                        return toolError("Invalid timestamp format")
            
            if isTimestamp:
                # Convert timestamp to date
                try:
                    let dt = fromUnix(timestamp).utc
                    return toolSuccess(%*{
                        "timestamp": timestamp
                        ,"iso8601": dt.format(ISO8601_FORMAT_UTC)
                        ,"datetime": dt.format(DATETIME_FORMAT)
                        ,"friendly": dt.format(FRIENDLY_FORMAT)
                    })
                except:
                    return toolError(&"Invalid timestamp: {value}")
            else:
                # Convert date to timestamp
                try:
                    let dt = parseFlexibleDate(value)
                    return toolSuccess(%*{
                        "input": value
                        ,"timestamp": dt.toTime.toUnix
                        ,"iso8601": dt.format(ISO8601_FORMAT_UTC)
                    })
                except ValueError as e:
                    return toolError(e.msg)
    )


proc DateParseTool*(): Tool =
    ## Parse a date string and return structured components.
    Tool(
        name        : "date_parse"
        ,description: "Parse a date string and return its components (year, month, day, etc.)."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "date_string": {
                    "type": "string"
                    ,"description": "Date string to parse (supports many formats)"
                }
            }
            ,"required": ["date_string"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let dateStr = args["date_string"].getStr
            
            try:
                let dt = parseFlexibleDate(dateStr)
                return toolSuccess(%*{
                    "input": dateStr
                    ,"year": dt.year
                    ,"month": dt.month.ord
                    ,"month_name": $dt.month
                    ,"day": dt.monthday
                    ,"weekday": $dt.weekday
                    ,"weekday_number": dt.weekday.ord
                    ,"hour": dt.hour
                    ,"minute": dt.minute
                    ,"second": dt.second
                    ,"day_of_year": dt.yearday
                    ,"iso8601": dt.format(ISO8601_FORMAT_UTC)
                    ,"timestamp": dt.toTime.toUnix
                })
            except ValueError as e:
                return toolError(e.msg)
    )


proc DateDiffTool*(): Tool =
    ## Calculate the difference between two dates.
    Tool(
        name        : "date_diff"
        ,description: "Calculate the difference between two dates/times."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "start": {
                    "type": "string"
                    ,"description": "Start date/time"
                }
                ,"end": {
                    "type": "string"
                    ,"description": "End date/time (default: now)"
                }
            }
            ,"required": ["start"]
            ,"additionalProperties": false
        }
        ,strict     : false
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            try:
                let startDt = parseFlexibleDate(args["start"].getStr)
                let endDt = if args.hasKey("end") and args["end"].getStr.len > 0:
                    parseFlexibleDate(args["end"].getStr)
                else:
                    now().utc
                
                let diff = endDt.toTime - startDt.toTime
                let totalSecs = diff.inSeconds
                let absSecs = abs(totalSecs)
                
                let days = absSecs div 86400
                let hours = (absSecs mod 86400) div 3600
                let mins = (absSecs mod 3600) div 60
                let secs = absSecs mod 60
                
                let direction = if totalSecs < 0: "before" else: "after"
                
                return toolSuccess(%*{
                    "start": startDt.format(DATETIME_FORMAT)
                    ,"end": endDt.format(DATETIME_FORMAT)
                    ,"total_seconds": totalSecs
                    ,"total_minutes": totalSecs div 60
                    ,"total_hours": totalSecs div 3600
                    ,"total_days": totalSecs div 86400
                    ,"breakdown": {
                        "days": days
                        ,"hours": hours
                        ,"minutes": mins
                        ,"seconds": secs
                    }
                    ,"human_readable": formatDuration(diff)
                    ,"direction": direction
                })
            except ValueError as e:
                return toolError(e.msg)
    )


proc DateAddTool*(): Tool =
    ## Add or subtract time from a date.
    Tool(
        name        : "date_add"
        ,description: "Add or subtract time from a date. Use negative numbers to subtract."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "date": {
                    "type": "string"
                    ,"description": "Starting date/time (default: now)"
                }
                ,"years": {
                    "type": "integer"
                    ,"description": "Years to add (negative to subtract)"
                }
                ,"months": {
                    "type": "integer"
                    ,"description": "Months to add (negative to subtract)"
                }
                ,"days": {
                    "type": "integer"
                    ,"description": "Days to add (negative to subtract)"
                }
                ,"hours": {
                    "type": "integer"
                    ,"description": "Hours to add (negative to subtract)"
                }
                ,"minutes": {
                    "type": "integer"
                    ,"description": "Minutes to add (negative to subtract)"
                }
                ,"seconds": {
                    "type": "integer"
                    ,"description": "Seconds to add (negative to subtract)"
                }
            }
            ,"additionalProperties": false
        }
        ,strict     : false
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            try:
                var dt = if args.hasKey("date") and args["date"].getStr.len > 0:
                    parseFlexibleDate(args["date"].getStr)
                else:
                    now().utc
                
                let originalDt = dt
                
                # Add years and months (handled by DateTime operations)
                if args.hasKey("years"):
                    let y = args["years"].getInt
                    dt = dateTime(dt.year + y, dt.month, dt.monthday, dt.hour, dt.minute, dt.second, dt.nanosecond, dt.timezone)
                
                if args.hasKey("months"):
                    let m = args["months"].getInt
                    var newMonth = dt.month.ord + m
                    var yearAdj = 0
                    while newMonth > 12:
                        newMonth -= 12
                        yearAdj += 1
                    while newMonth < 1:
                        newMonth += 12
                        yearAdj -= 1
                    dt = dateTime(dt.year + yearAdj, Month(newMonth), dt.monthday, dt.hour, dt.minute, dt.second, dt.nanosecond, dt.timezone)
                
                # Add duration components
                var dur = initDuration()
                if args.hasKey("days"):
                    dur += initDuration(days = args["days"].getInt)
                if args.hasKey("hours"):
                    dur += initDuration(hours = args["hours"].getInt)
                if args.hasKey("minutes"):
                    dur += initDuration(minutes = args["minutes"].getInt)
                if args.hasKey("seconds"):
                    dur += initDuration(seconds = args["seconds"].getInt)
                
                let resultDt = dt + dur
                
                return toolSuccess(%*{
                    "original": originalDt.format(DATETIME_FORMAT)
                    ,"result": resultDt.format(DATETIME_FORMAT)
                    ,"iso8601": resultDt.format(ISO8601_FORMAT_UTC)
                    ,"timestamp": resultDt.toTime.toUnix
                })
            except ValueError as e:
                return toolError(e.msg)
    )


proc DateFormatTool*(): Tool =
    ## Format a date in various styles.
    Tool(
        name        : "date_format"
        ,description: "Format a date/timestamp in a specific format."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "date": {
                    "type": "string"
                    ,"description": "Date string or Unix timestamp to format"
                }
                ,"format": {
                    "type": "string"
                    ,"description": "Format string (e.g., 'yyyy-MM-dd', 'MMMM d, yyyy') or preset: iso8601, rfc2822, date, time, datetime, friendly"
                }
            }
            ,"required": ["date", "format"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let 
                dateStr = args["date"].getStr
                formatStr = args["format"].getStr
            
            try:
                let dt = parseFlexibleDate(dateStr)
                
                let actualFormat = case formatStr
                    of "iso8601": ISO8601_FORMAT_UTC
                    of "rfc2822": RFC2822_FORMAT
                    of "date": DATE_FORMAT
                    of "time": TIME_FORMAT
                    of "datetime": DATETIME_FORMAT
                    of "friendly": FRIENDLY_FORMAT
                    else: formatStr
                
                return toolSuccess(%*{
                    "input": dateStr
                    ,"format": actualFormat
                    ,"result": dt.format(actualFormat)
                })
            except ValueError as e:
                return toolError(e.msg)
            except:
                return toolError(&"Invalid format string: {formatStr}")
    )


proc DurationParseTool*(): Tool =
    ## Parse duration strings.
    Tool(
        name        : "duration_parse"
        ,description: "Parse a duration string (e.g., '2h30m', '1d12h', '90s') and return components."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "duration": {
                    "type": "string"
                    ,"description": "Duration string (e.g., '2h30m', '1d', '1w2d3h4m5s')"
                }
            }
            ,"required": ["duration"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let durStr = args["duration"].getStr
            
            try:
                let dur = parseDuration(durStr)
                let totalSecs = dur.inSeconds
                
                let days = totalSecs div 86400
                let hours = (totalSecs mod 86400) div 3600
                let mins = (totalSecs mod 3600) div 60
                let secs = totalSecs mod 60
                
                return toolSuccess(%*{
                    "input": durStr
                    ,"total_seconds": totalSecs
                    ,"total_minutes": totalSecs div 60
                    ,"total_hours": totalSecs div 3600
                    ,"total_days": totalSecs div 86400
                    ,"breakdown": {
                        "days": days
                        ,"hours": hours
                        ,"minutes": mins
                        ,"seconds": secs
                    }
                    ,"human_readable": formatDuration(dur)
                })
            except ValueError as e:
                return toolError(e.msg)
    )


proc SleepTool*(): Tool =
    ## Pause execution for a specified duration.
    ## Note: This is async-friendly.
    Tool(
        name        : "sleep"
        ,description: "Pause execution for a specified duration. Useful for rate limiting or delays."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "duration": {
                    "type": "string"
                    ,"description": "Duration to sleep (e.g., '5s', '100ms', '1m30s') - max 60 seconds"
                }
            }
            ,"required": ["duration"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let durStr = args["duration"].getStr
            
            try:
                var dur = parseDuration(durStr)
                let maxDur = initDuration(seconds = 60)
                
                if dur > maxDur:
                    dur = maxDur
                    echo "  ⚠ Duration capped at 60 seconds"
                
                let ms = dur.inMilliseconds
                echo &"  → Sleeping for {formatDuration(dur)}..."
                
                await sleepAsync(ms.int)
                
                echo "  ✓ Awake!"
                return toolSuccess(%*{
                    "requested": durStr
                    ,"slept_ms": ms
                    ,"slept_human": formatDuration(dur)
                })
            except ValueError as e:
                return toolError(e.msg)
    )


proc CronParseTool*(): Tool =
    ## Parse and explain cron expressions.
    Tool(
        name        : "cron_parse"
        ,description: "Parse a cron expression and explain what it means."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "expression": {
                    "type": "string"
                    ,"description": "Cron expression (5 fields: minute hour day month weekday)"
                }
            }
            ,"required": ["expression"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let expr = args["expression"].getStr
            let parts = expr.strip.split(' ').filterIt(it.len > 0)
            
            if parts.len < 5:
                return toolError(&"Invalid cron expression. Expected 5 fields, got {parts.len}")
            
            let 
                minute = parts[0]
                hour = parts[1]
                dayOfMonth = parts[2]
                month = parts[3]
                dayOfWeek = parts[4]
            
            var description = "Runs at "
            
            # Build human-readable description
            if minute == "*" and hour == "*":
                description = "Runs every minute"
            elif minute == "0" and hour == "*":
                description = "Runs at the start of every hour"
            elif minute != "*" and hour == "*":
                description = &"Runs at minute {minute} of every hour"
            elif minute == "*" and hour != "*":
                description = &"Runs every minute during hour {hour}"
            else:
                description = &"Runs at {hour}:{minute}"
            
            if dayOfMonth != "*":
                description &= &" on day {dayOfMonth} of the month"
            
            if month != "*":
                description &= &" in month {month}"
            
            if dayOfWeek != "*":
                let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
                try:
                    let idx = parseInt(dayOfWeek)
                    if idx >= 0 and idx < weekdays.len:
                        description &= &" on {weekdays[idx]}"
                    else:
                        description &= &" on weekday {dayOfWeek}"
                except:
                    description &= &" on weekday {dayOfWeek}"
            
            return toolSuccess(%*{
                "expression": expr
                ,"fields": {
                    "minute": minute
                    ,"hour": hour
                    ,"day_of_month": dayOfMonth
                    ,"month": month
                    ,"day_of_week": dayOfWeek
                }
                ,"field_descriptions": {
                    "minute": getCronFieldDescription(minute, "minute")
                    ,"hour": getCronFieldDescription(hour, "hour")
                    ,"day_of_month": getCronFieldDescription(dayOfMonth, "day")
                    ,"month": getCronFieldDescription(month, "month")
                    ,"day_of_week": getCronFieldDescription(dayOfWeek, "weekday")
                }
                ,"description": description
            })
    )


proc TimerTool*(): Tool =
    ## Create a simple countdown or measure elapsed time.
    Tool(
        name        : "timer"
        ,description: "Start a timer and return when it completes, or calculate time until a target."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "action": {
                    "type": "string"
                    ,"enum": ["countdown", "until"]
                    ,"description": "'countdown' for duration, 'until' for target datetime"
                }
                ,"value": {
                    "type": "string"
                    ,"description": "Duration (e.g., '30s') for countdown, or datetime for until"
                }
            }
            ,"required": ["action", "value"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let 
                action = args["action"].getStr
                value = args["value"].getStr
            
            case action
            of "countdown":
                try:
                    var dur = parseDuration(value)
                    let maxDur = initDuration(seconds = 60)
                    if dur > maxDur:
                        dur = maxDur
                    
                    let startTime = now()
                    let ms = dur.inMilliseconds
                    
                    echo &"  → Timer started for {formatDuration(dur)}..."
                    await sleepAsync(ms.int)
                    
                    let endTime = now()
                    echo "  ✓ Timer complete!"
                    
                    return toolSuccess(%*{
                        "started_at": startTime.format(DATETIME_FORMAT)
                        ,"ended_at": endTime.format(DATETIME_FORMAT)
                        ,"duration": formatDuration(dur)
                    })
                except ValueError as e:
                    return toolError(e.msg)
            
            of "until":
                try:
                    let targetDt = parseFlexibleDate(value)
                    let nowDt = now().utc
                    let diff = targetDt.toTime - nowDt.toTime
                    
                    return toolSuccess(%*{
                        "now": nowDt.format(DATETIME_FORMAT)
                        ,"target": targetDt.format(DATETIME_FORMAT)
                        ,"time_until": formatDuration(diff)
                        ,"seconds_until": diff.inSeconds
                        ,"is_past": diff.inSeconds < 0
                    })
                except ValueError as e:
                    return toolError(e.msg)
            
            else:
                return toolError(&"Unknown action: {action}")
    )


# -----------------------------------------------------------------------------
# Toolkits
# -----------------------------------------------------------------------------

proc TimeBasicToolkit*(): Toolkit =
    ## Basic time operations: current time, timestamp conversion, date diff.
    result = newToolkit("time_basic", "Basic time and date operations")
    result.add CurrentTimeTool()
    result.add TimestampTool()
    result.add DateDiffTool()
    result.add DateParseTool()


proc TimeFullToolkit*(): Toolkit =
    ## All time operations.
    result = newToolkit("time_full", "Complete time and date toolkit")
    result.add CurrentTimeTool()
    result.add TimestampTool()
    result.add DateParseTool()
    result.add DateDiffTool()
    result.add DateAddTool()
    result.add DateFormatTool()
    result.add DurationParseTool()
    result.add SleepTool()
    result.add CronParseTool()
    result.add TimerTool()