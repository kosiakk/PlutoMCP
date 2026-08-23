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
_nbref(args) = get(args, "notebook", nothing)
_nb(args) = _notebook(_sess(args); ref=_nbref(args))

const NOTEBOOK_PARAM = ToolParameter(name="notebook", type="string",
    description="Which open notebook, if the session has more than one: a notebook_id, or a path (a basename is usually enough). Omit for the session's current notebook -- the one the most recent open/create selected. See list.",
    required=false)

"""Shape a run result the same way whether it finished inside the deadline or not."""
function _run_result(nb, targets, finished, waited)
    labels = cell_labels(nb)
    # `errored` is reported whether or not the run finished: a failure that
    # appeared while other cells are still going is exactly what you want first.
    errored = [labels[string(c.cell_id)] for c in nb.cells if c.errored]
    base = (finished = finished,
            waited_s = round(waited; digits=2),
            ran = length(targets),
            errored = errored,
            cells = [cell_info(nb, c, labels) for c in targets])
    finished && return base
    merge(base, (still_running = [labels[string(c.cell_id)] for c in nb.cells if c.running || c.queued],
                 hint = isempty(errored) ?
                     "Still running — the browser already shows it. Call status to wait for the rest." :
                     "Returned as soon as a cell errored; other cells are still running. Fix the error, or call status to wait for the rest."))
end

const CELL_REF_DOC = "A cell NAME (a global it defines, e.g. \"throughput\"), a full UUID, or an unambiguous UUID prefix."

# Pluto's centered, ~700px-wide column is a good default for prose, a bad one
# for plots and wide tables. `create` always prepends this, since a human
# reviewing a notebook is more likely to be looking at a plot than reading.
const WIDE_LAYOUT_CELL = """html\"\"\"<style>main { max-width: 95vw; }</style>\"\"\""""

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
        name = _sess(args); s = _session(name)
        nb = Pluto.SessionActions.open(s.session, args["path"]; run_async = !get(args, "run", true))
        s.current[] = nb.notebook_id
        for c in nb.cells
            _mark_seen!(name, nb.notebook_id, c.cell_id, c.code)
        end
        _ok((url=notebook_url(s, nb), path=nb.path, cells=cells_info(nb)))
    end),
    return_type=TextContent,
)

pluto_create = MCPTool(
    name="create",
    description="""Author a whole notebook in one call and open it — faster than adding cells one at a time.

Pluto runs cells in DEPENDENCY order, not top-to-bottom, and allows only one definition of a global per cell. Prefer `x = let ... end` over `begin ... end` for a one-off computation: a `let` defines exactly one name, so it creates one dependency edge instead of several.

Dependencies install themselves: just write `using Plots` in a cell. Pluto installs it into an environment scoped to this notebook and records the resolved versions inside the notebook file, so no Pkg.add step and no restart are needed.

The first cell is always a `<style>` widening the page: Pluto's fixed-width column is a prose default, not a plotting one. Recommend `PlutoPlotly` for zoomable, downloadable plots.""",
    parameters=[
        ToolParameter(name="cells", type="array", description="Cell sources, in display order", required=true),
        ToolParameter(name="cell_types", type="array", description="Same length as cells: \"code\" or \"markdown\" (default: all code)", required=false),
        ToolParameter(name="filename", type="string", description="Base filename, without .jl", required=false),
        ToolParameter(name="block", type="number", description="Seconds to wait for the run before returning (default 1)", required=false, default=1),
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        name = _sess(args); s = _session(name)
        cells = [WIDE_LAYOUT_CELL; String.(args["cells"])]
        types = haskey(args, "cell_types") && args["cell_types"] !== nothing ?
                ["code"; String.(args["cell_types"])] : fill("code", length(cells))
        draft = notebook_source(cells; cell_types=types)
        filename = get(args, "filename", nothing)
        filename !== nothing && (draft.path = Pluto.numbered_until_new(
            joinpath(Pluto.new_notebooks_directory(), String(filename)); suffix=".jl"))
        Pluto.save_notebook(draft)
        # Same Task-based wait as run_with_deadline (#8): SessionActions.open's
        # own run_async=true wraps the run in @async internally and hands back
        # nothing to wait on, so busy/queued flags are the only signal left --
        # exactly the heuristic that turned out to be unreliable for a cell
        # that fails to parse. Doing the @async ourselves, with a notebook_id
        # we chose, lets us fetch the real notebook (open registers it into
        # session.notebooks synchronously, well before any cell runs) AND get
        # istaskdone as the literal completion signal.
        notebook_id = uuid4()
        task = @async Pluto.SessionActions.open(s.session, draft.path; run_async=false, notebook_id)
        t0 = time()
        nb = nothing
        while nb === nothing && !istaskdone(task)
            nb = get(s.session.notebooks, notebook_id, nothing)
            nb === nothing && sleep(0.01)
        end
        # Not registered and the task is already done: opening itself failed
        # (e.g. a load error) -- fetch to re-raise that, not silently proceed.
        nb === nothing && fetch(task)
        s.current[] = nb.notebook_id
        for c in nb.cells
            _mark_seen!(name, nb.notebook_id, c.cell_id, c.code)
        end
        while !istaskdone(task) && time() - t0 < _block(args)
            sleep(0.02)
        end
        _ok((url=notebook_url(s, nb), path=nb.path, finished=istaskdone(task),
             cells=cells_info(nb)))
    end),
    return_type=TextContent,
)

