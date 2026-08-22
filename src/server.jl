#=
The MCP server: same tested client.jl functions, exposed as discoverable
tools any MCP client (Claude, Claude Desktop, etc.) can call directly.

Sessions are named (default: "default") so more than one Pluto notebook
can be driven at once; each is a live `Conn` held in `SESSIONS` for the
life of the server process — the whole point of a long-running MCP server
is that this state persists across tool calls.

CONCURRENT EDITING IS THE POINT, NOT AN EDGE CASE. The notebook is open in a
browser and may be open to other sessions; a human can rewrite, reorder or
delete any cell at any moment, including between two of our own calls. So:

  - cached state is a snapshot, never the truth. Re-read before acting on it.
  - a cell that is missing, renamed, or different from what we last wrote is
    the NORMAL outcome of someone else working, not damage to be repaired.
  - never "restore" a notebook to what a tool remembers. Report the difference
    and let the human decide.

This is not hypothetical: a cell whose markdown had been deliberately folded
into a function docstring, plus a cell the user had deleted in the UI, were once
read as a corrupted file and "fixed" — undoing intentional work. Absence is what
deliberate editing looks like from the outside, so absence is never evidence of
corruption.
=#

const SESSIONS = Dict{String,Conn}()

function _conn(session::AbstractString)
    haskey(SESSIONS, session) || error("no session named \"$session\" — call connect first")
    return SESSIONS[session]
end

"""
Hooks that turn a human-written cell reference into a cell UUID.

A UUID is a poor handle: not memorable, not greppable, and not stable across a
notebook still being authored. Pluto already knows a far better name for most
cells -- the symbol each one DEFINES -- but only the in-process API exposes it,
so the Pluto extension registers a resolver here instead of this file reaching
for something the websocket state never carries.

Empty by default: with no resolver installed every reference passes through
untouched and behaviour is exactly as before.
"""
const CELL_RESOLVERS = Function[]

"""
    _cell(session, ref) -> String

Resolve `ref` -- a UUID, a UUID prefix, or a name like "throughput" -- to a
cell UUID. An unresolvable reference is returned unchanged so it fails in the
tool that uses it, with that tool's own error message, rather than here.
"""
function _cell(session::AbstractString, ref)
    ref === nothing && return nothing
    s = String(ref)
    for r in CELL_RESOLVERS
        hit = try r(session, s) catch; nothing end
        hit === nothing || return hit
    end
    return s
end

_cellrefs(session::AbstractString, refs) = String[_cell(session, r) for r in refs]

"""
    _sniff_mime(bytes, declared) -> String

Recover a byte body's real type when the declared one is not credible. Only
consulted when a raw byte vector arrives labelled as text, which means the mime
was absent from the notebook state rather than genuinely text.
"""
function _sniff_mime(body::Vector{UInt8}, declared::AbstractString)
    length(body) < 4 && return declared
    body[1:4] == UInt8[0x89, 0x50, 0x4e, 0x47] && return "image/png"
    body[1:3] == UInt8[0xff, 0xd8, 0xff]       && return "image/jpeg"
    head = lowercase(String(copy(body[1:min(end, 512)])))
    (occursin("<svg", head) || (occursin("<?xml", head) && occursin("svg", head))) && return "image/svg+xml"
    return declared
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
    name="connect",
    description="Connect to a running Pluto session and open one of its notebooks. Call this first.",
    parameters=[
        ToolParameter(name="host", type="string", description="Pluto server host:port, e.g. localhost:1234", required=true),
        ToolParameter(name="secret", type="string", description="Pluto's access secret (from its URL's ?secret= query param)", required=true),
        ToolParameter(name="notebook_id", type="string", description="Notebook UUID (see list_notebooks)", required=true),
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
    name="list_notebooks",
    description="List notebooks currently open on a running Pluto server, as {notebook_id => path}.",
    parameters=[
        ToolParameter(name="host", type="string", description="Pluto server host:port", required=true),
        ToolParameter(name="secret", type="string", description="Pluto's access secret", required=true),
    ],
    handler=(args -> @safely _ok(list_notebooks(args["host"], args["secret"]))),
    return_type=TextContent,
)

pluto_new_notebook = MCPTool(
    name="new_notebook",
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
    name="read_notebook",
    description="List all cells (id, code, current output mime, errored) in display order. Does not run anything.",
    parameters=[ToolParameter(name="session", type="string", description="Which connect session to use", required=false, default="default")],
    handler=(args -> @safely _ok(read_notebook(_conn(args["session"])))),
    return_type=TextContent,
)

