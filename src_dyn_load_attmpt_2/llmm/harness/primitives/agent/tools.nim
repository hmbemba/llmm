# ---------------------------------------------------------------------------
# Tool registration (unchanged)
# ---------------------------------------------------------------------------
proc tool_already_registered*(agent: Agent, toolName: string): bool = agent.cfg.tools.hasKey(toolName)

discard """
var a     = new Agent(
    tools : addTools myTool
)
"""
proc addTools *(tool: Tool) : OrderedTable[string, Tool] =
    result[tool.name] = tool
    return result

discard """
var a     = new Agent(
    tools : addTools @[CodeToolKit(), FileToolkit()]
)
"""
proc addTools *(tk : Toolkit) : OrderedTable[string, Tool] =
    for tool in tk.tools:
        result[tool.name] = tool
    return result

discard """
var a     = new Agent(
    tools : addTools @[CodeExecTool(), FileReadTool()]
)
"""
proc addTools * (newTools: seq[Tool]) : OrderedTable[string, Tool] =
    for tool in newTools:
        result[tool.name] = tool
    return result


discard """
a.addTools @[CodeTool(), FileTool()]
"""
proc addTools * (agent: Agent, newTools: seq[Tool]) =
    for tool in newTools:
        if agent.tool_already_registered(tool.name): continue
        agent.cfg.tools[tool.name] = tool
        
discard """
a.addTools CodeTool()
"""
proc addTools * (agent: Agent, tool: Tool) =
    if agent.tool_already_registered(tool.name): return
    agent.cfg.tools[tool.name] = tool
    
discard """
a.addTools CodeToolKit()
"""
proc addTools * (agent: Agent, toolkit: Toolkit) =
    for tool in toolkit.tools:
        if agent.tool_already_registered(tool.name): continue
        agent.cfg.tools[tool.name] = tool
        
discard """
a.addTools @[CodeToolKit(), FileToolkit()]
"""
proc addTools * (agent: Agent, toolkit: seq[Toolkit]) =
    for tk in toolkit:
        for tool in tk.tools:
            if agent.tool_already_registered(tool.name): continue
            agent.cfg.tools[tool.name] = tool
            

