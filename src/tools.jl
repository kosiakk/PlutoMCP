#=
The MCP surface: eight tools, one record, one vocabulary.

Eight because every capability question has the same answer -- the agent writes a
cell. Probing a value, reading a docstring, computing a statistic, rendering a
plot: all of these are cells, usually deleted on success. Tools exist only where
cells cannot reach: lifecycle, the result record, raw bytes, and human-edit
history. A new tool has to pass both gates: cells cannot do it, and usage shows
the need.

Two renderers, and neither of them is this package:

  the record   is PLUTO's rendering -- its summary of a value, one line, one
               level deep (see render.jl)
  `output`     is JULIA's -- `show(io, MIME"text/plain"(), x)` with the REPL's
               elision turned off, on the value itself, fetched from the worker

The plot is the exception on both sides, and only because Pluto stores one MIME
per cell and prefers SVG, which no MCP client can show: the record says `mime`
and stops, and `output` asks the figure's own library for a PNG.

One vocabulary, no synonyms:

  wait_seconds     how long to wait, on every tool that runs or waits
  waited_seconds   the receipt for it, in the record
  status           running | queued | success | error | disabled | unrun,
                   cell and record alike
  ran_seconds      how long a cell's last completed run took
  running_seconds  how long the one executing now has been going
  running_progress how far along, when the cell says so with @progress
  code             the text of a cell, everywhere (Pluto's own word)
  cell / cells     the only way to address cells: name, UUID, or unique prefix
  timestamp        server clock in the record, ISO 8601 UTC; copy it back into `since`
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

# Long enough that an ordinary cell finishes inside the call, short enough that
# a slow one does not hold the agent up. An explicit 0 is the deliberate
# fire-and-forget, for authoring a run of cells before reading any of them.
const DEFAULT_WAIT = 0.1

_wait(args, default=DEFAULT_WAIT) = Float64(something(get(args, "wait_seconds", default), default))
_nb(args) = _notebook(; ref=get(args, "notebook", nothing))

"""Resolve the `cells` argument, or the whole notebook when it is absent."""
function _targets(args, nb, key="cells")
    v = get(args, key, nothing)
    v === nothing && return copy(nb.cells)
    Pluto.Cell[resolve_cell(nb, String(r)) for r in v]
end

const CELL_REF_DOC = "A cell NAME (a global it defines, e.g. \"throughput\"), a full UUID, or any unambiguous prefix of one (\"0dfbd0b6\" is normally plenty — ids are random)."

const NOTEBOOK_PARAM = ToolParameter(name="notebook", type="string",
    description="Which open notebook, if more than one is open: its file name. Omit for the current one — the last one opened.",
    required=false)

wait_param(default=DEFAULT_WAIT) = ToolParameter(name="wait_seconds", type="number",
    description="Seconds to wait before returning the record (default $default). The record comes back on completion, on a new error, or on expiry — whichever is first. Expiry shows as status=\"running\"; nothing is cancelled. Pass 0 to fire and forget — a slow cell keeps going and the browser shows it, so there is rarely a reason to sit and wait.",
    required=false, default=default)

# ------------------------------------------------------------------ lifecycle --

pluto_start = MCPTool(
    name="start",
    description="Start a Pluto server in this process and return its host and secret. The HTTP server exists only so a human can watch in a browser; every tool here calls Pluto directly. Follow with open.",
    parameters=[
        ToolParameter(name="port", type="number", description="Port for the browser UI; a free one is picked if omitted", required=false),
    ],
    handler=(args -> @safely begin
        s = start_session(; port = haskey(args, "port") ? Int(args["port"]) : nothing)
        _ok((host=s.host, secret=s.secret))
    end),
    return_type=TextContent,
)

pluto_open = MCPTool(
    name="open",
    description="""Get a notebook: open an existing .jl file, or create a new one with create=true.

Give the returned URL to the user — every later edit appears there live. The notebook you open is the current one; later calls default to it, and name any other by its file name. Name the file after the experiment when the work is meant to be kept; a pathless create is a scratch notebook in a temp directory.

Pluto runs cells in DEPENDENCY order and allows one definition of a global per cell, so prefer `x = let ... end` over `begin ... end`. Dependencies install themselves: write `using Plots` in a cell and Pluto records the resolved versions in the notebook file.""",
    parameters=[
        ToolParameter(name="path", type="string", description="Path to the notebook .jl file. Omit only with create=true, for an anonymous scratch notebook.", required=false),
        ToolParameter(name="create", type="boolean", description="Create the notebook instead of opening an existing one (default false)", required=false, default=false),
        wait_param(),
    ],
    handler=(args -> @safely begin
        s = session()
        path = get(args, "path", nothing)
        create = get(args, "create", false)
        path === nothing && !create &&
            error("open needs a path, or create=true for a new scratch notebook")

        target = create ? _draft_path(path === nothing ? nothing : String(path)) : String(path)
        # `open` means "get me this notebook", so a path the session already has
        # open is a hit, not a conflict. Pluto's own SessionActions.open throws
        # NotebookIsRunningException for this case, which is right for its HTTP
        # router and wrong here.
        already = _already_open(s, target)
        nb, finished, waited = already === nothing ?
            _open_awaited(s, target; wait_seconds=_wait(args)) :
            (already, wait_for_idle(already; wait_seconds=_wait(args))[1:2]...)
        s.current[] = nb.notebook_id
        for c in nb.cells
            _mark_seen!(nb.notebook_id, c.cell_id, c.code)
        end
        # ensure, not inject: reopening an already-open notebook (a hit above)
        # has a live, already-injected worker, and the identity check is free.
        ensure_renderer!(s.session, nb)
        # Pluto refuses to run a notebook it considers risky until a person has
        # looked at it. Nothing else in the record explains why every cell is
        # `unrun` and nothing is wrong, so it says so — and the next `edit`
        # is what grants permission.
        _ok(record(nb, nb.cells, finished, waited; url=notebook_url(s, nb), path=nb.path))
    end),
    return_type=TextContent,
)

"""
Write the file a `create` will open: an empty notebook.

A pathless create lands in a temp directory under Pluto's own cutename, so a
scratch notebook never accumulates in the directory a person keeps their real
ones in. A named one is taken literally, and `numbered_until_new` keeps a second
run of the same experiment from overwriting the first.
"""
function _draft_path(filename::Union{Nothing,String})
    base = filename === nothing ?
        joinpath(mkpath(joinpath(tempdir(), "plutomcp")), Pluto.cutename()) :
        (endswith(filename, ".jl") ? filename[1:end-3] : filename)
    dirname(base) == "" && (base = joinpath(Pluto.new_notebooks_directory(), base))
    draft = notebook_source(String[])
    draft.path = Pluto.numbered_until_new(base; suffix=".jl")
    Pluto.save_notebook(draft)
    draft.path
end

"""The session's notebook for this path, if it has one. Compared by realpath,
the same way Pluto compares them, so `./x.jl` and an absolute path are one
notebook rather than two."""
function _already_open(s, path::AbstractString)
    isfile(path) || return nothing
    target = realpath(path)
    for nb in values(s.session.notebooks)
        isfile(nb.path) && realpath(nb.path) == target && return nb
    end
    nothing
end

"""
    _open_awaited(s, path; wait_seconds) -> (nb, finished, waited)

Open a notebook and honour `wait_seconds` over its run.

`SessionActions.open`'s own `run_async=true` wraps the run in `@async`
internally and hands back nothing to wait on, leaving busy/queued flags as the
only completion signal -- which reads "settled" for a cell that fails to PARSE,
because such a cell never reaches running or queued at all. Doing the `@async`
here, with a notebook_id we chose, gives both the real notebook (open registers
it into `session.notebooks` synchronously, well before any cell runs) and
`istaskdone` as the literal answer.
"""
function _open_awaited(s, path::String; wait_seconds)
    notebook_id = uuid4()
    task = @async Pluto.SessionActions.open(s.session, path; run_async=false, notebook_id)
    t0 = time()
    nb = nothing
    while nb === nothing && !istaskdone(task)
        nb = get(s.session.notebooks, notebook_id, nothing)
        nb === nothing && sleep(0.01)
    end
    # Never registered under the id we chose, and the task is already done:
    # either opening failed (a load error, an unwritable path), which fetch
    # re-raises, or Pluto handed back a notebook of its own choosing. Take the
    # task's own return value in both cases -- dropping it here would leave nb
    # as nothing and fail one step later, with a worse message.
    nb === nothing && (nb = fetch(task))
    while !istaskdone(task) && time() - t0 < wait_seconds
        sleep(0.02)
    end
    istaskdone(task) && istaskfailed(task) && fetch(task)
    (nb, istaskdone(task), time() - t0)
end

pluto_stop = MCPTool(
    name="stop",
    description="""Stop things, narrowing with each argument.

No arguments: shut the whole session down — server, notebook workers, spill files. `notebook`: shut down that one notebook. `notebook` and `cell`: interrupt what the notebook is evaluating right now, the same as the browser's stop button. A cell cannot interrupt itself, which is why that last one is a tool.

An interrupted cell reports `unrun` — you asked for the stop, so its error is not news. Pluto escalates a stop that is ignored into killing the worker, and then every value in the notebook is gone: the cell says so with an `error`, and your next `edit` re-runs the notebook.""",
    parameters=[
        NOTEBOOK_PARAM,
        ToolParameter(name="cell", type="string", description="With `notebook`: interrupt this cell's evaluation instead of shutting anything down. $CELL_REF_DOC", required=false),
    ],
    handler=(args -> @safely begin
        if get(args, "notebook", nothing) === nothing
            get(args, "cell", nothing) === nothing ||
                error("stop with a cell also needs a notebook")
            stop_session()
            return _ok((stopped="server",))
        end
        s = session(); nb = _nb(args)
        ref = get(args, "cell", nothing)
        if ref === nothing
            rm(spill_dir(nb); recursive=true, force=true)
            # This notebook's share of the flat state. CODE_SENT is untouched:
            # closing a notebook does not un-send its text to the agent.
            for c in nb.cells
                _forget_seen!(c.cell_id); _forget_reported!(c.cell_id)
            end
            filter!(e -> e.notebook_id != nb.notebook_id, CHANGES)
            path = nb.path
            s.current[] == nb.notebook_id && (s.current[] = nothing)
            Pluto.SessionActions.shutdown(s.session, nb; async=false)
            return _ok((stopped="notebook", path=path))
        end
        c = resolve_cell(nb, String(ref))
        # Pluto interrupts the WORKER, not one cell: a notebook runs its cells
        # sequentially in one process, so interrupting it stops whatever is
        # running now and `wants_to_interrupt` keeps the queued ones from
        # starting.
        #
        # Guarded on something actually running, exactly as Pluto's own stop
        # button is (Dynamic.jl's response_interrupt_all). The flag is cleared
        # only at the END of a reactive run (Run.jl), so setting it on an idle
        # notebook would not interrupt anything -- it would silently skip the
        # NEXT run's cells instead.
        busy = busy_cells(nb)
        if isempty(busy)
            finished, waited, touched = wait_for_idle(nb; wait_seconds=0)
            return _ok(record(nb, touched, finished, waited; stopped="cell",
                              interrupted=nothing))
        end
        nb.wants_to_interrupt = true
        # verbose=false: Pluto's own version println()s its progress, and
        # stdout belongs to the JSON-RPC transport.
        Pluto.WorkspaceManager.interrupt_workspace((s.session, nb); verbose=false)
        finished, waited, touched = wait_for_idle(nb; wait_seconds=5.0)
        _ok(record(nb, touched, finished, waited; stopped="cell",
                   interrupted=string(c.cell_id)))
    end),
    return_type=TextContent,
)

# -------------------------------------------------------------------- writing --

pluto_edit = MCPTool(
    name="edit",
    description="""Write the notebook. What you pass says what happens:

    code, no cell     a new cell, at the end
    cell + code       that cell's text becomes this
    cell + code ""    the cell is deleted

`code` is Julia, always — prose is a cell whose expression is `md\"\"\"…\"\"\"`. There are no cell types, and there is no order to manage: Pluto runs cells by dependency, not by position.

Editing one cell re-runs whatever depends on it, so a small edit can be a large run; the record lists every cell the cascade touched. There is no separate run tool. Sending a cell's text again runs it again, unchanged or not, which is all that is left for the inputs reactivity cannot see — a file on disk, an RNG, an environment variable.

A deleted cell comes back in the record with `change: "deleted"`, and with its `old_code` if you were not the one who wrote it — so a delete you did not mean is one edit away from undone, and nobody has to be asked "are you sure".

`delete_on_success=true` (new cells only) deletes the cell again if its status is `success` when the call returns — the way to probe a value, read a docstring, compute a statistic or render a plot without leaving anything behind. It runs normally and is visible in the browser while it does. If it errors, or if `wait_seconds` expired before the result was in, the cell stays and you delete it by the returned id.""",
    parameters=[
        ToolParameter(name="cell", type="string", description="The cell to act on. $CELL_REF_DOC Omit to add a new cell at the end.", required=false),
        # NO default. The MCP layer fills a declared default in for an absent
        # parameter, and absence is what says "delete" here.
        ToolParameter(name="code", type="string", description="The cell's text. Empty deletes the cell. Sending a cell's existing text again runs it again.", required=true),
        ToolParameter(name="delete_on_success", type="boolean", description="Delete the cell again if it reaches status=\"success\" before this call returns (default false; new cells only)", required=false, default=false),
        wait_param(),
        NOTEBOOK_PARAM,
    ],
    handler=(args -> @safely begin
        s = session(); nb = _nb(args)
        ref = get(args, "cell", nothing)
        throwaway = get(args, "delete_on_success", false) == true
        # `code` is always given: what happens is decided by whether a cell is
        # named and whether the text is empty. Empty means "there should be no
        # cell" -- an empty cell means nothing, so the token is free for the
        # operation that does. Not JSON null: the published schema types `code`
        # as a string, and a model asked for null sends the four characters
        # "null" instead, measured rather than guessed.
        haskey(args, "code") && args["code"] !== nothing ||
            error("code is required: the cell's text, or \"\" to delete it")
        code = String(args["code"])

        if isempty(code)
            ref === nothing && error("a new cell needs code")
            c = resolve_cell(nb, String(ref))
            # Name and text before removal: a label exists only while the cell
            # does, and handing the code back is what makes a mistaken delete
            # something the agent can undo from this same record.
            label = cell_labels(nb)[string(c.cell_id)]
            # The text comes back only if the agent does not already hold it.
            # An undo needs the code; an agent that wrote the cell has it.
            old_code = hash(c.code) in CODE_SENT ? nothing : c.code
            _remove_cell!(nb, c)
            # Hand the removed cell to the run: the topology then sees it defines
            # nothing, so its globals are released and dependents re-run.
            finished, waited, touched = run_with_deadline(nb, _run_set(nb, c, false);
                                                          wait_seconds=_wait(args))
            gone = (name=label, cell_id=string(c.cell_id), status="success",
                    change="deleted")
            old_code === nothing || (gone = merge(gone, (old_code=old_code,)))
            return _ok(record(nb, Any[gone; filter(x -> x.cell_id != c.cell_id, touched)],
                              finished, waited))
        end

        if ref === nothing
            c = new_cell(code)
            Pluto.withtoken(nb.executetoken) do
                push!(nb.cell_order, c.cell_id)
                nb.cells_dict[c.cell_id] = c
            end
            _mark_seen!(nb.notebook_id, c.cell_id, c.code)
            _mark_code_sent!(c.code)
            # save=!throwaway is an implementation detail, not the contract:
            # skipping the intermediate write keeps a probe out of the file in
            # the common case. What the agent is promised is the deletion below.
            finished, waited, touched = run_with_deadline(nb, _run_set(nb, c, false);
                                                          wait_seconds=_wait(args),
                                                          save=!throwaway)
            r = record(nb, touched, finished, waited)
            # Deleted iff the status is success at RETURN time -- that is the
            # whole contract, hence the name. An errored or still-running
            # cell stays: the agent has to see it to act on it, and a cell that
            # vanished mid-run is a worse surprise than one deleted on purpose.
            if throwaway && r.status == "success"
                label = cell_labels(nb)[string(c.cell_id)]
                _remove_cell!(nb, c)
                Pluto.update_save_run!(s.session, nb, Pluto.Cell[c]; run_async=false, save=false)
                r = merge(r, (deleted=label,))
            end
            return _ok(r)
        end

        c = resolve_cell(nb, String(ref))
        unchanged = c.code == code
        # A cell that BECOMES prose folds, the way one created as prose does.
        # Only on the transition: a cell that was already prose keeps whatever
        # fold state it has, because that state may be a human's deliberate
        # choice to read the source while the agent edits it.
        is_prose(code) && !is_prose(c.code) && (c.code_folded = true)
        c.code = code
        _mark_seen!(nb.notebook_id, c.cell_id, code)
        _mark_code_sent!(code)
        # Identical text is how a cell is re-run: Pluto runs whatever cells it
        # is handed, changed or not, as shift-enter does.
        finished, waited, touched = run_with_deadline(nb, _run_set(nb, c, unchanged);
                                                      wait_seconds=_wait(args))
        _ok(record(nb, touched, finished, waited))
    end),
    return_type=TextContent,
)

"""Take a cell out of the notebook under the same lock the browser's edits use."""
function _remove_cell!(nb, c)
    Pluto.withtoken(nb.executetoken) do
        i = findfirst(==(c.cell_id), nb.cell_order)
        i === nothing || deleteat!(nb.cell_order, i)
        delete!(nb.cells_dict, c.cell_id)
    end
    _forget_seen!(c.cell_id)
    _forget_reported!(c.cell_id)
    return nothing
end

pluto_bond = MCPTool(
    name="bond",
    description="Set an `@bind`-ed variable and re-run its dependents, the way moving the widget in the browser would. Only for variables introduced with `@bind name widget`.",
    parameters=[
        ToolParameter(name="name", type="string", description="The bound variable's name, as written in @bind name widget", required=true),
        ToolParameter(name="value", type="string", description="New value, as the JSON TYPE the widget holds — a number for a slider (7, not \"7\"), true/false for a checkbox, a string only for a textual widget. Sent as given, with no coercion.", required=true),
        wait_param(),
        NOTEBOOK_PARAM,
    ],
    handler=(args -> @safely begin
        s = session(); nb = _nb(args)
        sym = Symbol(String(args["name"]))
        # Not `haskey(nb.bonds, sym)`: a bond no browser has touched (the common
        # case headless) has no entry yet. is_assigned_anywhere is what Pluto's
        # own set_bond_values_reactive checks.
        Pluto.MoreAnalysis.is_assigned_anywhere(nb.topology, sym) ||
            error("no @bind'ed variable named \"$(args["name"])\" -- see read for what this notebook has")
        # Passed through as-is. Pluto's own set_bond_value_pairs! runs the value
        # through transform_bond_value, the same step a browser's JS-typed
        # message goes through, and does NO string->number parsing: a browser
        # never sends "7" for a slider, it sends the JSON number 7. Nothing in a
        # string distinguishes "the number 7, sent as a string" from "the text
        # 7, typed into a text field", so the value's TYPE is the agent's to get
        # right -- see the parameter description.
        nb.bonds[sym] = Pluto.BondValue(args["value"])
        finished, waited, touched = await_run(nb, Pluto.Cell[]; wait_seconds=_wait(args)) do
            # NOT run_async=true: set_bond_values_reactive forwards kwargs
            # straight into run_reactive_async!, so this is the only way to get
            # a call that is genuinely done when it returns.
            Pluto.set_bond_values_reactive(; session=s.session, notebook=nb,
                bound_sym_names=Symbol[sym], run_async=false)
        end
        _ok(record(nb, touched, finished, waited; bound=String(args["name"])))
    end),
    return_type=TextContent,
)

# -------------------------------------------------------------------- reading --

pluto_read = MCPTool(
    name="read",
    description="""The notebook as it is right now: the same record every other tool returns, running nothing.

The notebook object is read directly, so a human's browser edits are already in it. `wait_seconds` waits for the run to go idle or for a new error. `since` (a `timestamp` from an earlier record) drops the cells you already have instead of compacting them. Naming `cells` returns those cells whole — `code` included, even if you were sent it before. That is the way back after a compact; a bare `read` omits code you already hold. Human edits arrive with `old_code` beside the new `code` — the review channel. `tree=true` adds the dependency graph.""",
    parameters=[
        ToolParameter(name="cells", type="array", description="Cell references to report on. $CELL_REF_DOC Omit for all of them.", required=false),
        ToolParameter(name="tree", type="boolean", description="Add each reported cell's references, and its upstream/downstream cells", required=false, default=false),
        wait_param(),
        ToolParameter(name="since", type="string", description="A `timestamp` from an earlier record, e.g. \"2026-08-23T18:42:23.788Z\": omit cells this session has already been shown unchanged, rather than listing them compactly. Copy the value, never compute it.", required=false),
        NOTEBOOK_PARAM,
    ],
    handler=(args -> @safely begin
        nb = _nb(args)
        finished, waited, _ = wait_for_idle(nb; wait_seconds=_wait(args))
        since = get(args, "since", nothing)
        labels = cell_labels(nb)
        targeted = haskey(args, "cells") && args["cells"] !== nothing
        cells = Vector{Any}(targeted ? _targets(args, nb) : copy(nb.cells))
        changes = _human_edits(nb, since)
        # A cell the human deleted has nothing left to describe, so its entry is
        # synthesised, because there is no Cell left to render it from. Never
        # onto a targeted read: a report asked for by name answers with those
        # cells, and a deletion elsewhere in the notebook is not one of them.
        live = Set(string(c.cell_id) for c in nb.cells)
        for (id, e) in changes
            # A deleted cell has no code left: `old_code` is what it was, and
            # there is no `code` to report -- the entry says so by omission.
            (targeted || id in live) ||
                push!(cells, merge((name=id, cell_id=id, status="success",
                                    mime="text/plain", output=""), e))
        end
        # Naming cells is asking to be told about them: they come back whole,
        # code included, however much of it this session was already sent.
        r = record(nb, cells, finished, waited; since, changes, full=targeted)
        if get(args, "tree", false) == true
            # Keyed by name, because a compacted entry carries no cell_id and
            # the dependency graph is worth having either way -- it is a
            # property of the notebook, not of the cell's output.
            trees = Dict(labels[string(c.cell_id)] => _tree_of(nb, c, labels) for c in nb.cells)
            r = merge(r, (cells = [merge(e, get(trees, e.name, NamedTuple())) for e in r.cells],))
        end
        _ok(r)
    end),
    return_type=TextContent,
)

"""
Human browser edits from the CHANGES log, as `old_code` to attach to
a cell's entry. The only history the notebook itself does not hold: an edit made
through these tools marks itself seen before running, so what is left in the log
is genuinely somebody else's.
"""
function _human_edits(nb, since)
    cutoff = something(parse_timestamp(since), -Inf)
    # Text the agent holds is not news, however it got there. A human who typed
    # over a cell and typed it back has ended where the agent already is —
    # Pluto's own Run button disappears in exactly that case — so there is
    # nothing to report.
    held(id) = (c = get(nb.cells_dict, id, nothing); c !== nothing && hash(c.code) in CODE_SENT)
    edits = Dict{String,NamedTuple}()
    for e in CHANGES
        e.notebook_id == nb.notebook_id && e.at > cutoff || continue
        e.change == "edited" && held(Base.UUID(e.cell_id)) && continue
        # `old_code` only. The log is a snapshot from when the event fired, and
        # the cell may have moved on since; the record's `code` is the cell's
        # text as it is NOW, and a stale entry must not override it.
        edits[e.cell_id] = (change=e.change, old_code=e.old_code)
    end
    edits
end

"""One cell's place in Pluto's reactivity graph, by cell name."""
function _tree_of(nb, c::Pluto.Cell, labels)
    # `topology.nodes` is an ImmutableDefaultDict: indexing an unanalysed cell
    # yields an empty node rather than throwing, and it has no 3-arg `get`.
    node = nb.topology.nodes[c]
    bylabel(m) = Dict(string(sym) => unique!([labels[string(cc.cell_id)] for cc in cs])
                      for (sym, cs) in m if !isempty(cs))
    # A macro like @bind or html"..." drags in Pluto's own runtime internals;
    # nobody ever meant to ask about PlutoRunner.Base.get.
    (references = sort!(String[string(r) for r in node.references
                              if !startswith(string(r), "PlutoRunner")]),
     upstream = bylabel(Pluto.upstream_cells_map(c, nb.topology)),
     downstream = bylabel(Pluto.downstream_cells_map(c, nb.topology)))
end

"""
    _run_set(nb, c, unchanged) -> Vector{Pluto.Cell}

The cells to hand the run: this one, or all of them when the notebook has
nothing live to run against.

A dead worker leaves no choice — one cell cannot run in a workspace that holds
nothing, so everything runs.

A notebook Pluto is holding for review is different, and `unchanged` is the
whole of it. Writing a cell back exactly as it stands says "I have read this
and it can run": that is consent, and everything runs. Writing DIFFERENT text
is not consent, it is the agent fixing something it did not like — so the text
is saved and nothing runs, which is what Pluto does anyway while
`will_run_code` is false. Sanitise every cell that worries you, then hand one
back unchanged.
"""
function _run_set(nb::Pluto.Notebook, c::Pluto.Cell, unchanged::Bool)
    s = session()
    held = nb.process_status == Pluto.ProcessStatus.waiting_for_permission
    if held
        unchanged || return Pluto.Cell[c]      # saved, not run: Pluto refuses anyway
        nb.process_status = Pluto.ProcessStatus.starting
        return copy(nb.cells)
    end
    _current_worker(s.session, nb) === nothing ? copy(nb.cells) : Pluto.Cell[c]
end

"""
    _from_worker(nb, c, call, extra...) -> Union{Nothing,Any}

Ask the notebook's worker for something about cell `c`'s VALUE.

The value lives in the worker; Pluto keeps only its rendering. `output` is the
one tool that wants the thing itself, so it asks -- by cell_id, which every
cell has, rather than by a variable name, which most do not.

`nothing` is a real answer, and there are exactly two ways to get it: the
notebook is busy (a read must not queue behind the run it was called to look
at), or the worker could not produce what was asked for. The caller turns
either into a message; neither is worth failing over.
"""
function _from_worker(nb::Pluto.Notebook, c::Pluto.Cell, call::Symbol, extra...)
    isempty(busy_cells(nb)) || return nothing
    s = session()
    ensure_renderer!(s.session, nb)
    try
        Pluto.WorkspaceManager.eval_fetch_in_workspace((s.session, nb),
            :(Main.PlutoMCP.$call($(string(c.cell_id)), $(extra...))))
    catch
        nothing
    end
end

# Which MIMEs an MCP client can actually display. Everything else is text to a
# reader -- SVG included, which is why asking for it hands back the XML.
const VIEWABLE = Set(["image/png", "image/jpeg", "image/gif", "image/webp"])

pluto_output = MCPTool(
    name="output",
    description="""One cell's value — or the whole notebook — shown as you ask for it.

`text/plain` is the value as Julia prints it, with nothing elided; the record only ever carries a summary. `image/png` is the picture, for a cell whose value is a figure. Ask a figure for `image/svg+xml` and you get the XML; `text/html`, `text/markdown`, `application/pdf` and anything else the value supports work the same way. Ask for something it cannot be and the answer lists what it can.

Omit `cell` and the subject is the NOTEBOOK: `text/html` is Pluto's export — code, outputs and state embedded, opens in a browser with no Pluto server, though the Pluto frontend itself loads from a CDN, so it is not an offline file; `text/plain` is the `.jl` source as it stands on disk.

`path` writes the result to that file instead of carrying it, whatever the size, and returns the path — that is how you save a figure, a table, or the export. With no `path`, the result comes back inline, spilling to a file only when it is too big to carry.""",
    parameters=[
        ToolParameter(name="cell", type="string", description="$CELL_REF_DOC Omit for the notebook itself.", required=false),
        ToolParameter(name="mime", type="string", description="How to render it: \"text/plain\" for the value as text (or the notebook's .jl source), \"image/png\" for a picture, \"text/html\" for a notebook's self-contained export, or any MIME the value can show as (\"image/svg+xml\", \"application/pdf\", …).", required=true),
        ToolParameter(name="path", type="string", description="Write the rendered result to this file and return the path, at any size. Omit to have it inline.", required=false),
        NOTEBOOK_PARAM,
    ],
    handler=(args -> @safely begin
        nb = _nb(args)
        want = String(args["mime"])
        dest = get(args, "path", nothing)
        ref = get(args, "cell", nothing)

        # No cell: the notebook is the subject, and it renders itself. Pluto
        # owns both forms -- generate_html is what its own export button calls,
        # save_notebook is the .jl file format -- so this is the same rule as
        # everywhere else, one level up.
        if ref === nothing
            bytes = want == "text/html" ? Vector{UInt8}(Pluto.generate_html(nb)) :
                    want == "text/plain" ? Vector{UInt8}(sprint(Pluto.save_notebook, nb)) :
                    error("a notebook shows as \"text/html\" (Pluto's export) or \"text/plain\" (its .jl source), not \"$want\"")
            out = dest === nothing ? nothing : String(dest)
            if out !== nothing
                mkpath(dirname(abspath(out))); write(out, bytes)
                return _ok((notebook=nb.path, mime=want, path=out, bytes=length(bytes)))
            end
            return _ok((notebook=nb.path, mime=want,
                        output=truncate_payload(String(bytes); nb,
                                                label=basename(nb.path), kind="notebook")))
        end

        c = resolve_cell(nb, String(ref))
        label = cell_labels(nb)[string(c.cell_id)]

        # A cell that failed has no value to render: the error IS its result,
        # and the record already put it in structured form.
        if c.errored
            return _ok((cell=label, status="error",
                        error=truncate_payload(_error_text(c); nb, label, kind="error")))
        end

        bytes = _from_worker(nb, c, :render, want)
        if !(bytes isa Vector{UInt8}) || isempty(bytes)
            can = _from_worker(nb, c, :offers)
            # The status says which: `running`/`queued` means a read would
            # queue behind the run it was called to look at, `unrun` means
            # there is nothing there yet.
            can isa Vector ||
                error("$label is $(cell_status(c)): there is no value to render")
            return _ok((cell=label, mime=want, shows_as=can))
        end

        if dest !== nothing
            out = String(dest)
            mkpath(dirname(abspath(out)))
            write(out, bytes)
            return _ok((cell=label, mime=want, path=out, bytes=length(bytes)))
        end
        if want in VIEWABLE
            # Bigger than a comfortable payload is worth a path instead: the
            # client and the server share a machine.
            length(bytes) > 1_000_000 || return ImageContent(data=bytes, mime_type=want)
            dir = spill_dir(nb); mkpath(dir)
            path = joinpath(dir, "$(_slug(label))-output." * last(split(want, "/")))
            write(path, bytes)
            return _ok((cell=label, mime=want, path=path, bytes=length(bytes)))
        end
        _ok((cell=label, mime=want, status=cell_status(c),
             output=truncate_payload(String(bytes); nb, label, kind="full")))
    end),
    return_type=Content,
)

const ALL_TOOLS = [pluto_start, pluto_open, pluto_edit,
                   pluto_read, pluto_output, pluto_bond, pluto_stop]

const SERVER_DESCRIPTION = """
Author and drive Pluto.jl notebooks: reactive, reproducible, self-contained with their own package environment. Pluto runs in-process and is called directly, so reads are always current and edits appear instantly to a human watching the browser.

The loop: edit, then check `status`. `success`, proceed. `error`, read the cells and fix. `running` or `queued`, the work is in flight — carry on writing cells, or call `read(wait_seconds=N, since=<timestamp from the record>)` for the same record. `unrun` means nothing is coming: an `edit` starts it. `disabled` means a person switched that cell off.

Use `delete_on_success` for anything not worth keeping in the notebook: probes, docstrings, statistics, plots. Prefer `@info` with key-value pairs over `println`; structured entries survive truncation individually.

Every response except `output` and `start`'s host/secret is that one record: `status, waited_seconds, timestamp, cells`, where `status` is one of `running | queued | success | error | disabled | unrun` at both levels.
"""

function build_server()
    mcp_server(name="pluto", version="0.4.7",
               description=SERVER_DESCRIPTION, tools=ALL_TOOLS)
end

"""
    run_server()

Serve over stdio, MCP's default transport. Blocks forever reading stdin: this
is the entry point for a client that launches the server as a subprocess.

stdout carries JSON-RPC and nothing else. `ModelContextProtocol.jl`'s
`run_server_loop` writes every response with a bare `println(response)`, using
the `stdout` global, so the transport cannot be shielded by redirecting that
global -- doing so redirects the responses themselves. The logger is the place
to fix it: host-side Pluto chatter goes to stderr, and worker output was never
on stdout at all, since Malt keeps worker streams on private pipes.
"""
function run_server()
    global_logger(ConsoleLogger(stderr))
    start!(build_server())
end