pluto_notebook_edit = MCPTool(
    name="notebook_edit",
    description="Replace, insert, or delete a single Pluto cell — same shape as the built-in NotebookEdit tool for .ipynb files. insert adds a cell after cell_id (or at the very start if cell_id is omitted). Does not run the cell; call run_cells after.",
    parameters=[
        ToolParameter(name="new_source", type="string", description="New cell code (ignored for edit_mode=delete)", required=false, default=""),
        ToolParameter(name="cell_id", type="string", description="Target cell (required for replace/delete; anchor for insert)", required=false),
        ToolParameter(name="cell_type", type="string", description="\"code\" or \"markdown\" (markdown is emulated: source gets wrapped in md\"...\")", required=false, default="code"),
        ToolParameter(name="edit_mode", type="string", description="\"replace\", \"insert\", or \"delete\"", required=false, default="replace"),
        ToolParameter(name="code_folded", type="boolean", description="Collapse this cell's code in the UI so only its rendered output shows (purely cosmetic — the source is still always readable via read_notebook/get_output, folding doesn't hide it from tools). Omit to leave unchanged on replace, or default to unfolded on insert.", required=false),
        ToolParameter(name="session", type="string", description="Which connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        result = notebook_edit(_conn(args["session"]), get(args, "new_source", "");
            cell_id=_cell(args["session"], get(args, "cell_id", nothing)), cell_type=get(args, "cell_type", "code"),
            edit_mode=get(args, "edit_mode", "replace"), code_folded=get(args, "code_folded", nothing))
        _ok((cell_id=result,))
    end),
    return_type=TextContent,
)

