# Pluto's own new_notebooks_directory() defaults to ~/.julia/pluto_notebooks
# -- a real user's actual notebook folder. Anything that lets Pluto pick a path
# would otherwise litter it with test notebooks on every run. Redirect before
# anything can create one.
ENV["JULIA_PLUTO_NEW_NOTEBOOKS_DIR"] = mktempdir(; prefix="PlutoMCP_test_")

using Test
using PlutoMCP
using Pluto
using JSON3

const P = PlutoMCP
const TOOLS = Dict(t.name => t for t in P.ALL_TOOLS)

"""Call a tool the way an MCP client would, and decode its JSON result.

There is one server, so a suite that used to isolate state in named sessions
isolates it in separate NOTEBOOKS instead: the state maps are keyed by
notebook."""
function call(name::String, args::Dict=Dict{String,Any}())
    r = TOOLS[name].handler(args)
    r isa P.TextContent ? JSON3.read(r.text) : r
end

"A notebook built from source, with no server involved."
offline_notebook(cells::Vector{String}) = P.notebook_source(cells)

"""The rendered output of one cell, whichever shape the record used.

A record compacts cells this session has already been shown, so a value the
suite wants to check again comes from `output` -- which is exactly the tool the
agent would reach for."""
cell_output(name) = call("output", Dict("cell" => name, "mime" => "text/plain")).output

"Every field the one record promises. Used as an acceptance test everywhere."
const RECORD_FIELDS = (:status, :waited_seconds, :timestamp, :cells)
is_record(r) = all(f -> haskey(r, f), RECORD_FIELDS) &&
    !any(f -> haskey(r, f), (:finished, :errored)) &&
    r.status in ("running", "queued", "success", "error", "disabled", "unrun")

# ---------------------------------------------------------------------------
# Pure: no Pluto server, fast.
# ---------------------------------------------------------------------------

@testset "notebook_source" begin
    # Cells are Julia text, stored as written: no cell types, no wrapping.
    # Pluto has no such concept and neither does this.
    nb = P.notebook_source(["x = 1", "md\"# heading\""])
    @test nb isa Pluto.Notebook
    @test length(nb.cells) == 2
    @test nb.cells[1].code == "x = 1"
    @test nb.cells[2].code == "md\"# heading\""

    # ids are uuid4, not Cell's default uuid1 (time-based): cells made in a
    # tight loop still need discriminating prefixes -- see resolve_cell.
    many = P.notebook_source(fill("1", 20))
    @test length(unique(c.cell_id for c in many.cells)) == 20

end

@testset "prose cells start folded" begin
    # A display default, made where a person would make the same one: Pluto
    # renders md"…", so leaving the source open puts markup in front of a
    # reader who wanted the paragraph. One click unfolds it.
    @test P.is_prose("md\"\"\"# Findings\"\"\"")
    @test P.is_prose("  md\"one line\"")
    @test P.is_prose("html\"<b>hi</b>\"")
    @test !P.is_prose("x = 1")
    @test !P.is_prose("model = md_fit(x)")        # a name that merely starts md
    @test !P.is_prose("\"a plain string\"")

    @test P.new_cell("md\"hi\"").code_folded
    @test !P.new_cell("x = 1").code_folded
end

@testset "is_name" begin
    @test P.is_name("abl")
    @test P.is_name("read_curve")
    @test P.is_name("_private")
    @test P.is_name("isvalid!")
    @test !P.is_name("")
    @test !P.is_name("2fast")                    # cannot start with a digit
    @test !P.is_name("has space")
    @test !P.is_name("a-b")
    @test !P.is_name("the-full-corpus-entropy")  # a slug is not a name
    @test !P.is_name("x"^33)                     # too long to be a handle
end

@testset "cell_labels" begin
    nb = offline_notebook(["a = 1", "f(x) = x + 1", "md\"# hi\"", "let; 1 + 1; end"])
    labels = P.cell_labels(nb)
    ids = [string(c.cell_id) for c in nb.cells]

    @test labels[ids[1]] == "a"          # named for the global it defines
    @test labels[ids[2]] == "f"          # a function definition counts
    @test labels[ids[3]] == ids[3]       # markdown defines nothing -> UUID
    @test labels[ids[4]] == ids[4]       # a bare let defines nothing -> UUID

    # Every cell always has a label, and labels are unique.
    @test length(labels) == length(nb.cells)
    @test length(unique(values(labels))) == length(nb.cells)
end

@testset "cell_labels: no source parsing" begin
    # A docstringed definition reaches ExpressionExplorer as Core.@doc with no
    # `definitions`, so Pluto reports no name for it. The UUID is the correct
    # answer; guessing one by parsing the source is not.
    nb = offline_notebook(["\"\"\"\ndocs\n\"\"\"\nfunction documented(x)\n    x\nend"])
    id = string(nb.cells[1].cell_id)
    @test P.cell_labels(nb)[id] == id

    # A leading COMMENT must never become a name: `#` opens a Julia comment as
    # well as a Markdown heading.
    nb2 = offline_notebook(["# some explanatory comment\nlet; 1; end"])
    id2 = string(nb2.cells[1].cell_id)
    @test P.cell_labels(nb2)[id2] == id2
end

@testset "resolve_cell" begin
    # Names that are not themselves valid hex digits: name lookup correctly
    # takes priority over an ambiguous short UUID prefix (CELL_REF_DOC's
    # documented order is name, full UUID, then prefix), so a single-letter
    # name from a-f could otherwise coincidentally shadow a genuine prefix
    # match below, which is a property of THIS test picking adversarial
    # names, not a bug in resolve_cell.
    nb = offline_notebook(["first = 1", "second = 2", "md\"x\""])
    id_md = string(nb.cells[3].cell_id)

    @test P.resolve_cell(nb, "first").code == "first = 1"      # by name
    @test string(P.resolve_cell(nb, id_md).cell_id) == id_md   # by full UUID

    # A prefix resolves exactly when it is unique. The length needed depends on
    # the ids, so find the shortest that is unambiguous rather than assume one.
    ids = [string(c.cell_id) for c in nb.cells]
    k = findfirst(n -> count(startswith(first(id_md, n)), ids) == 1, 1:length(id_md))
    @test k !== nothing
    @test k <= 8                       # uuid4 ids separate almost immediately
    @test string(P.resolve_cell(nb, first(id_md, k)).cell_id) == id_md

    @test_throws ErrorException P.resolve_cell(nb, "nope")
    @test_throws ErrorException P.resolve_cell(nb, "")         # matches everything
    err = try P.resolve_cell(nb, first(id_md, 4)); "" catch e; sprint(showerror, e) end
    @test isempty(err) || occursin("ambiguous", err)
end

@testset "a cell answers to every name it declares" begin
    # A variable is assigned in exactly one cell — two is the
    # MultipleDefinitionsError — so any name it declares identifies it, whether
    # or not it is the one shown as the cell's name.
    nb = offline_notebook(["a, b = 1, 2", "f(x::Int) = x", "md\"prose\""])
    @test Set(P.declarations(nb, nb.cells[1])) == Set(["a", "b"])
    @test "f" in P.declarations(nb, nb.cells[2])
    @test isempty(P.declarations(nb, nb.cells[3]))

    @test P.resolve_cell(nb, "b").code == "a, b = 1, 2"     # not the displayed name
    @test P.resolve_cell(nb, "a").code == "a, b = 1, 2"     # which is `a`
    @test P.cell_labels(nb)[string(nb.cells[1].cell_id)] == "a"
end

@testset "truncate_payload" begin
    small = "x"^100
    @test P.truncate_payload(small) === small          # under the limit, untouched
    @test P.truncate_payload("x"^P.INLINE_LIMIT) == "x"^P.INLINE_LIMIT

    big = P.truncate_payload("a"^5000 * "TAIL")
    @test length(big) < 5000
    @test startswith(big, "aaa")
    @test endswith(big, "TAIL")                        # the tail is kept, not just the head
    @test occursin("…", big)
    @test occursin("total", big)

    # Head AND tail: the marker sits between them, so both ends survive.
    marked = P.truncate_payload("HEAD" * "-"^5000 * "TAIL")
    @test findfirst("HEAD", marked)[1] < findfirst("…", marked)[1] < findfirst("TAIL", marked)[1]

    # Never split a character. Multi-byte text truncated at a byte boundary
    # must still be a valid String.
    wide = P.truncate_payload("é"^4000)
    @test isvalid(wide)
    @test all(c -> c in ('é', '…', ' ', '\n') || isascii(c), wide)

    # ANSI colour codes are Pluto's own display truncation marker; they are
    # noise to a reader that is not a terminal.
    @test P.truncate_payload("a\e[93m\e[1mb\e[22m\e[39mc") == "abc"
end

