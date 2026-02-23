## subagent_example.nim — Complete Subagent Usage Example
##
## This example demonstrates how to use subagents in the llmm framework.
## A parent agent (coordinator) creates specialized child agents to work
## in parallel on different aspects of a complex task.
##
## Usage:
##   nim c -d:ic -d:ssl -r ./examples/agents/subagent_example.nim

import std/[
    asyncdispatch,
    parseopt,
    strutils,
    os,
    strformat,
    json,
    options
]

import ../../src/llmm
import ../../src/llmm/tools
import ../../src/llmm/harness/primitives/subagents  # Import subagent support
import mynimlib/keys

# =============================================================================
# Configuration
# =============================================================================

let workspaceDir = getCurrentDir() / "workspace" / "subagent_demo"
let dbPath = "agent.db"

let systemPrompt = """You are an intelligent coordinator agent that can delegate tasks to specialized subagents.

Your capabilities:
1. Create subagents with specific roles and expertise
2. Delegate tasks to subagents and wait for results
3. Synthesize information from multiple subagents
4. Manage parallel execution for efficiency

When given a complex task:
- Break it down into subtasks
- Create specialized subagents for each subtask
- Delegate work in parallel when possible
- Synthesize results into a coherent response

You have access to subagent management tools:
- create_subagent: Create a new child agent with a specific role
- send_to_subagent: Send a task to a subagent and wait for result
- list_subagents: See all active subagents
- get_subagent_status: Check on a subagent's progress
- wait_for_subagent: Wait for a specific subagent to complete
- wait_for_all_subagents: Wait for all subagents to finish
- cancel_subagent: Cancel a running subagent
- cleanup_subagent: Remove a subagent when done"""

# =============================================================================
# Create the Coordinator Agent
# =============================================================================

var coordinator = new Agent(
    provider: newKimiChatProvider(KimiClient(apiKey: keys.kimi_api_key)),
    cfg: AgentConfig(
        id: "coordinator-001",
        name: "kimi-coordinator",
        role: "Task Coordinator",
        model: "kimi-k2.5",
        workspaceDir: workspaceDir,
        dbPath: workspaceDir / dbPath,
        systemPrompt: systemPrompt,
        enableReflection: true,
        policy: AgentPolicy(maxToolCalls: 150),
        tools: addTools @[HITLTool()]
    )
)

echo pretty %coordinator.cfg

# Add standard toolkits for file operations and code execution
coordinator.addTools @[
    FileCrudToolkit(workspaceDir),
    CodeExecToolkit(workspaceDir),
    NimDevToolkit(workspaceDir),
    CodeEditToolkit(workspaceDir)
]

# Enable CodeAct for Python code execution
coordinator.enableCodeAct()

# Enable subagent support - this adds tools for creating/managing subagents
coordinator.enableSubagents(maxSubagents = 5)

echo "\n✅ Coordinator agent initialized with subagent support\n"

# =============================================================================
# Example 1: Research Team with Subagents
# =============================================================================

proc researchTeamExample() {.async.} =
    echo "\n" & "=".repeat(70)
    echo "  EXAMPLE 1: Research Team with Subagents"
    echo "=".repeat(70) & "\n"
    
    let researchTask = """Research the topic: "The impact of artificial intelligence on healthcare in 2024"

Your task is to coordinate a team of specialized research subagents:

1. Create 3 subagents with these roles:
   - "clinical_researcher": Focus on AI in clinical practice, diagnosis, and treatment
   - "operational_researcher": Focus on AI in hospital operations and administration
   - "ethical_researcher": Focus on ethical considerations, privacy, and regulations

2. For each subagent:
   - Give them specific research instructions
   - Assign them a focused research task
   - Have them save their findings to files

3. Wait for all subagents to complete their research

4. Read all their outputs and synthesize into a comprehensive report

5. Save the final synthesized report to "healthcare_ai_research_2024.md"

Use parallel execution where possible to be efficient."""

    let result = await coordinator.chat(researchTask, maxToolCalls = 100)
    
    echo "\n" & "=".repeat(70)
    echo "  RESEARCH TEAM RESULT"
    echo "=".repeat(70)
    echo result

# =============================================================================
# Example 2: Code Review Pipeline
# =============================================================================

