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

# The one server this process runs, or nothing. One process, one client, one
# server: a stdio MCP server has no second tenant to keep apart, and a name for
# the only session there can be is a parameter on every tool that never varies.
const SERVER = Ref{Any}(nothing)

"""
Serialises PlutoMCP's OWN calls into `Pluto.update_save_run!`, per notebook.

That function mutates `nb.topology` (`old = nb.topology; nb.topology =
updated_topology(old, nb, cells)`, in Run.jl) BEFORE it ever touches
`nb.executetoken` -- Pluto's own run lock only wraps the execution that
follows. Every `edit`/`bond` call here starts its run inside its own `@async`
task (`await_run`), so `wait_seconds=0` -- fire-and-forget batch authoring,
the documented way to author several cells at once -- has several of these
tasks in flight together. Two of them racing on that unlocked mutation is a
lost update: the loser's topology change is overwritten, and the cell it just
inserted sits in the notebook forever with no run and no error -- present in
`cell_inputs`, absent from `cell_results`, invisible to a `read` and to
anyone watching the browser tab, because nothing ever reports it as anything
but silently unrun.

One `Token` per notebook, held for the WHOLE of `update_save_run!`, not just
its topology-mutating prefix: Pluto already serialises the execution that
follows under `nb.executetoken` ("one cell at a time, in one worker"), so this
adds no waiting beyond what that promise already implies -- it only makes the
topology update queue in the same order as the calls that caused it.
"""
const RUN_LOCKS = Dict{Base.UUID,Pluto.Token}()
_run_lock(nb::Pluto.Notebook) = get!(Pluto.Token, RUN_LOCKS, nb.notebook_id)
_forget_run_lock!(notebook_id::Base.UUID) = (delete!(RUN_LOCKS, notebook_id); nothing)

# Cell-level edits seen via StateChangeEvent, oldest first. A DROPPING buffer:
# a notification path must never be able to block the thing it observes.
#
# One log, not one per notebook: an entry names the notebook it happened in,
# which is a property of the event rather than a key to file it under.
const CHANGES = NamedTuple[]
const CHANGES_MAX = 256

# cell_id => (notebook_id, code) as of the last StateChangeEvent. Lets the
# event hook tell an edit apart from a mere state transition (queued/running),
# and reconstructs the pair `read` reports as `old_code` and `code`.
#
# Keyed by cell_id alone: a cell_id is a UUID and identifies a cell anywhere.
# The notebook_id rides along as a VALUE, because a deleted cell is gone from
# `nb.cells` and its notebook has to be recoverable from somewhere.
const SNAPSHOTS = Dict{Base.UUID,Tuple{Base.UUID,String}}()

"""
    _mark_seen!(notebook_id, cell_id, code)

Record `code` as already-known for `cell_id` before running it, so the
StateChangeEvent that follows does not report our own edit back to us as a
change. The change log exists to tell the agent what a HUMAN did while it was
not looking; an edit the agent just made through these tools is not that.
"""
function _mark_seen!(notebook_id::Base.UUID, cell_id, code::AbstractString)
    SNAPSHOTS[cell_id] = (notebook_id, String(code))
    return nothing
end

"Drop a cell from the snapshot, so its removal is not reported as a deletion."
function _forget_seen!(cell_id)
    delete!(SNAPSHOTS, cell_id)
    return nothing
end