@testset "sketch: one line, one level" begin
    arr(prefix, els; short="", more=false) = Dict{Symbol,Any}(
        :type => :Array, :prefix => prefix, :prefix_short => short,
        :elements => more ? Any[[(i, (string(e), MIME"text/plain"())) for (i, e) in enumerate(els[1:end-1])];
                                "more";
                                [(99, (string(els[end]), MIME"text/plain"()))]] :
                            Any[(i, (string(e), MIME"text/plain"())) for (i, e) in enumerate(els)])

    s = P.sketch(arr("Float64", [1.0, 2.0, 3.0]))
    @test s == "Vector{Float64}, 3 elements: [1.0, 2.0, 3.0]"
    @test !occursin("\n", s)                     # one line, always

    # Pluto sends the elements it chose, never the container's real length, so
    # a truncated container must say "at least", not invent a total.
    @test occursin("≥", P.sketch(arr("Int64", [1, 2, 3, 4]; more=true)))

    # A non-Vector array already describes itself in :prefix.
    @test startswith(P.sketch(arr("2×3 Matrix{Float64}: ", [1.0]; short="Matrix")),
                     "2×3 Matrix{Float64}, 1 element")

    nested = Dict{Symbol,Any}(:type => :struct, :prefix => "P", :prefix_short => "P",
        :elements => Any[(:a, ("1", MIME"text/plain"())),
                         (:b, (arr("Float64", [1.0, 2.0]), MIME"application/vnd.pluto.tree+object"()))])
    @test P.sketch(nested) == "P(a = 1, b = Float64[1.0, 2.0])"

    # One level of fields, no recursion: a container inside a container inside a
    # container collapses rather than expanding forever.
    deep = Dict{Symbol,Any}(:type => :struct, :prefix => "Q", :prefix_short => "Q",
        :elements => Any[(:x, (nested, MIME"application/vnd.pluto.tree+object"()))])
    @test occursin("…", P.sketch(deep))
    @test !occursin("1.0", P.sketch(deep))

    # A truncated container's LAST element is the container's real last. Trimming
    # a tail off the head Pluto sent would print elements 7 and 8 beside element
    # 20 and call them the end of the array -- short is fine, wrong is not.
    long = arr("Int64", [0, 1, 2, 3, 4, 5, 6, 7, 8, 20]; more=true)
    @test P.sketch(long) == "Vector{Int64}, ≥10 elements: [0, 1, 2, 3, 4, 5, …, 20]"

    @test P.sketch(Dict{Symbol,Any}(:type => :circular)) == "#= circular reference =#"
    # An unfamiliar tree type is summarised, never dumped.
    @test P.sketch(Dict{Symbol,Any}(:type => :SomethingNew)) == "<SomethingNew>"
end

@testset "the vocabulary has no synonyms" begin
    # Item 0 of the round-2 spec, enforced rather than remembered. `block`,
    # `new_source`, `cell_id` and `source` are the words this surface used to
    # speak; every one of them now has exactly one replacement.
    banned = ["block", "new_source", "source", "cell_id", "waited_s", "full",
              "edit_mode", "ephemeral", "finished", "errored", "session", "cell_type",
              "mode", "after", "run", "tree", "upstream", "downstream"]
    for tool in P.ALL_TOOLS, p in tool.parameters
        @test !(p.name in banned)
    end

    # Everything that runs or waits takes wait_seconds, nothing else does, and
    # they all carry the SAME default -- one value flowing to one function.
    waits = Set(["open", "edit", "read", "bond"])
    for tool in P.ALL_TOOLS
        w = [p for p in tool.parameters if p.name == "wait_seconds"]
        @test (length(w) == 1) == (tool.name in waits)
        isempty(w) || @test only(w).default == P.DEFAULT_WAIT
    end
    # Not 0: a fast cell should converge inside the call, so the common case
    # comes back complete without a follow-up read.
    @test P.DEFAULT_WAIT > 0

    # Eight tools, exactly these. `export` folded into `output` (a notebook
    # rendered as text/html IS the export); `list` gone (the agent lists files
    # itself, and a bad ref names what is open).
    @test Set(keys(TOOLS)) == Set(["start", "open", "edit",
                                   "read", "output", "bond", "stop"])
    # No tool takes a session: there is one server per process.
    @test !any(p -> p.name == "session", Iterators.flatten(t.parameters for t in P.ALL_TOOLS))
end

@testset "bond's wire schema does not constrain value to a string" begin
    # `bond`'s `parameters` still types `value` as "string" (see the vocabulary
    # test above, which walks that shape); a schema-conforming client never
    # sees it, because `input_schema` -- which MCPTool prefers whenever it is
    # given -- overrides it. A number, a boolean, and an array are all valid
    # here; only "string" alone would be wrong, since that is exactly the
    # constraint that made every non-textual widget unreachable.
    value_schema = P.pluto_bond.input_schema["properties"]["value"]
    @test !haskey(value_schema, "type") ||
          value_schema["type"] != "string"
    @test P.pluto_bond.input_schema["required"] == ["name", "value"]
end

# ---------------------------------------------------------------------------
# Server-backed. One Pluto server for most of it: starting one is slow.
# ---------------------------------------------------------------------------

@testset "server lifecycle" begin
    # Before start there is no server, and every tool must say so cleanly --
    # not a KeyError from some other argument, and not a crash. Every handler
    # resolves the server before touching anything else, so this is uniform.
    for tool in P.ALL_TOOLS
        tool.name == "start" && continue        # start CREATES it
        r = call(tool.name)
        @test r.error
        @test occursin("no server running", r.message)
    end

    r = call("start")
    @test occursin("localhost:", r.host)
    @test !isempty(r.secret)

    # Started, but nothing open: a clear refusal again.
    @test occursin("no notebook open", call("read").message)
end

@testset "every notebook-taking tool refuses a bad notebook ref cleanly" begin
    for tool in P.ALL_TOOLS
        any(p -> p.name == "notebook", tool.parameters) || continue
        r = call(tool.name, Dict("notebook" => "nonexistent-xyz.jl"))
        @test r.error
        @test occursin("no open notebook", r.message)
    end
end

@testset "start twice doesn't leak the first server" begin
    call("open", Dict("create" => true, "wait_seconds" => 90))
    old_worker = Pluto.WorkspaceManager.get_workspace(
        (P.session().session, P._notebook())).worker

    r2 = call("start")                                  # a second time
    @test occursin("localhost:", r2.host)
    @test !Pluto.Malt.isrunning(old_worker)             # the old one is really gone
    @test occursin("no notebook open", call("read").message)   # and so is its notebook
end

@testset "stop clears the state of every notebook it closes" begin
    # The state maps are keyed per notebook -- several can be open -- and spill
    # directories are per notebook too, holding output nobody wants surviving
    # the server that produced it.
    call("start")
    call("open", Dict("create" => true, "wait_seconds" => 90))
    # A cell of its own: state is keyed by cell, so an empty notebook has none.
    call("edit", Dict("code" => "p = 1", "wait_seconds" => 60))
    other = P.notebook_source(["q = 2"])
    other.path = tempname() * ".jl"
    Pluto.save_notebook(other)
    call("open", Dict("path" => other.path, "wait_seconds" => 90))
    # State is keyed by cell_id, which is a UUID and needs no notebook above
    # it: both notebooks' cells live in the same flat maps, each entry naming
    # the notebook it belongs to. (CHANGES is not checked here — an edit made
    # through these tools marks itself seen, so it logs nothing; that log is
    # for what a HUMAN did, and is tested where a browser edit is simulated.)
    @test length(unique(first(v) for v in values(P.SNAPSHOTS))) == 2
    @test !isempty(P.REPORTED)

    spill = P.spill_dir(P._notebook())
    mkpath(spill); write(joinpath(spill, "leftover.txt"), "x")

    call("stop")
    @test isempty(P.CHANGES)
    @test isempty(P.SNAPSHOTS)
    @test isempty(P.REPORTED)
    @test !isdir(spill)

    call("start")           # the rest of the suite needs one
end

@testset "open: create, and the record it returns" begin
    r = call("open", Dict("create" => true, "wait_seconds" => 120))
    @test is_record(r)
    @test r.status == "success"
    @test startswith(r.url, "http://localhost:")
    @test endswith(r.path, ".jl")
    @test isfile(r.path)
    # A pathless create is scratch: it must not land in the directory a person
    # keeps their real notebooks in.
    @test startswith(r.path, tempdir())
    # Empty: a new notebook is the agent's to write, and a layout cell put
    # there by this package is content nobody asked for.
    @test isempty(r.cells)
end

