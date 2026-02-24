## Prompt Caching Phase 3 Demo
## Demonstrates cache-optimized prompt structure with static content ordering

import std/[asyncdispatch, os, json]
import llmm
import llmm/harness/primitives/agent
import llmm/harness/primitives/subagents
import llmm/harness/providers/openai_responses
import llmm/providers/oai/oai_client
import llmm/harness/tools/filesystem
import llmm/harness/tools/timetools

proc main() {.async.} =
  echo "=== Prompt Caching Phase 3 Demo ==="
  echo ""
  echo "Phase 3: Prompt Reordering for Maximum Cache Efficiency"
  echo ""
  
  # Get API key
  let apiKey = getEnv("OPENAI_API_KEY")
  if apiKey.len == 0:
    echo "Error: Set OPENAI_API_KEY environment variable"
    return
  
  # Create OpenAI client
  let client = newOpenAIClient(apiKey)
  let provider = newOpenAIResponsesProvider(client, "openai")
  
  # Create a parent agent with Phase 3 optimizations
  echo "Creating parent agent with Phase 3 cache optimization..."
  var parentAgent = Agent(
    provider: provider,
    cfg: AgentConfig(
      id: "parent_demo_001",
      name: "demo_coordinator",
      role: "coordinator",
      model: "gpt-4o-mini",
      
      # Phase 3: Separated static content for optimal caching
      systemPrompt: """You are an AI coordinator that manages specialized subagents.
You have access to file system tools and time tools.
Your job is to delegate tasks to appropriate subagents and synthesize results.""",
      
      instructions: "Always verify file operations and provide clear summaries.",
      
      # Phase 3: Static persona content (cached across all turns)
      personaContent: """You are an experienced technical coordinator with expertise in:
- Project management and task delegation
- File system operations and data processing
- Time-based scheduling and coordination
- Quality assurance and result verification""",
      
      # Phase 3: Static context (cached across all turns)
      staticContext: """## Project Guidelines
- Always create backups before modifying files
- Use ISO 8601 format for all timestamps
- Verify file existence before read operations
- Report errors with specific file paths and error details""",
      
      workspaceDir: "workspace/phase3_demo",
      
      # Phase 2: Cache configuration
      promptCacheKey: "coordinator_demo_v1",
      promptCacheRetention: "24h"
    ),
    state: AgentState()
  )
  
  # Initialize the agent
  parentAgent = parentAgent.new()
  
  # Add tools
  parentAgent.addTools FileReadTool(parentAgent.cfg.workspaceDir)
  parentAgent.addTools FileWriteTool(parentAgent.cfg.workspaceDir)
  parentAgent.addTools CurrentTimeTool()
  
  echo "Parent agent created with:"
  echo "  - System prompt: ~", parentAgent.cfg.systemPrompt.len, " chars"
  echo "  - Persona content: ~", parentAgent.cfg.personaContent.len, " chars"
  echo "  - Static context: ~", parentAgent.cfg.staticContext.len, " chars"
  echo "  - Cache key: ", parentAgent.cfg.promptCacheKey
  echo "  - Cache retention: ", parentAgent.cfg.promptCacheRetention
  echo ""
  
  # Enable subagent support
  parentAgent.enableSubagents()
  
  # Create a subagent with Phase 3 optimizations
  echo "Creating research subagent with Phase 3 optimizations..."
  let researcher = await parentAgent.createSubagent(
    name = "research_specialist",
    role = "Research and analysis specialist",
    instructions = "Research the requested topic thoroughly and provide a concise summary with key findings.",
    model = "gpt-4o-mini",
    maxToolCalls = 20,
    lightweight = true,
    
    # Phase 3: Static content for this subagent role
    personaContent = """You are a meticulous research specialist with expertise in:
- Gathering and synthesizing information from multiple sources
- Analyzing data and identifying key patterns
- Providing well-structured, evidence-based summaries
- Citing sources and noting confidence levels""",
    
    staticContext = """## Research Guidelines
- Always verify information from multiple sources when possible
- Note the confidence level for each finding (High/Medium/Low)
- Format output in clear sections: Summary, Key Findings, Recommendations
- If information is incomplete, clearly state what's missing"""
  )
  
  echo "Research subagent created with:"
  echo "  - ID: ", researcher.id
  echo "  - Cache key: subagent_research_specialist_parent_dem..."
  echo ""
  
  # Run a multi-turn conversation to demonstrate caching
  echo "=== Multi-Turn Conversation (Cache Warming) ==="
  echo ""
  
  echo "Turn 1: Initial question..."
  let response1 = await parentAgent.ask("What time is it now?")
  echo "Response: ", response1
  echo ""
  
  echo "Turn 2: Follow-up question (should benefit from cache)..."
  let response2 = await parentAgent.ask("What is today's date?")
  echo "Response: ", response2
  echo ""
  
  echo "Turn 3: File operation (testing tool definitions in cache)..."
  let response3 = await parentAgent.ask("Create a file called 'test.txt' with 'Hello from Phase 3 demo!' as content.")
  echo "Response: ", response3
  echo ""
  
  # Run the subagent
  echo "=== Subagent Execution ==="
  echo ""
  echo "Running research task on subagent..."
  let researchResult = await researcher.run("Explain the concept of prompt caching in LLMs and its benefits.")
  
  echo "Research completed:"
  echo "  - Success: ", researchResult.success
  echo "  - Output length: ", researchResult.output.len, " chars"
  echo "  - Tool calls: ", researchResult.toolCalls
  echo "  - Tokens used: ", researchResult.tokensUsed
  echo ""
  
  echo "=== Summary ==="
  echo ""
  echo "Phase 3 optimizations demonstrated:"
  echo "✅ Static content separated (system, persona, context, tools)"
  echo "✅ Static content placed first for caching"
  echo "✅ Dynamic conversation history at the end"
  echo "✅ Subagents inherit Phase 3 structure"
  echo "✅ Cache key grouping for similar agents"
  echo ""
  echo "Expected cache performance:"
  echo "  - Turn 1: 0% cache hit (cold start, warming cache)"
  echo "  - Turn 2+: 60-80% cache hit on static content"
  echo "  - Subagent: Shares cache with same-role agents"
  echo ""
  echo "Demo complete!"

when isMainModule:
  waitFor main()
