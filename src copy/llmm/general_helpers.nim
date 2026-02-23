import std/[json, options, tables,sequtils, strutils, os,times,paths]
import harness/tools/base
import std/private/ospaths2

export ospaths2.`/`
export ospaths2.`/../`

proc fileExistsOrErr*(path: string | paths.Path): string =
    let this_path = path.string
    if not this_path.fileExists:
        raise newException(ValueError, "File : '" & this_path & "' does not exist")
    return this_path


proc max_len*(str : string, max_len:int) : string = 
    if str.len >= max_len:
        let lenn = max_len - 1
        return str[0..lenn]
    return str

proc max_len*[T](seqq: seq[T], max_len:int) : seq[T] = 
    if seqq.len >= max_len:
        let lenn = max_len - 1
        return seqq[0..lenn]
    return seqq

proc `%`*(zone: Timezone): JsonNode =
    %zone.name

proc `%`*(this_table : Table[string, int]): JsonNode =
    result = newJObject()
    for k, v in this_table:
        result[k] = %v

proc `%`*(tools : OrderedTable[string, Tool]): JsonNode =
    result = newJObject()
    for name, tool in tools:
        result[name] = %tool

proc appendToJsonFile*(filepath: string, content: JsonNode) =
    let f = open(filepath, fmAppend)
    defer: f.close()
    f.writeLine($content) # One JSON object per line



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
