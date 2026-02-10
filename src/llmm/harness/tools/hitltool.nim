# In a new file or your tools module
import std/[json, asyncdispatch,options,strutils]
import base

type
    HITLHandler* = proc(question: string, context: JsonNode): string {.gcsafe.}

proc defaultCLIHandler(question: string, context: JsonNode): string =
    echo "\n🤖 Agent asks: ", question
    if context.kind != JNull: echo "   Context: ", context
    echo ">>> (Paste your text, then type END on a new line)"
    stdout.flushFile()
    
    var lines: seq[string]
    while true:
        let line = stdin.readLine()
        if line.strip() == "END": break
        lines.add(line)
    
    return lines.join("\n")

proc HITLTool*(handler: HITLHandler = defaultCLIHandler): Tool = 
    # Capture handler in closure
    let h = handler
    
    Tool(
        name         : "ask_human"
        ,description : "Ask the human user a question when you need clarification, approval, or input. Use this when you're uncertain about how to proceed or need human judgment."
        ,parameters  : %*{
            "type": "object",
            "properties": {
                "question": {
                    "type": "string",
                    "description": "The question to ask the human"
                },
                "context": {
                    "type": "object",
                    "description": "Optional context about why you're asking"
                }
            },
            "required": ["question"]
        },
        handler: proc (args: JsonNode): Future[JsonNode] {.async.} =
            let 
                question = args["question"].getStr()
                context  = if args.hasKey("context"): args["context"] else: newJNull()

            # Synchronously get input right here
            let response = h(question, context)
            return %*{"status": "success", "response": response}


    )