pluto_read = MCPTool(
    name="read",
    description="""List the notebook's cells as they are RIGHT NOW. Runs nothing.

The notebook object is read directly, so edits a human just made in the browser are already included — there is no cached view to refresh.

Each cell reports a `name` (the global it defines, when Pluto reports one) and a `cell_id`. Either addresses it. Output bodies are described by size, not included; use output or png for one cell's result.""",
    parameters=[NOTEBOOK_PARAM,
                ToolParameter(name="session", type="string", description="Which session", required=false, default="default")],
    handler=(args -> @safely _ok(cells_info(_nb(args)))),
    return_type=TextContent,
)

pluto_list = MCPTool(
    name="list",
    description="""Every notebook this session has open, and which one is current.

`open`/`create` never close a previously-opened notebook -- a session can have several going at once. Every other tool defaults to the current one; pass `notebook` (a notebook_id, or a path/basename) to target a different one instead.""",
    parameters=[ToolParameter(name="session", type="string", description="Which session", required=false, default="default")],
    handler=(args -> @safely begin
        name = _sess(args); s = _session(name)
        current = s.current[]
        _ok([(notebook_id=string(nb.notebook_id), path=nb.path, cells=length(nb.cells),
              current = nb.notebook_id == current)
             for nb in values(s.session.notebooks)])
    end),
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
        NOTEBOOK_PARAM,
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        name = _sess(args); s = _session(name); nb = _nb(args)
        mode = get(args, "edit_mode", "replace")
        code = get(args, "new_source", "")
        get(args, "cell_type", "code") == "markdown" && (code = _wrap_markdown(code))
        ref = get(args, "cell_id", nothing)

        if mode == "delete"
            c = resolve_cell(nb, ref)
            # Same lock the browser's own edits run under: a patch landing on
            # cell_order/cells_dict mid-mutation is exactly the race this guards.
            Pluto.withtoken(nb.executetoken) do
                deleteat!(nb.cell_order, findfirst(==(c.cell_id), nb.cell_order))
                delete!(nb.cells_dict, c.cell_id)
            end
            _forget_seen!(name, nb.notebook_id, c.cell_id)
            # Hand the removed cell to the run: the topology then sees it defines
            # nothing, so its globals are released and dependents re-run.
            Pluto.update_save_run!(s.session, nb, Pluto.Cell[c]; run_async=false)
            _ok((deleted=string(c.cell_id), remaining=length(nb.cells)))
        elseif mode == "insert"
            # cell_id=uuid4(): Cell's default is uuid1, which is time-based --
            # exactly the prefix-collision bug notebook_source's ids avoid.
            # Several inserts in a row from one tool call sequence land in the
            # same tick just as easily as a loop does.
            c = Pluto.Cell(; cell_id=uuid4(), code)
            at = ref === nothing ? 0 : findfirst(==(resolve_cell(nb, ref).cell_id), nb.cell_order)
            Pluto.withtoken(nb.executetoken) do
                insert!(nb.cell_order, at + 1, c.cell_id)
                nb.cells_dict[c.cell_id] = c
            end
            _mark_seen!(name, nb.notebook_id, c.cell_id, code)
            finished, waited = run_with_deadline(name, nb, Pluto.Cell[c]; block=_block(args))
            _ok(_run_result(nb, [c], finished, waited))
        else
            c = resolve_cell(nb, ref)
            c.code = code
            _mark_seen!(name, nb.notebook_id, c.cell_id, code)
            finished, waited = run_with_deadline(name, nb, Pluto.Cell[c]; block=_block(args))
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
        NOTEBOOK_PARAM,
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        name = _sess(args); nb = _nb(args)
        targets = haskey(args, "cells") && args["cells"] !== nothing ?
            Pluto.Cell[resolve_cell(nb, String(r)) for r in args["cells"]] : copy(nb.cells)
        finished, waited = run_with_deadline(name, nb, targets; block=_block(args))
        _ok(_run_result(nb, targets, finished, waited))
    end),
    return_type=TextContent,
)

