#=
Client for Pluto.jl's internal WebSocket "Dynamic" protocol — the one its
own browser frontend uses. No Pluto source changes; works against any
already-running `Pluto.run()` session.

Design notes (why these choices):
- Cells are addressed by UUID at the wire level (Pluto has no name-based
  addressing), but this API adds name-based lookup on top, built entirely
  from data Pluto already pushes to every client: `cell_dependencies`
  (upstream_cells_map / downstream_cells_map, keyed by *variable name*,
  not just one "rootassignee") is the same topology Pluto's reactivity
  engine uses internally. Pluto also guarantees each global name has at
  most one defining cell, so name -> cell lookup is unambiguous.
- `save_png` exists because binary cell output (SVG bytes from Plots.jl)
  cannot be viewed directly by most tooling; it re-runs the cell's code
  wrapped in `savefig(..., path)` in a throwaway cell, since Pluto keeps
  no raster form of a plot around otherwise.
- Naming follows Claude Code's own tools where a real analog exists:
  `notebook_edit` mirrors the built-in `NotebookEdit` tool's shape exactly
  (`cell_id`, `cell_type`, `edit_mode` ∈ replace/insert/delete, `new_source`),
  and `read_notebook` mirrors `Read`'s behavior on a `.ipynb` (cells +
  their current outputs together, no execution triggered).
=#

mutable struct Conn
    ws::HTTP.WebSockets.WebSocket
    task::Task
    client_id::String
    notebook_id::String
    state::Ref{Any}   # mirrors the server's notebook_to_js(notebook) dict
    # Set by `_recv_loop` when the socket closes or the loop dies. Without it,
    # a dead connection is indistinguishable from a slow cell: `get_output`
    # polls a frozen `state` and reports "timed out waiting for cell X", which
    # sends you looking at the notebook instead of at the transport.
    dead::Ref{Any}    # nothing while healthy, else the Exception / :closed
end

struct CellOutput
    mime::String
    body::Any          # String, Vector{UInt8}, or nothing
    errored::Bool
end

# ---------------------------------------------------------------- wire ----

# Generic JSON-Patch application, matching what Firebasey sends:
# {"op": "add"|"replace"|"remove", "path": [...], "value": ...}
# An empty path means "replace the whole state" (the initial full sync).
function _apply_patch!(conn::Conn, patch)
    path = patch["path"]
    op = patch["op"]
    if isempty(path)
        conn.state[] = patch["value"]
        return
    end
    container = conn.state[]
    for key in path[1:end-1]
        container = get!(container, key, Dict{Any,Any}())
    end
    lastkey = path[end]
    if op == "remove"
        delete!(container, lastkey)
    else # "add" or "replace"
        container[lastkey] = patch["value"]
    end
end

"""
Applies every incoming patch to `conn.state[]` for the connection's lifetime.

This loop must NEVER block. It previously pushed each decoded message into a
bounded `Channel{Any}(256)` that nothing ever read: after 256 messages `put!`
blocked forever, the loop stopped applying patches, and `conn.state[]` froze
with every cell still marked `queued` by `run_cells`. The visible symptoms were
`get_output` timing out on cells that had finished milliseconds earlier, and the
server growing to several GB as undrained websocket data backed up. If a message
log is ever wanted here, it has to be a DROPPING buffer, never a blocking one.
"""
function _recv_loop(conn::Conn)
    try
        for msg in conn.ws
            data = MsgPack.unpack(msg)
            if get(data, "type", nothing) == "notebook_diff" && haskey(data, "message")
                for patch in get(data["message"], "patches", [])
                    try
                        _apply_patch!(conn, patch)
                    catch e
                        @warn "failed to apply patch, skipping" patch exception = (e, catch_backtrace())
                    end
                end
            end
        end
        conn.dead[] = :closed
    catch e
        conn.dead[] = e
        rethrow()
    end
end