"""
    _note_change!(nb)

Diff `nb` against the last-seen snapshot for this notebook and
append one entry per inserted, edited or deleted cell to `CHANGES`. Runs on
every `StateChangeEvent`, for whichever notebook it fired on -- keyed by
notebook_id, so a change in one open notebook cannot appear as every OTHER open
notebook's cells having just been deleted. A
tool-initiated edit already updated the snapshot via `_mark_seen!` before
running, so it diffs to nothing here -- what is left is what a human changed
in the browser while nobody was looking.

An entry is `at, cell_id, change, old_code` and nothing more. Names are
resolved at REPORT time, from the live notebook -- this hook fires on every
state transition of every run, and paying for a topology update here, to
record a field no reader uses, would tax the thing it observes. The new code
is deliberately absent too: the record's `code` is the cell's text as it is
now, and a stale copy must never be able to override it.
"""
function _note_change!(nb::Pluto.Notebook)
    t = time()
    id = nb.notebook_id
    seen = Set{Base.UUID}()
    for c in nb.cells
        push!(seen, c.cell_id)
        old = get(SNAPSHOTS, c.cell_id, nothing)
        if old === nothing
            push!(CHANGES, (at=t, notebook_id=id, cell_id=string(c.cell_id),
                            change="inserted", old_code=""))
        elseif last(old) != c.code
            push!(CHANGES, (at=t, notebook_id=id, cell_id=string(c.cell_id),
                            change="edited", old_code=last(old)))
        end
        SNAPSHOTS[c.cell_id] = (id, c.code)
    end
    # Gone from THIS notebook: a snapshot entry filed under it that no longer
    # appears among its cells. Another notebook's cells are untouched, which is
    # what the notebook_id in the value is for.
    for (cid, (nid, code)) in collect(SNAPSHOTS)
        nid == id && !(cid in seen) || continue
        push!(CHANGES, (at=t, notebook_id=id, cell_id=string(cid),
                        change="deleted", old_code=code))
        delete!(SNAPSHOTS, cid)
    end
    length(CHANGES) > CHANGES_MAX && deleteat!(CHANGES, 1:(length(CHANGES) - CHANGES_MAX))
    return nothing
end

"""
    _poke_wake!(nb)

Best-effort wake-up nudge for whoever is blocked reading `wake_path(nb)`.
Fires on every `StateChangeEvent` -- a human edit AND a bare status
transition (a long run finishing) alike -- from the same hook `_note_change!`
already runs from, so no second detection path is needed.

Never creates the FIFO: that is the waiter's job (see the `pluto-workflow`
skill), so a notebook nobody is waiting on carries no extra state and this
function is a no-op for it. Never blocks the caller either -- opening a FIFO
read+write cannot block on POSIX (the fd is its own "other end"), and the
write is one byte, which fits in the kernel pipe buffer even with no reader
attached yet. Delivery is at-least-once and a spurious wake is harmless: this
is a nudge to go call `read`, never the answer itself, so losing one changes
nothing but timing.

Windows has no POSIX FIFO; `isfifo` is simply false there and this quietly
does nothing until a Windows recipe exists.
"""
function _poke_wake!(nb::Pluto.Notebook)
    path = wake_path(nb)
    isfifo(path) || return nothing
    try
        open(path, "r+") do io
            write(io, 0x01)
        end
    catch
        # A waiter that closed its end between the isfifo check and the open:
        # not this hook's job to report, since the agent's own read() is the
        # source of truth, not this nudge.
    end
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
    start_session(; port=nothing) -> server record

Start a Pluto server in this process. The HTTP server exists only so a human
can open the notebook in a browser; nothing here talks to it over the network.

Registers an `on_event` hook first, so changes are observable from the moment
the session exists rather than from the first time someone asks. The same
hook also pokes each notebook's wake FIFO, if one is waiting (`_poke_wake!`).

Calling this twice stops whatever was already running first -- otherwise
SERVER would just be overwritten, leaking the previous server and every
notebook worker process it owned.
"""
function start_session(; port::Union{Nothing,Int}=nothing)
    SERVER[] === nothing || stop_session()
    port = something(port, _free_port())
    options = Pluto.Configuration.from_flat_kwargs(;
        port, launch_browser=false, require_secret_for_access=true,
        on_event = function (e)
            if e isa Pluto.StateChangeEvent
                _note_change!(e.notebook)
                _poke_wake!(e.notebook)
            end
            nothing
        end,
    )
    session = Pluto.ServerSession(; options)
    server = Pluto.run!(session)
    SERVER[] = (host="localhost:$port", secret=session.secret,
                    session=session, server=server,
                    # Every open notebook is already tracked by
                    # session.notebooks (Pluto's own Dict{UUID,Notebook}); this
                    # is only which one a call that names no notebook means.
                    current=Ref{Union{Nothing,Base.UUID}}(nothing))
    return SERVER[]
end

"""
Shut down every notebook this session has open -- each one owns a worker
process -- THEN close the HTTP server. `close(server)` alone leaves those
worker processes running with nothing left to stop them.

