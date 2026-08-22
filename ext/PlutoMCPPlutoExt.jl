#=
"Managed mode": PlutoMCP starts its own Pluto server rather than attaching
to one you already have running. Only loaded when the `Pluto` package
itself is present (it's a heavy dependency; attach-only users shouldn't
need it) — a Julia package extension, not a separate package, so the
whole thing stays one MCP server with one tool list. See
`PlutoMCP.extra_tools()`, which this module overrides.

Deliberately *not* a from-scratch direct-call implementation bypassing
the WebSocket bridge (even though a self-started session could, in
principle, be driven by calling Pluto's internal functions directly,
with no protocol involved). This reuses the exact same tested
`connect_pluto` path attach mode uses, just pointed at localhost — the
lower-risk choice for now; going fully in-process is future work.
=#
module PlutoMCPPlutoExt

using PlutoMCP
using ModelContextProtocol
import Pluto
import Sockets

const MANAGED = Dict{String,NamedTuple{(:host, :secret, :session, :server),Tuple{String,String,Pluto.ServerSession,Pluto.RunningPlutoServer}}}()  # session name => the server we started

# session name => the live Notebook object. Managed mode has this in-process;
# it is what makes naming cells possible at all, since the websocket state
# carries outputs but not the reactivity graph the names come from.
const NOTEBOOKS = Dict{String,Pluto.Notebook}()

"""
    _is_name(s) -> Bool

Whether `s` is usable as a handle: a plain Julia identifier, short enough to
type. Anything else -- empty, punctuated, or long -- is not a name, and the
UUID is the honest answer instead of a mangled approximation of one.
"""
_is_name(s::AbstractString) =
    !isempty(s) && length(s) <= 32 && occursin(r"^[A-Za-z_][A-Za-z0-9_!]*$", s)

"""
    cell_labels(nb) -> Dict(cell_id => name)

Name every cell by WHAT IT DEFINES.

A UUID is a poor handle: unmemorable, unguessable, and meaningless in a diff.
Pluto already computes something better for its reactivity graph --
`ReactiveNode.definitions`, the globals a cell defines -- so `abl =
read_curve(...)` is simply the cell named `abl`, and Pluto's own one-definition
-per-cell rule is what makes those names unique.

**Every cell is always addressable by its UUID.** A name is a convenience for
the cells that happen to have one, never a replacement — so anything Pluto does
not report a definition for keeps its UUID, and that is a correct answer rather
than a failure.

**Pluto is the only source.** Do not re-derive names by parsing cell source:
Pluto owns the reactivity graph, it already exposes every declaration and
dependency, and a second implementation drifts from its semantics. Two attempts
to be clever here were built and removed:

  - names from markdown headings — `#` opens a Julia comment as well as a
    Markdown heading, so plot cells got named after an incidental comment, and
    the slugs were neither identifiers nor short;
  - names from re-parsing docstringed definitions — a docstring becomes
    `Core.@doc`, which ExpressionExplorer reports as a macrocall with no
    `definitions`, so the reparse was an attempt to out-guess Pluto. It shipped
    two bugs immediately (`Meta.parse` reads only the first form; the macro name
    is a `GlobalRef`, not a `Symbol`), and it was solving a problem Pluto solves
    itself once macros are expanded in a running notebook.

A missing name is cheap. A wrong name is not: an unnamed cell in a listing was
once read as evidence of a corrupted notebook.
"""
function cell_labels(nb::Pluto.Notebook)
    top = Pluto.updated_topology(Pluto.NotebookTopology{Pluto.Cell}(), nb, nb.cells)
    labels = Dict{String,String}()
    seen = Set{String}()
    for c in nb.cells
        node = top.nodes[c]
        defs  = sort!(String[string(d) for d in node.definitions])
        funcs = sort!(String[string(f) for f in node.funcdefs_without_signatures])
        cand = !isempty(defs) ? defs[1] : (!isempty(funcs) ? funcs[1] : "")
        id = string(c.cell_id)
        labels[id] = (_is_name(cand) && !(cand in seen)) ? (push!(seen, cand); cand) : id
    end
    return labels
end