function _send(conn::Conn, type::String, body::Dict; notebook_id=conn.notebook_id)
    msg = Dict(
        "type" => type,
        "client_id" => conn.client_id,
        "request_id" => string(uuid4()),
        "body" => body,
        "notebook_id" => notebook_id,
    )
    HTTP.WebSockets.send(conn.ws, MsgPack.pack(msg))
    return nothing
end

"""
    connect_pluto(host, secret, notebook_id) -> Conn

`host` like "localhost:1234". Opens the websocket, sends the initial
`connect` handshake, then `reset_shared_state` to force Pluto to push a
full notebook snapshot (the connect ack alone does not — this matches what
the frontend does on (re)connect, see Editor.js `on_reconnect`).

Uses `HTTP.WebSockets.open`'s do-block/callback form, not the "returns a
handle directly" form — the latter only exists in HTTP.jl v2.x, and this
package also needs to work with v1.x (which Pluto itself pins to when
both are in the same environment, i.e. whenever managed mode is used).
The do-block runs for the connection's whole lifetime inside a background
task; `ready` hands the constructed `Conn` back to the caller once the
socket exists, without waiting for the (indefinite) message loop.
"""
function connect_pluto(host::String, secret::String, notebook_id::String)
    url = "ws://$host/?secret=$secret"
    client_id = string(uuid4())[1:8]
    state = Ref{Any}(Dict{Any,Any}())
    dead = Ref{Any}(nothing)
    ready = Channel{Conn}(1)

    @async HTTP.WebSockets.open(url) do ws
        conn = Conn(ws, current_task(), client_id, notebook_id, state, dead)
        put!(ready, conn)
        _recv_loop(conn)
    end

    conn = take!(ready)
    _send(conn, "connect", Dict(); notebook_id=notebook_id)
    sleep(0.3)
    resync!(conn)
    return conn
end

"""Force a fresh full-state sync from the server (also self-heals after a skipped patch)."""
function resync!(conn::Conn)
    _send(conn, "reset_shared_state", Dict())
    t0 = time()
    while time() - t0 < 10 && !haskey(conn.state[], "cell_order")
        sleep(0.1)
    end
    return conn
end

list_notebooks(host::String, secret::String) = MsgPack.unpack(HTTP.get("http://$host/notebooklist?secret=$secret").body)

"""
    new_notebook(host, secret) -> notebook_id

Creates a brand-new empty notebook on the server (via Pluto's `GET /new`,
which 302-redirects to `./edit?id=<uuid>`) and returns its id, ready to
pass to `connect_pluto`.
"""
function new_notebook(host::String, secret::String)
    r = HTTP.get("http://$host/new?secret=$secret"; redirect=false, status_exception=false)
    loc = HTTP.header(r, "Location")
    m = match(r"id=([0-9a-fA-F-]{36})", loc)
    m === nothing && error("new_notebook: couldn't parse notebook id from redirect \"$loc\"")
    return String(m.captures[1])
end

close_pluto(conn::Conn) = close(conn.ws)

"""
    notebook_source(cells; cell_types=fill("code", length(cells))) -> String

Renders a valid Pluto `.jl` notebook file's *text* from a plain list of
cell source strings — no live connection involved. Useful for authoring
a notebook's initial structure in one shot (batch, via `save_upload`/
`SessionActions.open`) rather than cell-by-cell over the WebSocket
protocol, which is slower and (per `notebook_edit`'s docs) has to be
paced to avoid racing Pluto's own server-side handling.

`cell_types[i] == "markdown"` auto-wraps that cell in `md"..."` (same
rule as `notebook_edit`). Cell UUIDs are generated fresh; display order
matches `cells`' order.
"""
function notebook_source(cells::Vector{String}; cell_types::Vector{String}=fill("code", length(cells)))
    length(cell_types) == length(cells) || error("notebook_source: cell_types must have the same length as cells")
    ids = [string(uuid4()) for _ in cells]
    io = IOBuffer()
    println(io, "### A Pluto.jl notebook ###")
    println(io, "# v0.20.0")
    println(io)
    println(io, "using Markdown")
    println(io, "using InteractiveUtils")
    println(io)
    for (id, code, ctype) in zip(ids, cells, cell_types)
        source = ctype == "markdown" ? _wrap_markdown(code) : code
        println(io, "# ╔═╡ ", id)
        println(io, source)
        println(io)
    end
    println(io, "# ╔═╡ Cell order:")
    for id in ids
        println(io, "# ╠═", id)
    end
    return String(take!(io))