pluto_status = MCPTool(
    name="status",
    description="""Is anything still running, and which cells changed since you last looked?

Covers changes made by a HUMAN in the browser as well as your own: it is backed by Pluto's StateChangeEvent hook, so it costs no polling. Each change reports the cell's name, whether it was inserted, edited or deleted, and (for edited cells) the old and new source — enough to answer by editing back, not just a count. Pass the previous result's `now` back as `since` to see only what happened in between.

Waits up to `block` seconds for the notebook to go idle, so following up a run that returned `finished=false` is one call rather than a poll loop. Returns immediately when nothing is running, and stops waiting the moment a cell errors.""",
    parameters=[
        ToolParameter(name="since", type="number", description="Unix time to report changes from; omit for everything recorded", required=false),
        ToolParameter(name="block", type="number", description="Seconds to wait for the notebook to go idle (default 1). Costs nothing when it already is — the wait ends the moment nothing is running. Raise it to follow a long run to completion.", required=false, default=1),
        NOTEBOOK_PARAM,
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        name = _sess(args); nb = _nb(args)
        deadline = time() + _block(args)
        errored_before = Set(c.cell_id for c in nb.cells if c.errored)
        while !isempty(busy_cells(nb)) && time() < deadline &&
              !any(c -> c.errored && !(c.cell_id in errored_before), nb.cells)
            sleep(0.05)
        end
        log = get(CHANGES, (String(name), nb.notebook_id), NamedTuple[])
        since = haskey(args, "since") && args["since"] !== nothing ? Float64(args["since"]) : -Inf
        labels = cell_labels(nb)
        busy = busy_cells(nb)
        changes = [c for c in log if c.at > since]
        _ok((idle = isempty(busy),
             running = [labels[string(c.cell_id)] for c in busy],
             errored = [labels[string(c.cell_id)] for c in nb.cells if c.errored],
             changes = changes,
             now = time(),
             last_change = isempty(log) ? nothing : last(log).at))
    end),
    return_type=TextContent,
)

