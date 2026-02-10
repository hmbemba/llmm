import std/[
json
,options
,times
,tables
,asyncdispatch
,os
,osproc
,strformat
,strutils
,sequtils
,parseopt
,enumerate
]

import ../../src/llmm
,../../src/llmm/tools

import ctxlib
,rz
,ic

import mynimlib/keys

blok "prompts":
    #let 
    #    ctx   = readfile currentSourcePath.parentDir / "poc_planner_runner_workspace" / "ctx.md"
    #    rules = readfile currentSourcePath.parentDir / "poc_planner_runner_workspace" / "rules.md"
    let planner_prompt = Prompt(
        body: unindent strip &"""
            Analyze the following library/project context and create a detailed plan.json file that outlines 
            a series of progressive POCs (Proof of Concepts) to demonstrate key features and usage patterns of the library/project.
            Ensure each POC is progressively more complex, standalone, and has clear success criteria.
            
            If a plan.json already exists in the workspace, confirm its presence and state that the plan is ready for execution.
            If it fits the requirements below just exit you're done.

            Requirements:
            - Generate between 5 and 10 POCs
            The plan.json must follow this exact schema:
            
            - Plan
            {% llmm.Plan()     }            
            - Plan Step
            {% llmm.PlanStep() }
            """
        #,ctx : ctx
    )

    ic planner_prompt
    
#     const PLANNER_SYSTEM_PROMPT* = unindent """
#     You are a Nim programming expert creating structured learning plans.

#     Your task is to analyze the provided library/project context and create a comprehensive plan.json file with progressive POCs (Proof of Concepts).

#     ## Plan Design Principles:
#     1. **Progressive Complexity**: Start simple, build up to advanced usage
#     2. **Standalone POCs**: Each POC should be independently runnable
#     3. **Build on Prior Work**: Later POCs can reference patterns from earlier ones
#     4. **Clear Success Criteria**: Each POC must have measurable completion criteria
#     5. **Practical Examples**: Focus on real-world use cases, not toy examples

#     ## POC Structure Guidelines:
#     - **title**: Short, descriptive (e.g., "POC 3 - Thread Pool Basics")
#     - **goal**: One-sentence objective
#     - **description**: 2-3 sentences explaining what will be demonstrated
#     - **successCriteria**: Specific, testable outcomes

#     When creating the plan, use the file_create tool with filename "plan.json".
#     """

#     let EXECUTOR_SYSTEM_PROMPT* = unindent &"""
#     You are a Nim programming expert executing POCs from a plan.

#     ## Your Workflow:
#     1. Read `plan.json` to see all POCs and their status
#     2. Find the earliest POC where `done` is false
#     3. Implement that POC
#     4. Compile and test using nim_run
#     5. Fix any errors (read them carefully!)
#     6. When the POC works, update `plan.json` to mark it `done: true` and add `completion_notes`
#     7. Respond with POC_COMPLETE

#     If you cannot complete after several attempts, respond with POC_FAILED and explain why.

#     ## Important:
#     - Make sure to import the library/project correctly
#     - The library is already installed in the Nim environment, just import it and create POCs
#     - Always read plan.json first to know what to work on
#     - Update plan.json when you complete a POC
#     - Each POC should be standalone and runnable
#     - Test your code before marking complete

#     # Context on the library
#     {ctx}

#     # Rules
#     {rules}
#     """

# # =============================================================================
# # Setup
# # =============================================================================

# blok "Workspace":
#     let
#         client       = initOpenAIClient(apiKey = keys.open_ai_api_key)
#         workspaceDir = dirExistsOrMk currentSourcePath.parentDir / "poc_planner_runner_workspace"
#         artifactsDir = dirExistsOrMk workspaceDir / ".artifacts"


# blok "agents":
#     var planner       = newAgent(
#         name          = "Planner"
#         ,role         = "POC Plan Generator"
#         ,model        = "gpt-5-mini"
#         ,systemPrompt = PLANNER_SYSTEM_PROMPT
#     )
#     planner.toolkits     = @[FileFullToolkit(workspaceDir)]
#     planner.workspaceDir = workspaceDir
#     planner.artifactsDir = artifactsDir / "planner"

#     var runner        = newAgent(
#         name          = "Runner"
#         ,role         = "POC Executor"
#         ,model        = "gpt-5.2"
#         ,systemPrompt = EXECUTOR_SYSTEM_PROMPT
#     )
#     runner.policy.maxToolCalls  = 100   # allow more tool calls since this agent will be iterating over multiple POCs
#     runner.toolkits             = @[NimDevToolkit(workspaceDir),FileFullToolkit(workspaceDir)]
#     runner.workspaceDir         = workspaceDir
#     runner.artifactsDir         = artifactsDir / "runner"


# blok "poc_loop":
#     let poc_loop           = client.newLoop(runner)
#     poc_loop.maxIterations = 30
#     poc_loop.onIteration   = proc(ctx: LoopContext, res: TickResult) =
#         ic &"  [Iteration {ctx.iteration}] Tools: {res.toolCalls.len}, Response: {res.text.len} chars"

#     poc_loop.onComplete = proc(results: seq[TickResult], state: JsonNode) =
#         icb &"=== POC Loop Complete ==="
#         ic &"Total iterations: {results.len}"

# # =============================================================================
# # Main Execution
# # =============================================================================

# blok "Run":
#     # Step 1: Run planner to generate plan.json
#     icb "=== Step 1: Generating POC Plan ==="
#     let planResult = waitFor client.run(planner, $planner_prompt)
#     if planResult.error.isSome:
#         icr &"Planner failed: {planResult.error.get}"
#         quit(1)

#     icb "\n=== Step 2: Executing POCs ==="
#     let loopResult = waitFor poc_loop.run proc(ctx: LoopContext): LoopAction =
#         if ctx.prevResult.isNone:
#             return next("Read plan.json and execute the first incomplete POC. It's important that you implement the POC in a way so that it will end. it shouldn't be a program that runs forveer. When done, respond with POC_COMPLETE.")
        
#         let agentOutput = ctx.prevResult.get.text.toUpperAscii
#         ic  agentOutput.max_len(200)
        
#         if "POC_COMPLETE" in agentOutput:
#             return next("Check plan.json for the next incomplete POC and implement it. If all are done, respond with ALL_COMPLETE.")
        
#         if "ALL_COMPLETE" in agentOutput or "ALL_BLOCKED" in agentOutput:
#             return stop()
        
#         if "POC_FAILED" in agentOutput:
#             return next("That POC failed. Move on to the next incomplete POC in plan.json. If all are done, respond with ALL_COMPLETE.")
        
#         return next("Continue working on the current POC.")

#     if loopResult.ok:
#         icb &"All POCs complete! Total iterations: {loopResult.val.len}"
#     else:
#         icr loopResult.err

# discard """
# nim r -d:ssl -d:ic examples/loops/poc_planner_runner.nim
# """