@testset "open: create with a name, and reopening it" begin
    path = joinpath(mktempdir(), "throughput experiment.jl")
    r = call("open", Dict("create" => true, "path" => path,
                          "wait_seconds" => 120))
    @test r.path == path
    call("edit", Dict("code" => "kept = 41 + 1", "wait_seconds" => 60))

    # Reopening the FILE gets the saved work back, cells and all.
    r2 = call("open", Dict("path" => path, "wait_seconds" => 120))
    @test is_record(r2)
    @test any(c -> c.name == "kept", r2.cells)
    @test cell_output("kept") == "42"

    # open without a path and without create is a clear refusal, not a guess.
    @test call("open", Dict()).error
end

# The notebook most testsets build up (a, b, total). Testsets that need
# isolation open their OWN notebook and stop it afterwards, then come back
# here -- reopening an already-open path is a hit, and makes it current again.
const MAIN = Ref{String}("")

@testset "edit: insert, replace, delete" begin
    call("open", Dict("create" => true, "wait_seconds" => 120))
    MAIN[] = P._notebook().path

    r = call("edit", Dict("code" => "a = 6", "wait_seconds" => 60))
    @test is_record(r)
    @test r.status == "success"
    @test only(c.name for c in r.cells) == "a"
    @test only(c.output for c in r.cells) == "6"

    call("edit", Dict("code" => "b = 7", "wait_seconds" => 60))
    call("edit", Dict("code" => "total = a * b", "wait_seconds" => 60))
    @test cell_output("total") == "42"

    # Prose is a cell like any other, and its code is not read back to the
    # caller who just wrote it. Naming the cell is how you see it.
    m = call("edit", Dict("code" => "md\"\"\"# a heading\"\"\"",
                          "wait_seconds" => 60))
    @test !haskey(only(m.cells), :code)
    wrapped = call("read", Dict("cells" => [only(c.cell_id for c in m.cells)]))
    @test occursin("md\"\"\"", only(c.code for c in wrapped.cells))

    d = call("edit", Dict("cell" => only(c.cell_id for c in m.cells), "code" => "", "wait_seconds" => 60))
    @test is_record(d)
    @test !any(c -> occursin("a heading", get(c, :code, "")),
               call("read", Dict()).cells)

    # `code` with no cell is not a refusal any more: it is how a cell is added,
    # which is what 45 of 59 edits in a live run were doing.
    @test !haskey(call("edit", Dict("code" => "added_ok = 1", "wait_seconds" => 60)), :error)
    call("edit", Dict("cell" => "added_ok", "code" => "", "wait_seconds" => 60))
end

@testset "a cell that becomes prose folds too" begin
    # Prose written by REPLACING a cell is prose all the same. Found by a live
    # run: its title cell was the one unfolded md in the notebook, because it
    # was written over an existing code cell.
    r = call("edit", Dict("code" => "placeholder = 1",
                          "wait_seconds" => 60))
    id = only(r.cells).cell_id
    @test !P.resolve_cell(P._notebook(), String(id)).code_folded

    call("edit", Dict("cell" => String(id), "code" => "md\"# A heading\"",
                      "wait_seconds" => 60))
    @test P.resolve_cell(P._notebook(), String(id)).code_folded

    # ...but editing prose that is ALREADY prose leaves the fold alone: a human
    # may have unfolded it deliberately to read along.
    P.resolve_cell(P._notebook(), String(id)).code_folded = false
    call("edit", Dict("cell" => String(id), "code" => "md\"# Another heading\"",
                      "wait_seconds" => 60))
    @test !P.resolve_cell(P._notebook(), String(id)).code_folded

end

@testset "cells reports the whole cascade, not just the target" begin
    # Editing `a` re-runs `total` cleanly. Reporting only the edited cell
    # describes the request; the cascade is what actually happened.
    r = call("edit", Dict("cell" => "a", "code" => "a = 10",
                          "wait_seconds" => 60))
    names = Set(c.name for c in r.cells)
    @test "a" in names
    @test "total" in names                     # a clean downstream re-run
    @test any(c -> c.name == "total" && c.output == "70", r.cells)
end

@testset "code this session already holds is not sent again" begin
    # The caller wrote this text; sending it back is the one field of the
    # record they already have, and for a large cell it is the biggest.
    r = call("edit", Dict("code" => "echoed = 6 * 7", "wait_seconds" => 60))
    entry = only(c for c in r.cells if c.name == "echoed")
    @test !haskey(entry, :code)
    @test entry.output == "42"                  # everything asked for is still there

    # Replace is the same promise, with no comparison of contents: the caller
    # initiated the write, so the text cannot have become news in between.
    r2 = call("edit", Dict("cell" => "echoed",
                           "code" => "echoed = 6 * 8", "wait_seconds" => 60))
    @test !haskey(only(c for c in r2.cells if c.name == "echoed"), :code)

    # Prose is the caller's cell too, and not read back to them.
    md = call("edit", Dict("code" => "md\"a heading\"", "wait_seconds" => 60))
    entry_md = only(md.cells)
    @test !haskey(entry_md, :code)

    # An execution cascade never rewrites code, so a downstream cell re-runs
    # without repeating its source -- the answer is the news, not the code.
    call("edit", Dict("code" => "downstream_of_echoed = echoed + 1", "wait_seconds" => 60))
    r3 = call("edit", Dict("cell" => "echoed",
                           "code" => "echoed = 6 * 9", "wait_seconds" => 60))
    cascaded = only(c for c in r3.cells if c.name == "downstream_of_echoed")
    @test !haskey(cascaded, :code)
    @test cascaded.output == "55"

    # Naming a cell is the way back after a compact: whole entry, code first.
    # A bare read stays compact -- an agent that still holds the code has no
    # reason to ask for it.
    quiet = call("read", Dict())
    @test !any(c -> haskey(c, :code), quiet.cells)
    one = call("read", Dict("cells" => ["downstream_of_echoed"]))
    @test only(c.code for c in one.cells) == "downstream_of_echoed = echoed + 1"
    @test only(c.output for c in one.cells) == "55"          # and all the details

    # An output that is text this session supplied is dropped the same way the
    # code is: a cell whose value IS the string the agent just wrote says
    # nothing by reading it back.
    lit = "a string that is its own output"
    e = call("edit", Dict("code" => "md\"$lit\"", "wait_seconds" => 60))
    @test !haskey(only(e.cells), :output)
    call("edit", Dict("cell" => String(only(e.cells).cell_id), "code" => "", "wait_seconds" => 60))

    for n in ("downstream_of_echoed", "echoed", entry_md.name)
        call("edit", Dict("cell" => n, "code" => "",
                          "wait_seconds" => 60))
    end
end

@testset "edit: delete_on_success" begin
    before = length(call("read", Dict()).cells)

    r = call("edit", Dict("code" => "a + b", "delete_on_success" => true, "wait_seconds" => 60))
    @test r.status == "success"
    # Reported by NAME, the way the agent addresses a cell -- not by a UUID it
    # never used. An unnamed cell is named by its id, so this one is its id.
    @test haskey(r, :deleted)
    @test r.deleted == only(c.name for c in r.cells)
    @test only(c.output for c in r.cells) == "17"       # the answer still comes back
    @test length(call("read", Dict()).cells) == before
    @test !occursin("a + b", read(P._notebook().path, String))

    # A cell that FAILS stays put, so the agent can read it and remove it
    # deliberately -- a cell that vanished mid-error is worse.
    e = call("edit", Dict("code" => "error(\"probe blew up\")", "delete_on_success" => true,
                          "wait_seconds" => 60))
    @test e.status == "error"
    @test !haskey(e, :deleted)
    @test !haskey(e, :deleted)          # kept, and the record says so by omission
    stuck = only(c.cell_id for c in e.cells)
    # An unnamed cell is named by its own id, so a compacted entry still
    # addresses it.
    @test any(c -> c.name == stuck, call("read", Dict()).cells)
    call("edit", Dict("cell" => stuck, "code" => "",
                      "wait_seconds" => 60))
    @test length(call("read", Dict()).cells) == before

    # An explicit wait_seconds=0 returns before the result is in, so the flag
    # cannot fire: deletion at return time is the entire contract.
    z = call("edit", Dict("code" => "1 + 1", "delete_on_success" => true, "wait_seconds" => 0))
    @test z.status in ("running", "queued")
    @test !haskey(z, :deleted)
    call("edit", Dict("cell" => only(c.cell_id for c in z.cells), "code" => "", "wait_seconds" => 60))
end

@testset "a cell with two expressions says what to do about it" begin
    # Pluto's frontend rewrites this one message into advice (split, or wrap in
    # begin/end) because Julia's wording describes the parser's problem, not
    # the writer's. The boundaries come free in the error; the remedy is the
    # same one the UI offers.
    r = call("edit", Dict("wait_seconds" => 60,
                          "code" => "two = 1\nexpressions = 2"))
    c = only(r.cells)
    @test c.status == "error"
    @test occursin("ONE expression", c.error)
    @test occursin("begin ... end", c.error)
    call("edit", Dict("cell" => String(c.cell_id), "code" => "",
                      "wait_seconds" => 60))