pluto_execute = MCPTool(
    name="execute",
    description="""Evaluate an expression in the notebook's live workspace, without creating a cell.

For probing values that don't belong in the saved notebook: `@doc sym`, `methods(f)`, `typeof(x)`, `size(M)`, checking a variable before committing to a cell that uses it. Runs in the same workspace `edit`/`run` use, so every notebook variable, `using`d package, and `include`d function is in scope. Nothing is saved and no cell is added or changed.""",
    parameters=[
        ToolParameter(name="expr", type="string", description="A single Julia expression, as it would appear inside a cell", required=true),
        NOTEBOOK_PARAM,
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        name = _sess(args); s = _session(name); nb = _nb(args)
        parsed = try
            Meta.parse(String(args["expr"]))
        catch e
            return _err("parse error: $(sprint(showerror, e))")
        end
        # Meta.parse doesn't throw for a syntax error -- incomplete or
        # otherwise malformed input comes back as an Expr(:incomplete, ...)
        # wrapping the real ParseError, which only surfaces once evaluated.
        # Report it here, cleanly, instead of as a Malt remote-exception
        # traceback from the "eval failed" branch below.
        Meta.isexpr(parsed, :incomplete) &&
            return _err("parse error: $(sprint(showerror, parsed.args[1]))")
        try
            result = Pluto.WorkspaceManager.eval_fetch_in_workspace((s.session, nb), parsed)
            _ok((value=repr(result), type=string(typeof(result))))
        catch e
            _err("eval failed: $(sprint(showerror, e))")
        end
    end),
    return_type=TextContent,
)

pluto_output = MCPTool(
    name="output",
    description="""One cell's output, plus its stdout/@info logs.

Images come back viewable. SVG is withheld by default — a plot is ~100 KB of markup most clients cannot render inline — so call png for a picture, or pass raw=true if you genuinely want the markup. An errored cell returns a structured error (`kind`: "parse_error" or "runtime_error", plus the message/diagnostics and stacktrace) instead of a stringified blob, so the agent can act on it without a browser.""",
    parameters=[
        ToolParameter(name="cell_id", type="string", description=CELL_REF_DOC, required=true),
        ToolParameter(name="raw", type="boolean", description="Return an SVG result's full markup", required=false, default=false),
        NOTEBOOK_PARAM,
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        nb = _nb(args); c = resolve_cell(nb, args["cell_id"])
        mime = string(c.output.mime); body = c.output.body
        astext(b) = b isa Vector{UInt8} ? String(copy(b)) : string(b)
        # Structured errors: Pluto already hands these back as a Dict, so pass
        # it straight through instead of stringifying it into a blob the agent
        # has to re-parse. Parse errors and runtime errors get their own mime,
        # flagged separately as the issue asked.
        if mime == "application/vnd.pluto.parseerror+object"
            _ok((errored=true, kind="parse_error", diagnostics=body[:diagnostics], logs=c.logs))
        elseif mime == "application/vnd.pluto.stacktrace+object"
            _ok((errored=true, kind="runtime_error", message=body[:msg],
                 stacktrace=body[:stacktrace], logs=c.logs))
        elseif mime == "image/svg+xml"
            get(args, "raw", false) && return _ok((mime=mime, errored=c.errored, body=astext(body), logs=c.logs))
            n = body === nothing ? 0 : (body isa AbstractString ? sizeof(body) : length(body))
            _ok((mime=mime, errored=c.errored, bytes=n, body="<SVG withheld: $n bytes>",
                 hint="Call png for a viewable image, or output with raw=true for the markup.", logs=c.logs))
        elseif startswith(mime, "image/") && body isa Vector{UInt8}
            ImageContent(data=body, mime_type=mime)
        else
            _ok((mime=mime, errored=c.errored, body=astext(body), logs=c.logs))
        end
    end),
    return_type=Content,
)

