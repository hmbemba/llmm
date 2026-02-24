## Jina Basic Reader Demo (NO API KEY REQUIRED)
## This demo shows how to use the free Jina Reader tool
## Simply prepend 'https://r.jina.ai/' to any URL to get LLM-friendly content
##
## Usage:
##   nim c -d:ssl -d:ic -r ./examples/agents/jina_basic_reader_demo.nim

import std/[os, strformat]
import ../../src/llmm
import ../../src/llmm/tools
import ../../src/llmm/providers/oai/oai_client
import mynimlib/keys

# Create workspace
let workspaceDir = getCurrentDir() / "workspace" / "jina_basic_demo"

# Create OpenAI client directly
var openaiClient = OpenAIClient(apiKey: keys.open_ai_api_key) # You can set this to an empty string or omit it since the basic reader doesn't require it

# Create agent with ONLY the free Jina Basic Reader tool
var agent = new Agent(
    provider: newOpenAIResponsesProvider(openaiClient),
    cfg: AgentConfig(
        id: "jina-basic-demo-001",
        name: "jina_basic_reader_assistant",
        model: "gpt-4o-mini",
        workspaceDir: workspaceDir,
        systemPrompt: """You are a helpful assistant that can extract and summarize content from web pages.
You have access to the Jina Basic Reader tool, which is FREE to use - no API key required!
Simply provide any URL and the tool will return clean, LLM-friendly markdown content.
""",
        policy: AgentPolicy(maxToolCalls: 100)
    )
)

# Add ONLY the free basic reader tool
agent.addTools JinaBasicFreeToolkit()

# Start interactive chat
echo "🚀 Jina Basic Reader Demo - FREE, no API key required!"
echo "======================================================="
echo ""
echo "Available tool:"
echo "  - jina_basic_reader: Extract content from any URL (FREE!)"
echo ""
echo "Try asking:"
echo """  "What does https://jina.ai say?"""
echo """  "Summarize the content from https://news.ycombinator.com"""
echo """  "Extract the article from https://example.com/some-article"""
echo ""
echo "💡 Tip: The basic reader works with any public URL!"
echo ""

agent.chatRepl()
