#=
Drive Pluto by calling Pluto. There is no protocol in this file.

PlutoMCP runs the Pluto server inside its own process, so it holds the
`Notebook` -- the very object the server mutates. Reading it IS reading the
truth: no mirrored copy, nothing to synchronise, nothing that can go stale.

Pluto is already an MVC and we do not add another (see its own notes in
`webserver/Dynamic.jl`): the `Notebook` is the model, `notebook_to_js` is the
view, and `send_notebook_changes!` diffs against a per-client snapshot and
pushes patches to every open browser. `Pluto.update_save_run!` calls it, and
defaults to `save=true`, so after a run the file on disk and any open tab are
both current.

Edits made in the BROWSER need no notification: the frontend's patches land on
this same `Notebook`, so the next read sees them. To react rather than poll,
Pluto publishes `options.server.on_event` and fires `StateChangeEvent` on every
change -- outside the connected-clients branch, so it fires with no browser
attached.
=#

# ------------------------------------------------------------------ sessions --

# session name => the server, the Pluto session, and the notebook it is driving
const SESSIONS = Dict{String,Any}()

# (session name, notebook_id) => log of cell-level edits seen via
# StateChangeEvent, oldest first. A DROPPING buffer: a notification path must
# never be able to block the thing it observes. Keyed per notebook, not just
# per session -- a session can have several open (see `list`), and a shared
# per-session log would misattribute every OTHER notebook's untouched cells as
# newly deleted the moment any one of them changed (they'd be absent from
# that event's `nb.cells`, which is exactly what "deleted" used to mean).
const CHANGES = Dict{Tuple{String,Base.UUID},Vector{NamedTuple}}()
const CHANGES_MAX = 256

# (session name, notebook_id) => cell_id => code, as of the last
# StateChangeEvent. Lets the event hook tell an edit apart from a mere state
# transition (queued/running), and reconstructs old/new source for the diff
# `status` reports. Same per-notebook keying as CHANGES, for the same reason.
const SNAPSHOTS = Dict{Tuple{String,Base.UUID},Dict{Base.UUID,String}}()

"""
    _mark_seen!(name, notebook_id, cell_id, code)

Record `code` as already-known for `cell_id` before running it, so the
StateChangeEvent that follows does not report our own edit back to us as a
change. `status` exists to tell the agent what a HUMAN did while it was not
looking; an edit the agent just made through these tools is not that.
"""
function _mark_seen!(name::AbstractString, notebook_id::Base.UUID, cell_id, code::AbstractString)
    snap = get!(SNAPSHOTS, (String(name), notebook_id), Dict{Base.UUID,String}())
    snap[cell_id] = code
    return nothing
end

"Drop a cell from the snapshot, so its removal is not reported as a deletion."
function _forget_seen!(name::AbstractString, notebook_id::Base.UUID, cell_id)
    key = (String(name), notebook_id)
    haskey(SNAPSHOTS, key) && delete!(SNAPSHOTS[key], cell_id)
    return nothing
end

"""
    _note_change!(name, nb)

Diff `nb` against the last-seen snapshot for this (session, notebook) and
append one entry per inserted, edited or deleted cell to `CHANGES`. Runs on
every `StateChangeEvent`, for whichever notebook it fired on -- keyed by
notebook_id, not just session, so a change in one open notebook cannot appear
as every OTHER open notebook's cells having just been deleted. A
tool-initiated edit already updated the snapshot via `_mark_seen!` before
running, so it diffs to nothing here -- what is left is what a human changed
in the browser while nobody was looking.
"""
function _note_change!(name::String, nb::Pluto.Notebook)
    t = time()
    key = (name, nb.notebook_id)
    snap = get!(SNAPSHOTS, key, Dict{Base.UUID,String}())
    log = get!(CHANGES, key, NamedTuple[])
    labels = cell_labels(nb)
    seen = Set{Base.UUID}()
    for c in nb.cells
        push!(seen, c.cell_id)
        old = get(snap, c.cell_id, nothing)
        if old === nothing
            push!(log, (at=t, cell_id=string(c.cell_id), name=labels[string(c.cell_id)],
                        kind="inserted", old_source="", new_source=c.code))
        elseif old != c.code
            push!(log, (at=t, cell_id=string(c.cell_id), name=labels[string(c.cell_id)],
                        kind="edited", old_source=old, new_source=c.code))
        end
        snap[c.cell_id] = c.code
    end
    for id in setdiff(keys(snap), seen)
        push!(log, (at=t, cell_id=string(id), name=string(id),
                    kind="deleted", old_source=snap[id], new_source=""))
        delete!(snap, id)
    end
    length(log) > CHANGES_MAX && deleteat!(log, 1:(length(log) - CHANGES_MAX))
    return nothing
