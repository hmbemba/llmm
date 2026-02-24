## Jina AI Tools Demo
## Get your Jina AI API key for free: https://jina.ai/?sui=apikey
## Set JINA_API_KEY environment variable before running (required for most tools)
##
## Note: jina_basic_reader works WITHOUT an API key for basic usage!
##
## Usage:
##   nim c -d:ssl -r ./examples/agents/jina_tools_demo.nim

import std/[os, strformat]
import ../../src/llmm
import ../../src/llmm/tools
import ../../src/llmm/providers/oai/oai_client
import mynimlib/keys

# Create workspace
let workspaceDir = getCurrentDir() / "workspace" / "jina_demo"

# Create OpenAI client directly
var openaiClient = OpenAIClient(apiKey: keys.open_ai_api_key)

# Create agent with Jina AI tools
var agent = new Agent(
    provider: newOpenAIResponsesProvider(openaiClient),
    cfg: AgentConfig(
        id: "jina-demo-001",
        name: "jina_assistant",
        model: "gpt-4o-mini",
        workspaceDir: workspaceDir,
        systemPrompt: """You are a helpful assistant with access to Jina AI Search Foundation APIs.
Use these tools to search the web, extract content from URLs, generate embeddings, and more.
Remember to set the JINA_API_KEY environment variable.
""",
        policy: AgentPolicy(maxToolCalls: 100)
    )
)

# Add Jina AI tools
agent.addTools JinaFullToolkit()

# Start interactive chat
echo "🚀 Jina AI Tools Demo - Type 'quit' to exit"
echo "==========================================="
echo ""
echo "Available tools:"
echo "  - jina_basic_reader: Extract content from URLs (FREE - no API key!)"
echo "  - jina_search: Search the web"
echo "  - jina_reader: Advanced URL extraction with options"
echo "  - jina_embeddings: Generate text/image embeddings"
echo "  - jina_rerank: Rerank documents by relevance"
echo "  - jina_vlm_chat: Vision-language model chat"
echo "  - jina_deepsearch: Comprehensive web research"
echo "  - jina_segment: Tokenize and chunk text"
echo "  - jina_classify: Zero-shot classification"
echo ""
echo "Try asking:"
echo """  "Read https://jina.ai" (works without API key!)"""
echo """  "Search for the latest news about AI" """
echo """  "Generate embeddings for: ['hello world', 'goodbye world']" """
echo ""

agent.chatRepl()