proc codeReviewExample() {.async.} =
    echo "\n" & "=".repeat(70)
    echo "  EXAMPLE 2: Code Review Pipeline"
    echo "=".repeat(70) & "\n"
    
    # Create a sample file to review
    let sampleCode = """# payment_processor.py - Sample module for review

import sqlite3
from datetime import datetime

def process_payment(user_id, amount, card_number):
    # Validate inputs
    if amount <= 0:
        return {"error": "Invalid amount"}
    
    # Connect to database
    conn = sqlite3.connect('payments.db')
    cursor = conn.cursor()
    
    # Log payment attempt
    query = "INSERT INTO payment_logs (user_id, amount, timestamp) VALUES (%s, %s, '%s')" % (user_id, amount, datetime.now())
    cursor.execute(query)
    
    # Process payment (mock)
    success = True
    
    # Store card info for future use (security issue!)
    cursor.execute("UPDATE users SET card_number = '%s' WHERE id = %s" % (card_number, user_id))
    
    conn.commit()
    conn.close()
    
    return {"success": success, "amount": amount}

def refund_payment(transaction_id, amount):
    # No validation of transaction ownership
    conn = sqlite3.connect('payments.db')
    cursor = conn.cursor()
    
    # SQL injection vulnerability
    cursor.execute("UPDATE transactions SET refunded = 1 WHERE id = " + str(transaction_id))
    
    conn.commit()
    conn.close()
    
    return {"refunded": True, "amount": amount}
"""
    
    let codeFile = workspaceDir / "payment_processor.py"
    writeFile(codeFile, sampleCode)
    echo "✅ Created sample code file: ", codeFile, "\n"
    
    let reviewTask = """Perform a comprehensive code review of "payment_processor.py" using specialized reviewer subagents.

1. Create 4 reviewer subagents:
   - "security_reviewer": Focus on SQL injection, data exposure, authentication issues
   - "style_reviewer": Focus on code style, PEP 8 compliance, naming conventions
   - "logic_reviewer": Focus on business logic errors, edge cases, validation
   - "performance_reviewer": Focus on database efficiency, resource management

2. Send each reviewer:
   - The code file content
   - Their specific review focus area
   - Instructions to provide specific, actionable feedback

3. Wait for all reviewers to complete

4. Synthesize all feedback into a comprehensive review report with:
   - Executive summary
   - Critical issues (security/logic)
   - Style and maintainability issues
   - Performance recommendations
   - Specific code suggestions with examples

5. Save the report to "code_review_report.md"

The file "payment_processor.py" is in your workspace."""

    let result = await coordinator.chat(reviewTask, maxToolCalls = 100)
    
    echo "\n" & "=".repeat(70)
    echo "  CODE REVIEW RESULT"
    echo "=".repeat(70)
    echo result

# =============================================================================
# Example 3: Parallel Task Processing
# =============================================================================

proc parallelTaskExample() {.async.} =
    echo "\n" & "=".repeat(70)
    echo "  EXAMPLE 3: Parallel Task Processing"
    echo "=".repeat(70) & "\n"
    
    let parallelTask = """Demonstrate efficient parallel task processing with subagents.

Create 3 subagents that each perform a different analysis on the same dataset concept:

1. Create these subagents:
   - "data_analyst": Analyze trends and patterns
   - "statistician": Calculate statistical measures and significance
   - "visualization_expert": Suggest visualizations and insights

2. First, create a sample dataset by writing a CSV file with:
   - 20 rows of sample sales data (date, product, region, amount, units)
   - Vary the data to show trends

3. Then assign each subagent their analysis task IN PARALLEL:
   - Start all 3 subagents without waiting
   - Use get_subagent_status to check progress
   - Then use wait_for_all_subagents to collect results

4. Synthesize their analyses into a comprehensive data report

5. Save the report to "data_analysis_report.md"

This demonstrates the async pattern: start multiple subagents, do other work while they run, then collect results."""

    let result = await coordinator.chat(parallelTask, maxToolCalls = 80)
    
    echo "\n" & "=".repeat(70)
    echo "  PARALLEL TASK RESULT"
    echo "=".repeat(70)
    echo result

# =============================================================================
# Example 4: Hierarchical Task Decomposition
# =============================================================================

