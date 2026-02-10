import std/[json, options, tables,sequtils, strutils, os,times]

import std/private/ospaths2

export ospaths2.`/`
export ospaths2.`/../`


proc now_unix*: int64 = now().toTime.toUnix

proc this_minute_unix*: int64 =
    let t = now_unix(); return t - (t mod 60)
    
proc only_alphanumeric*(s: string, extras: seq[char] = @[]): string = 
    s.filterIt(it.toLowerAscii in 'a'..'z' or it == ' ' or it in extras or it in ['0','1','2','3','4','5','6','7','8','9']).join()


proc to_slug*(s:string) : string = s.strip.only_alphanumeric.replace(" ", "-").toLowerAscii()


proc dirExistsOrMk*(path: string): string = path.createDir() ; return path

proc toOptJson*[T: object](obj: T): JsonNode =
    result = newJObject()

    for name, field in obj.fieldPairs:

        when field is Option:
            if field.isSome:
                let v = field.get

                when v is JsonNode:
                    result[name] = v
                elif v is Table or v is OrderedTable:
                    result[name] = %v
                elif v is object:
                    result[name] = toOptJson(v)
                else:
                    result[name] = %v

        elif field is JsonNode:
            result[name] = field

        elif field is Table or field is OrderedTable:
            # IMPORTANT: serialize as JSON object, not as seq[KeyValuePair]
            result[name] = %field

        elif field is object:
            result[name] = toOptJson(field)

        else:
            result[name] = %field
