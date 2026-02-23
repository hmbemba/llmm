import json

# -----------------------------------------------------------------------------
# Text Extraction
# -----------------------------------------------------------------------------

proc extractText*(response: JsonNode): string =
    ## Extract the text content from a raw JSON response.
    result = ""
    if response.hasKey("output"):
        for item in response["output"]:
            if item.hasKey("content"):
                for content in item["content"]:
                    if content.hasKey("type") and content["type"].getStr == "output_text":
                        if content.hasKey("text"):
                            if result.len > 0:
                                result &= "\n"
                            result &= content["text"].getStr