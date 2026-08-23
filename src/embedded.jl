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
# per session -- a session can have several open (see `list`), and a shared log
# would read every OTHER notebook's cells as freshly deleted the moment any one
# of them fired an event, since they are absent from that event's `nb.cells`.
const CHANGES = Dict{Tuple{String,Base.UUID},Vector{NamedTuple}}()
const CHANGES_MAX = 256

# (session name, notebook_id) => cell_id => code, as of the last
# StateChangeEvent. Lets the event hook tell an edit apart from a mere state
# transition (queued/running), and reconstructs the pair `read` reports as
# `old_code` and `code`. Same per-notebook keying as CHANGES, for the same reason.
const SNAPSHOTS = Dict{Tuple{String,Base.UUID},Dict{Base.UUID,String}}()

"""
    _mark_seen!(name, notebook_id, cell_id, code)

Record `code` as already-known for `cell_id` before running it, so the
StateChangeEvent that follows does not report our own edit back to us as a
change. The change log exists to tell the agent what a HUMAN did while it was
not looking; an edit the agent just made through these tools is not that.
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
                        change="inserted", old_code="", new_code=c.code))
        elseif old != c.code
            push!(log, (at=t, cell_id=string(c.cell_id), name=labels[string(c.cell_id)],
                        change="edited", old_code=old, new_code=c.code))
        end
        snap[c.cell_id] = c.code
    end
    for id in setdiff(keys(snap), seen)
        push!(log, (at=t, cell_id=string(id), name=string(id),
                    change="deleted", old_code=snap[id], new_code=""))
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

Also sweeps each notebook's spill directory: oversize output is written there
so a payload can name a path instead of carrying megabytes, and the files are
only meaningful while the session that produced them is alive.
"""
function stop_session(name::AbstractString)
    s = _session(name)
    for nb in collect(values(s.session.notebooks))
        rm(spill_dir(nb); recursive=true, force=true)
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
    for k in collect(keys(REPORTED))
        first(k) == nm && delete!(REPORTED, k)
    end
    for k in collect(keys(CODE_SENT))
        first(k) == nm && delete!(CODE_SENT, k)
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

"""
    cell_status(c) -> String

One enum, `pending | calculating | success | error`, and the only progress
vocabulary anywhere. A cell that has never run is `pending` just as a queued one
is: from the agent's side both mean "no result yet", and a second word for the
same fact is a second thing to reason about.
"""
function cell_status(c::Pluto.Cell)
    c.errored && return "error"
    c.running && return "calculating"
    (c.queued || c.output.last_run_timestamp == 0) && return "pending"
    "success"
end

"""
    aggregate_status(statuses, finished) -> String

The record's own `status`, by the single stated rule: any `error` means
`error`, else any `pending`/`calculating` means `calculating`, else `success`.

`finished` folds in the one thing the cells cannot say. An asynchronous run
that has not yet touched its first cell leaves every cell looking settled, and
calling that `success` would be a lie with a receipt.
"""
function aggregate_status(statuses, finished::Bool)
    any(==("error"), statuses) && return "error"
    (!finished || any(s -> s in ("pending", "calculating"), statuses)) && return "calculating"
    "success"
end

"""
    cell_info(nb, c, labels; change=nothing) -> NamedTuple

One cell's entry in the record: identity, `status`, `code`, rendered output,
capped log entries, and an error message when it failed. `change` carries a
human browser edit's `old_code` beside the new `code`, which is the only thing
a record ever says that the notebook itself does not.

`code` is dropped by `record` when this session already holds that exact text
(see `CODE_SENT`), so an entry without it is not a cell without code.
"""
function cell_info(nb::Pluto.Notebook, c::Pluto.Cell, labels=cell_labels(nb);
                   change::Union{Nothing,NamedTuple}=nothing)
    label = labels[string(c.cell_id)]
    logs, dropped = render_logs(nb, c, label)
    info = merge((name = label,
                  cell_id = string(c.cell_id),
                  status = cell_status(c),
                  code = c.code,
                  runtime_ns = c.runtime),
                 render_output(nb, c, label))
    isempty(logs) || (info = merge(info, (logs = logs,)))
    dropped === nothing || (info = merge(info, (logs_dropped = dropped,)))
    change === nothing || (info = merge(info, change))
    return info
end

#=
(session, notebook) => cell_id => (fingerprint, reported_at) for the last
version of that cell this SESSION was told about.