end

"""
Find a free port by binding and releasing it. Pluto's own auto-selection does
not write the chosen port back onto the session options, so the port has to be
known before the server starts. Small race, accepted.
"""
function _free_port()
    server = Sockets.listen(Sockets.localhost, 0)
    port = Sockets.getsockname(server)[2]
    close(server)
    return Int(port)
end

"""
    start_session(name; port=nothing) -> session record

Start a Pluto server in this process. The HTTP server exists only so a human
can open the notebook in a browser; nothing here talks to it over the network.

Registers an `on_event` hook first, so changes are observable from the moment
the session exists rather than from the first time someone asks.

Calling this twice for the same `name` stops whatever was already running
under it first -- otherwise SESSIONS[nm] would just be overwritten, leaking
the previous server and every notebook worker process it owned.
"""
function start_session(name::AbstractString; port::Union{Nothing,Int}=nothing)
    nm = String(name)
    haskey(SESSIONS, nm) && stop_session(nm)
    port = something(port, _free_port())
    options = Pluto.Configuration.from_flat_kwargs(;
        port, launch_browser=false, require_secret_for_access=true,
        on_event = function (e)
            e isa Pluto.StateChangeEvent && _note_change!(nm, e.notebook)
            nothing
        end,
    )
    session = Pluto.ServerSession(; options)
    server = Pluto.run!(session)
    SESSIONS[nm] = (host="localhost:$port", secret=session.secret,
                    session=session, server=server,
                    # Every open notebook is already tracked by
                    # session.notebooks (Pluto's own Dict{UUID,Notebook}); this
                    # is only which one a `session`-only tool call means.
                    current=Ref{Union{Nothing,Base.UUID}}(nothing))
    return SESSIONS[nm]
end

"""
Shut down every notebook this session has open -- each one owns a worker
process -- THEN close the HTTP server. `close(server)` alone leaves those
worker processes running with nothing left to stop them.
"""
function stop_session(name::AbstractString)
    s = _session(name)
    for nb in collect(values(s.session.notebooks))
        Pluto.SessionActions.shutdown(s.session, nb; async=false)
    end
    close(s.server)
    delete!(SESSIONS, String(name))
    # Keyed by (session, notebook_id), so this session's entries aren't one
    # key -- drop everything whose first component matches.
    nm = String(name)
    for k in collect(keys(CHANGES))
        first(k) == nm && delete!(CHANGES, k)
    end
    for k in collect(keys(SNAPSHOTS))
        first(k) == nm && delete!(SNAPSHOTS, k)
    end
    return nothing
end

function _session(name::AbstractString)
    haskey(SESSIONS, String(name)) ||
        error("no session \"$name\" — call start first")
    return SESSIONS[String(name)]
end

"""
    _notebook(name; ref=nothing) -> Pluto.Notebook

Resolve which of the session's open notebooks a tool call means. Every
notebook the session has open is already in `s.session.notebooks`
(Pluto's own registry, keyed by notebook_id) -- `open`/`create` never
replaced anything there, only our own single-notebook `Ref` did.

`ref` is a notebook_id, a path (or an unambiguous suffix of one, so a
basename is usually enough), or `nothing` for the session's CURRENT
notebook -- the one the most recent `open`/`create` selected, matching the
single-notebook behavior every other tool call defaults to.
"""
function _notebook(name::AbstractString; ref::Union{Nothing,AbstractString}=nothing)
    s = _session(name)
    if ref === nothing
        id = s.current[]
        id === nothing &&
            error("session \"$name\" has no notebook — call open or create first")
        return s.session.notebooks[id]
    end
    id = tryparse(Base.UUID, ref)
    id !== nothing && haskey(s.session.notebooks, id) && return s.session.notebooks[id]
    hits = [nb for nb in values(s.session.notebooks) if endswith(nb.path, ref)]
    length(hits) == 1 && return only(hits)
    length(hits) > 1 && error("\"$ref\" matches $(length(hits)) open notebooks in session \"$name\"")
    error("no open notebook matches \"$ref\" in session \"$name\" — see list")
