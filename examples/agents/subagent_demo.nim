## subagent_demo.nim — Demonstration of subagent functionality
##
## This example shows how an agent can create and manage child agents
## to accomplish tasks in parallel. Each subagent has:
##   - Its own isolated session and workspace
##   - Specialized role and instructions
##   - Independent tool usage tracking
##
## Usage:
##   nim r -d:ssl subagent_demo.nim

import std/[
  json,
  asyncdispatch,
  os,
  strformat
]

import 
  llmm/harness/primitives/agent,
  llmm/harness/primitives/tick,
  llmm/harness/tools/base,
  llmm/harness/tools/filesystem,
  llmm/providers/oai/oai_client

import mynimlib/keys
from mynimlib/utils import dirExistsOrMk

# =============================================================================
# Demo: Research Team with Subagents
# =============================================================================

proc researchTeamDemo() {.async.} =
  ## Demonstrates a parent agent coordinating multiple researcher subagents
  
  echo "\n" & "=".repeat(60)
  echo "  SUBAGENT DEMO: Research Team"
  echo "=".repeat(60) & "\n"
  
  # Create the parent agent (the research coordinator)
  var coordinator = Agent(
    provider: newOpenAIResponsesProvider(OpenAIClient(apiKey: keys.open_ai_api_key)),
    cfg: AgentConfig(
      id: "coordinator-001",
      name: "ResearchCoordinator",
      role: "Research Team Lead",
      model: "gpt-4o-mini",
      systemPrompt: """You are a research team coordinator. Your job is to:
1. Break down complex research tasks into subtasks
2. Create specialized subagents for each subtask
3. Delegate work and monitor progress
4. Synthesize results from all subagents into a coherent report

You have access to tools for creating and managing subagents.
Be strategic about when to work sequentially vs in parallel.""",
      workspaceDir: getCurrentDir() / "workspace" / "research_team",
      policy: AgentPolicy(maxToolCalls: 100)
    ),
    state: AgentState()
  )
  
  # Initialize the coordinator agent
  coordinator = coordinator.new()
  
  # Enable subagent support (adds create_subagent, send_to_subagent, etc.)
  coordinator.enableSubagents(maxSubagents = 5)
  
  # Add file tools so subagents can save their research
  coordinator.addTools FileCrudToolkit(coordinator.cfg.workspaceDir)
  
  echo "✅ Coordinator agent initialized with subagent support\n"
  
  # Run the coordinator with a research task
  let researchTopic = "The impact of AI on software development in 2024"
  
  echo &"📝 Research Topic: {researchTopic}\n"
  echo "The coordinator will create subagents to research different aspects...\n"
  
  let prompt = &"""Research the topic: "{researchTopic}"

Your task:
1. Create 3 specialized subagents:
   - "trends_researcher": Focus on current AI trends in development
   - "tools_researcher": Focus on AI-powered development tools  
   - "future_researcher": Focus on future predictions and implications

2. Give each subagent a specific research task related to their specialty

3. Wait for all subagents to complete their research

4. Read their outputs and synthesize into a comprehensive report

5. Save the final report to "ai_development_research.md"

Use the subagent tools:
- create_subagent to create each researcher
- send_to_subagent to assign tasks (wait for each to complete)
- wait_for_all_subagents to collect all results
- write_file to save the final report

Be efficient - you can create all subagents first, then assign tasks in parallel."""

  let result = await coordinator.chat(prompt, maxToolCalls = 50)
  
  echo "\n" & "=".repeat(60)
  echo "  FINAL OUTPUT"
  echo "=".repeat(60)
  echo result
  
  # Show subagent statistics
  echo "\n" & "=".repeat(60)
  echo "  SUBAGENT STATISTICS"
  echo "=".repeat(60)
  
  let subagents = coordinator.listSubagents()
  echo &"\nTotal subagents created: {subagents.len}\n"
  
  for sa in subagents:
    echo &"  📋 {sa.name}"
    echo &"     Status: {sa.status}"
    if sa.result.isSome:
      let r = sa.result.get()
      echo &"     Tokens: {r.tokensUsed}, Tool calls: {r.toolCalls}"
      echo &"     Success: {r.success}"
    echo ""

# =============================================================================
# Demo: Code Review Pipeline
# =============================================================================