end

@testset "every status a cell can be in" begin
    # The whole vocabulary, against the live surface.
    call("edit", Dict("code" => "vocab_ok = 6 * 7", "wait_seconds" => 60))
    entry(n) = only(c for c in call("read", Dict("cells" => [n])).cells)
    @test entry("vocab_ok").status == "success"
    @test entry("vocab_ok").ran_seconds > 0        # seconds, like every duration here

    # error: it ran and threw.
    e = call("edit", Dict("code" => "vocab_bad = error(\"no\")", "wait_seconds" => 60))
    @test only(e.cells).status == "error"

    # error also covers a graph the engine rejects, which never ran at all. Two
    # cells defining `vocab_ok` puts BOTH in the record — the fix is in the
    # other cell, which is exactly why the message names it.
    dup = call("edit", Dict("code" => "vocab_ok = 1", "wait_seconds" => 60))
    @test length(dup.cells) == 2
    @test all(c -> c.status == "error", dup.cells)
    @test any(c -> occursin("ultiple", get(c, :error, "")), dup.cells)
    intruder = only(c for c in P._notebook().cells if c.code == "vocab_ok = 1")
    call("edit", Dict("cell" => string(intruder.cell_id), "code" => "", "wait_seconds" => 60))

    # disabled: Pluto's own metadata, the way a person sets it in the browser.
    nb = P._notebook()
    c = P.resolve_cell(nb, "vocab_ok")
    c.metadata["disabled"] = true
    Pluto.update_save_run!(P.session().session, nb, Pluto.Cell[c]; run_async=false)
    d = entry("vocab_ok")
    @test d.status == "disabled"
    @test d.output == "42"                       # the last true result is still true
    @test call("output", Dict("cell" => "vocab_ok", "mime" => "text/plain")).output == "42"
    c.metadata["disabled"] = false
    Pluto.update_save_run!(P.session().session, nb, Pluto.Cell[c]; run_async=false)

    # running: how long so far, and how far along when the cell says so.
    call("edit", Dict("code" => "using ProgressLogging", "wait_seconds" => 300))
    call("edit", Dict("code" => "vocab_slow = let\n  t = 0.0\n  @progress for i in 1:60\n" *
                                "    sleep(0.1); t += i\n  end\n  t\nend", "wait_seconds" => 0))
    # Pluto delivers log records on a throttled schedule, so the first
    # @progress message lands somewhere in the first second or two: poll for it
    # rather than sampling once and hoping.
    seen_running, secs, prog = false, nothing, nothing
    for _ in 1:40
        hits = [c for c in call("read", Dict("wait_seconds" => 0)).cells
                if get(c, :name, "") == "vocab_slow"]
        mid = isempty(hits) ? nothing : first(hits)
        if mid !== nothing && get(mid, :status, "") == "running"
            seen_running = true
            let v = get(mid, :running_seconds, nothing); v === nothing || (secs = v) end
            let v = get(mid, :running_progress, nothing); v === nothing || (prog = v) end
            @test !haskey(mid, :output)          # no stale result while it runs
            @test !any(l -> occursin("Progress", get(l, :level, "")), get(mid, :logs, ()))
        end
        prog === nothing || break
        sleep(0.25)
    end
    @test seen_running
    @test secs !== nothing && secs > 0
    @test prog !== nothing && 0 < prog < 1       # from @progress, not a log line

    call("read", Dict("wait_seconds" => 60))
    for n in ("vocab_slow", "vocab_bad", "vocab_ok")
        call("edit", Dict("cell" => n, "code" => "", "wait_seconds" => 60))
    end
end

@testset "a function spread across cells reads as all of them" begin
    # Pluto lets a function's methods live in different cells, so `f` honestly
    # has two defining cells. Reading it reports both, each with its own id;
    # writing to it is refused, because a write needs exactly one target.
    call("edit", Dict("code" => "spread(x::Int) = x + 1", "wait_seconds" => 60))
    call("edit", Dict("code" => "spread(x::String) = x * \"!\"", "wait_seconds" => 60))

    r = call("read", Dict("cells" => ["spread"]))
    @test length(r.cells) == 2
    @test all(c -> haskey(c, :cell_id), r.cells)            # addressable individually
    @test Set(c.code for c in r.cells) ==
          Set(["spread(x::Int) = x + 1", "spread(x::String) = x * \"!\""])

    e = call("edit", Dict("cell" => "spread", "code" => "spread(x::Int) = x + 2",
                          "wait_seconds" => 60))
    @test e.error && occursin("2 cells", e.message)

    # By id it is unambiguous, and that is what the refusal told you to do.
    for c in r.cells
        call("edit", Dict("cell" => String(c.cell_id), "code" => "", "wait_seconds" => 60))
    end
end

@testset "errors are reported as messages, not blobs" begin
    r = call("edit", Dict("code" => "broken = (", "wait_seconds" => 60))
    c = only(r.cells)
    @test c.status == "error"
    @test r.status == "error"                     # aggregated by the one rule
    @test occursin("parseerror", c.mime)
    @test !isempty(c.error)                       # a message, not a Dict dump
    @test !occursin("Dict", c.error)
    call("edit", Dict("cell" => c.cell_id, "code" => "",
                      "wait_seconds" => 60))

    r2 = call("edit", Dict("code" => "boom = error(\"kaboom\")", "wait_seconds" => 60))
    c2 = only(r2.cells)
    @test c2.status == "error"
    @test occursin("kaboom", c2.error)
    @test occursin("stacktrace", c2.mime)
    call("edit", Dict("cell" => "boom", "code" => "",
                      "wait_seconds" => 60))
end

@testset "what edit does is what you passed" begin
    # code, no cell -> a new cell at the end.
    added = call("edit", Dict("code" => "added_at_end = 1", "wait_seconds" => 60))
    @test only(added.cells).name == "added_at_end"
    @test P._notebook().cells[end].code == "added_at_end = 1"

    # Re-running is sending the text again. There is no `run` tool and no
    # implicit shape for it: the inputs reactivity cannot see enter at a cell,
    # and rewriting that cell with what it already says runs it.
    call("edit", Dict("code" => "rolled = rand()", "wait_seconds" => 60))
    first_roll = cell_output("rolled")
    r = call("edit", Dict("cell" => "rolled", "code" => "rolled = rand()",
                          "wait_seconds" => 60))
    @test is_record(r) && r.status == "success"
    @test cell_output("rolled") != first_roll

    # cell + empty code -> deleted. An empty cell means nothing, so the token
    # is free for the operation that does.
    call("edit", Dict("cell" => "rolled", "code" => "", "wait_seconds" => 60))
    @test !any(c -> get(c, :name, "") == "rolled", call("read").cells)

    # A cell the agent wrote comes back without its code: it already holds it.
    d = call("edit", Dict("cell" => "added_at_end", "code" => "", "wait_seconds" => 60))
    entry = only(c for c in d.cells if get(c, :change, "") == "deleted")
    @test !haskey(entry, :old_code)

    # One it never wrote comes back WITH the code, so the delete is undoable
    # without anyone being asked "are you sure".
    nb = P._notebook()
    human = P.new_cell("typed_by_a_human = 7")
    Pluto.withtoken(nb.executetoken) do
        push!(nb.cell_order, human.cell_id); nb.cells_dict[human.cell_id] = human
    end
    Pluto.update_save_run!(P.session().session, nb, Pluto.Cell[human]; run_async=false)
    d2 = call("edit", Dict("cell" => "typed_by_a_human", "code" => "", "wait_seconds" => 60))
    entry2 = only(c for c in d2.cells if get(c, :change, "") == "deleted")
    @test entry2.old_code == "typed_by_a_human = 7"

    # `code` is required, so there is no shape to guess at.
    @test call("edit", Dict()).error
    @test call("edit", Dict("cell" => "total")).error
end

@testset "short wait, then keep running" begin
    call("edit", Dict("code" => "slow = (sleep(3); 99)", "wait_seconds" => 0.2))
    r = call("read", Dict("cells" => ["slow"]))
    @test r.status in ("running", "queued", "success")

    # read(wait_seconds=N) is the follow-up: one call, not a poll loop.
    done = call("read", Dict("cells" => ["slow"], "wait_seconds" => 30))
    @test done.status == "success"
    @test done.waited_seconds >= 0
    @test only(done.cells).output == "99"
    call("edit", Dict("cell" => "slow", "code" => "",
                      "wait_seconds" => 30))
end

@testset "a fast cell is not reported as still running" begin
    # The whole point of the Task-based wait: completion is istaskdone, not a
    # guess from busy flags that read "idle" before the run had even started.
    for _ in 1:5
        r = call("edit", Dict("code" => "quick = 1 + 1", "wait_seconds" => 30))
        @test r.status == "success"
        @test only(c.output for c in r.cells) == "2"
        call("edit", Dict("cell" => "quick", "code" => "",
                          "wait_seconds" => 30))
    end
