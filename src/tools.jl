#=
The MCP surface. Each handler is a few lines, because Pluto does the work.

Conventions, kept close to the built-in notebook tools:

  cell_id / new_source / cell_type / edit_mode   as in NotebookEdit
  read                                            lists cells, runs nothing
  a cell_id may be a NAME, a UUID, or a UUID prefix
=#

_ok(x) = TextContent(type="text", text=JSON3.write(x))
_err(msg) = TextContent(type="text", text=JSON3.write(Dict("error" => true, "message" => msg)))

# A Pluto-side problem (unknown cell, cell threw, no session) is something the
# calling agent should read and react to, not a transport failure.
macro safely(body)
    quote
        try
            $(esc(body))
        catch e
            _err(sprint(showerror, e))
        end
    end
end

_sess(args) = get(args, "session", "default")
_block(args) = Float64(get(args, "block", 1.0))

"""Shape a run result the same way whether it finished inside the deadline or not."""
function _run_result(nb, targets, finished, waited)
    labels = cell_labels(nb)
    base = (finished = finished,
            waited_s = round(waited; digits=2),
            ran = length(targets),
            cells = [cell_info(nb, c, labels) for c in targets])
    finished ?
        merge(base, (errored = [labels[string(c.cell_id)] for c in targets if c.errored],)) :
        merge(base, (still_running = [labels[string(c.cell_id)] for c in targets if c.running || c.queued],
                     hint = "Still running — the browser is already showing it. Call status to see when it finishes; nothing is lost by waiting."))
end

const CELL_REF_DOC = "A cell NAME (a global it defines, e.g. \"throughput\"), a full UUID, or an unambiguous UUID prefix."