end

# ------------------------------------------------------------ cell CRUD ----

_wrap_markdown(src::String) = startswith(strip(src), "md\"") ? src : "md\"\"\"\n$src\n\"\"\""

"""
Applies `updates` to local `conn.state[]` immediately (optimistic, like the
real frontend's Immer-based local apply), then sends them to the server.
Without this, `conn.state[]` only reflects a mutation after the server's
own diff round-trips back over `_recv_loop` — a real race if code reads
state right after calling a mutator instead of waiting on `get_output`.
"""
function _send_update!(conn::Conn, updates)
    for u in updates
        _apply_patch!(conn, u)
    end
    _send(conn, "update_notebook", Dict("updates" => updates))
    # Firing several update_notebook messages within milliseconds of each
    # other (faster than any human typing) was observed to race against
    # Pluto's own async server-side handling and silently drop/revert
    # some of them. This pacing sidesteps it; a proper fix would confirm
    # each message server-side before sending the next.
    sleep(0.25)
    return nothing
end

"""
    notebook_edit(conn, new_source; cell_id=nothing, cell_type="code", edit_mode="replace") -> cell_id

Mirrors the built-in `NotebookEdit` tool's shape (`cell_id`, `cell_type`,
`edit_mode`, `new_source`) so the calling convention transfers directly:

- `edit_mode="replace"` (default): overwrite `cell_id`'s source. Requires `cell_id`.
- `edit_mode="insert"`: add a new cell *after* `cell_id`, or at the start of
  the notebook if `cell_id` is omitted — same rule `NotebookEdit` uses.
  Returns the new cell_id.
- `edit_mode="delete"`: remove `cell_id` (both from display order and
  `cell_inputs`). `new_source` is ignored.

`cell_type="markdown"` is emulated (Pluto has no distinct cell types —
markdown is just a cell whose code is an `md` string macro call):
`new_source` is auto-wrapped unless it already starts with `md"`.
"""
function notebook_edit(conn::Conn, new_source::String="";
    cell_id::Union{Nothing,String}=nothing, cell_type::String="code", edit_mode::String="replace",
    code_folded::Union{Nothing,Bool}=nothing)
    if edit_mode == "delete"
        cell_id === nothing && error("notebook_edit: edit_mode=\"delete\" requires cell_id")
        new_order = filter(!=(cell_id), collect(String.(get(conn.state[], "cell_order", []))))
        updates = [
            Dict("op" => "replace", "path" => ["cell_order"], "value" => new_order),
            Dict("op" => "remove", "path" => ["cell_inputs", cell_id]),
        ]
        _send_update!(conn, updates)
        return nothing
    end

    source = cell_type == "markdown" ? _wrap_markdown(new_source) : new_source

    if edit_mode == "insert"
        new_id = string(uuid4())
        current_order = collect(String.(get(conn.state[], "cell_order", [])))
        new_order = if cell_id === nothing
            vcat([new_id], current_order)               # "beginning if not specified"
        else
            idx = findfirst(==(cell_id), current_order)
            idx === nothing ? vcat(current_order, [new_id]) :
            vcat(current_order[1:idx], [new_id], current_order[idx+1:end])  # after cell_id
        end
        updates = [
            Dict("op" => "add", "path" => ["cell_inputs", new_id],
                "value" => Dict("cell_id" => new_id, "code" => source,
                    "code_folded" => something(code_folded, false), "metadata" => Dict())),
            Dict("op" => "replace", "path" => ["cell_order"], "value" => new_order),
        ]
        _send_update!(conn, updates)
        return new_id
    end

    # edit_mode == "replace"
    cell_id === nothing && error("notebook_edit: edit_mode=\"replace\" requires cell_id")
    updates = [Dict("op" => "replace", "path" => ["cell_inputs", cell_id, "code"], "value" => source)]
    if code_folded !== nothing
        push!(updates, Dict("op" => "replace", "path" => ["cell_inputs", cell_id, "code_folded"], "value" => code_folded))
    end
    _send_update!(conn, updates)
    return cell_id