"""
Resolve a name, a UUID, or a UUID prefix to a cell UUID. Registered into
`PlutoMCP.CELL_RESOLVERS` at load, so every tool taking a `cell_id` accepts a
name without any of them knowing this module exists. Returns `nothing` when it
cannot resolve, which tells the caller to fall through to the next resolver.
"""
function resolve_cell(session::AbstractString, ref::AbstractString)
    nb = get(NOTEBOOKS, session, nothing)
    nb === nothing && return nothing
    ids = String[string(c.cell_id) for c in nb.cells]
    ref in ids && return ref
    for (id, name) in cell_labels(nb)
        name == ref && return id
    end
    hits = filter(id -> startswith(id, ref), ids)
    length(hits) == 1 && return only(hits)
    return nothing
end

"""
Finds a free TCP port by briefly binding to it and releasing it — used
so the actual port is known *before* starting Pluto, since `Pluto.run!`'s
own auto-port-selection (`port_serversocket`) doesn't write the port it
picked back onto `session.options.server.port`. There's a small race
(something else could grab the port in between); acceptable for now.
"""
function _free_port()
    server = Sockets.listen(Sockets.localhost, 0)
    port = Sockets.getsockname(server)[2]
    close(server)
    return Int(port)
end

"""
    start_pluto(; port=nothing) -> (host, secret, session, server)

Starts a fresh Pluto server in this same Julia process (non-blocking —
`Pluto.run!`, not `Pluto.run`) with a random secret, and returns enough
to connect to it. `server` is the `RunningPlutoServer` handle `Pluto.run!`
returns; `close(server)` (see `stop_pluto`) shuts down the HTTP server and
every one of its notebooks' worker processes together.
"""
function start_pluto(; port::Union{Nothing,Int}=nothing)
    port = something(port, _free_port())
    options = Pluto.Configuration.from_flat_kwargs(;
        port=port, launch_browser=false, require_secret_for_access=true)
    session = Pluto.ServerSession(; options)
    server = Pluto.run!(session)
    return (host="localhost:$port", secret=session.secret, session=session, server=server)
end

"""Shuts down a managed Pluto server: the HTTP server and every one of its notebooks' worker processes."""
stop_pluto(started) = close(started.server)

const _ok = PlutoMCP._ok
const _err = PlutoMCP._err
const var"@safely" = PlutoMCP.var"@safely"