The reference point is the agent's context, not the notebook's history, and
that is why the map is written only while building a record -- never from a
StateChangeEvent. A cell that changed and changed back between two records was
never reported in between, so there is nothing for the agent to re-read: ABA is
the right answer here, not a bug to defend against.
=#
const REPORTED = Dict{Tuple{String,Base.UUID},Dict{Base.UUID,Tuple{UInt64,Float64}}}()

#=
(session, notebook) => cell_id => hash of the cell's code, for code this
SESSION already holds -- because a record delivered it, or because an `edit`
supplied it in the first place.

Kept apart from REPORTED because it answers a different question. REPORTED asks
"is this whole entry the one I last sent?", which a re-run to a new output makes
false; the code is unchanged all the same, and an execution cascade never
rewrites code. So a cascade over a large notebook stops repeating source the
agent is already holding, and an `edit` never reads its own text back to it.

Recovery is `read(cells=[...])`. The agent's context is the reference point,
and after a compact it no longer holds what this map claims -- so naming cells
means send them whole, ledger or no ledger. An agent that still holds a cell
has no reason to name it.
=#
const CODE_SENT = Dict{Tuple{String,Base.UUID},Dict{Base.UUID,UInt64}}()

"""
    _mark_code_sent!(name, notebook_id, cell_id, code)

Record `code` as text this session holds. `edit` calls it with the code it was
handed: the caller wrote that text, so reading it back is the one field of the
record they already have.
"""
function _mark_code_sent!(name::AbstractString, notebook_id::Base.UUID, cell_id, code::AbstractString)
    sent = get!(CODE_SENT, (String(name), notebook_id), Dict{Base.UUID,UInt64}())
    sent[cell_id] = hash(code)
    return nothing
end

"Drop a cell from the reported map, so a deleted cell stops costing memory."
function _forget_reported!(name::AbstractString, notebook_id::Base.UUID, cell_id)
    key = (String(name), notebook_id)
    haskey(REPORTED, key) && delete!(REPORTED[key], cell_id)
    haskey(CODE_SENT, key) && delete!(CODE_SENT[key], cell_id)
    return nothing
end

"""
    iso_timestamp(t) -> String

The server clock as ISO 8601 UTC with milliseconds. A float unix time is the
same number of characters and says nothing a reader can use; `2026-08-23T18:42:23.788Z`
round-trips just as exactly, sorts lexicographically, and can be read.
"""
iso_timestamp(t::Real) =
    Dates.format(Dates.unix2datetime(t), dateformat"yyyy-mm-dd\THH:MM:SS.sss") * "Z"

"""
    parse_timestamp(x) -> Union{Nothing,Float64}

`since`, back from a client. An ISO string is what every record now hands out;
a number is still accepted, because a float from an older transcript is a
perfectly good timestamp and refusing it would only lose a delta.
"""
parse_timestamp(::Nothing) = nothing
parse_timestamp(x::Real) = Float64(x)
function parse_timestamp(x::AbstractString)
    t = strip(String(x))
    endswith(t, "Z") && (t = t[1:end-1])
    try
        Dates.datetime2unix(Dates.DateTime(t))
    catch
        error("since: expected a `timestamp` from an earlier record, like " *
              "\"2026-08-23T18:42:23.788Z\", got \"$x\"")
    end
end