end

@testset "an error ends the wait early" begin
    t0 = time()
    r = call("edit", Dict("code" => "fails = error(\"nope\")", "wait_seconds" => 30))
    @test time() - t0 < 25                       # did not serve out the deadline
    @test r.status == "error"
    call("edit", Dict("cell" => "fails", "code" => "",
                      "wait_seconds" => 30))
end

@testset "read: snapshot, subset, dependencies" begin
    r = call("read", Dict())
    @test is_record(r)
    @test r.status == "success"
    # Every entry carries a name and a status, in every shape. A compacted one
    # carries `unchanged_since`; every other one carries the id you address it
    # by. `code` is not promised: the agent may already hold it.
    @test all(c -> haskey(c, :name) && haskey(c, :status), r.cells)
    @test all(c -> haskey(c, :unchanged_since) || haskey(c, :cell_id), r.cells)

    # A cell this session never wrote does come back with its code.
    nb = P._notebook()
    theirs = P.new_cell("written_elsewhere = 1")
    Pluto.withtoken(nb.executetoken) do
        push!(nb.cell_order, theirs.cell_id); nb.cells_dict[theirs.cell_id] = theirs
    end
    Pluto.update_save_run!(P.session().session, nb, Pluto.Cell[theirs]; run_async=false)
    @test any(c -> get(c, :code, "") == "written_elsewhere = 1", call("read").cells)
    call("edit", Dict("cell" => "written_elsewhere", "code" => "", "wait_seconds" => 60))

    one = call("read", Dict("cells" => ["total"]))
    @test length(one.cells) == 1

    t = call("read", Dict("cells" => ["total"], "dependencies" => true))
    c = only(t.cells)
    # Flat lists of cell names, one hop each way. Every entry is a reference
    # you can send straight back as `cell=`.
    @test Set(c.uses) == Set(["a", "b"])
    @test !haskey(c, :references) && !haskey(c, :upstream)

    a = only(call("read", Dict("cells" => ["a"], "dependencies" => true)).cells)
    @test "total" in a.used_by
end

@testset "cells this session already saw compress, and since drops them" begin
    # A fresh notebook is fresh state: the maps are keyed by notebook.
    opened = call("open", Dict("create" => true, "wait_seconds" => 120))
    @test isempty(opened.cells)                           # a new notebook is empty

    ins = call("edit", Dict("code" => "base = 2",
                            "wait_seconds" => 60))
    # A cell the caller just wrote is the one exception: its code is not read
    # back to it (see "edit does not echo"), but the rest of the entry is full.
    @test !haskey(only(ins.cells), :code)
    @test haskey(only(ins.cells), :output)
    call("edit", Dict("code" => "derived = base * 3",
                      "wait_seconds" => 60))

    # Looking again at state the session has already been given: every cell is
    # name, status, unchanged_since and nothing else. Compressed, not hidden --
    # the cascade stays countable.
    again = call("read", Dict())
    @test length(again.cells) == 2
    @test all(c -> haskey(c, :unchanged_since) && !haskey(c, :code), again.cells)
    # ISO 8601 UTC, fixed width: lexicographic order IS chronological order.
    @test all(c -> c.unchanged_since <= again.timestamp, again.cells)

    # A real change comes back in full -- minus the code the caller just sent
    # -- and so does the cascade it caused.
    r = call("edit", Dict("cell" => "base", "code" => "base = 5",
                          "wait_seconds" => 60))
    changed = only(c for c in r.cells if get(c, :name, "") == "base")
    @test !haskey(changed, :code) && get(changed, :output, "") == "5"
    cascaded = only(c for c in r.cells if get(c, :name, "") == "derived")
    @test get(cascaded, :output, "") == "15"

    # Re-running a cell to the SAME answer is not a change. Pluto allocates a
    # fresh object and a fresh objectid; the fingerprint deliberately ignores
    # that, because it identifies the rendered output, not the object.
    # Re-running is sending the text again — there is nothing else to it.
    call("edit", Dict("cell" => "derived", "code" => "derived = base * 3",
                      "wait_seconds" => 60))
    bare = call("read", Dict())
    @test haskey(only(c for c in bare.cells if c.name == "derived"), :unchanged_since)
    # ...but naming it asks to be told, so it comes back whole.
    named = call("read", Dict("cells" => ["derived"]))
    @test haskey(only(named.cells), :code) && haskey(only(named.cells), :output)

    # `since` is the same comparison shown as a delta rather than a summary.
    # Empty is the honest answer when every record so far already delivered
    # everything -- an `edit` hands over its cascade, so there is no backlog.
    t = call("read", Dict()).timestamp
    @test isempty(call("read", Dict("since" => t)).cells)

    # A string that is not a timestamp is refused with the shape it wanted.
    bad = call("read", Dict("since" => "yesterday"))
    @test bad.error && occursin("timestamp", bad.message)

    # A change made OUTSIDE the tools -- what a browser patch does -- was never
    # delivered, so it is genuinely new and arrives in full.
    nb = P._notebook()
    cell = P.resolve_cell(nb, "base")
    cell.code = "base = 7"
    Pluto.update_save_run!(P.session().session, nb, Pluto.Cell[cell]; run_async=false)
    delta = call("read", Dict("since" => t))
    @test is_record(delta)
    @test "base" in [c.name for c in delta.cells]
    # Deltas are never compact -- though code this session wrote is still not
    # read back to it; what a human typed is not code this session holds.
    @test all(c -> haskey(c, :output), delta.cells)
    @test any(c -> get(c, :old_code, "") == "base = 5" && c.code == "base = 7",
              delta.cells)

    # A float unix time is still a timestamp: transcripts and older clients have
    # them, and refusing one would only lose a delta. Asked LAST, because a read
    # is not free of consequence -- it reports, and reporting is what makes the
    # next record able to leave things out.
    @test isempty(call("read", Dict("since" => P.parse_timestamp(t))).cells)

    dedup_nb = P._notebook()
    dedup_cells = copy(dedup_nb.cells)
    call("stop", Dict("notebook" => basename(dedup_nb.path)))
    @test !any(c -> haskey(P.REPORTED, c.cell_id), dedup_cells)
    call("open", Dict("path" => MAIN[], "wait_seconds" => 60))   # back to the main notebook
end

@testset "a container that re-runs to the same value fingerprints the same" begin
    # The objectid case, isolated: ones(5) allocates a new array every run, so a
    # fingerprint over Pluto's raw tree body would call this changed forever.
    call("open", Dict("create" => true, "wait_seconds" => 120))
    call("edit", Dict("code" => "vals = ones(5)",
                      "wait_seconds" => 60))
    call("read", Dict())
    call("edit", Dict("cell" => "vals", "code" => "vals = ones(5)", "wait_seconds" => 60))
    # A bare read is where compaction shows: naming the cell asks to be told
    # about it, and is answered in full.
    bare = call("read", Dict())
    @test haskey(only(c for c in bare.cells if c.name == "vals"), :unchanged_since)
    call("stop", Dict("notebook" => basename(P._notebook().path)))
    call("open", Dict("path" => MAIN[], "wait_seconds" => 60))   # back to the main notebook
end

@testset "read: a human's browser edit comes back with old_code and code" begin
    t0 = call("read", Dict()).timestamp

    # An edit made THROUGH our own tools is pre-marked as seen, so it must not
    # come back as a change: `since` reports what a HUMAN did, not an echo.
    call("edit", Dict("cell" => "a", "code" => "a = 5",
                      "wait_seconds" => 60))
    mine = call("read", Dict("since" => t0))
    @test !any(c -> haskey(c, :old_code), mine.cells)

    t1 = call("read", Dict()).timestamp
    # A change made OUTSIDE our tools -- exactly what a browser patch does.
    nb = P._notebook()
    cell = P.resolve_cell(nb, "a")
    cell.code = "a = 9"
    Pluto.update_save_run!(P.session().session, nb, Pluto.Cell[cell]; run_async=false)

    theirs = call("read", Dict("since" => t1))
    @test is_record(theirs)
    edited = only(c for c in theirs.cells if get(c, :change, nothing) == "edited")
    @test edited.name == "a"
    @test edited.old_code == "a = 5"
    @test edited.code == "a = 9"
    # ...and the cascade it caused is in the same record, without a second call.
    @test any(c -> c.name == "total", theirs.cells)

    # A report asked for BY NAME answers with those cells. A human deleting
    # some other cell is real news, but it is not what this call asked about --
    # and a synthesised entry for it would land in every later targeted read.
    call("edit", Dict("code" => "doomed = 1", "wait_seconds" => 60))
    nb2 = P._notebook()
    doomed = P.resolve_cell(nb2, "doomed")
    Pluto.withtoken(nb2.executetoken) do
        deleteat!(nb2.cell_order, findfirst(==(doomed.cell_id), nb2.cell_order))
        delete!(nb2.cells_dict, doomed.cell_id)
    end
    Pluto.update_save_run!(P.session().session, nb2, Pluto.Cell[doomed]; run_async=false)
    named = call("read", Dict("cells" => ["a"]))
    @test only(named.cells).name == "a"

    # A bare read DOES report the deletion, old_code and all -- once. The
    # CHANGES log keeps the entry for `since` arithmetic, but the reference
    # point is the agent's context: a second bare read repeating a cell that is
    # no longer in the notebook would be noise, not news.
    gone = call("read", Dict())
    @test any(c -> get(c, :change, nothing) == "deleted" &&
                   get(c, :old_code, "") == "doomed = 1", gone.cells)
    again = call("read", Dict())
    @test !any(c -> get(c, :change, nothing) == "deleted", again.cells)