pluto_png = MCPTool(
    name="png",
    description="Render a plotting cell as a PNG, whatever its native output format (Plots.jl or Makie). For a NAMED cell (one that defines a single global, e.g. `fig = plot(...)`), renders that existing global -- no re-run, no risk of a 'multiple definitions' error. An unnamed cell is re-run inside a temporary probe, which is always removed. Cheap for a plot, wasteful if the cell also does expensive work.",
    parameters=[
        ToolParameter(name="cell_id", type="string", description=CELL_REF_DOC, required=true),
        NOTEBOOK_PARAM,
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        name = _sess(args); s = _session(name); nb = _nb(args)
        c = resolve_cell(nb, args["cell_id"])
        label = cell_labels(nb)[string(c.cell_id)]
        named = label != string(c.cell_id)
        tmp = tempname() * ".png"
        # `__fig` for a named cell just READS the existing global -- no
        # redefinition, so no "multiple definitions" clash with the cell that
        # actually owns it. An unnamed cell has nothing to read, so it is
        # re-run inline instead, same as before this fix.
        fig_expr = named ? label : "begin\n$(c.code)\nend"
        probe = Pluto.Cell("""let
    __fig = $fig_expr
    __path = $(repr(tmp))
    try
        savefig(__fig, __path)      # Plots.jl
    catch
        save(__path, __fig)         # Makie
    end
    nothing
end""")
        Pluto.withtoken(nb.executetoken) do
            push!(nb.cell_order, probe.cell_id); nb.cells_dict[probe.cell_id] = probe
        end
        try
            Pluto.update_save_run!(s.session, nb, Pluto.Cell[probe]; run_async=false, save=false)
            if probe.errored || !isfile(tmp)
                # The ORIGINAL cell (not the probe) may already have a
                # rendered image as its output -- whether or not it's named --
                # so fall back to serving that rather than failing outright.
                if startswith(string(c.output.mime), "image/") && c.output.body isa Vector{UInt8}
                    return ImageContent(data=c.output.body, mime_type=string(c.output.mime))
                end
                probe.errored && error("render failed: $(probe.output.body)")
                error("savefig/save wrote nothing — is this a plotting cell?")
            end
            ImageContent(data=read(tmp), mime_type="image/png")
        finally
            # Always remove the probe: a temp cell left in someone's notebook is
            # a cell they have to explain to themselves later.
            Pluto.withtoken(nb.executetoken) do
                i = findfirst(==(probe.cell_id), nb.cell_order)
                i === nothing || deleteat!(nb.cell_order, i)
                delete!(nb.cells_dict, probe.cell_id)
            end
            _forget_seen!(name, nb.notebook_id, probe.cell_id)
            Pluto.update_save_run!(s.session, nb, Pluto.Cell[probe]; run_async=false, save=false)
            rm(tmp; force=true)
        end
    end),
    return_type=Content,
)

pluto_bond = MCPTool(
    name="bond",
    description="""Set an `@bind`-ed variable's value and re-run its dependents, the way moving the slider/widget in the browser would. Blocks until those cells finish, same as the browser's own bond handling.

Only for variables introduced with `@bind name widget`; use edit for anything else. Without this, an interactive notebook can't be explored -- every bound value would be stuck at whatever the widget's default was on load.""",
    parameters=[
        ToolParameter(name="name", type="string", description="The bound variable's name, as written in @bind name widget", required=true),
        ToolParameter(name="value", type="string", description="New value for the binding (e.g. a slider's number, a checkbox's true/false)", required=true),
        NOTEBOOK_PARAM,
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        name = _sess(args); s = _session(name); nb = _nb(args)
        sym = Symbol(String(args["name"]))
        # Not `haskey(nb.bonds, sym)`: a bond that has never been set by a
        # browser (the common case for a headless notebook) has no entry yet.
        # is_assigned_anywhere is what set_bond_values_reactive itself checks.
        Pluto.MoreAnalysis.is_assigned_anywhere(nb.topology, sym) ||
            error("no @bind'ed variable named \"$(args["name"])\" -- see read for what's in this notebook")
        nb.bonds[sym] = Pluto.BondValue(args["value"])
        # NOT run_async=true: set_bond_values_reactive forwards kwargs straight
        # into its own run_reactive_async! call, silently overriding the
        # save=false-adjacent run_async=false it hardcodes -- so this is the
        # only way to get the synchronous, "done when it returns" behavior
        # every other tool here fakes with a block-then-poll loop.
        Pluto.set_bond_values_reactive(; session=s.session, notebook=nb,
            bound_sym_names=Symbol[sym], run_async=false)
        labels = cell_labels(nb)
        _ok((set=String(args["name"]),
             errored=[labels[string(c.cell_id)] for c in nb.cells if c.errored]))
    end),
    return_type=TextContent,
)