proc hierarchicalTaskExample() {.async.} =
    echo "\n" & "=".repeat(70)
    echo "  EXAMPLE 4: Hierarchical Task Decomposition"
    echo "=".repeat(70) & "\n"
    
    let hierarchicalTask = """Demonstrate hierarchical task decomposition with subagents.

Task: "Design a simple web application for task management"

1. Create an "architect" subagent:
   - Task: Design the overall system architecture
   - Output: Component list, data models, API structure
   - Save to: "architecture.md"

2. Wait for architect to complete, then read the architecture

3. Create 3 implementation subagents based on the architecture:
   - "backend_dev": Design the backend API and database schema
   - "frontend_dev": Design the UI/UX and frontend components  
   - "devops_dev": Design deployment and infrastructure

4. Run all 3 implementation subagents in parallel

5. Create a "qa_reviewer" subagent:
   - Task: Review all designs for consistency and completeness
   - Input: Read architecture.md and all implementation docs
   - Output: Review report with suggestions
   - Save to: "design_review.md"

6. Synthesize everything into a final project specification
   - Save to: "project_spec.md"

This shows how subagents can work in stages (sequential dependencies) and in parallel."""

    let result = await coordinator.chat(hierarchicalTask, maxToolCalls = 120)
    
    echo "\n" & "=".repeat(70)
    echo "  HIERARCHICAL TASK RESULT"
    echo "=".repeat(70)
    echo result

# =============================================================================
# Show Subagent Statistics
# =============================================================================

proc showSubagentStats() =
    echo "\n" & "=".repeat(70)
    echo "  SUBAGENT STATISTICS"
    echo "=".repeat(70) & "\n"
    
    let subagents = coordinator.listSubagents()
    echo &"Total subagents created: {subagents.len}\n"
    
    for sa in subagents:
        echo &"  📋 {sa.name} (ID: {sa.id})"
        echo &"     Status: {sa.status}"
        echo &"     Created: {sa.createdAt}"
        if sa.result.isSome:
            let r = sa.result.get()
            echo &"     Result: success={r.success}, tokens={r.tokensUsed}, toolCalls={r.toolCalls}"
            if r.error.isSome:
                echo &"     Error: {r.error.get()}"
        echo ""

# =============================================================================
# Main - Interactive REPL with Subagent Support
# =============================================================================

proc main() =
    echo """
╔══════════════════════════════════════════════════════════════════════╗
║                    LLMM Subagent Example                             ║
║                                                                      ║
║  This agent can create and manage child agents (subagents) for       ║
║  parallel task execution. Try asking it to:                          ║
║                                                                      ║
║  • "Research a topic using 3 specialized subagents"                  ║
║  • "Review this code with security and style reviewers"              ║
║  • "Create a team of experts to analyze this data"                   ║
║  • "Break down this project into subtasks for subagents"             ║
║                                                                      ║
║  Or run one of the built-in examples below.                          ║
╚══════════════════════════════════════════════════════════════════════╝
"""
    
    echo "Choose an option:"
    echo "  1. Run Research Team Example"
    echo "  2. Run Code Review Pipeline Example"
    echo "  3. Run Parallel Task Processing Example"
    echo "  4. Run Hierarchical Task Example"
    echo "  5. Run ALL Examples"
    echo "  6. Start Interactive REPL"
    echo ""
    stdout.write "Choice [1/2/3/4/5/6]: "
    stdout.flushFile()
    
    let choice = stdin.readLine().strip()
    
    case choice
    of "1":
        waitFor researchTeamExample()
        showSubagentStats()
    of "2":
        waitFor codeReviewExample()
        showSubagentStats()
    of "3":
        waitFor parallelTaskExample()
        showSubagentStats()
    of "4":
        waitFor hierarchicalTaskExample()
        showSubagentStats()
    of "5":
        waitFor researchTeamExample()
        waitFor codeReviewExample()
        waitFor parallelTaskExample()
        waitFor hierarchicalTaskExample()
        showSubagentStats()
    of "6", "":
        echo "\n🚀 Starting interactive REPL...\n"
        coordinator.chatRepl()
    else:
        echo "Invalid choice. Starting interactive REPL...\n"
        coordinator.chatRepl()

when isMainModule:
    main()

discard """
# Compile commands:
nim c -d:ssl ./examples/agents/subagent_example.nim
nim c -d:llmm_repl_termui -d:llmm_repl_clipboard -d:ssl ./examples/agents/subagent_example.nim
nim c -d:llmm_repl_clipboard -d:ssl ./examples/agents/subagent_example.nim
"""