end

"""
Runs `cell_ids`. Marks each as locally "pending" before sending, so
`get_output` can't mistake a stale prior result (or a fresh cell's
never-run default state) for this run having already finished — both
look identical to "not running, not queued" until the server's own
"now queued" patch arrives, which is a real race without this.
"""
function run_cells(conn::Conn, cell_ids::Vector{String})
    results = get!(conn.state[], "cell_results", Dict{Any,Any}())
    for id in cell_ids
        # No "output" key here (deliberately, not even `nothing`): incoming
        # patches target ["cell_results", id, "output", "body"], and
        # _apply_patch!'s get!-based auto-vivify only creates a fresh Dict
        # container when the key is *absent* — an existing `nothing` value
        # would be returned as-is and crash on the next nested index.
        results[id] = Dict{Any,Any}("queued" => true, "running" => false, "errored" => false)
    end
    _send(conn, "run_multiple_cells", Dict("cells" => cell_ids))
    return nothing
end
run_all(conn::Conn) = run_cells(conn, collect(String.(get(conn.state[], "cell_order", []))))

"""
    restart_process(conn::Conn)

Kills and restarts the notebook's worker process (Pluto's "restart" button —
same effect as a Jupyter kernel restart): all global state is lost, but
cells and their last-computed outputs stay in `conn.state[]` until
something re-runs them. Follow up with `run_all` to bring the notebook
back to a fully-evaluated state.
"""
restart_process(conn::Conn) = _send(conn, "restart_process", Dict())

# ---------------------------------------------------------- introspection ----

"""
    read_notebook(conn) -> Vector of (id, code, mime, errored, code_folded)

Mirrors `Read` on a `.ipynb`: cells *and* their currently-cached output
together, in display order. Unlike `get_output`, this never blocks or
triggers execution — it just reports whatever's already there (mime is
`"unrun"` for a cell that hasn't executed yet).

`code_folded` is Pluto's "hide this cell's code, show only its
rendered output" UI toggle — purely cosmetic, the full source is always
returned in `code` regardless (folding never removes it from what Pluto
sends to any client). Surfaced so an agent can tell a cell is meant to
read as prose/output-only, not because the source is otherwise hidden.
"""
function read_notebook(conn::Conn)
    results = get(conn.state[], "cell_results", Dict())
    return [begin
        input = conn.state[]["cell_inputs"][id]
        entry = get(results, id, nothing)
        mime = entry === nothing ? "unrun" : string(get(get(entry, "output", Dict()), "mime", "unrun"))
        errored = entry === nothing ? false : get(entry, "errored", false)
        (id=id, code=input["code"], mime=mime, errored=errored, code_folded=get(input, "code_folded", false))
    end for id in String.(get(conn.state[], "cell_order", []))]
end

get_code(conn::Conn, cell_id::String) = conn.state[]["cell_inputs"][cell_id]["code"]

"""Substring or regex search over cell source code."""
function search_cells(conn::Conn, pattern::Union{Regex,AbstractString})
    rx = pattern isa Regex ? pattern : Regex(pattern)
    return [c for c in read_notebook(conn) if occursin(rx, c.code)]
end

"""
    find_definition(conn, name) -> (id, code) or nothing

Finds the cell that defines global variable/function `name`, using
`cell_dependencies[*]["downstream_cells_map"]` — whose *keys* are every
name that cell assigns (a `begin...end` block can define several). Pluto
guarantees at most one cell defines any given global name.
"""
function find_definition(conn::Conn, name::AbstractString)
    deps = get(conn.state[], "cell_dependencies", Dict())
    for (id, d) in deps
        if haskey(get(d, "downstream_cells_map", Dict()), name)
            return (id=id, code=get_code(conn, id))
        end
    end
    return nothing
end