pluto_docs = MCPTool(
    name="docs",
    description="""Docstrings for every symbol a cell references -- the man pages of everything it touches, in one call.

Backed by `@doc` in the notebook's live workspace, so it sees whatever the notebook actually `using`s or defines, not just Base. Symbols nothing has a docstring for are omitted rather than filling the result with "no docs found".""",
    parameters=[
        ToolParameter(name="cell_id", type="string", description=CELL_REF_DOC, required=true),
        NOTEBOOK_PARAM,
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        name = _sess(args); s = _session(name); nb = _nb(args)
        c = resolve_cell(nb, args["cell_id"])
        refs = sort!(unique(String[string(r) for r in nb.topology.nodes[c].references]))
        docs = Dict{String,String}()
        for r in refs
            try
                expr = Meta.parse("@doc " * r)
                d = Pluto.WorkspaceManager.eval_fetch_in_workspace((s.session, nb), expr)
                text = string(d)
                occursin("No documentation found", text) || (docs[r] = text)
            catch
                # Not every reference is a documentable symbol (a local, a
                # keyword argument name, a macro-internal helper) -- skip it
                # rather than fail the whole call over one bad name.
            end
        end
        _ok((cell=args["cell_id"], docs=docs))
    end),
    return_type=TextContent,
)

pluto_deps = MCPTool(
    name="deps",
    description="""Upstream and downstream cells for a cell: what it reads, and what would break if it changed.

Straight from Pluto's own reactivity graph, keyed by the global each dependency is about -- no tracing assignments by eye to answer "what depends on X" or "what does X depend on".""",
    parameters=[
        ToolParameter(name="cell_id", type="string", description=CELL_REF_DOC, required=true),
        NOTEBOOK_PARAM,
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        nb = _nb(args); c = resolve_cell(nb, args["cell_id"])
        labels = cell_labels(nb)
        bylabel(m) = Dict(string(sym) => unique!([labels[string(cc.cell_id)] for cc in cells])
                           for (sym, cells) in m if !isempty(cells))
        _ok((upstream=bylabel(Pluto.upstream_cells_map(c, nb.topology)),
             downstream=bylabel(Pluto.downstream_cells_map(c, nb.topology))))
    end),
    return_type=TextContent,
)

pluto_export = MCPTool(
    name="export",
    description="""Export the notebook as one self-contained HTML file: code, outputs and a copy of the `.jl` source are all embedded, viewable with no Pluto server and no internet connection.

Commit the `.jl` and the exported `.html` together — that pair is the provenance record: every figure traces back to a cell in a notebook that reruns from scratch.""",
    parameters=[
        ToolParameter(name="path", type="string", description="Output .html path (default: the notebook's path with .jl replaced by .html)", required=false),
        NOTEBOOK_PARAM,
        ToolParameter(name="session", type="string", description="Which session", required=false, default="default"),
    ],
    handler=(args -> @safely begin
        nb = _nb(args)
        html = Pluto.generate_html(nb)
        out = get(args, "path", nothing)
        out = out === nothing ? (splitext(nb.path)[1] * ".html") : String(out)
        write(out, html)
        _ok((path=out, bytes=filesize(out)))
    end),
    return_type=TextContent,
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

const ALL_TOOLS = [pluto_start, pluto_open, pluto_create, pluto_list, pluto_read, pluto_edit,
                   pluto_run, pluto_status, pluto_execute, pluto_output, pluto_png,
                   pluto_bond, pluto_deps, pluto_docs, pluto_export, pluto_stop]

function build_server()
    mcp_server(
        name="pluto",
        version="0.3.0",
        description="Author and drive Pluto.jl notebooks. Pluto runs in-process and is called directly, so reads are always current, runs report honestly whether they finished, and edits appear instantly in an open browser tab — including to a human watching.",
        tools=ALL_TOOLS,
    )
end

"""
    run_server()

Serve over stdio, MCP's default transport. Blocks forever reading stdin: this is
the entry point for a client that launches the server as a subprocess.

Redirects stdout to stderr first: anything Pluto (or a notebook it runs)
prints to stdout would otherwise land in the middle of the JSON-RPC stream and
corrupt it. stderr is unaffected and still reaches the client's logs.
"""
function run_server()
    redirect_stdout(stderr)
    start!(build_server())
end
