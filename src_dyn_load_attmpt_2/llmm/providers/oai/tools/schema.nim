## Fluent JSON Schema Builder
##
## Makes function tool parameter schemas ergonomic.
## Avoids %*{...} boilerplate everywhere.
##
## Example - Basic calculator tool:
##   import oai/tools/schema
##   let params = obj()
##       .prop("a", num().desc("First number"), required = true)
##       .prop("b", num().desc("Second number"), required = true)
##       .noAdditionalProps()
##       .toJson()
##
## Example - Using inline helpers (more concise):
##   let params = obj()
##       .numProp("a", "First number", required = true)
##       .numProp("b", "Second number", required = true)
##       .noAdditionalProps()
##       .toJson()
##
## Example - Search tool with optional filters:
##   let searchParams = obj()
##       .strProp("query", "Search query text", required = true)
##       .intProp("limit", "Max results to return (1-100)")
##       .boolProp("include_metadata", "Whether to include metadata")
##       .prop("sort_by", enumStr(["relevance", "date", "popularity"]).desc("Sort order"))
##       .noAdditionalProps()
##       .toJson()

import
    std/json
    ,std/sequtils

type
    Schema* = object
        node*: JsonNode

# =============================================================================
# CORE CONSTRUCTORS
# =============================================================================

proc toJson*(s: Schema): JsonNode =
    ## Convert schema to JsonNode
    s.node

proc obj*(): Schema =
    ## Create an object schema
    Schema(node: %*{
        "type": "object",
        "properties": %*{}
    })

proc arr*(items: Schema): Schema =
    ## Create an array schema with specified item type
    Schema(node: %*{
        "type": "array",
        "items": items.toJson()
    })

proc str*(): Schema =
    ## Create a string schema
    Schema(node: %*{"type": "string"})

proc num*(): Schema =
    ## Create a number schema
    Schema(node: %*{"type": "number"})

proc intt*(): Schema =
    ## Create an integer schema
    Schema(node: %*{"type": "integer"})

proc booll*(): Schema =
    ## Create a boolean schema
    Schema(node: %*{"type": "boolean"})

proc null*(): Schema =
    ## Create a null schema
    Schema(node: %*{"type": "null"})

# =============================================================================
# MODIFIERS
# =============================================================================

proc desc*(s: Schema, text: string): Schema =
    ## Add a description to the schema
    result = s
    if text.len > 0:
        result.node["description"] = %text

proc example*(s: Schema, value: JsonNode): Schema =
    ## Add an example value to the schema
    result = s
    result.node["example"] = value

proc default*(s: Schema, value: JsonNode): Schema =
    ## Set a default value for the schema
    result = s
    result.node["default"] = value

proc nullable*(s: Schema): Schema =
    ## Make a schema nullable by using anyOf with null type
    Schema(node: %*{
        "anyOf": [s.toJson(), %*{"type": "null"}]
    })

proc oneOf*(schemas: varargs[Schema]): Schema =
    ## Create a oneOf schema (value must match exactly one)
    result = Schema(node: %*{"oneOf": newJArray()})
    for schema in schemas:
        result.node["oneOf"].add(schema.toJson())

proc anyOf*(schemas: varargs[Schema]): Schema =
    ## Create an anyOf schema (value must match at least one)
    result = Schema(node: %*{"anyOf": newJArray()})
    for schema in schemas:
        result.node["anyOf"].add(schema.toJson())

proc enumStr*(vals: openArray[string]): Schema =
    ## Create a string enum schema
    result = str()
    result.node["enum"] = %vals.toSeq

proc enumInt*(vals: openArray[int]): Schema =
    ## Create an integer enum schema
    result = intt()
    result.node["enum"] = %vals.toSeq

proc constt*(value: JsonNode): Schema =
    ## Create a const schema (value must equal exactly this)
    Schema(node: %*{"const": value})

# =============================================================================
# STRING CONSTRAINTS
# =============================================================================

proc minLen*(s: Schema, n: int): Schema =
    ## Set minimum string length
    result = s
    result.node["minLength"] = %n

proc maxLen*(s: Schema, n: int): Schema =
    ## Set maximum string length
    result = s
    result.node["maxLength"] = %n

proc pattern*(s: Schema, regex: string): Schema =
    ## Add a regex pattern constraint to a string schema
    result = s
    result.node["pattern"] = %regex

# =============================================================================
# NUMBER CONSTRAINTS
# =============================================================================

proc min*(s: Schema, n: float): Schema =
    ## Set minimum value (inclusive)
    result = s
    result.node["minimum"] = %n

proc max*(s: Schema, n: float): Schema =
    ## Set maximum value (inclusive)
    result = s
    result.node["maximum"] = %n