end

@testset "reads reflect the live notebook" begin
    # Mutate the Notebook directly, the way Pluto's frontend patches do, and
    # confirm a read sees it with no refresh step of any kind.
    nb = P._notebook()
    P.resolve_cell(nb, "a").code = "a = 12345"
    @test any(c -> get(c, :code, "") == "a = 12345",
              call("read", Dict()).cells)
    call("edit", Dict("cell" => "a", "code" => "a = 6", "wait_seconds" => 60))
end

@testset "output rendering: sketches, not dumps" begin
    # The insert's own record is where the sketch appears: a later read would
    # compact this cell, having already delivered it.
    r = call("edit", Dict("code" => "vec = collect(1.0:100000.0)", "wait_seconds" => 60))
    sketched = only(c.output for c in r.cells if get(c, :name, "") == "vec")
    @test occursin("Vector{Float64}", sketched)
    @test occursin("elements", sketched)
    @test !occursin("\n", sketched)              # one line for 100k elements
    @test length(sketched) < 400

    # `output` is the VALUE, as Julia prints it, fetched from the worker --
    # 100k elements is far past the inline limit, so it spills and names a path.
    full = cell_output("vec")
    # The exact spelling is Julia's business -- Vector{Float64} or
    # Array{Float64, 1} -- and pinning it here would be this suite deciding
    # something the principle says it does not decide.
    @test occursin("100000-element", full) && occursin("Float64", full)
    @test occursin("full output:", full)
    path = match(r"full output: ([^)]+)\)", full)[1]
    @test isfile(path)
    @test occursin("100000.0", read(path, String))       # the real last element
    @test !occursin("Dict{Symbol", full)

    call("edit", Dict("code" => "tup = (x=1, y=\"two\", z=[1,2,3])", "wait_seconds" => 60))
    # Julia's own printing, not our sketch: nested containers are complete.
    @test cell_output("tup") == "(x = 1, y = \"two\", z = [1, 2, 3])"

end

@testset "rendered markup never comes back" begin
    # A markdown cell's rendering IS the prose the agent just wrote, re-encoded.
    # The record says what mime it produced and stops there.
    r = call("edit", Dict("code" => "md\"\"\"\n# Findings\n\nThe **mean** over \$(2+3) runs was significant.\n\"\"\"",
                          "wait_seconds" => 60))
    c = only(r.cells)
    @test c.mime == "text/html"
    @test !haskey(c, :output)            # not the markup, and not its text either
    @test !haskey(c, :code)              # the caller wrote it; it is not read back

    # ...and it needs no special case to be readable: the cell's VALUE is a
    # Markdown.MD, which Julia prints as text on its own.
    shown = call("output", Dict("cell" => String(c.cell_id),
                                "mime" => "text/plain"))
    @test occursin("Findings", shown.output)
    @test occursin("5", shown.output)    # the interpolation did run
    @test !occursin("<h1", shown.output)

    w = call("edit", Dict("code" => "html\"<table><tr><td>a</td><td>1</td></tr></table>\"",
                          "wait_seconds" => 60))
    @test !haskey(only(w.cells), :output)

    for id in (c.cell_id, only(w.cells).cell_id)
        call("edit", Dict("cell" => String(id), "code" => "",
                          "wait_seconds" => 60))
    end
end

@testset "output reaches a cell that defines no name" begin
    # The value is fetched by cell_id from the worker, so a `let` block with no
    # name is as readable as a global -- which a lookup by variable never was.
    r = call("edit", Dict("code" => "let\n    collect(1:5) .^ 2\nend", "wait_seconds" => 60))
    id = only(r.cells).cell_id
    @test only(r.cells).name == id            # no global, so it is named by its id
    full = call("output", Dict("cell" => String(id), "mime" => "text/plain"))
    @test occursin("25", full.output)
    call("edit", Dict("cell" => String(id), "code" => "",
                      "wait_seconds" => 60))
end

@testset "output: one cell, complete" begin
    r = call("output", Dict("cell" => "total", "mime" => "text/plain"))
    @test r.cell == "total"
    @test r.output == "42"
    @test r.status == "success"

    # Text past the inline limit spills, and the payload names the path.
    # `Text` rather than a bare String on purpose: Pluto renders a String
    # through `repr` with :limit, so it arrives already shortened and there is
    # nothing left for us to spill. Text is stored whole, which is the case
    # this guard exists for.
    call("edit", Dict("code" => "long = Text(join(string.(1:20000), \"\\n\"))",
                      "wait_seconds" => 60))
    big = call("output", Dict("cell" => "long", "mime" => "text/plain"))
    @test occursin("full output:", big.output)
    # The marker is `… (<size> total, full output: <path>)` -- take the path up
    # to the closing paren, not to the next space.
    path = match(r"full output: ([^)]+)\)", big.output)[1]
    @test isfile(path)
    @test filesize(path) > P.INLINE_LIMIT
    @test occursin("20000", big.output)              # the tail survived
    @test startswith(big.output, "1\n2\n3\n")        # ...and so did the head
    @test read(path, String) == join(string.(1:20000), "\n")   # the file is whole
    call("edit", Dict("cell" => "long", "code" => "",
                      "wait_seconds" => 60))

    # A value PLUTO shortened for its own display is complete here: the record
    # carries Pluto's summary, `output` asks the worker for the value itself.
    call("edit", Dict("code" => "shortened = join(string.(1:20000), \"\\n\")",
                      "wait_seconds" => 60))
    s = call("output", Dict("cell" => "shortened", "mime" => "text/plain"))
    @test occursin("full output:", s.output)         # spilled, not elided
    whole = read(match(r"full output: ([^)]+)\)", s.output)[1], String)
    # Julia displays a String quoted and escaped, so the newlines arrive as
    # \\n. That is what `display` does, and rendering it raw instead would be
    # this package overriding Julia on how a String looks -- the one thing the
    # two-renderers rule forbids.
    @test occursin("20000", whole) && occursin("1\\n2\\n", whole)
    @test !occursin("\e[", s.output)
    call("edit", Dict("cell" => "shortened", "code" => "",
                      "wait_seconds" => 60))

    # A print blob is a log entry, and hits the same one truncation function.
    r = call("edit", Dict("code" => "printy = (println(\"p\"^9000); 3)", "wait_seconds" => 60))
    # The print may not have been flushed when the edit returned; whichever
    # record first carries it is the one to read, and a later read compacts a
    # cell it has already delivered.
    logs = get(only(c for c in r.cells if get(c, :name, "") == "printy"), :logs, nothing)
    for _ in 1:150
        logs === nothing || break
        logs = get(only(call("read", Dict("cells" => ["printy"])).cells),
                   :logs, nothing)
        logs === nothing && sleep(0.1)
    end
    @test logs !== nothing
    @test occursin("full output:", only(logs).msg)
    call("edit", Dict("cell" => "printy", "code" => "",
                      "wait_seconds" => 60))

    @test call("output", Dict("cell" => "no-such-cell", "mime" => "text/plain")).error
end

@testset "logs: structured, capped, counted" begin
    r = call("edit", Dict("code" => "noisy = begin; for i in 1:100; @info \"step\" i=i; end; println(\"done\"); 7; end",
        "wait_seconds" => 60))
    # Pluto delivers a cell's log entries on its own throttled schedule, AFTER
    # the cell itself reports success, so the print this cell emits last may or
    # may not have made the edit's own record. Whichever record first carries it
    # is the one to read: once the logs settle, later records compact the cell.
    settled(c) = any(l -> l.level == "Stdout", get(c, :logs, ()))
    c = only(x for x in r.cells if get(x, :name, "") == "noisy")
    for _ in 1:150
        settled(c) && break
        sleep(0.1)
        c = only(call("read", Dict("cells" => ["noisy"])).cells)
    end
    @test settled(c)
    @test c.output == "7"
    @test length(c.logs) == P.LOGS_KEPT           # the LAST 20, not the first
    @test c.logs[1].level == "Info"
    @test c.logs[1].kwargs["i"] == "82"           # 100 @info + 1 println, last 20
    # println is captured too, at Pluto's private level -- reported as Stdout
    # rather than as the meaningless "LogLevel(-555)".
    @test any(l -> l.level == "Stdout" && occursin("done", l.msg), c.logs)
    @test occursin("earlier entries", c.logs_dropped)
    dropped = match(r"→ (.+)$", c.logs_dropped)
    @test dropped !== nothing && isfile(dropped[1])
    call("edit", Dict("cell" => "noisy", "code" => "",
                      "wait_seconds" => 60))
