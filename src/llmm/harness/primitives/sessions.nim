## OAI Chat Session Types
##
## Defines the core types for managing chat sessions with the OpenAI API.
## Sessions maintain message history, system prompts, and model configuration.
##
## Example:
##   var session = newChatSession("gpt-4o", instructions = "You are a helpful assistant.")
##   let response = await client.chat(session, "Hello!")
##   echo response.text  # assistant reply
##   echo session.len     # 2 (user + assistant)

import std/[
options
,json
,tables
,times
]

type
    # https://platform.openai.com/docs/guides/conversation-state
    ChatSession         * = ref object
        #id              * : string                 ## Session identifier (user-defined or auto-generated)
        metadata        * : Table[string, string]  ## Arbitrary metadata
        createdAt       * : DateTime               ## When session was created
        
        messages        * : seq[JsonNode]       
        # To manually share context across generated responses, include the model's previous response output as input, 
        # and append that input to your next request.
        # {"role": "user", "content": "knock knock."},
        # {"role": "assistant", "content": "Who's there?"},
        # {"role": "user", "content": "Orange."},
        

        
        conversationId  * : Option[string]         
        # OpenAI conversation ID (if using Conversations API)
        # In a multi-turn interaction, you can pass the conversation into subsequent responses to persist state 
        # and share context across subsequent responses, rather than having to chain multiple response items together.
        # ex-
        #     response = openai.responses.create(
        #         model="gpt-4.1",
        #         input=[{"role": "user", "content": "What are the 5 Ds of dodgeball?"}],
        #         conversation="conv_689667905b048191b4740501625afd940c7533ace33a2dab"
        #     )

        lastResponseId  * : Option[string]         
        # Another way to manage conversation state is to share context across generated responses with 
        # the previous_response_id parameter. This parameter lets you chain responses and create a threaded conversation.
        # response = client.responses.create(
        #     model="gpt-4o-mini",
        #     input="tell me a joke",
        # )
        # print(response.output_text)
        # second_response = client.responses.create(
        #     model="gpt-4o-mini",
        #     previous_response_id=response.id,
        #     input=[{"role": "user", "content": "explain why this is funny."}],
        # )


