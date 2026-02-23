## Moonshot (Kimi) API Client Library
##
## Unified entry point for the Moonshot (Kimi) API.
##
## Example:
##   import llmm/providers/kimi
##   let client = newKimiClient(apiKey = "sk-...")
##   let r = await client.createChatCompletion(initCreateChatCompletionOptions(
##       model = "moonshot-v1-8k",
##       messages = @[userMessage("Hello!")]
##   ))
##   if r.ok:
##       echo r.text

# =============================================================================
# Core Client
# =============================================================================

import kimi_client ; export kimi_client

# =============================================================================
# Common
# =============================================================================

import common/errors
export errors

# =============================================================================
# Builders
# =============================================================================

import utils/builders ; export builders

# =============================================================================
# Chat API
# =============================================================================

import chat/api   as chat_api   ; export chat_api
import chat/types as chat_types ; export chat_types
import chat/utils as chat_utils ; export chat_utils


when isMainModule:
    import mynimlib/keys
    import asyncdispatch

    let 
        client   = newKimiClient(apiKey = keys.kimi_api_key)
        r        = waitFor  client.createChatCompletion initCreateChatCompletionOptions(
            model    = "moonshot-v1-8k",
            messages = @[userMessage("Hello!")]
        )
    if r.ok:
        echo r.text
    else:
        echo "Error: ", r.err