Also sweeps each notebook's spill directory: oversize output is written there
so a payload can name a path instead of carrying megabytes, and the files are
only meaningful while the session that produced them is alive.
"""
function stop_session()
    s = session()
    for nb in collect(values(s.session.notebooks))
        rm(spill_dir(nb); recursive=true, force=true)
        Pluto.SessionActions.shutdown(s.session, nb; async=false)
    end
    close(s.server)
    SERVER[] = nothing
    # CODE_SENT survives: stopping a server does not empty the agent's context.
    empty!(CHANGES); empty!(SNAPSHOTS); empty!(REPORTED); empty!(RUN_LOCKS)
    return nothing
end

"The running server, or a clear refusal. Every tool resolves this first."
function session()
    SERVER[] === nothing && error("no server running — call start first")
    return SERVER[]
end

"""
    _notebook(; ref=nothing) -> Pluto.Notebook

Resolve which open notebook a tool call means. Every notebook that is open is
already in `s.session.notebooks`
(Pluto's own registry, keyed by notebook_id) -- `open`/`create` never
replaced anything there, only our own single-notebook `Ref` did.

`ref` is a file name -- a path, or any unambiguous suffix of one, so the
basename is usually enough -- or `nothing` for the CURRENT notebook, the one
the most recent `open` selected.

A file name, not an id: the notebook_id is Pluto's internal handle, it means
nothing to a reader, and a notebook already has a name that everyone involved
already uses.
"""
function _notebook(; ref::Union{Nothing,AbstractString}=nothing)
    s = session()
    open_paths() = sort!([basename(nb.path) for nb in values(s.session.notebooks)])
    if ref === nothing
        id = s.current[]
        id === nothing && error("no notebook open — call open first")
        return s.session.notebooks[id]
    end
    hits = [nb for nb in values(s.session.notebooks) if endswith(nb.path, ref)]
    length(hits) == 1 && return only(hits)
    length(hits) > 1 && error("\"$ref\" matches $(length(hits)) open notebooks: $(join(open_paths(), ", "))")
    error("no open notebook matches \"$ref\" — open: $(join(open_paths(), ", "))")
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
function resolve_cells(nb::Pluto.Notebook, ref::AbstractString)
    for c in nb.cells
        string(c.cell_id) == ref && return Pluto.Cell[c]
    end
    # Every cell that declares this name. Usually one, because a variable is
    # assigned in exactly one cell -- but a function's methods may be spread
    # across cells (`f(x::Int)` here, `f(x::String)` there), and two cells
    # assigning the same global is the MultipleDefinitionsError, where seeing
    # both IS the diagnosis.
    decls = declarations(nb)
    hits = [c for c in nb.cells if ref in decls[string(c.cell_id)]]
    isempty(hits) || return hits
    hits = [c for c in nb.cells if startswith(string(c.cell_id), ref)]
    length(hits) == 1 && return hits
    length(hits) > 1 && error("\"$ref\" is ambiguous — it matches $(length(hits)) cells")
    error("no cell named or identified by \"$ref\"")
end

"""
    resolve_cell(nb, ref) -> Pluto.Cell

The one cell `ref` names, for the tools that write to it.

`read` takes every cell a name resolves to; writing needs exactly one, so a
name that several cells declare is a refusal here rather than a guess.
"""
function resolve_cell(nb::Pluto.Notebook, ref::AbstractString)
    cells = resolve_cells(nb, ref)
    length(cells) == 1 && return only(cells)
    error("\"$ref\" is declared in $(length(cells)) cells — name the one you mean by its id")
end

"""
    declarations(nb) -> Dict(cell_id => names)
    declarations(nb, c) -> Vector{String}

Every name each cell declares: globals it assigns, and functions it defines.

Pluto's reactivity graph again, never the source. `cell_labels` picks ONE of
these to show, because a cell needs a name a reader can hold on to; this is the
whole set, because a cell defining `a, b` answers to both.

Computed for the whole notebook at once: `updated_topology` reuses its analysis
for every cell whose source has not changed, and asking cell by cell would
throw that away N times over.
"""
function declarations(nb::Pluto.Notebook)
    top = Pluto.updated_topology(nb.topology, nb, nb.cells)
    out = Dict{String,Vector{String}}()
    for c in nb.cells
        node = top.nodes[c]
        names = String[string(d) for d in node.definitions]
        append!(names, String[string(f) for f in node.funcdefs_without_signatures])
        out[string(c.cell_id)] = unique!(names)
    end
    out
end

declarations(nb::Pluto.Notebook, c::Pluto.Cell) = declarations(nb)[string(c.cell_id)]

# ------------------------------------------------------------------ reading --

"""
    is_blocked(c) -> Bool

Whether this cell will not run, however the notebook is driven.

Pluto's own metadata: a person disables a cell in the browser, and Pluto marks
everything downstream `depends_on_disabled_cells`. Neither runs. Reported,
never set -- switching a cell off is a decision about someone's notebook.
"""
is_blocked(c::Pluto.Cell) = Pluto.is_disabled(c) || c.depends_on_disabled_cells

"""
    cell_status(c) -> String

One enum, and the only progress vocabulary anywhere:

  running     executing right now -- one cell at a time, since Pluto runs a
              notebook's cells in sequence in a single worker
  queued      in this run, waiting its turn
  success     it ran
  error       it ran and threw, or the reactivity graph rejects it (two cells
              defining `a`, a cycle) -- the message says which
  disabled    switched off, or downstream of something switched off
  unrun       no result and no run coming: a notebook held for review, a dead
              worker, a cell that has never run, or one the agent interrupted.
              An interrupt is an absence, not a failure, and the message it
              leaves says nothing the caller did not ask for. A worker that
              DIED is different and stays an `error`: every global went with it

`running` and `queued` are separate words because "which one is this waiting
on" is a question worth answering: Pluto's own UI shows them alike and leaves
you hunting for the ticking counter.

The order below is the precedence, and two entries in it are deliberate.
`queued` outranks `error`: a cell waiting to re-run still carries the error
from the run before, which describes a world that no longer exists. `disabled`
outranks `error` for the mirror reason -- nothing is going to revisit it.
"""
function cell_status(c::Pluto.Cell)
    c.running && return "running"
    c.queued && return "queued"
    is_blocked(c) && return "disabled"
    # An interrupt is not a failure, it is an absence: the caller asked for the
    # stop, and what is left is a cell with no result — the same place the
    # cells behind it in the queue are.
    (was_interrupted(c) || c.output.last_run_timestamp == 0) && return "unrun"
    c.errored && return "error"
    "success"
end

"""
    aggregate_status(statuses, finished) -> String

The record's own `status`, by one rule: the most urgent thing any reported cell
is doing. `error`, then `running`, then `queued`, then `unrun`, then `disabled`,
then `success`.

`finished` folds in the one thing the cells cannot say. An asynchronous run
that has not yet touched its first cell leaves every cell looking settled, and
calling that `success` would be a lie with a receipt.
"""
function aggregate_status(statuses, finished::Bool)
    any(==("error"), statuses) && return "error"
    (!finished || any(==("running"), statuses)) && return "running"
    for s in ("queued", "unrun", "disabled")
        any(==(s), statuses) && return s
    end
    "success"
end

"""
    running_seconds(nb) -> Union{Nothing,Float64}

How long the cell executing right now has been going.

Pluto keeps this in its status tree, which reports each cell of a run as a
`Business` with `started_at` and `finished_at` -- keyed by position in the run
rather than by cell, so the one that is started and not finished IS the one
executing. Best effort over a Pluto internal: no field, no number, and the
record simply does not carry one.
"""
function running_seconds(nb::Pluto.Notebook)
    try
        evaluate = nb.status_tree.subtasks[:run].subtasks[:evaluate]
        for b in values(evaluate.subtasks)
            b.started_at === nothing || b.finished_at !== nothing && continue
            return time() - b.started_at
        end
    catch
    end
    nothing
end

# Seconds, like every other duration here, and to three significant digits: a
# cell that takes 12 microseconds should read 1.23e-5 rather than 0.0.
_round_seconds(s::Nothing) = nothing
_round_seconds(s::Real) = round(Float64(s); sigdigits=3)
_seconds(ns::Nothing) = nothing
_seconds(ns::Real) = round(ns / 1e9; sigdigits=3)

"""
    running_progress(c) -> Union{Nothing,Float64}

The fraction a cell reports through `@progress`, if it reports one.

ProgressLogging.jl logs at its own level with a `progress` keyword, which Pluto
captures like any other log entry. As a log line it is noise -- the same
message forty times -- and as a number it is the one thing worth knowing about
a long run.
"""
function running_progress(c::Pluto.Cell)
    for e in Iterators.reverse(c.logs)
        for kv in get(e, "kwargs", ())
            kv isa Tuple && length(kv) == 2 && string(first(kv)) == "progress" || continue
            v = _logtext(last(kv))
            v == "done" && return 1.0
            f = tryparse(Float64, v)
            f === nothing || return round(f; sigdigits=3)
        end
    end
    nothing
end

_is_progress(e) = any(kv -> kv isa Tuple && length(kv) == 2 && string(first(kv)) == "progress",
                      get(e, "kwargs", ()))

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
    status = cell_status(c)
    # A cell with no current result reports none. Pluto keeps the PREVIOUS
    # output on screen while a cell is queued or re-running, which is right for
    # a human watching a value blink and wrong for a reader who would take it
    # for the answer to the code that is there now.
    if status in ("queued", "unrun", "running")
        entry = (name = label, cell_id = string(c.cell_id), status = status)
        # What it took last time it finished, which is what says whether to
        # wait -- on a queued cell too.
        status == "unrun" && return entry
        ran = _seconds(c.runtime)
        ran === nothing || (entry = merge(entry, (ran_seconds = ran,)))
        status == "queued" && return entry
        # Running: how long so far, how far along, and the logs of THIS run --
        # Pluto clears them when the cell starts, so they are current.
        for (k, v) in ((:running_seconds, _round_seconds(running_seconds(nb))),
                       (:running_progress, running_progress(c)))
            v === nothing || (entry = merge(entry, NamedTuple{(k,)}((v,))))
        end
        logs, _ = render_logs(nb, c, label)
        return isempty(logs) ? entry : merge(entry, (logs = logs,))
    end
    logs, dropped = render_logs(nb, c, label)
    info = merge((name = label,
                  cell_id = string(c.cell_id),
                  status = status,
                  code = c.code,
                  ran_seconds = _seconds(c.runtime)),
                 render_output(nb, c, label))
    isempty(logs) || (info = merge(info, (logs = logs,)))
    dropped === nothing || (info = merge(info, (logs_dropped = dropped,)))
    change === nothing || (info = merge(info, change))
    return info
end

#=
cell_id => (fingerprint, reported_at) for the last version of that cell the
client was told about. A cell_id is a UUID, so it needs no notebook to file it
under.

The reference point is the agent's context, not the notebook's history, and
that is why the map is written only while building a record -- never from a
StateChangeEvent. A cell that changed and changed back between two records was
never reported in between, so there is nothing for the agent to re-read: ABA is
the right answer here, not a bug to defend against.
=#
const REPORTED = Dict{Base.UUID,Tuple{UInt64,Float64}}()

#=
Hashes of every piece of cell text this client has been sent -- by a record
that carried it, or by the `edit` that supplied it in the first place.

One flat set, not a map per notebook, because the thing it models is the
CLIENT'S CONTEXT, and that context does not reset when a notebook does. Reopen
a file this agent wrote and Pluto hands back a fresh notebook_id; a
per-notebook ledger would forget everything and read the whole file back to the
agent that wrote it minutes earlier.

Kept apart from REPORTED because it answers a different question. REPORTED asks
"is this whole entry the one I last sent?", which a re-run to a new output makes
false; the code is unchanged all the same, and an execution cascade never
rewrites code.

Recovery is `read(cells=[...])`. The agent's context is the reference point,
and after a compact it no longer holds what this set claims -- so naming cells
means send them whole, ledger or no ledger. An agent that still holds a cell
has no reason to name it.
=#
const CODE_SENT = Set{UInt64}()

"""
    _mark_code_sent!(code)

Record `code` as text the client holds. `edit` calls it with the code it was
handed: the caller wrote that text, so reading it back is the one field of the
record they already have.
"""
_mark_code_sent!(code::AbstractString) = (push!(CODE_SENT, hash(code)); nothing)

"Drop a cell from the reported map, so a deleted cell stops costing memory."
function _forget_reported!(cell_id)
    delete!(REPORTED, cell_id)
    # CODE_SENT is deliberately untouched: deleting a cell does not un-send its
    # text to the agent that is still holding it.
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
    record(nb, cells, finished, waited; since, changes, extra...) -> NamedTuple

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
function record(nb::Pluto.Notebook, cells, finished::Bool, waited::Real;
                since::Union{Nothing,Real,AbstractString}=nothing, full::Bool=false,
                changes::Dict{String,<:NamedTuple}=Dict{String,NamedTuple}(), extra...)
    timestamp = time()
    labels = cell_labels(nb)
    # `full` is a read that named its cells: nothing is compacted and nothing
    # is suppressed. The only reason to name a cell is not knowing, or not
    # remembering, what is in it -- and an agent that knows does not ask.
    holds_code(c) = !full && hash(c.code) in CODE_SENT

    entries = Any[]
    statuses = String[]
    for c in cells
        if !(c isa Pluto.Cell)          # a synthetic entry: a deleted cell
            # Deduped like any real cell: a deletion is news exactly once. The
            # CHANGES log keeps the entry for `since` arithmetic, but a bare
            # read that already delivered it must not repeat it -- and there is
            # no compact form to fall back to, because the cell is no longer in
            # the notebook and a summary line would claim it is.
            id = tryparse(Base.UUID, String(get(c, :cell_id, "")))
            fingerprint = hash(c)
            previous = id === nothing ? nothing : get(REPORTED, id, nothing)
            previous !== nothing && first(previous) == fingerprint && continue
            id === nothing || (REPORTED[id] = (fingerprint, timestamp))
            push!(entries, c)
            push!(statuses, get(c, :status, "success"))
            continue
        end
        id = string(c.cell_id)
        push!(statuses, cell_status(c))
        fingerprint = cell_fingerprint(c)
        previous = get(REPORTED, c.cell_id, nothing)
        # A running cell is never "unchanged": it is moving, and how far it has
        # got is the news. Its fingerprint deliberately ignores progress
        # records — a thousand of them are one fact, not a thousand changes —
        # so compaction would freeze `running_seconds` and `running_progress`
        # at whatever the first read happened to see.
        if !full && cell_status(c) != "running" &&
           previous !== nothing && first(previous) == fingerprint
            since === nothing && push!(entries, (name = labels[id],
                                                 status = cell_status(c),
                                                 unchanged_since = iso_timestamp(last(previous))))
            continue
        end
        REPORTED[c.cell_id] = (fingerprint, timestamp)
        info = cell_info(nb, c, labels; change = get(changes, id, nothing))
        # Code the agent holds is dropped, not the entry: status, output, logs
        # and any error are what the run was asked for.
        holds_code(c) ? (info = Base.structdiff(info, NamedTuple{(:code,)})) :
                        push!(CODE_SENT, hash(c.code))
        # ...and the same test on the way out: a cell whose rendered output is
        # text the client supplied says nothing by repeating it.
        !full && haskey(info, :output) && info.output isa AbstractString &&
            hash(String(info.output)) in CODE_SENT &&
            (info = Base.structdiff(info, NamedTuple{(:output,)}))
        push!(entries, info)
    end
    base = (status = aggregate_status(statuses, finished),
            waited_seconds = round(Float64(waited); digits=2),
            timestamp = iso_timestamp(timestamp),
            cells = entries)
    # Pluto is holding this notebook for review: nothing runs, whatever is
    # edited. Said in every record, not just the one from `open` — a read an
    # hour later is owed the same explanation, and an edit that quietly did not
    # run is the worst thing this surface could do silently.
    nb.process_status == Pluto.ProcessStatus.waiting_for_permission &&
        (base = merge(base, (awaiting_permission = true,)))
    merge(base, NamedTuple(extra))
end

cells_info(nb::Pluto.Notebook) =
    (labels = cell_labels(nb); [cell_info(nb, c, labels) for c in nb.cells])

# ------------------------------------------------------------------ writing --

"""Run `cells` synchronously: save the file, push patches to every browser, return when done."""
function run_cells!(nb::Pluto.Notebook, cells::Vector{Pluto.Cell}; save::Bool=true)
    s = session()
    # Cheap when nothing restarted, and the only moment we are guaranteed to be
    # asked before a cell runs.
    ensure_renderer!(s.session, nb)
    isempty(cells) || Pluto.withtoken(_run_lock(nb)) do
        Pluto.update_save_run!(s.session, nb, cells; run_async=false, save)
    end
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
    run_with_deadline(nb, cells; wait_seconds=1.0) -> (finished, waited, touched)

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
function run_with_deadline(nb::Pluto.Notebook, cells::Vector{Pluto.Cell};
                           wait_seconds::Real=1.0, save::Bool=true)
    s = session()
    isempty(cells) && return (true, 0.0, Pluto.Cell[])
    # Every run funnels through here, which makes it the one place that can
    # notice the worker was replaced under us (see ensure_renderer!).
    ensure_renderer!(s.session, nb)
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

    task = @async Pluto.withtoken(f, _run_lock(nb))
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
    notebook_source(cells) -> Pluto.Notebook

Build a notebook from `Pluto.Cell`/`Pluto.Notebook` directly -- never by
hand-writing the `.jl` file's text format, which only Pluto should own. Not
yet saved to disk; call `Pluto.save_notebook` (or open it via a session) when
ready.
"""
function notebook_source(cells::Vector{String})
    pcells = [new_cell(src) for src in cells]
    Pluto.Notebook(pcells)
end

"""
    is_prose(code) -> Bool

Whether this cell is prose: its expression is `md"…"` or `html"…"`.

Not a cell type -- Pluto has none, and neither does the tool surface. It is a
guess about DISPLAY, made where a person would make the same one.
"""
is_prose(code::AbstractString) = occursin(r"^\s*(md|html)\"", code)

"""
    new_cell(code) -> Pluto.Cell

Every cell this package creates, made in one place.

`uuid4`, not `Cell`'s default `uuid1`: uuid1 is time-based, so cells created in
a loop land in the same tick, share a long leading run of digits, and a short
prefix identifies nothing. Random ids keep prefixes discriminating.

Prose starts folded, the way a person writing a notebook would fold it: Pluto
renders `md"…"` and the source is one click away, so leaving it open puts a
paragraph of markup in front of a reader who wanted the paragraph. It is a
display default and nothing more -- `code_folded` is Pluto's own field, it
persists in the file (a `# ╟─` line rather than `# ╠═`), the human unfolds it
with one click, and no tool takes it, reports it or depends on it.
"""
new_cell(code::AbstractString) =
    Pluto.Cell(; cell_id=uuid4(), code=String(code), code_folded=is_prose(code))

# --------------------------------------------------------- the render helper --

#=
The worker side of `output`.

Pluto keeps a RENDERING of each cell's value, chosen by its own MIME
preference. This is the value itself, out of `PlutoRunner.cell_results`, so
`show` can be asked for any MIME the object supports -- which is all `output`
ever needed. A figure answers `image/png` with a picture and `image/svg+xml`
with the XML because that is what the object does, and this file knows nothing
about plots.

It is injected into the WORKER, not written into the notebook: the notebook is
the artifact a human keeps, and a helper the server needs is not something the
reader should have to scroll past. It goes into the worker's `Main`, which
Pluto never bumps -- unlike `Main.workspace#N`, which is rebuilt on every
reactive run. Nothing is added to `workspace_preamble` and nothing is visible
to cells: no cell has any reason to call this.
=#
const RENDERER_SOURCE = raw"""
module PlutoMCP

_value(id) = getfield(Main, :PlutoRunner).cell_results[Base.UUID(id)]

# Far past anything worth carrying, and still cheap in-process;
# `IOBuffer(maxsize=)` stops the write rather than the machine.
const RENDER_CAP = 32_000_000

# Every MIME worth offering, in the order a person would try them.
const CANDIDATES = ["text/plain", "text/html", "text/markdown", "text/latex",
                    "image/png", "image/svg+xml", "image/jpeg", "application/pdf"]

# render(id, mime) -> Vector{UInt8}, or nothing if the value cannot do that MIME.
#
# `show(io, MIME(mime), value)` and nothing else -- the same dispatch a frontend
# or a file writer gets. text/plain is the display form with the REPL's elision
# turned off, which is the most complete text there is.
function render(id, mime::AbstractString)
    v = _value(id)
    io = IOBuffer(maxsize=RENDER_CAP)
    if mime == "text/plain"
        show(IOContext(io, :limit => false, :color => false, :compact => false),
             MIME"text/plain"(), v)
    elseif showable(MIME(mime), v)
        show(io, MIME(mime), v)
    else
        return nothing
    end
    take!(io)
end

# What this value can be shown as, for a caller who asked for something it cannot.
offers(id) = (v = _value(id);
              [m for m in CANDIDATES if m == "text/plain" || showable(MIME(m), v)])

end
"""

# Which worker process each notebook's renderer was injected into. Pluto starts
# a NEW process when the package environment changes -- `using Plots` in a cell
# installs a package and restarts -- and the fresh process has no
# `Main.PlutoMCP`. Injecting once at `open` is therefore not enough: the helper
# disappears exactly when a notebook first acquires a plotting library, which is
# when it is about to be needed.
const INJECTED_WORKER = Dict{Base.UUID,Any}()

_current_worker(session, nb::Pluto.Notebook) =
    try
        ws = Pluto.WorkspaceManager.get_workspace((session, nb); allow_creation=false)
        ws === nothing ? nothing : ws.worker
    catch
        nothing  # discarded workspace, or an internal that moved: fall through and re-inject
    end

"""
    needs_full_run(session, nb) -> Bool

Whether this notebook has nothing live to run a single cell against.

Two ways to get there, and Pluto's answer to both is the same one its own
"Run notebook code" banner takes (`restart_process`): run every cell.

  - `waiting_for_permission` -- Pluto opened a notebook it considers risky and
    is holding it for a human to look at. `will_run_code` is false, so an edit
    would quietly not execute and the agent would watch `unrun` forever.
  - no worker -- the process died, or was restarted for a package install.
    Every global went with it, so one cell cannot be re-run against what is
    left, because nothing is left.
"""
needs_full_run(session, nb::Pluto.Notebook) =
    nb.process_status == Pluto.ProcessStatus.waiting_for_permission ||
    _current_worker(session, nb) === nothing

"""
    ensure_renderer!(session, nb)

Re-inject the renderer if this notebook is running in a worker we have not
injected into. The check is in-process -- an identity comparison against the
`Workspace`'s worker -- so the common case costs no round trip to the worker
and nothing is evaluated.
"""
function ensure_renderer!(session, nb::Pluto.Notebook)
    worker = _current_worker(session, nb)
    worker !== nothing && get(INJECTED_WORKER, nb.notebook_id, nothing) === worker && return nothing
    inject_renderer!(session, nb)
end

"""
    inject_renderer!(session, nb)

Define `Main.PlutoMCP` in this notebook's worker. Best-effort: failing to add a
helper is never a reason to fail the `open` that asked for it.
"""
function inject_renderer!(session, nb::Pluto.Notebook)
    try
        Pluto.WorkspaceManager.eval_in_workspace((session, nb),
            # Defined once. Re-evaluating would print a "replacing module"
            # warning and invalidate the module on every open.
            :(isdefined(Main, :PlutoMCP) ||
              Core.eval(Main, $(QuoteNode(Meta.parseall(RENDERER_SOURCE))))))
        # Record only on success, and only after the eval: the workspace may
        # not have existed until eval_in_workspace made it.
        let worker = _current_worker(session, nb)
            worker === nothing || (INJECTED_WORKER[nb.notebook_id] = worker)
        end
    catch e
        # Warned, not swallowed: a helper that silently stopped existing turns
        # into a mystifying `output` failure much later. stderr is safe -- the
        # JSON-RPC transport owns stdout, nothing else.
        @warn "PlutoMCP's render helper could not be injected into the worker" exception=e
    end
    return nothing
end