end

@testset "output renders whatever MIME the value supports" begin
    # A Plots figure stores SVG, which no MCP client can show. Handing back a
    # screenful of <path d="..."> is not a smaller version of the picture, it
    # is a picture nobody gets -- so `output` names the shape and the way out.
    # A type that can only show as SVG stands in for the plotting library.
    call("edit", Dict("wait_seconds" => 60,
                      "code" => "struct TinySVG end"))
    rshow = call("edit", Dict("wait_seconds" => 60,
                      "code" => "Base.show(io::IO, ::MIME\"image/svg+xml\", ::TinySVG) = " *
                                "print(io, \"<svg xmlns='http://www.w3.org/2000/svg'>\" * " *
                                "repeat(\"<path d='M0 0 L9 9'/>\", 200) * \"</svg>\")"))
    r0 = call("edit", Dict("wait_seconds" => 60,
                           "code" => "svgfig = TinySVG()"))
    @test only(c.mime for c in r0.cells if c.name == "svgfig") == "image/svg+xml"

    # TinySVG cannot show as PNG, so `output` says so by listing what it can be.
    r = call("output", Dict("cell" => "svgfig", "mime" => "image/png"))
    @test !occursin("<path", string(r))          # not one screenful of it, either
    # It cannot be a PNG, so the answer is what it CAN be -- data, not advice.
    @test "image/svg+xml" in r.shows_as
    @test "text/plain" in r.shows_as        # everything can be text/plain
    @test !occursin("AsPNG", string(r))

    # ...and asking for what it CAN do returns the XML, because render is just
    # `show(io, MIME(mime), value)`.
    xml = call("output", Dict("cell" => "svgfig", "mime" => "image/svg+xml"))
    @test occursin("<svg", xml.output)

    # `path` writes it to a file at any size, which is how a figure is saved.
    out = tempname() * ".svg"
    saved = call("output", Dict("cell" => "svgfig",
                                "mime" => "image/svg+xml", "path" => out))
    @test saved.path == out && isfile(out) && saved.bytes > 1000
    @test occursin("<svg", read(out, String))
    rm(out; force=true)

    # The method cell defines no global, so it is addressed by id -- and it goes
    # FIRST: left behind, it would error the moment TinySVG stopped existing.
    for n in (only(c.cell_id for c in rshow.cells), "svgfig", "TinySVG")
        call("edit", Dict("cell" => n, "code" => "",
                          "wait_seconds" => 60))
    end
end

@testset "output renders a figure to PNG instead of describing it" begin
    # A type that CAN show as PNG stands in for a plotting library: `output`
    # asks it for the picture rather than telling the agent to go and ask.
    call("edit", Dict("wait_seconds" => 60,
                      "code" => "struct BothWays end"))
    rshow = call("edit", Dict("wait_seconds" => 60,
                      "code" => "begin\n" *
                                "Base.show(io::IO, ::MIME\"image/svg+xml\", ::BothWays) = print(io, \"<svg/>\")\n" *
                                "Base.show(io::IO, ::MIME\"image/png\", ::BothWays) = write(io, UInt8[0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a])\n" *
                                "end"))
    call("edit", Dict("wait_seconds" => 60,
                      "code" => "bothfig = BothWays()"))
    r = call("output", Dict("cell" => "bothfig", "mime" => "image/png"))
    @test r.mime_type == "image/png"      # ImageContent, not a JSON record
    @test r.data isa Vector{UInt8} && !isempty(r.data)

    for n in (only(c.cell_id for c in rshow.cells), "bothfig", "BothWays")
        call("edit", Dict("cell" => n, "code" => "",
                          "wait_seconds" => 60))
    end
end

@testset "a notebook held for review: sanitise, then consent" begin
    # Pluto holds a notebook it considers risky, and while it does, NOTHING
    # runs — will_run_code is false. The agent has had to `read` the notebook
    # to know its cells at all, which is the review, and what it does next
    # decides: rewrite a cell it does not like and that is a change, saved and
    # not run; hand a cell back exactly as it stands and that is consent, and
    # the whole notebook runs. Pluto's own banner does the same thing.
    nb = P._notebook()
    call("edit", Dict("code" => "held_a = 2", "wait_seconds" => 60))
    call("edit", Dict("code" => "held_b = held_a * 3", "wait_seconds" => 60))
    nb.process_status = Pluto.ProcessStatus.waiting_for_permission

    # Every record says so, not just the one from `open`: an edit that quietly
    # did not run is the worst thing this surface could do in silence.
    @test call("read").awaiting_permission

    sanitised = call("edit", Dict("cell" => "held_a", "code" => "held_a = 5",
                                  "wait_seconds" => 30))
    @test sanitised.awaiting_permission
    @test cell_output("held_b") == "6"           # nothing ran: still the old value

    consent = call("edit", Dict("cell" => "held_a", "code" => "held_a = 5",
                                "wait_seconds" => 60))
    @test !haskey(consent, :awaiting_permission) # the hold is over
    @test cell_output("held_b") == "15"          # everything ran, sanitised text and all

    # A dead worker is the same situation from the other direction: one cell
    # cannot run against a workspace that holds nothing.
    Pluto.WorkspaceManager.unmake_workspace((P.session().session, nb);
                                            async=false, verbose=false)
    r = call("edit", Dict("cell" => "held_b", "code" => "held_b = held_a * 3",
                          "wait_seconds" => 120))
    @test r.status == "success"
    @test cell_output("held_b") == "15"          # held_a was restored first

    for n in ("held_b", "held_a")
        call("edit", Dict("cell" => n, "code" => "", "wait_seconds" => 60))
    end
end

@testset "the render helper survives Pluto restarting the worker" begin
    # Installing a package restarts the notebook PROCESS, so `Main.PlutoMCP`
    # goes away and injecting once at `open` is not enough. `unmake_workspace`
    # is that restart, without the minutes a real Pkg install would cost.
    nb = P._notebook()
    old_worker = Pluto.WorkspaceManager.get_workspace((P.session().session, nb)).worker
    Pluto.WorkspaceManager.unmake_workspace((P.session().session, nb); async=false, verbose=false)
    @test !Pluto.Malt.isrunning(old_worker)

    # A value lives in the worker, so a restart destroys every one of them:
    # until something re-runs, `output` has nothing to reach and says so. The
    # record is unaffected -- Pluto's stored renderings outlive the process.
    call("read", Dict("wait_seconds" => 120))
    @test call("output", Dict("cell" => "total",
                              "mime" => "text/plain")).error

    # Re-run everything, the way a human clicks "Run all" after a restart: a
    # new worker holds no globals, so one cell cannot be re-run alone. Through
    # the internals, because no tool re-runs a whole notebook — an agent would
    # `stop` and `open`, which is a fresh worker and a run.
    P.run_with_deadline(P._notebook(), copy(P._notebook().cells); wait_seconds=120)
    @test cell_output("total") == "42"
end

@testset "bond: set slider/widget values" begin
    call("edit", Dict("code" => "slider = @bind slider html\"<input type=range>\"",
                      "wait_seconds" => 60))
    call("edit", Dict("code" => "doubled_bond = slider * 2", "wait_seconds" => 60))

    r = call("bond", Dict("name" => "slider", "value" => 7,
                          "wait_seconds" => 60))
    @test is_record(r)
    @test r.status == "success"
    @test r.bound == "slider"
    # The cascade the bond caused is in the record itself, without a re-read.
    @test any(c -> c.name == "doubled_bond" && c.output == "14", r.cells)

    r2 = call("bond", Dict("name" => "slider", "value" => 10,
                           "wait_seconds" => 60))
    @test any(c -> c.name == "doubled_bond" && c.output == "20", r2.cells)

    @test call("bond", Dict("name" => "not_a_bond", "value" => 1)).error

    # The value is passed through exactly as given, with no type coercion --
    # deliberately. Pluto's own transform_bond_value does no string->number
    # parsing (a browser sends the JSON number 7, never the string "7"), and
    # nothing in a string tells "the number 7, sent as a string" apart from
    # "the text '7', typed into a genuinely textual field". Both cases below
    # prove pass-through: the second only works BECAUSE it stayed a string.
    call("edit", Dict("code" => "greeting = @bind greeting html\"<input type=text>\"",
                      "wait_seconds" => 60))
    call("edit", Dict("code" => "shout = greeting * \"!\"", "wait_seconds" => 60))
    g = call("bond", Dict("name" => "greeting", "value" => "hello",
                          "wait_seconds" => 60))
    @test any(c -> c.name == "shout" && c.output == "\"hello!\"", g.cells)
    g2 = call("bond", Dict("name" => "greeting", "value" => "7",
                           "wait_seconds" => 60))
    @test any(c -> c.name == "shout" && c.output == "\"7!\"", g2.cells)

    for n in ("shout", "greeting", "doubled_bond", "slider")
        call("edit", Dict("cell" => n, "code" => "",
                          "wait_seconds" => 60))
    end