"""
    record(name, nb, cells, finished, waited; since, changes, extra...) -> NamedTuple

The one response shape: `status, waited_seconds, timestamp, cells`.

Every tool that runs, waits or reads returns this, so the agent parses one
thing and reads one word for progress. `status` describes THIS operation --
aggregated over the cells the record reports, not over the whole notebook -- so
an unrelated broken cell elsewhere cannot make every later edit look like a
failure. A full `read` reports every cell, which is where notebook-wide state
belongs.

A cell this session already saw, byte-identical, comes back as three fields:
`name`, `status`, `unchanged_since`. A reactive cascade over a large notebook is
mostly cells that re-ran to the same answer, and re-sending their code and
output every time is the single biggest thing this server can waste. The
cascade stays fully visible: an unchanged cell is compressed, never hidden.
With `since`, unchanged cells are dropped entirely -- the same comparison,
presented as a delta instead of a summary.

`timestamp` is stamped BEFORE any cell is read, and it round-trips straight
into `read(since=...)`. It leaves here as an ISO 8601 UTC string and comes back
through `parse_timestamp`; internally it stays a `Float64` unix time, which is
what Pluto's own `last_run_timestamp` is measured in. Stamp-first makes delivery at-least-once: a change
landing while the record is being assembled dates at or after the stamp, so the
next read shows it again. Stamp-last would lose it. It is deliberately not
taken under `nb.executetoken`: that is Pluto's RUN lock, held for the whole
reactive run, so waiting for it would make every `wait_seconds=0` call block
until the run it was trying not to wait for had finished.
"""
function record(name::AbstractString, nb::Pluto.Notebook, cells, finished::Bool, waited::Real;
                since::Union{Nothing,Real,AbstractString}=nothing, full::Bool=false,
                changes::Dict{String,<:NamedTuple}=Dict{String,NamedTuple}(), extra...)
    timestamp = time()
    labels = cell_labels(nb)
    key = (String(name), nb.notebook_id)
    seen = get!(REPORTED, key, Dict{Base.UUID,Tuple{UInt64,Float64}}())
    sent = get!(CODE_SENT, key, Dict{Base.UUID,UInt64}())
    # `full` is a read that named its cells: nothing is compacted and nothing
    # is suppressed. The only reason to name a cell is not knowing, or not
    # remembering, what is in it -- and an agent that knows does not ask.
    holds_code(c) = !full && get(sent, c.cell_id, nothing) == hash(c.code)

    entries = Any[]
    statuses = String[]
    for c in cells
        if !(c isa Pluto.Cell)          # a synthetic entry: a deleted cell
            push!(entries, c)
            push!(statuses, get(c, :status, "success"))
            continue
        end
        id = string(c.cell_id)
        push!(statuses, cell_status(c))
        fingerprint = cell_fingerprint(c)
        previous = get(seen, c.cell_id, nothing)
        if !full && previous !== nothing && first(previous) == fingerprint
            since === nothing && push!(entries, (name = labels[id],
                                                 status = cell_status(c),
                                                 unchanged_since = iso_timestamp(last(previous))))
            continue
        end
        seen[c.cell_id] = (fingerprint, timestamp)
        info = cell_info(nb, c, labels; change = get(changes, id, nothing))
        # Code the agent holds is dropped, not the entry: status, output, logs
        # and any error are what the run was asked for.
        holds_code(c) ? (info = Base.structdiff(info, NamedTuple{(:code,)})) :
                        (sent[c.cell_id] = hash(c.code))
        push!(entries, info)
    end
    merge((status = aggregate_status(statuses, finished),
           waited_seconds = round(Float64(waited); digits=2),
           timestamp = iso_timestamp(timestamp),
           cells = entries),
          NamedTuple(extra))
end

cells_info(nb::Pluto.Notebook) =
    (labels = cell_labels(nb); [cell_info(nb, c, labels) for c in nb.cells])

# ------------------------------------------------------------------ writing --

"""Run `cells` synchronously: save the file, push patches to every browser, return when done."""
function run_cells!(name::AbstractString, nb::Pluto.Notebook, cells::Vector{Pluto.Cell}; save::Bool=true)
    s = _session(name)
    # Cheap when nothing restarted, and the only moment we are guaranteed to be
    # asked before a cell runs.
    ensure_helpers!(s.session, nb)
    isempty(cells) || Pluto.update_save_run!(s.session, nb, cells; run_async=false, save)
    return nb
end

"""
    cascade(nb, before, targets) -> Vector{Pluto.Cell}

Every cell the reactive run touched, in notebook order.

Reporting only the cells that were asked for describes the request, not the
run: editing one definition can re-run a dozen cells downstream, and those
clean re-runs are the part worth seeing. A cell counts as touched if its
`last_run_timestamp` moved, if it is still running or queued, or if it was an
explicit target (a cell whose edit changed nothing still ran).
"""
function cascade(nb::Pluto.Notebook, before::Dict{Base.UUID,Float64}, targets)
    asked = Set(c.cell_id for c in targets)
    [c for c in nb.cells
     if c.cell_id in asked || c.running || c.queued ||
        c.output.last_run_timestamp != get(before, c.cell_id, -1.0)]
end

run_timestamps(nb::Pluto.Notebook) =
    Dict{Base.UUID,Float64}(c.cell_id => c.output.last_run_timestamp for c in nb.cells)