"""
    list_dependencies(conn, cell_id) -> Dict(name => defining_cell_id_or_nothing)

All names this cell references (`upstream_cells_map`'s keys); a `nothing`
value means the name resolves outside the notebook (Base/stdlib/a package).
"""
function list_dependencies(conn::Conn, cell_id::String)
    d = conn.state[]["cell_dependencies"][cell_id]
    up = get(d, "upstream_cells_map", Dict())
    return Dict(name => (isempty(cids) ? nothing : first(cids)) for (name, cids) in up)
end

"""Cells that depend on `name` (reads the *defining* cell's `downstream_cells_map[name]`)."""
function find_dependents(conn::Conn, name::AbstractString)
    def = find_definition(conn, name)
    def === nothing && return String[]
    d = conn.state[]["cell_dependencies"][def.id]
    return collect(String.(get(get(d, "downstream_cells_map", Dict()), name, [])))
end

# ----------------------------------------------------------------- output ----

"""
    get_output(conn, cell_id; timeout=60) -> CellOutput(mime, body, errored)

Blocks (polling `conn.state[]`, kept current by the background recv loop)
until the cell is no longer `running`/`queued`. Does NOT throw on a cell
error — check `.errored`; `.body` then holds Pluto's error/stacktrace
object instead of a normal MIME body.
"""
function get_output(conn::Conn, cell_id::String; timeout::Real=60)
    t0 = time()
    while time() - t0 < timeout
        results = get(conn.state[], "cell_results", Dict())
        entry = get(results, cell_id, nothing)
        if entry !== nothing && get(entry, "running", true) == false && get(entry, "queued", true) == false
            output = get(entry, "output", nothing)
            errored = get(entry, "errored", false)
            output === nothing && return CellOutput("nothing", nothing, errored)
            raw_body = get(output, "body", nothing)
            # MsgPack encodes Julia's raw-bytes cell output (e.g. image/png,
            # image/svg+xml) as an Extension type, not the plain `bin` format.
            unwrapped = raw_body isa MsgPack.Extension ? raw_body.data : raw_body
            return CellOutput(string(get(output, "mime", "text/plain")), unwrapped, errored)
        end
        # A frozen `state` and a slow cell look identical from here, so check the
        # transport before blaming the notebook.
        if conn.dead[] !== nothing
            error("connection to Pluto is dead ($(conn.dead[])); cell $cell_id " *
                  "may well have finished. Reconnect and re-read rather than re-running.")
        end
        sleep(0.15)
    end
    error("timed out waiting for cell $cell_id after $(timeout)s " *
          "(status: $(cell_status(conn, cell_id)))")
end

function cell_status(conn::Conn, cell_id::String)
    e = get(get(conn.state[], "cell_results", Dict()), cell_id, nothing)
    e === nothing && return (exists=false, queued=false, running=false, errored=false)
    return (exists=true, queued=get(e, "queued", false), running=get(e, "running", false), errored=get(e, "errored", false))
end

"""
    save_png(conn, cell_id, path; timeout=120) -> path

Re-runs `cell_id`'s code wrapped in `savefig(..., path)` inside a
throwaway cell (cleaned up afterward), and returns `path` once written.
Necessary because Pluto keeps no raster form of a plot around — its own
output is SVG bytes, which most tooling can't render directly. This
recomputes the cell rather than rasterizing the existing SVG, which is
fine for cheap plots but wasteful for an expensive one.
"""
function save_png(conn::Conn, cell_id::String, path::String; timeout::Real=120)
    code = get_code(conn, cell_id)
    wrapped = "let\n\t__pc_result__ = begin\n$code\n\tend\n\tPlots.savefig(__pc_result__, $(repr(path)))\n\t\"saved\"\nend"
    tmp_id = notebook_edit(conn, wrapped; edit_mode="insert")
    run_cells(conn, [tmp_id])
    out = get_output(conn, tmp_id; timeout=timeout)
    notebook_edit(conn; cell_id=tmp_id, edit_mode="delete")
    out.errored && error("save_png failed: $(out.body)")
    return path
end
