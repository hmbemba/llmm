## Content builders for Moonshot (Kimi) Chat API
##
## Kimi's chat endpoint is OpenAI-compatible and expects messages like:
##   {"role": "user", "content": "hello"}

import std/json

proc systemMessage*(content: string): JsonNode =
    %*{
        "role": "system",
        "content": content
    }

proc userMessage*(content: string): JsonNode =
    %*{
        "role": "user",
        "content": content
    }

proc assistantMessage*(content: string): JsonNode =
    %*{
        "role": "assistant",
        "content": content
    }

proc toolMessage*(
    tool_call_id: string,
    content: string,
    name: string = ""
): JsonNode =
    ## Tool response message (OpenAI-compatible).
    ## Moonshot's docs show a `name` field alongside `tool_call_id`.
    result = %*{
        "role": "tool",
        "tool_call_id": tool_call_id,
        "content": content
    }
    if name.len > 0:
      result["name"] = %name