pluto_start = MCPTool(
    name="start",
    description="Start a brand-new, PlutoMCP-managed Pluto server (rather than attaching to one you already have running) and connect to it. Use create_notebook next to author a notebook in it.",
    parameters=[
        ToolParameter(name="port", type="number", description="Port to run on; a free one is picked if omitted", required=false),
        ToolParameter(name="session", type="string", description="Name to refer to this connection by in later calls", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        port = haskey(args, "port") ? Int(args["port"]) : nothing
        started = start_pluto(; port=port)
        MANAGED[args["session"]] = started
        # No websocket connection yet — there's no notebook to attach to
        # until create_notebook (or new_notebook + connect)
        # runs. Just report how to reach this server.
        _ok((session=args["session"], host=started.host, secret=started.secret))
    end),
    return_type=TextContent,
)

pluto_create_notebook = MCPTool(
    name="create_notebook",
    description="Author a new notebook's full initial content in one shot (a list of cells, each code or markdown) and open it on a start-managed server — for building the initial structure of a notebook (title, sections, functions, a chart) faster than adding cells one at a time. Returns the notebook's edit URL. Follow up with the regular connect / notebook_edit tools to keep co-authoring it live.",
    parameters=[
        ToolParameter(name="cells", type="array", description="List of cell source strings, in display order", required=true),
        ToolParameter(name="cell_types", type="array", description="Same length as cells: \"code\" or \"markdown\" per cell (defaults to all \"code\")", required=false),
        ToolParameter(name="filename", type="string", description="Base filename (without .jl) for the notebook file", required=false),
        ToolParameter(name="session", type="string", description="The start session to create this notebook on", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        haskey(MANAGED, args["session"]) || error("no start session named \"$(args["session"])\" — call start first")
        started = MANAGED[args["session"]]

        cells = String.(args["cells"])
        cell_types = haskey(args, "cell_types") ? String.(args["cell_types"]) : fill("code", length(cells))
        source = PlutoMCP.notebook_source(cells; cell_types=cell_types)
        path = Pluto.SessionActions.save_upload(source; filename_base=get(args, "filename", nothing))

        notebook = Pluto.SessionActions.open(started.session, path)
        NOTEBOOKS[args["session"]] = notebook
        url = "http://$(started.host)/edit?id=$(notebook.notebook_id)&secret=$(started.secret)"
        _ok((notebook_id=string(notebook.notebook_id), path=path, url=url,
             cells=cell_labels(notebook)))
    end),
    return_type=TextContent,
)

pluto_open_notebook = MCPTool(
    name="open_notebook",
    description="Open an existing .jl notebook file by path on a start-managed server and connect to it. Use this instead of create_notebook when the notebook already exists on disk.",
    parameters=[
        ToolParameter(name="path", type="string", description="Path to the existing notebook .jl file", required=true),
        ToolParameter(name="session", type="string", description="The start session to open this notebook on, and the name to refer to the resulting connection by", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        haskey(MANAGED, args["session"]) || error("no start session named \"$(args["session"])\" — call start first")
        started = MANAGED[args["session"]]

        notebook = Pluto.SessionActions.open(started.session, args["path"])
        NOTEBOOKS[args["session"]] = notebook
        conn = PlutoMCP.connect_pluto(started.host, started.secret, string(notebook.notebook_id))
        PlutoMCP.SESSIONS[args["session"]] = conn
        url = "http://$(started.host)/edit?id=$(notebook.notebook_id)&secret=$(started.secret)"
        _ok((notebook_id=string(notebook.notebook_id), url=url, cell_count=length(PlutoMCP.read_notebook(conn))))
    end),
    return_type=TextContent,
)

pluto_stop = MCPTool(
    name="stop",
    description="Shut down a start-managed Pluto server: its HTTP server and every one of its notebooks' worker processes. Use this when you're done with a managed session, instead of leaving it running.",
    parameters=[ToolParameter(name="session", type="string", description="The start session to shut down", required=false, default="default")],
    handler=(args -> @safely begin
        haskey(MANAGED, args["session"]) || error("no start session named \"$(args["session"])\" — call start first")
        stop_pluto(MANAGED[args["session"]])
        delete!(MANAGED, args["session"])
        haskey(NOTEBOOKS, args["session"]) && delete!(NOTEBOOKS, args["session"])
        haskey(PlutoMCP.SESSIONS, args["session"]) && delete!(PlutoMCP.SESSIONS, args["session"])
        _ok((ok=true,))
    end),
    return_type=TextContent,
)

pluto_cells = MCPTool(
    name="cells",
    description="List a managed notebook's cells by NAME -- the global each one defines (`abl`, `throughput`, `read_curve()`), not a UUID -- in display order. Names are accepted anywhere a cell_id is, so cells can be addressed the way the notebook reads. Cells defining nothing (markdown, plots) fall back to a heading slug or position.",
    parameters=[ToolParameter(name="session", type="string", description="Which managed session to inspect", required=false, default="default")],
    handler=(args -> @safely begin
        haskey(NOTEBOOKS, args["session"]) || error("no managed notebook for session \"$(args["session"])\" — use create_notebook or open_notebook (naming needs the in-process notebook, so it is managed mode only)")
        nb = NOTEBOOKS[args["session"]]
        labels = cell_labels(nb)
        _ok([(name=labels[string(c.cell_id)], cell_id=string(c.cell_id), position=i,
              first_line=first(split(c.code, "\n"), 1)[1])
             for (i, c) in enumerate(nb.cells)])
    end),
    return_type=TextContent,
)

function __init__()
    push!(PlutoMCP.CELL_RESOLVERS, resolve_cell)
end

PlutoMCP.extra_tools() = [pluto_start, pluto_create_notebook, pluto_open_notebook, pluto_cells, pluto_stop]

end # module PlutoMCPPlutoExt