end

@testset "bond: a rejected value is rolled back, not left installed" begin
    # A widget that rejects one particular value, the way PlutoUI's Slider
    # rejects an out-of-range index -- reproduced with AbstractPlutoDingetjes
    # directly so the test needs no extra notebook dependency beyond it.
    # Pluto's own transform_bond_value (PlutoRunner/bonds.jl) catches whatever
    # this throws and hands the bound variable a sentinel value instead of
    # propagating the exception, so the rejection shows up downstream as a
    # cell in `error` -- not as this `bond` call throwing directly.
    call("edit", Dict("wait_seconds" => 300, "code" =>
        "begin\n" *
        "\timport AbstractPlutoDingetjes\n" *
        "\tstruct _PickyBond\n\t\treject::Int\n\tend\n" *
        "\tBase.show(io::IO, ::MIME\"text/html\", ::_PickyBond) = print(io, \"<input type=range>\")\n" *
        "\tAbstractPlutoDingetjes.Bonds.transform_value(w::_PickyBond, from_js) =\n" *
        "\t\tfrom_js == w.reject ? error(\"rejected: \$from_js\") : from_js\n" *
        "end"))
    call("edit", Dict("code" => "picky = @bind picky _PickyBond(13)", "wait_seconds" => 60))
    call("edit", Dict("code" => "picky_doubled = picky * 2", "wait_seconds" => 60))

    good = call("bond", Dict("name" => "picky", "value" => 5, "wait_seconds" => 60))
    @test good.status == "success"
    @test any(c -> c.name == "picky_doubled" && c.output == "10", good.cells)
    @test P._notebook().bonds[:picky].value == 5

    # The rejected call errors...
    bad = call("bond", Dict("name" => "picky", "value" => 13, "wait_seconds" => 60))
    @test bad.error
    # ...and does not leave the bad value installed: a fresh read shows the
    # notebook back where the last GOOD call left it, dependents included.
    @test P._notebook().bonds[:picky].value == 5
    @test cell_output("picky_doubled") == "10"

    # Not poisoned: a later good value still works normally.
    again = call("bond", Dict("name" => "picky", "value" => 9, "wait_seconds" => 60))
    @test again.status == "success"
    @test any(c -> c.name == "picky_doubled" && c.output == "18", again.cells)

    # A SECOND, never-before-bonded variable, rejected on its very first
    # `bond` call: there is no previous nb.bonds entry to restore, only the
    # earlier-branch's absence to put back -- the message says so rather than
    # claiming a rollback that did not happen. A dependent cell is needed here
    # too: with nothing reading `novel`, `where_referenced` finds no cell to
    # re-run, the sentinel value from the rejected transform touches nothing,
    # and the rejection would go unnoticed.
    call("edit", Dict("code" => "novel = @bind novel _PickyBond(4)", "wait_seconds" => 60))
    call("edit", Dict("code" => "novel_view = novel * 1", "wait_seconds" => 60))
    @test !haskey(P._notebook().bonds, :novel)
    first_try = call("bond", Dict("name" => "novel", "value" => 4, "wait_seconds" => 60))
    @test first_try.error
    @test occursin("no earlier bond value", first_try.message)
    @test !haskey(P._notebook().bonds, :novel)

    for n in ("novel_view", "novel", "picky_doubled", "picky", "_PickyBond")
        call("edit", Dict("cell" => n, "code" => "", "wait_seconds" => 60))
    end
end

@testset "the notebook itself renders, with no cell named" begin
    # A notebook shown as text/html IS the self-contained export, and as
    # text/plain it is the .jl source. Same tool, same rule, one level up --
    # which is why there is no `export`.
    out = tempname() * ".html"
    r = call("output", Dict("mime" => "text/html", "path" => out))
    @test r.path == out && isfile(out) && r.bytes > 1000
    @test occursin("<html", lowercase(read(out, String)))
    rm(out; force=true)

    src = call("output", Dict("mime" => "text/plain"))
    @test occursin("### A Pluto.jl notebook ###", src.output)
    @test occursin("Cell order:", src.output)     # the real file format

    # A notebook is not a figure, and says so rather than guessing.
    @test call("output", Dict("mime" => "image/png")).error
end

@testset "multiple notebooks at once" begin
    one = call("open", Dict("create" => true, "wait_seconds" => 120))
    call("edit", Dict("code" => "which = 1", "wait_seconds" => 60))
    two = call("open", Dict("create" => true, "wait_seconds" => 120))
    call("edit", Dict("code" => "which = 2", "wait_seconds" => 60))

    # A notebook is named by its FILE. There is no tool that lists them:
    # a ref that matches nothing answers with what IS open, which is the
    # information at the moment it is wanted.
    missing_ref = call("read", Dict("notebook" => "nonexistent-xyz.jl"))
    @test missing_ref.error
    @test occursin(basename(one.path), missing_ref.message)
    @test occursin(basename(two.path), missing_ref.message)

    # The second open is current; the first is still reachable by path.
    @test cell_output("which") == "2"
    @test call("output", Dict("cell" => "which", "mime" => "text/plain",
                              "notebook" => basename(one.path))).output == "1"

    # Regression: CHANGES/SNAPSHOTS are keyed per NOTEBOOK. A shared log would
    # report every cell of the other notebook as freshly deleted the moment
    # either one fired a state change.
    t0 = call("read", Dict()).timestamp
    call("edit", Dict("code" => "extra = 3", "wait_seconds" => 60))
    for ref in (one.path, two.path)
        r = call("read", Dict("notebook" => basename(ref), "since" => t0))
        @test !any(c -> get(c, :change, nothing) == "deleted", r.cells)
    end

    for ref in (one.path, two.path)
        call("stop", Dict("notebook" => basename(ref)))
    end
    call("open", Dict("path" => MAIN[], "wait_seconds" => 60))   # back to the main notebook
end

@testset "a missing required argument errors instead of crashing" begin
    for tool in P.ALL_TOOLS
        req = [p.name for p in tool.parameters if p.required]
        isempty(req) && continue
        r = call(tool.name, Dict())
        @test r isa JSON3.Object && r.error
    end
end

@testset "every running tool returns the one record" begin
    # The acceptance test from the spec, stated once and checked against the
    # live surface: if the agent needs a second parser, something is wrong.
    for (name, args) in (("read", Dict()),
                         ("edit", Dict("cell" => "total", "code" => "total = a * b",
                                       "wait_seconds" => 60)))
        r = call(name, Dict{String,Any}(args))
        @test is_record(r)
        @test r.status in ("running", "queued", "success", "error", "disabled", "unrun")
        # A real server clock, for `since` -- ISO 8601 UTC with milliseconds.
        @test occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$", r.timestamp)
        @test r.waited_seconds >= 0
    end
end

@testset "stop narrows by argument" begin
    # A cell to interrupt: sleep long enough that the stop lands mid-run.
    call("edit", Dict("code" => "napping = (sleep(30); :done)", "wait_seconds" => 0.3))
    r = call("stop", Dict("notebook" => basename(P._notebook().path),
                          "cell" => "napping"))
    @test is_record(r)
    @test r.stopped == "cell"
    @test call("read", Dict("cells" => ["napping"],
                            "wait_seconds" => 20)).status in ("error", "success")
    call("edit", Dict("cell" => "napping", "code" => "",
                      "wait_seconds" => 30))

    # stop(notebook): that notebook only, and its spill files with it.
    two = call("open", Dict("create" => true, "wait_seconds" => 120))
    spill = P.spill_dir(P._notebook())
    mkpath(spill); write(joinpath(spill, "x.txt"), "x")
    open_count() = length(P.session().session.notebooks)
    n = open_count()
    d = call("stop", Dict("notebook" => basename(two.path)))
    @test d.stopped == "notebook"
    @test open_count() == n - 1
    @test !isdir(spill)

    # stop(cell) without a notebook is a refusal, not a guess at which one.
    @test call("stop", Dict("cell" => "anything")).error

    # ...and with no arguments, everything.
    @test call("stop", Dict()).stopped == "server"
    @test call("read", Dict()).error
    @test call("stop", Dict()).error      # stopping twice is refused
end
