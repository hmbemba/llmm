## CodeAct Example - Demonstrates using the CodeAct tool
## 
## This example shows how to enable CodeAct for an agent, allowing the LLM
## to write Python code that can call other tools in a persistent interpreter.

import std/[asyncdispatch, json, os]
import llmm/harness/primitives/agent
import llmm/harness/tools/[base, filesystem]
import llmm/harness/providers/openai_responses
import llmm/providers/oai/oai_client

proc main() {.async.} =
  # Create an OpenAI client
  let client = newOpenAIClient()
  
  # Create provider
  let provider = newOpenAIResponsesProvider(client)
  
  # Create agent with some tools
  var myAgent = new Agent(
    provider: provider,
    cfg: AgentConfig(
      id: "codeact-demo-001",
      name: "CodeAct Demo",
      role: "demo",
      model: "gpt-4o",
      systemPrompt: "You are a helpful assistant with access to tools.",
      instructions: "Use tools when needed. You can also use codeact_tool to write Python code.",
      workspaceDir: getCurrentDir() / "workspace",
      tools: initOrderedTable[string, Tool](),
      policy: AgentPolicy(
        maxToolCalls: 50,
        allowedTools: @[]  # Will be populated dynamically
      )
    ),
    state: AgentState()
  )
  
  # Add some regular tools
  myAgent.addTools FileReadTool()
  myAgent.addTools FileWriteTool()
  myAgent.addTools DirListTool()
  
  # Enable CodeAct - this adds the codeact_tool and creates a per-agent Python process
  myAgent.enableCodeAct("python3")  # or just "python" on Windows
  
  echo "Agent created with CodeAct enabled!"
  echo "Available tools:"
  for toolName in myAgent.cfg.tools.keys:
    echo "  - ", toolName
  
  # Now the agent can use codeact_tool to execute Python code
  # The Python code can call other tools using tools("tool_name", **kwargs)
  #
  # Example of what the LLM might write:
  #
  # result = tools("file_read", filename="data.txt")
  # content = result.get("content", "")
  # words = content.split()
  # print(f"Word count: {len(words)}")
  # tools("file_write", filename="stats.txt", content=f"Words: {len(words)}")

when isMainModule:
  waitFor main()