proc codeReviewDemo() {.async.} =
  ## Demonstrates a code review pipeline with parallel reviewer subagents
  
  echo "\n" & "=".repeat(60)
  echo "  SUBAGENT DEMO: Code Review Pipeline"
  echo "=".repeat(60) & "\n"
  
  # Create a sample file to review
  let workDir = getCurrentDir() / "workspace" / "code_review"
  discard dirExistsOrMk(workDir)
  
  let sampleCode = """# sample_module.py - A sample module to review

def calculate_total(items):
    total = 0
    for item in items:
        total = total + item['price'] * item['quantity']
    return total

def process_order(order_id, items, customer):
    # Process an order
    total = calculate_total(items)
    
    # Save to database (mock)
    db_query = f"INSERT INTO orders VALUES ({order_id}, {customer}, {total})"
    
    return {
        'order_id': order_id,
        'total': total,
        'customer': customer
    }

def get_customer_orders(customer_id):
    # SQL injection vulnerability!
    query = "SELECT * FROM orders WHERE customer_id = " + str(customer_id)
    return execute_query(query)
"""
  
  writeFile(workDir / "sample_module.py", sampleCode)
  echo "✅ Created sample code file to review\n"
  
  # Create the review coordinator
  var reviewer = Agent(
    provider: newOpenAIResponsesProvider(OpenAIClient(apiKey: keys.open_ai_api_key)),
    cfg: AgentConfig(
      id: "reviewer-001",
      name: "CodeReviewLead",
      role: "Code Review Coordinator",
      model: "gpt-4o-mini",
      systemPrompt: """You are a code review coordinator. Your job is to:
1. Create specialized reviewer subagents for different aspects
2. Assign code review tasks to each subagent
3. Collect and synthesize all review feedback
4. Produce a comprehensive code review report

Each reviewer should focus on their specialty area.""",
      workspaceDir: workDir,
      policy: AgentPolicy(maxToolCalls: 50)
    ),
    state: AgentState()
  )
  
  reviewer = reviewer.new()
  reviewer.enableSubagents(maxSubagents = 4)
  reviewer.addTools FileCrudToolkit(workDir)
  
  let prompt = """Review the file "sample_module.py" using a team of specialized reviewers.

1. Create these reviewer subagents:
   - "security_reviewer": Focus on security vulnerabilities (SQL injection, etc.)
   - "style_reviewer": Focus on code style, naming, and Python best practices
   - "logic_reviewer": Focus on logic errors and edge cases
   - "performance_reviewer": Focus on performance issues and optimizations

2. For each reviewer, send them the file content and their specific review task

3. Wait for all reviewers to complete and collect their feedback

4. Synthesize all reviews into a comprehensive report with:
   - Summary of issues found by category
   - Priority-ranked list of fixes needed
   - Code snippets showing suggested improvements

5. Save the report to "code_review_report.md"

The code file "sample_module.py" is in your workspace."""

  let result = await reviewer.chat(prompt, maxToolCalls = 40)
  
  echo "\n" & "=".repeat(60)
  echo "  REVIEW COMPLETE"
  echo "=".repeat(60)
  echo result

# =============================================================================
# Demo: Async Subagent Pattern
# =============================================================================

proc asyncPatternDemo() {.async.} =
  ## Demonstrates starting subagents asynchronously and waiting later
  
  echo "\n" & "=".repeat(60)
  echo "  SUBAGENT DEMO: Async Pattern"
  echo "=".repeat(60) & "\n"
  
  var manager = Agent(
    provider: newOpenAIResponsesProvider(OpenAIClient(apiKey: keys.open_ai_api_key)),
    cfg: AgentConfig(
      id: "manager-001",
      name: "AsyncManager",
      role: "Task Manager",
      model: "gpt-4o-mini",
      systemPrompt: "You manage tasks using subagents. You can start multiple subagents in parallel.",
      workspaceDir: getCurrentDir() / "workspace" / "async_demo",
      policy: AgentPolicy(maxToolCalls: 50)
    ),
    state: AgentState()
  )
  
  manager = manager.new()
  manager.enableSubagents(maxSubagents = 3)
  
  echo "✅ Manager initialized\n"
  
  # This prompt demonstrates the async pattern
  let prompt = """Demonstrate the async subagent pattern:

1. Create 3 subagents:
   - "task_a": Quick task worker
   - "task_b": Quick task worker  
   - "task_c": Quick task worker

2. Start all 3 tasks ASYNCHRONOUSLY (don't wait):
   - Task A: "Write a haiku about coding"
   - Task B: "Write a haiku about debugging"
   - Task C: "Write a haiku about shipping"

3. While they're running, use get_subagent_status to check on each

4. Then use wait_for_all_subagents to collect all results

5. Combine all three haikus into a single poem and display it

This pattern is useful when you want to start multiple subagents
and do other work while they run in parallel."""

  let result = await manager.chat(prompt, maxToolCalls = 30)
  
  echo "\n" & "=".repeat(60)
  echo "  ASYNC PATTERN RESULT"
  echo "=".repeat(60)
  echo result

# =============================================================================
# Main
# =============================================================================

proc main() {.async.} =
  echo """
╔══════════════════════════════════════════════════════════════╗
║              LLMM Subagent System Demo                       ║
║                                                              ║
║  This demo showcases agents creating and managing            ║
║  child agents (subagents) for parallel task execution.       ║
╚══════════════════════════════════════════════════════════════╝
"""
  
  echo "Choose a demo:"
  echo "  1. Research Team (parallel research with synthesis)"
  echo "  2. Code Review Pipeline (specialized reviewers)"
  echo "  3. Async Pattern (start multiple, wait later)"
  echo "  4. Run all demos"
  echo ""
  stdout.write "Choice [1/2/3/4]: "
  stdout.flushFile()
  
  let choice = stdin.readLine().strip()
  
  case choice
  of "1":
    await researchTeamDemo()
  of "2":
    await codeReviewDemo()
  of "3":
    await asyncPatternDemo()
  of "4":
    await researchTeamDemo()
    await codeReviewDemo()
    await asyncPatternDemo()
  else:
    echo "Invalid choice. Running research team demo...\n"
    await researchTeamDemo()
  
  echo "\n" & "=".repeat(60)
  echo "  Demo Complete!"
  echo "=".repeat(60)

when isMainModule:
  waitFor main()
