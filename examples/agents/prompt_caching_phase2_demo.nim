## prompt_caching_phase2_demo.nim - Demonstrates Phase 2 Strategic Cache Keys
##
## This example shows how to:
##   1. Configure prompt caching on a main agent
##   2. Create subagents that automatically get strategic cache keys
##   3. Monitor cache hit rates via usage statistics
##
## Usage:
##   nim c -d:ssl -d:ic -r ./examples/agents/prompt_caching_phase2_demo.nim

import std/[asyncdispatch, os, strformat, json]
import ../../src/llmm
import ../../src/llmm/tools
import mynimlib/keys

# Create workspace
let workspaceDir = getCurrentDir() / "workspace" / "caching_demo"

# =============================================================================
# Example 1: Main Agent with Cache Configuration
# =============================================================================

echo "=== Phase 2: Strategic Cache Keys Demo ===\n"

# Create OpenAI client and provider
let client = newOpenAIClient(apiKey: keys.openai_api_key)
let provider = newOpenAIResponsesProvider(client)

# Configure the provider with a cache key for this agent type
provider.setPromptCacheConfig(
  cacheKey = "coordinator_main_v1",
  retention = "24h"  # Extended retention for long-running coordinator
)

# Create coordinator agent with cache configuration
var coordinator = new Agent(
  provider: provider,
  cfg: AgentConfig(
    id: "coord-001",
    name: "coordinator",
    model: "gpt-4o",
    workspaceDir: workspaceDir,
    systemPrompt: """You are a task coordinator with access to specialized subagents.
You can create subagents for research, coding, and analysis tasks.
Your goal is to delegate work efficiently and synthesize results.""",
    policy: AgentPolicy(maxToolCalls: 100),
    # Phase 2: Cache configuration (also inherited by subagents)
    promptCacheKey: "coordinator_main_v1",
    promptCacheRetention: "24h"
  )
)

# Add file tools
coordinator.addTools FileCrudToolkit(workspaceDir)

# Enable subagent support (subagents get automatic cache keys)
coordinator.enableSubagents(maxSubagents = 5)

echo "✅ Coordinator agent created with cache key: coordinator_main_v1"
echo "   Cache retention: 24h (extended)\n"

# =============================================================================
# Example 2: Subagents with Automatic Strategic Cache Keys
# =============================================================================

echo "=== Creating Subagents (Automatic Cache Keys) ===\n"

# Import subagent tools for direct creation
import ../../src/llmm/harness/primitives/subagents

# Create researcher subagent
let researcher = waitFor createSubagent(
  parent = coordinator,
  name = "researcher",
  role = "Research Specialist",
  instructions = "Find and summarize information thoroughly. Be concise but comprehensive.",
  model = "gpt-4o-mini",  # Cheaper model for research
  maxToolCalls = 30,
  inheritTools = true,
  lightweight = true
)

echo &"✅ Created researcher subagent"
echo &"   Subagent ID: {researcher.id}"
echo &"   Cache Key: subagent_research-specialist_researcher_{coordinator.cfg.id[0..7]}"
echo "   (All researcher subagents will share this cache key)\n"

# Create coder subagent
let coder = waitFor createSubagent(
  parent = coordinator,
  name = "coder",
  role = "Code Specialist",
  instructions = "Write clean, efficient code. Follow best practices and add comments.",
  model = "gpt-4o",
  maxToolCalls = 50,
  inheritTools = true,
  lightweight = true
)

echo &"✅ Created coder subagent"
echo &"   Subagent ID: {coder.id}"
echo &"   Cache Key: subagent_code-specialist_coder_{coordinator.cfg.id[0..7]}"
echo "   (All coder subagents will share this cache key)\n"

# Create analyst subagent  
let analyst = waitFor createSubagent(
  parent = coordinator,
  name = "analyst",
  role = "Data Analyst",
  instructions = "Analyze data and provide insights. Use statistical reasoning.",
  model = "gpt-4o-mini",
  maxToolCalls = 30,
  inheritTools = true,
  lightweight = true
)

echo &"✅ Created analyst subagent"
echo &"   Subagent ID: {analyst.id}"
echo &"   Cache Key: subagent_data-analyst_analyst_{coordinator.cfg.id[0..7]}"
echo "   (All analyst subagents will share this cache key)\n"

# =============================================================================
# Example 3: Running Tasks (Cache Benefits)
# =============================================================================

echo "=== Running Tasks (Cache Benefits) ===\n"
echo "Running similar tasks on subagents to demonstrate caching...\n"

# Run research task
let researchResult = waitFor researcher.run("What are the benefits of prompt caching in LLM APIs?")
echo &"📚 Research completed:"
echo &"   Tokens used: {researchResult.tokensUsed}"
echo &"   Output preview: {researchResult.output[0..min(100, researchResult.output.len-1)]}\n"

# Run code task
let codeResult = waitFor coder.run("Write a Python function to calculate fibonacci numbers")
echo &"💻 Code task completed:"
echo &"   Tokens used: {codeResult.tokensUsed}"
echo &"   Output preview: {codeResult.output[0..min(100, codeResult.output.len-1)]}\n"

# =============================================================================
# Cache Strategy Explanation
# =============================================================================

echo "=== Cache Strategy Summary ===\n"
echo "Cache Key Hierarchy:"
echo "  📌 Main Agent: coordinator_main_v1"
echo "      ├─ Subagent Role: research-specialist → researcher, scientist, etc."
echo "      ├─ Subagent Role: code-specialist → coder, developer, etc."
echo "      └─ Subagent Role: data-analyst → analyst, statistician, etc."
echo ""
echo "Benefits:"
echo "  ✅ Same-role subagents share cached prefixes (system prompts, tools)"
echo "  ✅ Tool definitions (often 1000+ tokens) are cached after first use"
echo "  ✅ 24h retention keeps cache warm for long-running workflows"
echo "  ✅ Parent ID in key prevents cross-parent collisions"
echo ""
echo "Monitoring:"
echo "  📊 Check Usage.cachedTokens to see cache hit rates"
echo "  📊 High cachedTokens = efficient caching"
echo "  📊 Zero cachedTokens = prompts may be <1024 tokens or no prefix match"
echo ""

# =============================================================================
# Cleanup
# =============================================================================

echo "=== Cleanup ===\n"

discard coordinator.cleanupSubagent(researcher.id)
discard coordinator.cleanupSubagent(coder.id)
discard coordinator.cleanupSubagent(analyst.id)

echo "✅ All subagents cleaned up\n"
echo "Demo complete! Check your OpenAI dashboard for cache usage metrics."