pluto_run_cells = MCPTool(
    name="run_cells",
    description="Run (or re-run) the given cells. Returns immediately — poll with get_output for results.",
    parameters=[
        ToolParameter(name="cell_ids", type="array", description="List of cell UUIDs to run", required=true),
        ToolParameter(name="session", type="string", description="Which connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        run_cells(_conn(args["session"]), _cellrefs(args["session"], args["cell_ids"]))
        _ok((ok=true,))
    end),
    return_type=TextContent,
)

pluto_run_all = MCPTool(
    name="run_all",
    description="Run every cell in the notebook. Returns immediately — poll individual cells with get_output for results. Use this after restart_kernel to bring the notebook back to a fully-evaluated state.",
    parameters=[ToolParameter(name="session", type="string", description="Which connect session to use", required=false, default="default")],
    handler=(args -> @safely begin
        run_all(_conn(args["session"]))
        _ok((ok=true,))
    end),
    return_type=TextContent,
)

pluto_restart_kernel = MCPTool(
    name="restart_kernel",
    description="Kill and restart the notebook's worker process (like Pluto's UI \"restart\" button, or a Jupyter kernel restart): all global state is lost. Cells are not re-run automatically — call run_all afterward.",
    parameters=[ToolParameter(name="session", type="string", description="Which connect session to use", required=false, default="default")],
    handler=(args -> @safely begin
        restart_process(_conn(args["session"]))
        _ok((ok=true,))
    end),
    return_type=TextContent,
)

pluto_get_output = MCPTool(
    name="get_output",
    description="Wait for a cell to finish running and return its output. Text/structured results come back as text; image (SVG/PNG/etc) results come back as a viewable image. errored=true means the cell threw — the message is in the returned text.",
    parameters=[
        ToolParameter(name="cell_id", type="string", description="Target cell UUID", required=true),
        ToolParameter(name="timeout", type="number", description="Seconds to wait", required=false, default=60),
        ToolParameter(name="raw", type="boolean", description="Return an SVG result's full markup instead of a size summary. SVG plots are ~100 KB of text that most clients cannot render inline; prefer render_png for a viewable image.", required=false, default=false),
        ToolParameter(name="session", type="string", description="Which connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        out = get_output(_conn(args["session"]), _cell(args["session"], args["cell_id"]); timeout=Float64(get(args, "timeout", 60)))
        mime = out.mime
        # A raw byte body labelled text/* is a contradiction, and in practice it
        # means the mime went missing from a patch and client.jl fell back to its
        # "text/plain" default. Sniff the bytes rather than handing back
        # "<115763 bytes, mime=text/plain>", which is useless AND misleading:
        # it reads like a size cap when the real problem is a wrong label.
        if out.body isa Vector{UInt8} && !startswith(mime, "image/")
            mime = _sniff_mime(out.body, mime)
        end
        # SVG is text, so it would otherwise be returned in full: a plot is
        # ~100 KB of markup that most clients cannot render inline and that
        # costs a large chunk of an agent's context to receive. Summarise it
        # and point at render_png, unless raw was explicitly asked for.
        if mime == "image/svg+xml" && !get(args, "raw", false)
            n = out.body isa Vector{UInt8} ? length(out.body) : sizeof(string(out.body))
            _ok((mime=mime, errored=out.errored, bytes=n,
                 body="<SVG withheld: $n bytes>",
                 hint="Call render_png for a viewable image, or get_output with raw=true for the markup."))
        elseif startswith(mime, "image/") && out.body isa Vector{UInt8}
            ImageContent(data=out.body, mime_type=mime)
        elseif out.body isa Vector{UInt8}
            _ok((mime=mime, errored=out.errored,
                 warning="cell returned $(length(out.body)) raw bytes labelled \"$(out.mime)\", " *
                         "which is not a renderable type and not text. The mime was most likely " *
                         "missing from the notebook state. Re-run the cell, or reconnect if this persists.",
                 body=String(copy(out.body))))
        else
            _ok((mime=mime, errored=out.errored, body=string(out.body)))
        end
    end),
    return_type=Content,
)

pluto_search_cells = MCPTool(
    name="search_cells",
    description="Find cells whose source matches a substring or regex.",
    parameters=[
        ToolParameter(name="pattern", type="string", description="Substring or regex to search cell source for", required=true),
        ToolParameter(name="session", type="string", description="Which connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely _ok(search_cells(_conn(args["session"]), args["pattern"]))),
    return_type=TextContent,
)

pluto_find_definition = MCPTool(
    name="find_definition",
    description="Find the cell that defines a given global variable/function name, using Pluto's own reactive dependency graph (exact, not text search). Pluto guarantees at most one cell defines any given name.",
    parameters=[
        ToolParameter(name="name", type="string", description="Global variable or function name", required=true),
        ToolParameter(name="session", type="string", description="Which connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        d = find_definition(_conn(args["session"]), args["name"])
        d === nothing ? _ok((found=false,)) : _ok((found=true, id=d.id, code=d.code))
    end),
    return_type=TextContent,
)

pluto_list_dependencies = MCPTool(
    name="list_dependencies",
    description="All names a cell references, mapped to the cell_id that defines each (or null if it resolves outside the notebook, e.g. Base/a package).",
    parameters=[
        ToolParameter(name="cell_id", type="string", description="Target cell UUID", required=true),
        ToolParameter(name="session", type="string", description="Which connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely _ok(list_dependencies(_conn(args["session"]), _cell(args["session"], args["cell_id"])))),
    return_type=TextContent,
)

pluto_find_dependents = MCPTool(
    name="find_dependents",
    description="Cells that depend on (reference) a given name.",
    parameters=[
        ToolParameter(name="name", type="string", description="Global variable or function name", required=true),
        ToolParameter(name="session", type="string", description="Which connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely _ok(find_dependents(_conn(args["session"]), args["name"]))),
    return_type=TextContent,
)

pluto_render_png = MCPTool(
    name="render_png",
    description="Get a cell's plot as a guaranteed PNG image, regardless of its native output format (e.g. SVG). Re-runs the cell's code wrapped in savefig — cheap for a plot, wasteful for an expensive underlying computation.",
    parameters=[
        ToolParameter(name="cell_id", type="string", description="Target cell UUID", required=true),
        ToolParameter(name="session", type="string", description="Which connect session to use", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        tmp_path = tempname() * ".png"
        try
            save_png(_conn(args["session"]), _cell(args["session"], args["cell_id"]), tmp_path)
            ImageContent(data=read(tmp_path), mime_type="image/png")
        finally
            isfile(tmp_path) && rm(tmp_path)
        end
    end),
    return_type=Content,
)

const ALL_TOOLS = [
    pluto_connect, pluto_new_notebook, pluto_list_notebooks, pluto_read_notebook,
    pluto_notebook_edit, pluto_run_cells, pluto_run_all, pluto_restart_kernel, pluto_get_output,
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
        description="Live co-authoring bridge into a Pluto.jl session: read, edit, run, and inspect notebook cells, including Pluto's reactive dependency graph. Attach to an already-running session, or (when the Pluto package is installed) start a fresh managed one.",
        tools=vcat(ALL_TOOLS, hasmethod(extra_tools, Tuple{}) ? extra_tools() : MCPTool[]),
    )
end

"""
    run_server()

Starts the PlutoMCP server over stdio (MCP's default transport). This
blocks forever reading stdin — call it as the entry point of a script an
MCP client launches as a subprocess, not interactively.
"""
run_server() = start!(build_server())
