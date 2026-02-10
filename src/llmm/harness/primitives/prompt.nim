import strutils

# =============================================================================
# Prompt Type
# =============================================================================

type
    Prompt    * = object
        rules * : string    # can be path or inline content
        ctx   * : string    # can be path or inline content    
        body  * : string

proc `$`*(p: Prompt): string =
    result = unindent p.body.strip & "\n"
    
    if p.ctx.len > 0:
        result.add "\n<context>\n"
        result.add unindent p.ctx
        result.add "\n</context>\n"
    
    if p.rules.len > 0:
        result.add "\n<rules>\n"
        result.add unindent p.rules
        result.add "\n</rules>\n"

proc numTokens*(p: Prompt): int =
    ## Rough estimate
    (p.body.len + p.ctx.len + p.rules.len) div 4