"""
    run_with_deadline(name, nb, cells; wait_seconds=1.0) -> (finished, waited, touched)

Start `cells` and wait up to `wait_seconds` for them to finish.

Most cells finish in milliseconds, and making a caller poll for a result that
was already there is pure latency. A package load or a full-corpus plot can take
minutes, and blocking on that is worse. So: start, wait briefly, say which
happened.

Expiry is neither an error nor a timeout: the cells are still running, the
browser already shows them running, and `read(wait_seconds=N)` reports when they
are done.

Returns as soon as a cell newly errors, rather than serving out the remaining
deadline: the rest of a reactive run cannot un-break it.

This is bounded by Pluto running a notebook's cells sequentially in one worker.
An error cannot be reported before the cell producing it has had its turn, so a
long-running cell ahead of it in the queue still has to finish first.
"""
function run_with_deadline(name::AbstractString, nb::Pluto.Notebook, cells::Vector{Pluto.Cell};
                           wait_seconds::Real=1.0, save::Bool=true)
    s = _session(name)
    isempty(cells) && return (true, 0.0, Pluto.Cell[])
    # Every run funnels through here, which makes it the one place that can
    # notice the worker was replaced under us (see ensure_helpers!).
    ensure_helpers!(s.session, nb)
    # Pluto's own run_async=true does exactly this -- @async around the
    # synchronous path (see maybe_async in Run.jl) -- but doesn't hand back
    # the Task, so a caller is left guessing whether a run has finished from
    # cell state alone. Doing the @async ourselves makes istaskdone the literal
    # truth instead of a heuristic over `running`/`queued`/timestamps, which
    # could read "idle" in the instant before an async run had even started.
    await_run(nb, cells; wait_seconds) do
        Pluto.update_save_run!(s.session, nb, cells; run_async=false, save)
    end
end

"""
    await_run(f, nb, targets; wait_seconds) -> (finished, waited, touched)

Run `f` -- anything that drives Pluto's reactive engine -- on a task, and wait
`wait_seconds` for it. One place decides what `finished` means, so `run`,
`edit` and `bond` cannot drift apart on it.
"""
function await_run(f, nb::Pluto.Notebook, targets; wait_seconds::Real=1.0)
    before = run_timestamps(nb)
    # Only NEW errors are worth stopping for; a notebook can already contain an
    # unrelated broken cell, and that is not news about this run.
    errored_before = Set(c.cell_id for c in nb.cells if c.errored)
    new_error() = any(c -> c.errored && !(c.cell_id in errored_before), nb.cells)

    task = @async f()
    t0 = time()
    while !istaskdone(task) && time() - t0 < wait_seconds
        # Surface a failure the moment it happens rather than serving out the
        # deadline: the rest of a reactive run cannot un-break it.
        new_error() && break
        sleep(0.02)
    end
    # A task that finished by throwing must not be reported as a clean finish:
    # fetch re-raises it into the tool handler, which turns it into an error
    # result the agent can read.
    istaskdone(task) && istaskfailed(task) && fetch(task)
    (istaskdone(task), time() - t0, cascade(nb, before, targets))
end

"""
    wait_for_idle(nb; wait_seconds) -> (finished, waited, touched)

Wait for a notebook already running to go idle, or for a NEW error, whichever
comes first. `read(wait_seconds=N)` is this and nothing else -- the same
early-return rule as `run_with_deadline`, over a run somebody else started.
"""
function wait_for_idle(nb::Pluto.Notebook; wait_seconds::Real=0.0)
    before = run_timestamps(nb)
    errored_before = Set(c.cell_id for c in nb.cells if c.errored)
    new_error() = any(c -> c.errored && !(c.cell_id in errored_before), nb.cells)
    t0 = time()
    while !isempty(busy_cells(nb)) && time() - t0 < wait_seconds && !new_error()
        sleep(0.02)
    end
    (isempty(busy_cells(nb)), time() - t0, cascade(nb, before, Pluto.Cell[]))
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

# ------------------------------------------------------------- injected help --

#=
`AsPNG(fig)` exists for one reason: Pluto's MIME ordering prefers SVG whenever a
backend offers both, and MCP images are PNG. A plot cell therefore comes back as
~100 KB of markup no client can show, when the agent wanted a picture.

It is injected into the WORKER, not written into the notebook, because the
notebook is the artifact a human keeps: a helper the agent needs is not
something the reader should have to scroll past.