end

notebook_url(s, nb) = "http://$(s.host)/edit?id=$(nb.notebook_id)&secret=$(s.secret)"

# ------------------------------------------------------------------- naming --

"""
    is_name(s) -> Bool

Whether `s` works as a handle: a plain Julia identifier, short enough to type.
Anything else is not a name, and the UUID is the honest answer rather than a
mangled approximation of one.
"""
is_name(s::AbstractString) =
    !isempty(s) && length(s) <= 32 && occursin(r"^[A-Za-z_][A-Za-z0-9_!]*$", s)

"""
    cell_labels(nb) -> Dict(cell_id => name)

Name each cell by WHAT IT DEFINES.

Pluto computes this already for its reactivity graph (`ReactiveNode.definitions`),
so `abl = read_curve(...)` is the cell named `abl`, and Pluto's
one-definition-per-cell rule is what keeps the names unique.

**Every cell is always addressable by its UUID.** A name is a convenience for
the cells that have one, never a replacement: a cell Pluto reports no definition
for keeps its UUID, and that is a correct answer rather than a failure.

**Ask Pluto; never parse cell source.** Pluto owns the reactivity graph and
exposes every declaration and dependency. A second implementation here can only
drift from its semantics, and a wrong name is worse than an honest UUID.
"""
function cell_labels(nb::Pluto.Notebook)
    # `nb.topology` is what Pluto's own reactive run keeps up to date after
    # every change (see Run.jl's run_reactive_core!). Passing it as the base
    # lets updated_topology reuse the analysis for every cell whose source
    # hasn't changed since, instead of re-running ExpressionExplorer over the
    # whole notebook on every call.
    top = Pluto.updated_topology(nb.topology, nb, nb.cells)
    labels = Dict{String,String}()
    seen = Set{String}()
    for c in nb.cells
        node = top.nodes[c]
        defs  = sort!(String[string(d) for d in node.definitions])
        funcs = sort!(String[string(f) for f in node.funcdefs_without_signatures])
        cand = !isempty(defs) ? defs[1] : (!isempty(funcs) ? funcs[1] : "")
        id = string(c.cell_id)
        labels[id] = (is_name(cand) && !(cand in seen)) ? (push!(seen, cand); cand) : id
    end
    return labels
end

"""
    resolve_cell(nb, ref) -> Pluto.Cell

Accept a name, a UUID, or an unambiguous UUID prefix.

An ambiguous prefix is reported rather than resolved arbitrarily. In
practice this needs a genuinely short prefix: every cell this package
creates gets a uuid4 id (see notebook_source and edit's insert path),
picked precisely so a short prefix stays discriminating -- unlike Cell's
own default, uuid1, which is time-based and collides in exactly that case.
"""
function resolve_cell(nb::Pluto.Notebook, ref::AbstractString)
    for c in nb.cells
        string(c.cell_id) == ref && return c
    end
    labels = cell_labels(nb)
    for c in nb.cells
        labels[string(c.cell_id)] == ref && return c
    end
    hits = [c for c in nb.cells if startswith(string(c.cell_id), ref)]
    length(hits) == 1 && return only(hits)
    length(hits) > 1 && error("\"$ref\" is ambiguous — it matches $(length(hits)) cells")
    error("no cell named or identified by \"$ref\"")
end

# ------------------------------------------------------------------ reading --

"""Summarise one cell. The output body is described, not included -- see `cell_output`."""
function cell_info(nb::Pluto.Notebook, c::Pluto.Cell, labels=cell_labels(nb))
    body = c.output.body
    n = body === nothing ? 0 :
        body isa AbstractString ? sizeof(body) :
        body isa Vector{UInt8}  ? length(body)  : -1
    (name = labels[string(c.cell_id)],
     cell_id = string(c.cell_id),
     code = c.code,
     mime = string(c.output.mime),
     errored = c.errored,
     running = c.running,
     queued = c.queued,
     runtime_ns = c.runtime,
     output_bytes = n,
     logs = c.logs)