pluto_start = MCPTool(
    name="start",
    description="""Start a Pluto server inside this process and drive it by calling Pluto directly.

The HTTP server exists only so a human can open the notebook in a browser; no tool here talks to it over the network. Returns a host and secret. Follow with open or create.""",
    parameters=[
        ToolParameter(name="port", type="number", description="Port for the browser UI; a free one is picked if omitted", required=false),
        ToolParameter(name="session", type="string", description="Name for this session, to refer to it in later calls", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        s = start_session(_sess(args); port = haskey(args, "port") ? Int(args["port"]) : nothing)
        _ok((session=_sess(args), host=s.host, secret=s.secret))
    end),
    return_type=TextContent,
)

pluto_open = MCPTool(
    name="open",
    description="Open an existing .jl notebook and run it. Returns its browser URL and its cells. Give the URL to the user — they can watch every later edit appear live.",
    parameters=[
        ToolParameter(name="path", type="string", description="Path to the notebook .jl file", required=true),
        ToolParameter(name="run", type="boolean", description="Run all cells on open (default true)", required=false, default=true),
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        s = _session(_sess(args))
        nb = Pluto.SessionActions.open(s.session, args["path"]; run_async = !get(args, "run", true))
        s.notebook[] = nb
        _ok((url=notebook_url(s, nb), path=nb.path, cells=cells_info(nb)))
    end),
    return_type=TextContent,
)

pluto_create = MCPTool(
    name="create",
    description="""Author a whole notebook in one call and open it — faster than adding cells one at a time.

Pluto runs cells in DEPENDENCY order, not top-to-bottom, and allows only one definition of a global per cell. Prefer `x = let ... end` over `begin ... end` for a one-off computation: a `let` defines exactly one name, so it creates one dependency edge instead of several.

Dependencies install themselves: just write `using Plots` in a cell. Pluto installs it into an environment scoped to this notebook and records the resolved versions inside the notebook file, so no Pkg.add step and no restart are needed. Do NOT call Pkg.activate unless the notebook must share an existing project — it switches Pluto's package management off, and the notebook stops recording its own dependencies.""",
    parameters=[
        ToolParameter(name="cells", type="array", description="Cell sources, in display order", required=true),
        ToolParameter(name="cell_types", type="array", description="Same length as cells: \"code\" or \"markdown\" (default: all code)", required=false),
        ToolParameter(name="filename", type="string", description="Base filename, without .jl", required=false),
        ToolParameter(name="block", type="number", description="Seconds to wait for the run before returning (default 1)", required=false, default=1),
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        name = _sess(args); s = _session(name)
        cells = String.(args["cells"])
        types = haskey(args, "cell_types") && args["cell_types"] !== nothing ?
                String.(args["cell_types"]) : fill("code", length(cells))
        src = notebook_source(cells; cell_types=types)
        path = Pluto.SessionActions.save_upload(src; filename_base=get(args, "filename", nothing))
        nb = Pluto.SessionActions.open(s.session, path; run_async=true)
        s.notebook[] = nb
        t0 = time()
        while any(c -> c.running || c.queued, nb.cells) && time() - t0 < _block(args)
            sleep(0.02)
        end
        finished = !any(c -> c.running || c.queued, nb.cells)
        _ok((url=notebook_url(s, nb), path=nb.path, finished=finished,
             cells=cells_info(nb)))
    end),
    return_type=TextContent,
)

pluto_read = MCPTool(
    name="read",
    description="""List the notebook's cells as they are RIGHT NOW. Runs nothing.

The notebook object is read directly, so edits a human just made in the browser are already included — there is no cached view to refresh.

Each cell reports a `name` (the global it defines, when Pluto reports one) and a `cell_id`. Either addresses it. Output bodies are described by size, not included; use output or png for one cell's result.""",
    parameters=[ToolParameter(name="session", type="string", description="Which session", required=false, default="default")],
    handler=(args -> @safely _ok(cells_info(_notebook(_sess(args))))),
    return_type=TextContent,
)

pluto_edit = MCPTool(
    name="edit",
    description="""Replace, insert or delete a cell, then run it — same shape as NotebookEdit.

Returns as soon as the cell finishes or `block` seconds pass, whichever comes first. The file is saved and any open browser tab updates either way; a slow cell keeps running and status will report it.

Editing one cell re-runs whatever depends on it, so a small edit can be a large run.""",
    parameters=[
        ToolParameter(name="cell_id", type="string", description="Target cell. $CELL_REF_DOC For insert, the cell to insert AFTER; omit to insert at the very start.", required=false),
        ToolParameter(name="new_source", type="string", description="New cell source (ignored for edit_mode=delete)", required=false, default=""),
        ToolParameter(name="edit_mode", type="string", description="\"replace\", \"insert\" or \"delete\"", required=false, default="replace"),
        ToolParameter(name="cell_type", type="string", description="\"code\" or \"markdown\" (markdown wraps the source in md\"\"\")", required=false, default="code"),
        ToolParameter(name="block", type="number", description="Seconds to wait for the run (default 1)", required=false, default=1),
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        name = _sess(args); s = _session(name); nb = _notebook(name)
        mode = get(args, "edit_mode", "replace")
        code = get(args, "new_source", "")
        get(args, "cell_type", "code") == "markdown" && (code = _wrap_markdown(code))
        ref = get(args, "cell_id", nothing)

        if mode == "delete"
            c = resolve_cell(nb, ref)
            deleteat!(nb.cell_order, findfirst(==(c.cell_id), nb.cell_order))
            delete!(nb.cells_dict, c.cell_id)
            # Hand the removed cell to the run: the topology then sees it defines
            # nothing, so its globals are released and dependents re-run.
            Pluto.update_save_run!(s.session, nb, Pluto.Cell[c]; run_async=false)
            _ok((deleted=string(c.cell_id), remaining=length(nb.cells)))
        elseif mode == "insert"
            c = Pluto.Cell(code)
            at = ref === nothing ? 0 : findfirst(==(resolve_cell(nb, ref).cell_id), nb.cell_order)
            insert!(nb.cell_order, at + 1, c.cell_id)
            nb.cells_dict[c.cell_id] = c
            finished, waited = run_with_deadline(name, Pluto.Cell[c]; block=_block(args))
            _ok(_run_result(nb, [c], finished, waited))
        else
            c = resolve_cell(nb, ref)
            c.code = code
            finished, waited = run_with_deadline(name, Pluto.Cell[c]; block=_block(args))
            _ok(_run_result(nb, [c], finished, waited))
        end
    end),
    return_type=TextContent,
)

pluto_run = MCPTool(
    name="run",
    description="""Run cells and return their results.

Waits up to `block` seconds. Most cells finish well inside that and come back complete; a slow one returns `finished=false` and keeps running — that is not an error and not a timeout. Poll status, or just carry on: the browser shows progress live.""",
    parameters=[
        ToolParameter(name="cells", type="array", description="Cell references. $CELL_REF_DOC Omit to run the whole notebook.", required=false),
        ToolParameter(name="block", type="number", description="Seconds to wait (default 1). Raise it for a cell you expect to be slow.", required=false, default=1),
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        name = _sess(args); nb = _notebook(name)
        targets = haskey(args, "cells") && args["cells"] !== nothing ?
            Pluto.Cell[resolve_cell(nb, String(r)) for r in args["cells"]] : copy(nb.cells)
        finished, waited = run_with_deadline(name, targets; block=_block(args))
        _ok(_run_result(nb, targets, finished, waited))
    end),
    return_type=TextContent,
)

pluto_status = MCPTool(
    name="status",
    description="""Is anything still running, and what has changed since you last looked?

Covers changes made by a HUMAN in the browser as well as your own: it is backed by Pluto's StateChangeEvent hook, so it costs no polling. Pass the previous result's `now` back as `since` to count only what happened in between.

Set `wait` to block until the notebook goes idle — the right way to follow up a run that returned `finished=false`.""",
    parameters=[
        ToolParameter(name="since", type="number", description="Unix time to count changes from; omit for everything recorded", required=false),
        ToolParameter(name="wait", type="number", description="Seconds to wait for the notebook to become idle (default 0, do not wait)", required=false, default=0),
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        name = _sess(args); nb = _notebook(name)
        deadline = time() + Float64(get(args, "wait", 0))
        while !isempty(busy_cells(nb)) && time() < deadline
            sleep(0.05)
        end
        v = get(CHANGES, String(name), Float64[])
        since = haskey(args, "since") && args["since"] !== nothing ? Float64(args["since"]) : -Inf
        labels = cell_labels(nb)
        busy = busy_cells(nb)
        _ok((idle = isempty(busy),
             running = [labels[string(c.cell_id)] for c in busy],
             errored = [labels[string(c.cell_id)] for c in nb.cells if c.errored],
             changes = count(>(since), v),
             now = time(),
             last_change = isempty(v) ? nothing : last(v)))
    end),
    return_type=TextContent,
)

pluto_output = MCPTool(
    name="output",
    description="""One cell's output.

Images come back viewable. SVG is withheld by default — a plot is ~100 KB of markup most clients cannot render inline — so call png for a picture, or pass raw=true if you genuinely want the markup.""",
    parameters=[
        ToolParameter(name="cell_id", type="string", description=CELL_REF_DOC, required=true),
        ToolParameter(name="raw", type="boolean", description="Return an SVG result's full markup", required=false, default=false),
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        nb = _notebook(_sess(args)); c = resolve_cell(nb, args["cell_id"])
        mime = string(c.output.mime); body = c.output.body
        if mime == "image/svg+xml" && !get(args, "raw", false)
            n = body === nothing ? 0 : (body isa AbstractString ? sizeof(body) : length(body))
            _ok((mime=mime, errored=c.errored, bytes=n, body="<SVG withheld: $n bytes>",
                 hint="Call png for a viewable image, or output with raw=true for the markup."))
        elseif startswith(mime, "image/") && body isa Vector{UInt8}
            ImageContent(data=body, mime_type=mime)
        else
            _ok((mime=mime, errored=c.errored,
                 body = body isa Vector{UInt8} ? String(copy(body)) : string(body)))
        end
    end),
    return_type=Content,
)

pluto_png = MCPTool(
    name="png",
    description="Render a plotting cell as a PNG, whatever its native output format. Re-runs the cell's code wrapped in savefig, inside a temporary cell that is always removed. Cheap for a plot, wasteful if the cell also does expensive work.",
    parameters=[
        ToolParameter(name="cell_id", type="string", description=CELL_REF_DOC, required=true),
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        name = _sess(args); s = _session(name); nb = _notebook(name)
        c = resolve_cell(nb, args["cell_id"])
        tmp = tempname() * ".png"
        probe = Pluto.Cell("""begin
    local __fig = begin
$(c.code)
    end
    savefig(__fig, $(repr(tmp)))
    nothing
end""")
        push!(nb.cell_order, probe.cell_id); nb.cells_dict[probe.cell_id] = probe
        try
            Pluto.update_save_run!(s.session, nb, Pluto.Cell[probe]; run_async=false, save=false)
            probe.errored && error("render failed: $(probe.output.body)")
            isfile(tmp) || error("savefig wrote nothing — is this a plotting cell?")
            ImageContent(data=read(tmp), mime_type="image/png")
        finally
            # Always remove the probe: a temp cell left in someone's notebook is
            # a cell they have to explain to themselves later.
            i = findfirst(==(probe.cell_id), nb.cell_order)
            i === nothing || deleteat!(nb.cell_order, i)
            delete!(nb.cells_dict, probe.cell_id)
            Pluto.update_save_run!(s.session, nb, Pluto.Cell[probe]; run_async=false)
            rm(tmp; force=true)
        end
    end),
    return_type=Content,
)

pluto_stop = MCPTool(
    name="stop",
    description="Shut down the session's Pluto server and its notebook worker processes. Do this when finished rather than leaving a server running.",
    parameters=[ToolParameter(name="session", type="string", description="Which session", required=false, default="default")],
    handler=(args -> @safely begin
        stop_session(_sess(args)); _ok((ok=true,))
    end),
    return_type=TextContent,
)

const ALL_TOOLS = [pluto_start, pluto_open, pluto_create, pluto_read, pluto_edit,
                   pluto_run, pluto_status, pluto_output, pluto_png, pluto_stop]

function build_server()
    mcp_server(
        name="pluto",
        version="0.2.0",
        description="Author and drive Pluto.jl notebooks. Pluto runs in-process and is called directly, so reads are always current, runs report honestly whether they finished, and edits appear instantly in an open browser tab — including to a human watching.",
        tools=ALL_TOOLS,
    )
end

"""
    run_server()

Serve over stdio, MCP's default transport. Blocks forever reading stdin: this is
the entry point for a client that launches the server as a subprocess.
"""
run_server() = start!(build_server())
