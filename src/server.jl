#=
The MCP server: same tested client.jl functions, exposed as discoverable
tools any MCP client (Claude, Claude Desktop, etc.) can call directly.

Sessions are named (default: "default") so more than one Pluto notebook
can be driven at once; each is a live `Conn` held in `SESSIONS` for the
life of the server process — the whole point of a long-running MCP server
is that this state persists across tool calls.
=#

const SESSIONS = Dict{String,Conn}()

function _conn(session::AbstractString)
    haskey(SESSIONS, session) || error("no session named \"$session\" — call pluto_connect first")
    return SESSIONS[session]
end

_ok(x) = TextContent(type="text", text=JSON3.write(x))
_err(msg) = TextContent(type="text", text=JSON3.write(Dict("error" => true, "message" => msg)))

# Wraps a handler body: catches exceptions and reports them as a normal
# (non-protocol-level) tool result — a Pluto-side error (bad cell_id, cell
# threw, unknown session) is something the calling agent should see and
# react to, not a transport-level failure.
macro safely(body)
    quote
        try
            $(esc(body))
        catch e
            _err(sprint(showerror, e))
        end
    end
end

# ---------------------------------------------------------------- tools ----

pluto_connect = MCPTool(
    name="pluto_connect",
    description="Connect to a running Pluto session and open one of its notebooks. Call this first.",
    parameters=[
        ToolParameter(name="host", type="string", description="Pluto server host:port, e.g. localhost:1234", required=true),
        ToolParameter(name="secret", type="string", description="Pluto's access secret (from its URL's ?secret= query param)", required=true),
        ToolParameter(name="notebook_id", type="string", description="Notebook UUID (see pluto_list_notebooks)", required=true),
        ToolParameter(name="session", type="string", description="Name to refer to this connection by in later calls", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        conn = connect_pluto(args["host"], args["secret"], args["notebook_id"])
        SESSIONS[args["session"]] = conn
        _ok((session=args["session"], cell_count=length(read_notebook(conn))))
    end),
    return_type=TextContent,
)

pluto_list_notebooks = MCPTool(
    name="pluto_list_notebooks",
    description="List notebooks currently open on a running Pluto server, as {notebook_id => path}.",
    parameters=[
        ToolParameter(name="host", type="string", description="Pluto server host:port", required=true),
        ToolParameter(name="secret", type="string", description="Pluto's access secret", required=true),
    ],
    handler=(args -> @safely _ok(list_notebooks(args["host"], args["secret"]))),
    return_type=TextContent,
)

pluto_new_notebook = MCPTool(
    name="pluto_new_notebook",
    description="Create a brand-new empty notebook on the Pluto server and connect to it. Use this to start a fresh notebook rather than editing an existing one.",
    parameters=[
        ToolParameter(name="host", type="string", description="Pluto server host:port", required=true),
        ToolParameter(name="secret", type="string", description="Pluto's access secret", required=true),
        ToolParameter(name="session", type="string", description="Name to refer to this connection by in later calls", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        nb_id = new_notebook(args["host"], args["secret"])
        conn = connect_pluto(args["host"], args["secret"], nb_id)
        SESSIONS[args["session"]] = conn
        _ok((session=args["session"], notebook_id=nb_id))
    end),
    return_type=TextContent,
)

pluto_read_notebook = MCPTool(
    name="pluto_read_notebook",
    description="List all cells (id, code, current output mime, errored) in display order. Does not run anything.",
    parameters=[ToolParameter(name="session", type="string", description="Which pluto_connect session to use", required=false, default="default")],
    handler=(args -> @safely _ok(read_notebook(_conn(args["session"])))),
    return_type=TextContent,
)

pluto_notebook_edit = MCPTool(
    name="pluto_notebook_edit",
    description="Replace, insert, or delete a single Pluto cell — same shape as the built-in NotebookEdit tool for .ipynb files. insert adds a cell after cell_id (or at the very start if cell_id is omitted). Does not run the cell; call pluto_run_cells after.",
    parameters=[
        ToolParameter(name="new_source", type="string", description="New cell code (ignored for edit_mode=delete)", required=false, default=""),
        ToolParameter(name="cell_id", type="string", description="Target cell (required for replace/delete; anchor for insert)", required=false),
        ToolParameter(name="cell_type", type="string", description="\"code\" or \"markdown\" (markdown is emulated: source gets wrapped in md\"...\")", required=false, default="code"),
        ToolParameter(name="edit_mode", type="string", description="\"replace\", \"insert\", or \"delete\"", required=false, default="replace"),
        ToolParameter(name="session", type="string", description="Which pluto_connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        result = notebook_edit(_conn(args["session"]), get(args, "new_source", "");
            cell_id=get(args, "cell_id", nothing), cell_type=get(args, "cell_type", "code"),
            edit_mode=get(args, "edit_mode", "replace"))
        _ok((cell_id=result,))
    end),
    return_type=TextContent,
)

pluto_run_cells = MCPTool(
    name="pluto_run_cells",
    description="Run (or re-run) the given cells. Returns immediately — poll with pluto_get_output for results.",
    parameters=[
        ToolParameter(name="cell_ids", type="array", description="List of cell UUIDs to run", required=true),
        ToolParameter(name="session", type="string", description="Which pluto_connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        run_cells(_conn(args["session"]), String.(args["cell_ids"]))
        _ok((ok=true,))
    end),
    return_type=TextContent,
)

pluto_get_output = MCPTool(
    name="pluto_get_output",
    description="Wait for a cell to finish running and return its output. Text/structured results come back as text; image (SVG/PNG/etc) results come back as a viewable image. errored=true means the cell threw — the message is in the returned text.",
    parameters=[
        ToolParameter(name="cell_id", type="string", description="Target cell UUID", required=true),
        ToolParameter(name="timeout", type="number", description="Seconds to wait", required=false, default=60),
        ToolParameter(name="session", type="string", description="Which pluto_connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        out = get_output(_conn(args["session"]), args["cell_id"]; timeout=Float64(get(args, "timeout", 60)))
        if startswith(out.mime, "image/") && out.body isa Vector{UInt8}
            ImageContent(data=out.body, mime_type=out.mime)
        else
            body_text = out.body isa Vector{UInt8} ? "<$(length(out.body)) bytes, mime=$(out.mime)>" : string(out.body)
            _ok((mime=out.mime, errored=out.errored, body=body_text))
        end
    end),
    return_type=Content,
)

pluto_search_cells = MCPTool(
    name="pluto_search_cells",
    description="Find cells whose source matches a substring or regex.",
    parameters=[
        ToolParameter(name="pattern", type="string", description="Substring or regex to search cell source for", required=true),
        ToolParameter(name="session", type="string", description="Which pluto_connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely _ok(search_cells(_conn(args["session"]), args["pattern"]))),
    return_type=TextContent,
)

pluto_find_definition = MCPTool(
    name="pluto_find_definition",
    description="Find the cell that defines a given global variable/function name, using Pluto's own reactive dependency graph (exact, not text search). Pluto guarantees at most one cell defines any given name.",
    parameters=[
        ToolParameter(name="name", type="string", description="Global variable or function name", required=true),
        ToolParameter(name="session", type="string", description="Which pluto_connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        d = find_definition(_conn(args["session"]), args["name"])
        d === nothing ? _ok((found=false,)) : _ok((found=true, id=d.id, code=d.code))
    end),
    return_type=TextContent,
)

pluto_list_dependencies = MCPTool(
    name="pluto_list_dependencies",
    description="All names a cell references, mapped to the cell_id that defines each (or null if it resolves outside the notebook, e.g. Base/a package).",
    parameters=[
        ToolParameter(name="cell_id", type="string", description="Target cell UUID", required=true),
        ToolParameter(name="session", type="string", description="Which pluto_connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely _ok(list_dependencies(_conn(args["session"]), args["cell_id"]))),
    return_type=TextContent,
)

pluto_find_dependents = MCPTool(
    name="pluto_find_dependents",
    description="Cells that depend on (reference) a given name.",
    parameters=[
        ToolParameter(name="name", type="string", description="Global variable or function name", required=true),
        ToolParameter(name="session", type="string", description="Which pluto_connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely _ok(find_dependents(_conn(args["session"]), args["name"]))),
    return_type=TextContent,
)

pluto_render_png = MCPTool(
    name="pluto_render_png",
    description="Get a cell's plot as a guaranteed PNG image, regardless of its native output format (e.g. SVG). Re-runs the cell's code wrapped in savefig — cheap for a plot, wasteful for an expensive underlying computation.",
    parameters=[
        ToolParameter(name="cell_id", type="string", description="Target cell UUID", required=true),
        ToolParameter(name="session", type="string", description="Which pluto_connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        tmp_path = tempname() * ".png"
        try
            save_png(_conn(args["session"]), args["cell_id"], tmp_path)
            ImageContent(data=read(tmp_path), mime_type="image/png")
        finally
            isfile(tmp_path) && rm(tmp_path)
        end
    end),
    return_type=Content,
)

const ALL_TOOLS = [
    pluto_connect, pluto_new_notebook, pluto_list_notebooks, pluto_read_notebook,
    pluto_notebook_edit, pluto_run_cells, pluto_get_output,
    pluto_search_cells, pluto_find_definition, pluto_list_dependencies,
    pluto_find_dependents, pluto_render_png,
]

"""
    build_server() -> Server

Constructs (but does not start) the PlutoMCP server object.
"""
function build_server()
    mcp_server(
        name="pluto-bridge",
        version="0.1.0",
        description="Live co-authoring bridge into a running Pluto.jl session: read, edit, run, and inspect notebook cells, including Pluto's reactive dependency graph.",
        tools=ALL_TOOLS,
    )
end

"""
    run_server()

Starts the PlutoMCP server over stdio (MCP's default transport). This
blocks forever reading stdin — call it as the entry point of a script an
MCP client launches as a subprocess, not interactively.
"""
run_server() = start!(build_server())