end

cells_info(nb::Pluto.Notebook) =
    (labels = cell_labels(nb); [cell_info(nb, c, labels) for c in nb.cells])

# ------------------------------------------------------------------ writing --

"""Run `cells` synchronously: save the file, push patches to every browser, return when done."""
function run_cells!(name::AbstractString, nb::Pluto.Notebook, cells::Vector{Pluto.Cell}; save::Bool=true)
    s = _session(name)
    isempty(cells) || Pluto.update_save_run!(s.session, nb, cells; run_async=false, save)
    return nb
end

"""
    run_with_deadline(name, nb, cells; block=1.0) -> (finished::Bool, waited)

Start `cells` and wait up to `block` seconds for them to finish.

Most cells finish in milliseconds, and making a caller poll for a result that
was already there is pure latency. A package load or a full-corpus plot can take
minutes, and blocking on that is worse. So: start, wait briefly, say which
happened.

`finished=false` is neither an error nor a timeout. The cells are still running,
the browser already shows them running, and `status` reports when they are done.

Returns as soon as a cell newly errors, rather than serving out the remaining
deadline: the rest of a reactive run cannot un-break it. `finished` in that
case reflects whether the Task happened to be done too, not just the error.

This is bounded by Pluto running a notebook's cells sequentially in one worker.
An error cannot be reported before the cell producing it has had its turn, so a
long-running cell ahead of it in the queue still has to finish first.
"""
function run_with_deadline(name::AbstractString, nb::Pluto.Notebook, cells::Vector{Pluto.Cell};
                           block::Real=1.0, save::Bool=true)
    s = _session(name)
    isempty(cells) && return (true, 0.0)

    errored_before = Set(c.cell_id for c in nb.cells if c.errored)
    # Pluto's own run_async=true does exactly this -- @async around the
    # synchronous path (see maybe_async in Run.jl) -- but doesn't hand back
    # the Task, so a caller is left guessing whether a run has finished from
    # cell state alone. Doing the @async ourselves makes istaskdone the literal
    # truth instead of a heuristic over `running`/`queued`/timestamps, which
    # could read "idle" in the instant before an async run had even started.
    task = @async Pluto.update_save_run!(s.session, nb, cells; run_async=false, save)
    # Only NEW errors are worth stopping for; a notebook can already contain an
    # unrelated broken cell, and that is not news about this run.
    new_error() = any(c -> c.errored && !(c.cell_id in errored_before), nb.cells)

    t0 = time()
    while !istaskdone(task) && time() - t0 < block
        # Surface a failure the moment it happens rather than serving out the
        # deadline: the rest of a reactive run cannot un-break it.
        new_error() && return (istaskdone(task), time() - t0)
        sleep(0.02)
    end
    return (istaskdone(task), time() - t0)
end

"""Cells currently running or queued, anywhere in the notebook."""
busy_cells(nb::Pluto.Notebook) = [c for c in nb.cells if c.running || c.queued]

"""
    notebook_source(cells; cell_types) -> Pluto.Notebook

Build a notebook from `Pluto.Cell`/`Pluto.Notebook` directly -- never by
hand-writing the `.jl` file's text format, which only Pluto should own. Not
yet saved to disk; call `Pluto.save_notebook` (or open it via a session) when
ready.
"""
function notebook_source(cells::Vector{String};
                         cell_types::Vector{String}=fill("code", length(cells)))
    length(cell_types) == length(cells) ||
        error("cell_types has $(length(cell_types)) entries for $(length(cells)) cells")
    pcells = [Pluto.Cell(;
                  # uuid4, not Cell's default uuid1: uuid1 is time-based, and
                  # cells created in a loop land in the same tick, so their ids
                  # share a long leading run of digits and a short prefix
                  # identifies nothing. Random ids make prefixes discriminating.
                  cell_id=uuid4(),
                  code = t == "markdown" ? _wrap_markdown(src) : src)
              for (src, t) in zip(cells, cell_types)]
    Pluto.Notebook(pcells)
end

_wrap_markdown(src::String) = startswith(strip(src), "md\"") ? src : "md\"\"\"\n$src\n\"\"\""
