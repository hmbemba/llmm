## subagent_simple.nim — Minimal Subagent Example
##
## The simplest possible example of using subagents in llmm.
##
## Usage:
##   nim c -d:ssl -d:ic -r ./examples/agents/subagent_simple.nim

import std/[asyncdispatch, os, strformat, json]
import ../../src/llmm
import ../../src/llmm/tools
import mynimlib/keys

# Create workspace
let workspaceDir = getCurrentDir() / "workspace" / "subagent_simple"

# Create coordinator agent
var coordinator = new Agent(
    provider: newKimiChatProvider(KimiClient(apiKey: keys.kimi_api_key)),
    cfg: AgentConfig(
        id: "coord-001",
        name: "coordinator",
        model: "kimi-k2.5",
        workspaceDir: workspaceDir,
        systemPrompt: "You are a task coordinator. You can create subagents to help with work.",
        policy: AgentPolicy(maxToolCalls: 100)
    )
)

# Add file tools
coordinator.addTools FileCrudToolkit(workspaceDir)

# Enable subagent support (adds create_subagent, send_to_subagent, etc.)
coordinator.enableSubagents(maxSubagents = 5)

echo "🚀 Coordinator ready with subagent support!"
echo "Starting interactive REPL...\n"
echo "Try asking:"
echo """  "Create a researcher subagent and ask it to summarize the benefits of Python" """
echo """  "Create two subagents to debate AI safety" """
echo ""

# Start REPL
coordinator.chatRepl()
