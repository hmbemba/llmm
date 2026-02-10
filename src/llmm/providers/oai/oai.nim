## OpenAI API Client Library
##
## Unified entry point for the OpenAI API.
## Import this module to access all functionality.
##
## Example:
##   import llmm/providers/oai
##
##   let client = newOpenAIClient(apiKey = "sk-...")
##
##   # Create a response
##   let response = await client.createResponse(initCreateResponseOptions(
##       model = "gpt-4o",
##       input = some(%"Hello, what is 2+2?")
##   ))
##
##   if response.ok:
##       echo response.text
##       echo "Tokens used: ", response.tokens
##
##   # Create a conversation
##   let conv = await client.createConversation(initCreateConversationOptions(
##       items = @[userMessage("Hello!")]
##   ))
##
##   # Clean up
##   client.close()

# =============================================================================
# Core Client
# =============================================================================

import oai_client ; export oai_client

# =============================================================================
# Common Types
# =============================================================================

import common/types as common_types
export common_types

import common/errors
export errors

# =============================================================================
# Content Builders
# =============================================================================

import utils/builders                ; export builders
import utils/common  as common_utils ; export common_utils

# =============================================================================
# Conversations API
# =============================================================================

import conversations/api as conv_api
export conv_api

import conversations/types as conv_types
export conv_types

import conversations/utils as conv_utils
export conv_utils

# =============================================================================
# Responses API
# =============================================================================

import responses/api as resp_api
export resp_api

import responses/types as resp_types
export resp_types

import responses/utils as resp_utils
export resp_utils

# =============================================================================
# Tools
# =============================================================================

import tools/builtin as builtin_tools
export builtin_tools

import tools/schema as fn_schema
export fn_schema
