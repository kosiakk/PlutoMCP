#=
The MCP surface: ten tools, one record, one vocabulary.

Ten because every capability question has the same answer -- the agent writes a
cell. Probing a value, reading a docstring, computing a statistic, rendering a
plot: all of these are cells, usually deleted on success. Tools exist only where
cells cannot reach: lifecycle, the result record, raw bytes, and human-edit
history. A new tool has to pass both gates: cells cannot do it, and usage shows
the need.

One vocabulary, no synonyms:

  wait_seconds     how long to wait, on every tool that runs or waits
  waited_seconds   the receipt for it, in the record
  status           pending | calculating | success | error, cell and record alike
  code             the text of a cell, everywhere (Pluto's own word)
  cell / cells     the only way to address cells: name, UUID, or unique prefix
  timestamp        server clock in the record; copy it back into `since`
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

_sess(args) = get(args, "session", "default")
_wait(args, default=DEFAULT_WAIT) = Float64(something(get(args, "wait_seconds", default), default))
_nb(args) = _notebook(_sess(args); ref=get(args, "notebook", nothing))

"""Resolve the `cells` argument, or the whole notebook when it is absent."""
function _targets(args, nb, key="cells")
    v = get(args, key, nothing)
    v === nothing && return copy(nb.cells)
    Pluto.Cell[resolve_cell(nb, String(r)) for r in v]
end

const CELL_REF_DOC = "A cell NAME (a global it defines, e.g. \"throughput\"), a full UUID, or an unambiguous prefix of one."

const SESSION_PARAM = ToolParameter(name="session", type="string",
    description="Which session", required=false, default="default")

const NOTEBOOK_PARAM = ToolParameter(name="notebook", type="string",
    description="Which open notebook, if the session has more than one: a notebook_id or a path (a basename is usually enough). Omit for the current one. See list.",
    required=false)

wait_param(default=DEFAULT_WAIT) = ToolParameter(name="wait_seconds", type="number",
    description="Seconds to wait before returning the record (default $default). The record comes back on completion, on a new error, or on expiry — whichever is first. Expiry shows as status=\"calculating\"; nothing is cancelled. Pass 0 to fire and forget, and raise it for work you expect to be slow.",
    required=false, default=default)

# Pluto's centered, ~700px-wide column is a good default for prose and a bad one
# for plots and wide tables. A new notebook always gets this first.
const WIDE_LAYOUT_CELL = """html\"\"\"<style>main { max-width: 95vw; }</style>\"\"\""""

# ------------------------------------------------------------------ lifecycle --

pluto_start = MCPTool(
    name="start",
    description="Start a Pluto server in this process and return its host and secret. The HTTP server exists only so a human can watch in a browser; every tool here calls Pluto directly. Follow with open.",
    parameters=[
        ToolParameter(name="port", type="number", description="Port for the browser UI; a free one is picked if omitted", required=false),
        SESSION_PARAM,
    ],
    handler=(args -> @safely begin
        s = start_session(_sess(args); port = haskey(args, "port") ? Int(args["port"]) : nothing)
        _ok((session=_sess(args), host=s.host, secret=s.secret))
    end),
    return_type=TextContent,
)

pluto_open = MCPTool(
    name="open",
    description="""Get a notebook: open an existing .jl file, or create a new one with create=true.

Give the returned URL to the user — every later edit appears there live. Name the file after the experiment when the work is meant to be kept; a pathless create is a scratch notebook in a temp directory.

Pluto runs cells in DEPENDENCY order and allows one definition of a global per cell, so prefer `x = let ... end` over `begin ... end`. Dependencies install themselves: write `using Plots` in a cell and Pluto records the resolved versions in the notebook file.""",
    parameters=[
        ToolParameter(name="path", type="string", description="Path to the notebook .jl file. Omit only with create=true, for an anonymous scratch notebook.", required=false),
        ToolParameter(name="create", type="boolean", description="Create the notebook instead of opening an existing one (default false)", required=false, default=false),
        wait_param(),
        SESSION_PARAM,
    ],
    handler=(args -> @safely begin
        name = _sess(args); s = _session(name)
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
            _mark_seen!(name, nb.notebook_id, c.cell_id, c.code)
        end
        inject_helpers!(s.session, nb)
        _ok(record(name, nb, nb.cells, finished, waited; url=notebook_url(s, nb), path=nb.path))
    end),
    return_type=TextContent,
)

"""
Write the file a `create` will open: one wide-layout cell and nothing else.

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
    draft = notebook_source(String[WIDE_LAYOUT_CELL])
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

pluto_list = MCPTool(
    name="list",
    description="Every notebook this session has open, and which one is current. `open` never closes a previous notebook; other tools default to the current one.",
    parameters=[SESSION_PARAM],
    handler=(args -> @safely begin
        s = _session(_sess(args)); current = s.current[]
        _ok([(notebook_id=string(nb.notebook_id), path=nb.path, cells=length(nb.cells),
              current = nb.notebook_id == current)
             for nb in values(s.session.notebooks)])
    end),
    return_type=TextContent,
)

pluto_stop = MCPTool(
    name="stop",
    description="""Stop things, narrowing with each argument.

No arguments: shut the whole session down — server, notebook workers, spill files. `notebook`: shut down that one notebook. `notebook` and `cell`: interrupt what the notebook is evaluating right now, the same as the browser's stop button. A cell cannot interrupt itself, which is why that last one is a tool.

`stop` then `open` is also the from-scratch reproducibility check: a fresh worker, the file as the only input.""",
    parameters=[
        NOTEBOOK_PARAM,
        ToolParameter(name="cell", type="string", description="With `notebook`: interrupt this cell's evaluation instead of shutting anything down. $CELL_REF_DOC", required=false),
        SESSION_PARAM,
    ],
    handler=(args -> @safely begin
        name = _sess(args)
        if get(args, "notebook", nothing) === nothing
            get(args, "cell", nothing) === nothing ||
                error("stop with a cell also needs a notebook")
            stop_session(name)
            return _ok((stopped="session", session=name))
        end
        s = _session(name); nb = _nb(args)
        ref = get(args, "cell", nothing)
        if ref === nothing
            rm(spill_dir(nb); recursive=true, force=true)
            delete!(CHANGES, (name, nb.notebook_id))
            delete!(SNAPSHOTS, (name, nb.notebook_id))
            delete!(REPORTED, (name, nb.notebook_id))
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
            return _ok(record(name, nb, touched, finished, waited; stopped="cell",
                              interrupted=nothing,
                              hint="Nothing was running, so nothing was interrupted."))
        end
        nb.wants_to_interrupt = true
        # verbose=false: Pluto's own version println()s its progress, and
        # stdout belongs to the JSON-RPC transport.
        Pluto.WorkspaceManager.interrupt_workspace((s.session, nb); verbose=false)
        finished, waited, touched = wait_for_idle(nb; wait_seconds=5.0)
        _ok(record(name, nb, touched, finished, waited; stopped="cell",
                   interrupted=string(c.cell_id)))
    end),
    return_type=TextContent,
)

# -------------------------------------------------------------------- writing --

pluto_edit = MCPTool(
    name="edit",
    description="""Write the notebook: insert, replace or delete a cell, save, and run it.

Editing one cell re-runs whatever depends on it, so a small edit can be a large run; the record lists every cell the cascade touched.

`delete_on_success=true` (insert only) deletes the cell again if its status is `success` when the call returns — the way to probe a value, read a docstring, compute a statistic or render a plot without leaving anything behind. It runs normally and is visible in the browser while it does. If it errors, or if `wait_seconds` expired before the result was in, the cell stays and you delete it by the returned id.""",
    parameters=[
        ToolParameter(name="cell", type="string", description="Target cell. $CELL_REF_DOC For insert, the cell to insert AFTER; omit to append at the end.", required=false),
        ToolParameter(name="code", type="string", description="New cell text (ignored for mode=delete)", required=false),
        ToolParameter(name="mode", type="string", description="\"replace\", \"insert\" or \"delete\"", required=false, default="replace"),
        ToolParameter(name="cell_type", type="string", description="\"code\" or \"markdown\" (markdown wraps the text in md\"\"\")", required=false, default="code"),
        ToolParameter(name="delete_on_success", type="boolean", description="Delete the cell again if it reaches status=\"success\" before this call returns (default false; insert only)", required=false, default=false),
        wait_param(),
        NOTEBOOK_PARAM,
        SESSION_PARAM,
    ],
    handler=(args -> @safely begin
        name = _sess(args); s = _session(name); nb = _nb(args)
        mode = get(args, "mode", "replace")
        code = String(something(get(args, "code", nothing), ""))
        get(args, "cell_type", "code") == "markdown" && (code = _wrap_markdown(code))
        ref = get(args, "cell", nothing)
        throwaway = get(args, "delete_on_success", false) == true

        mode != "insert" && ref === nothing &&
            error("mode=\"$mode\" needs a cell to act on")

        if mode == "delete"
            c = resolve_cell(nb, String(ref))
            _remove_cell!(name, nb, c)
            # Hand the removed cell to the run: the topology then sees it defines
            # nothing, so its globals are released and dependents re-run.
            finished, waited, touched = run_with_deadline(name, nb, Pluto.Cell[c];
                                                          wait_seconds=_wait(args))
            _ok(record(name, nb, filter(x -> x.cell_id != c.cell_id, touched), finished, waited;
                       deleted=string(c.cell_id)))
        elseif mode == "insert"
            # cell_id=uuid4(): Cell's default is uuid1, which is time-based --
            # exactly the prefix collision that makes a short reference useless.
            c = Pluto.Cell(; cell_id=uuid4(), code)
            at = ref === nothing ? length(nb.cell_order) :
                 findfirst(==(resolve_cell(nb, String(ref)).cell_id), nb.cell_order)
            Pluto.withtoken(nb.executetoken) do
                insert!(nb.cell_order, at + 1, c.cell_id)
                nb.cells_dict[c.cell_id] = c
            end
            _mark_seen!(name, nb.notebook_id, c.cell_id, code)
            # save=!throwaway is an implementation detail, not the contract:
            # skipping the intermediate write keeps a probe out of the file in
            # the common case. What the agent is promised is the deletion below.
            finished, waited, touched = run_with_deadline(name, nb, Pluto.Cell[c];
                                                          wait_seconds=_wait(args),
                                                          save=!throwaway)
            r = record(name, nb, touched, finished, waited)
            # Deleted iff the status is success at RETURN time -- that is the
            # whole contract, hence the name. An errored or still-calculating
            # cell stays: the agent has to see it to act on it, and a cell that
            # vanished mid-run is a worse surprise than one deleted on purpose.
            if throwaway && r.status == "success"
                _remove_cell!(name, nb, c)
                Pluto.update_save_run!(s.session, nb, Pluto.Cell[c]; run_async=false, save=false)
                r = merge(r, (deleted=string(c.cell_id),))
            elseif throwaway
                r = merge(r, (hint="status is \"$(r.status)\", so the cell was kept — delete it with edit(mode=\"delete\", cell=\"$(c.cell_id)\") once you have read it.",))
            end
            _ok(r)
        else
            c = resolve_cell(nb, String(ref))
            c.code = code
            _mark_seen!(name, nb.notebook_id, c.cell_id, code)
            finished, waited, touched = run_with_deadline(name, nb, Pluto.Cell[c];
                                                          wait_seconds=_wait(args))
            _ok(record(name, nb, touched, finished, waited))
        end
    end),
    return_type=TextContent,
)

"""Take a cell out of the notebook under the same lock the browser's edits use."""
function _remove_cell!(name, nb, c)
    Pluto.withtoken(nb.executetoken) do
        i = findfirst(==(c.cell_id), nb.cell_order)
        i === nothing || deleteat!(nb.cell_order, i)
        delete!(nb.cells_dict, c.cell_id)
    end
    _forget_seen!(name, nb.notebook_id, c.cell_id)
    _forget_reported!(name, nb.notebook_id, c.cell_id)
    return nothing
end

pluto_run = MCPTool(
    name="run",
    description="""Recompute cells whose NON-reactive inputs changed: a file on disk, an RNG, an environment variable.

The backup path, not the normal one. `edit` already saves and runs, and a human's browser edits run through Pluto's own UI, so reactivity covers everything that depends on the notebook's own code. For a from-scratch reproducibility check use `stop` then `open`, not this.""",
    parameters=[
        ToolParameter(name="cells", type="array", description="Cell references. $CELL_REF_DOC Omit to recompute everything.", required=false),
        wait_param(),
        NOTEBOOK_PARAM,
        SESSION_PARAM,
    ],
    handler=(args -> @safely begin
        name = _sess(args); nb = _nb(args)
        finished, waited, touched = run_with_deadline(name, nb, _targets(args, nb);
                                                      wait_seconds=_wait(args))
        _ok(record(name, nb, touched, finished, waited))
    end),
    return_type=TextContent,
)

pluto_bond = MCPTool(
    name="bond",
    description="Set an `@bind`-ed variable and re-run its dependents, the way moving the widget in the browser would. Only for variables introduced with `@bind name widget`.",
    parameters=[
        ToolParameter(name="name", type="string", description="The bound variable's name, as written in @bind name widget", required=true),
        ToolParameter(name="value", type="string", description="New value, as the JSON TYPE the widget holds — a number for a slider (7, not \"7\"), true/false for a checkbox, a string only for a textual widget. Sent as given, with no coercion.", required=true),
        wait_param(),
        NOTEBOOK_PARAM,
        SESSION_PARAM,
    ],
    handler=(args -> @safely begin
        name = _sess(args); s = _session(name); nb = _nb(args)
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
        _ok(record(name, nb, touched, finished, waited; bound=String(args["name"])))
    end),
    return_type=TextContent,
)

# -------------------------------------------------------------------- reading --

pluto_read = MCPTool(
    name="read",
    description="""The notebook as it is right now: the same record every other tool returns, running nothing.

The notebook object is read directly, so a human's browser edits are already in it. `wait_seconds` waits for the run to go idle or for a new error. `since` (a `timestamp` from an earlier record) drops the cells you already have instead of compacting them. Human edits arrive with `old_code`/`new_code` — the review channel. `tree=true` adds the dependency graph.""",
    parameters=[
        ToolParameter(name="cells", type="array", description="Cell references to report on. $CELL_REF_DOC Omit for all of them.", required=false),
        ToolParameter(name="tree", type="boolean", description="Add each reported cell's references, and its upstream/downstream cells", required=false, default=false),
        wait_param(),
        ToolParameter(name="since", type="number", description="A `timestamp` from an earlier record: omit cells this session has already been shown unchanged, rather than listing them compactly. Copy the value, never compute it.", required=false),
        NOTEBOOK_PARAM,
        SESSION_PARAM,
    ],
    handler=(args -> @safely begin
        name = _sess(args); nb = _nb(args)
        finished, waited, _ = wait_for_idle(nb; wait_seconds=_wait(args))
        since = get(args, "since", nothing)
        labels = cell_labels(nb)
        cells = Vector{Any}(haskey(args, "cells") && args["cells"] !== nothing ?
                            _targets(args, nb) : copy(nb.cells))
        changes = _human_edits(name, nb, since)
        # A cell the human deleted has nothing left to describe, so its entry is
        # synthesised, because there is no Cell left to render it from.
        live = Set(string(c.cell_id) for c in nb.cells)
        for (id, e) in changes
            id in live || push!(cells, merge((name=id, cell_id=id, status="success",
                                              code="", runtime_ns=nothing,
                                              mime="text/plain", output=""), e))
        end
        r = record(name, nb, cells, finished, waited; since, changes)
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
Human browser edits from the CHANGES log, as `old_code`/`new_code` to attach to
a cell's entry. The only history the notebook itself does not hold: an edit made
through these tools marks itself seen before running, so what is left in the log
is genuinely somebody else's.
"""
function _human_edits(name, nb, since)
    log = get(CHANGES, (String(name), nb.notebook_id), NamedTuple[])
    cutoff = since === nothing ? -Inf : Float64(since)
    edits = Dict{String,NamedTuple}()
    for e in log
        e.at > cutoff || continue
        edits[e.cell_id] = (change=e.change, old_code=e.old_code, new_code=e.new_code)
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

const RASTER_MIMES = Set(["image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp"])

pluto_output = MCPTool(
    name="output",
    description="One cell's output, complete: the full text where the record only had a sketch, or the image itself when the cell rendered one. Oversize output spills to a file and the path is returned — read or grep it directly.",
    parameters=[
        ToolParameter(name="cell", type="string", description=CELL_REF_DOC, required=true),
        NOTEBOOK_PARAM,
        SESSION_PARAM,
    ],
    handler=(args -> @safely begin
        nb = _nb(args); c = resolve_cell(nb, String(args["cell"]))
        label = cell_labels(nb)[string(c.cell_id)]
        mime = string(c.output.mime); body = c.output.body

        # Raster only. SVG is markup, not an image an MCP client can show, and
        # handing back 100 KB of it as ImageContent produces a broken picture
        # instead of a legible refusal -- which is exactly why AsPNG exists.
        if body isa Vector{UInt8} && mime in RASTER_MIMES
            # An image bigger than a comfortable payload is worth a path
            # instead: the client and the server share a machine.
            if length(body) > 1_000_000
                dir = spill_dir(nb); mkpath(dir)
                path = joinpath(dir, "$(_slug(label))-output." * last(split(mime, "/")))
                write(path, body)
                return _ok((cell=label, mime=mime, bytes=length(body), path=path))
            end
            return ImageContent(data=body, mime_type=mime)
        end
        text = body isa AbstractDict ? _full_text(body, mime) :
               body isa Vector{UInt8} ? String(copy(body)) :
               body === nothing ? "" : string(body)
        r = (cell=label, mime=mime, status=cell_status(c),
             output=truncate_payload(text; nb, label, kind="full"))
        startswith(mime, "image/") &&
            (r = merge(r, (hint="This is markup, not a raster image. For a picture, run `PlutoMCP.AsPNG(fig)` in a delete_on_success cell.",)))
        _ok(r)
    end),
    return_type=Content,
)

# The record renders a container as a one-line sketch, head and tail only;
# `output` renders every element Pluto stored. That is as complete as complete
# gets: the value itself lives in the worker, and this tool never re-executes a
# cell to go and ask it. For more than Pluto kept, the agent writes a cell.
_full_text(body::AbstractDict, mime::AbstractString) =
    mime == "application/vnd.pluto.parseerror+object" ? _parse_error_text(body) :
    mime == "application/vnd.pluto.stacktrace+object" ? _stacktrace_text(body) :
    sketch(body; full=true)

pluto_export = MCPTool(
    name="export",
    description="Export the notebook as one self-contained HTML file: code, outputs and a copy of the .jl source, viewable with no Pluto server. Commit the .jl and the .html together — that pair is the provenance record.",
    parameters=[
        ToolParameter(name="path", type="string", description="Output .html path (default: the notebook's path with .jl replaced by .html)", required=false),
        NOTEBOOK_PARAM,
        SESSION_PARAM,
    ],
    handler=(args -> @safely begin
        name = _sess(args); nb = _nb(args)
        out = get(args, "path", nothing)
        out = out === nothing ? (splitext(nb.path)[1] * ".html") : String(out)
        write(out, Pluto.generate_html(nb))
        _ok(record(name, nb, nb.cells, true, 0.0; exported=out, bytes=filesize(out)))
    end),
    return_type=TextContent,
)

const ALL_TOOLS = [pluto_start, pluto_open, pluto_list, pluto_edit, pluto_run,
                   pluto_read, pluto_output, pluto_bond, pluto_export, pluto_stop]

const SERVER_DESCRIPTION = """
Author and drive Pluto.jl notebooks: reactive, reproducible, self-contained with their own package environment. Pluto runs in-process and is called directly, so reads are always current and edits appear instantly to a human watching the browser.

The loop: edit, then check `status`. `success`, proceed. `error`, read the cells and fix. `calculating`, call `read(wait_seconds=N, since=<timestamp from the record>)` — same record. Use `delete_on_success` for anything not worth keeping in the notebook: probes, docstrings, statistics, plots. Prefer `@info` with key-value pairs over `println`; structured entries survive truncation individually.

Every response except `output`'s bytes, `start`'s host/secret and `list`'s paths is that one record: `status, waited_seconds, timestamp, cells`, where `status` is one of `pending | calculating | success | error` at both levels.
"""

function build_server()
    mcp_server(name="pluto", version="0.4.0",
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