proc exclusiveMin*(s: Schema, n: float): Schema =
    ## Set exclusive minimum (value must be > n)
    result = s
    result.node["exclusiveMinimum"] = %n

proc exclusiveMax*(s: Schema, n: float): Schema =
    ## Set exclusive maximum (value must be < n)
    result = s
    result.node["exclusiveMaximum"] = %n

proc multipleOf*(s: Schema, n: float): Schema =
    ## Constrain number to be a multiple of n
    result = s
    result.node["multipleOf"] = %n

# =============================================================================
# ARRAY CONSTRAINTS
# =============================================================================

proc minItems*(s: Schema, n: int): Schema =
    ## Set minimum number of items for array schema
    result = s
    result.node["minItems"] = %n

proc maxItems*(s: Schema, n: int): Schema =
    ## Set maximum number of items for array schema
    result = s
    result.node["maxItems"] = %n

proc uniqueItems*(s: Schema, unique = true): Schema =
    ## Require array items to be unique
    result = s
    result.node["uniqueItems"] = %unique

# =============================================================================
# OBJECT HELPERS
# =============================================================================

proc prop*(s: Schema, name: string, value: Schema, required = false): Schema =
    ## Add an object property; optionally mark it required
    result = s
    if not result.node.hasKey("properties"):
        result.node["properties"] = %*{}
    result.node["properties"][name] = value.toJson()
    if required:
        if not result.node.hasKey("required"):
            result.node["required"] = newJArray()
        # Avoid duplicates
        var already = false
        for r in result.node["required"]:
            if r.getStr == name:
                already = true
                break
        if not already:
            result.node["required"].add(%name)

proc require*(s: Schema, names: varargs[string]): Schema =
    ## Mark many fields as required (assumes object schema)
    result = s
    for n in names:
        result = result.prop(n, Schema(node: result.node{"properties"}{n}), required = true)

proc noAdditionalProps*(s: Schema): Schema =
    ## Disallow additional properties
    result = s
    result.node["additionalProperties"] = %false

proc additionalProps*(s: Schema, allowed: bool): Schema =
    ## Set whether additional properties are allowed
    result = s
    result.node["additionalProperties"] = %allowed

proc additionalProps*(s: Schema, schema: Schema): Schema =
    ## Allow additional properties matching a specific schema
    result = s
    result.node["additionalProperties"] = schema.toJson()

proc minProps*(s: Schema, n: int): Schema =
    ## Set minimum number of properties for object schema
    result = s
    result.node["minProperties"] = %n

proc maxProps*(s: Schema, n: int): Schema =
    ## Set maximum number of properties for object schema
    result = s
    result.node["maxProperties"] = %n

# =============================================================================
# INLINE PROPERTY HELPERS (convenience for common patterns)
# =============================================================================

proc strProp*(s: Schema, name: string, description = "", required = false): Schema =
    ## Add a string property with optional description
    let schema = if description.len > 0: str().desc(description) else: str()
    result = s.prop(name, schema, required)

proc numProp*(s: Schema, name: string, description = "", required = false): Schema =
    ## Add a number property with optional description
    let schema = if description.len > 0: num().desc(description) else: num()
    result = s.prop(name, schema, required)

proc intProp*(s: Schema, name: string, description = "", required = false): Schema =
    ## Add an integer property with optional description
    let schema = if description.len > 0: intt().desc(description) else: intt()
    result = s.prop(name, schema, required)

proc boolProp*(s: Schema, name: string, description = "", required = false): Schema =
    ## Add a boolean property with optional description
    let schema = if description.len > 0: booll().desc(description) else: booll()
    result = s.prop(name, schema, required)

proc arrProp*(s: Schema, name: string, items: Schema, description = "", required = false): Schema =
    ## Add an array property with specified item schema
    var schema = arr(items)
    if description.len > 0:
        schema = schema.desc(description)
    result = s.prop(name, schema, required)

proc objProp*(s: Schema, name: string, nested: Schema, description = "", required = false): Schema =
    ## Add a nested object property
    var schema = nested
    if description.len > 0:
        schema = schema.desc(description)
    result = s.prop(name, schema, required)

proc enumProp*(s: Schema, name: string, values: openArray[string], description = "", required = false): Schema =
    ## Add a string enum property
    var schema = enumStr(values)
    if description.len > 0:
        schema = schema.desc(description)
    result = s.prop(name, schema, required)

# =============================================================================
# FUNCTION TOOL HELPER
# =============================================================================

proc functionTool*(
    name: string,
    description: string,
    parameters: Schema,
    strict = true
): JsonNode =
    ## Create a function tool definition
    %*{
        "type": "function",
        "name": name,
        "description": description,
        "parameters": parameters.toJson(),
        "strict": strict
    }