Injecting it into the current workspace module would not survive: Pluto makes a
FRESH `Main.workspace#N` on every reactive run (`bump_workspace_module`) and
moves the notebook's variables across, so anything defined in the old module is
simply gone next run. The two durable places are the worker's `Main`, which is
never bumped, and `PlutoRunner.workspace_preamble` -- the list of expressions
Pluto evaluates inside each new workspace module, which is how `PlutoRunner`
itself becomes visible to cells. So: define the module in `Main` once, and add
one `using` to the preamble.
=#
const ASPNG_SOURCE = raw"""
module PlutoMCP

export AsPNG

# AsPNG(fig): show `fig` as a PNG, whatever its native format.
struct AsPNG{T}
    fig::T
end

Base.showable(::MIME"image/png", ::AsPNG) = true

function Base.show(io::IO, m::MIME"image/png", p::AsPNG)
    Base.showable(m, p.fig) && return show(io, m, p.fig)
    # Backends that cannot show/png (Plots' plotly, say) still save one. Look
    # the writer up in the figure's OWN module -- Plots.savefig for a
    # Plots.Plot, Makie.save for a Figure -- which needs no knowledge of what
    # the notebook happens to have `using`ed.
    ws = parentmodule(typeof(p.fig))
    path = tempname() * ".png"
    try
        for (name, args) in ((:savefig, (p.fig, path)), (:save, (path, p.fig)))
            isdefined(ws, name) || continue
            try
                Base.invokelatest(getfield(ws, name), args...)
                isfile(path) && return write(io, read(path))
            catch
            end
        end
        error("cannot render $(typeof(p.fig)) as PNG: it has no image/png show method, savefig or save")
    finally
        rm(path; force=true)
    end
end

end
"""

# Which worker process each notebook's helpers were injected into. Pluto starts
# a NEW process when the package environment changes -- `using Plots` in a cell
# installs a package and restarts -- and the fresh process has neither
# `Main.PlutoMCP` nor the preamble entry. Injecting once at `open` is therefore
# not enough: the helper disappears exactly when a notebook first acquires a
# plotting library, which is when it is about to be needed.
const INJECTED_WORKER = Dict{Base.UUID,Any}()

_current_worker(session, nb::Pluto.Notebook) =
    try
        ws = Pluto.WorkspaceManager.get_workspace((session, nb); allow_creation=false)
        ws === nothing ? nothing : ws.worker
    catch
        nothing  # discarded workspace, or an internal that moved: fall through and re-inject
    end

"""
    ensure_helpers!(session, nb)

Re-inject the helpers if this notebook is running in a worker we have not
injected into. The check is in-process -- an identity comparison against the
`Workspace`'s worker -- so the common case costs no round trip to the worker
and nothing is evaluated.
"""
function ensure_helpers!(session, nb::Pluto.Notebook)
    worker = _current_worker(session, nb)
    worker !== nothing && get(INJECTED_WORKER, nb.notebook_id, nothing) === worker && return nothing
    inject_helpers!(session, nb)
end

"""
    inject_helpers!(session, nb)

Make `PlutoMCP.AsPNG` available to every cell of this notebook, now and after
each reactive run. Best-effort: failing to add a convenience is never a reason
to fail the `open` that asked for it.
"""
function inject_helpers!(session, nb::Pluto.Notebook)
    try
        Pluto.WorkspaceManager.eval_in_workspace((session, nb), Expr(:toplevel,
            # Define it once in the worker's Main. Re-evaluating would print a
            # "replacing module" warning and invalidate the type on every open.
            :(isdefined(Main, :PlutoMCP) ||
              Core.eval(Main, $(QuoteNode(Meta.parseall(ASPNG_SOURCE))))),
            # Every future workspace module gets it, the same way PlutoRunner does.
            :(let e = :(using Main.PlutoMCP)
                  e in PlutoRunner.workspace_preamble ||
                      push!(PlutoRunner.workspace_preamble, e)
              end),
            # ...and the one that already exists.
            :(using Main.PlutoMCP),
        ))
        # Record only on success, and only after the eval: the workspace may
        # not have existed until eval_in_workspace made it.
        let worker = _current_worker(session, nb)
            worker === nothing || (INJECTED_WORKER[nb.notebook_id] = worker)
        end
    catch e
        # Warned, not swallowed: a helper that silently stopped existing is
        # found much later, as an UndefVarError in somebody's plotting cell.
        # stderr is safe -- the JSON-RPC transport owns stdout, nothing else.
        @warn "PlutoMCP.AsPNG could not be injected into the notebook workspace" exception=e
    end
    return nothing
end
