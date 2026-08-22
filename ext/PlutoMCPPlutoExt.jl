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

const MANAGED = Dict{String,NamedTuple{(:host, :secret, :session),Tuple{String,String,Pluto.ServerSession}}}()  # session name => the server we started

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
    start_pluto(; port=nothing) -> (host, secret, session)

Starts a fresh Pluto server in this same Julia process (non-blocking —
`Pluto.run!`, not `Pluto.run`) with a random secret, and returns enough
to connect to it.
"""
function start_pluto(; port::Union{Nothing,Int}=nothing)
    port = something(port, _free_port())
    options = Pluto.Configuration.from_flat_kwargs(;
        port=port, launch_browser=false, require_secret_for_access=true)
    session = Pluto.ServerSession(; options)
    Pluto.run!(session)
    return (host="localhost:$port", secret=session.secret, session=session)
end

const _ok = PlutoMCP._ok
const _err = PlutoMCP._err
const var"@safely" = PlutoMCP.var"@safely"

pluto_start = MCPTool(
    name="pluto_start",
    description="Start a brand-new, PlutoMCP-managed Pluto server (rather than attaching to one you already have running) and connect to it. Use pluto_create_notebook next to author a notebook in it.",
    parameters=[
        ToolParameter(name="port", type="number", description="Port to run on; a free one is picked if omitted", required=false),
        ToolParameter(name="session", type="string", description="Name to refer to this connection by in later calls", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        port = haskey(args, "port") ? Int(args["port"]) : nothing
        started = start_pluto(; port=port)
        MANAGED[args["session"]] = started
        # No websocket connection yet — there's no notebook to attach to
        # until pluto_create_notebook (or pluto_new_notebook + pluto_connect)
        # runs. Just report how to reach this server.
        _ok((session=args["session"], host=started.host, secret=started.secret))
    end),
    return_type=TextContent,
)

pluto_create_notebook = MCPTool(
    name="pluto_create_notebook",
    description="Author a new notebook's full initial content in one shot (a list of cells, each code or markdown) and open it on a pluto_start-managed server — for building the initial structure of a notebook (title, sections, functions, a chart) faster than adding cells one at a time. Returns the notebook's edit URL. Follow up with the regular pluto_connect / pluto_notebook_edit tools to keep co-authoring it live.",
    parameters=[
        ToolParameter(name="cells", type="array", description="List of cell source strings, in display order", required=true),
        ToolParameter(name="cell_types", type="array", description="Same length as cells: \"code\" or \"markdown\" per cell (defaults to all \"code\")", required=false),
        ToolParameter(name="filename", type="string", description="Base filename (without .jl) for the notebook file", required=false),
        ToolParameter(name="session", type="string", description="The pluto_start session to create this notebook on", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        haskey(MANAGED, args["session"]) || error("no pluto_start session named \"$(args["session"])\" — call pluto_start first")
        started = MANAGED[args["session"]]

        cells = String.(args["cells"])
        cell_types = haskey(args, "cell_types") ? String.(args["cell_types"]) : fill("code", length(cells))
        source = PlutoMCP.notebook_source(cells; cell_types=cell_types)
        path = Pluto.SessionActions.save_upload(source; filename_base=get(args, "filename", nothing))

        notebook = Pluto.SessionActions.open(started.session, path)
        url = "http://$(started.host)/edit?id=$(notebook.notebook_id)&secret=$(started.secret)"
        _ok((notebook_id=string(notebook.notebook_id), path=path, url=url))
    end),
    return_type=TextContent,
)

PlutoMCP.extra_tools() = [pluto_start, pluto_create_notebook]

end # module PlutoMCPPlutoExt
