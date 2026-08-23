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

"Call a tool the way an MCP client would, and decode its JSON result."
function call(name::String, args::Dict=Dict{String,Any}())
    r = TOOLS[name].handler(args)
    r isa P.TextContent ? JSON3.read(r.text) : r
end

"A notebook built from source, with no server involved."
offline_notebook(cells::Vector{String}; cell_types::Vector{String}=fill("code", length(cells))) =
    P.notebook_source(cells; cell_types)

"""The rendered output of one cell, whichever shape the record used.

A record compacts cells this session has already been shown, so a value the
suite wants to check again comes from `output` -- which is exactly the tool the
agent would reach for."""
cell_output(session, name) = call("output", Dict("session" => session, "cell" => name)).output

"Every field the one record promises. Used as an acceptance test everywhere."
const RECORD_FIELDS = (:status, :waited_seconds, :timestamp, :cells)
is_record(r) = all(f -> haskey(r, f), RECORD_FIELDS) &&
    !any(f -> haskey(r, f), (:finished, :errored)) &&
    r.status in ("pending", "calculating", "success", "error")

# ---------------------------------------------------------------------------
# Pure: no Pluto server, fast.
# ---------------------------------------------------------------------------

@testset "notebook_source" begin
    nb = P.notebook_source(["x = 1", "# heading"]; cell_types=["code", "markdown"])
    @test nb isa Pluto.Notebook
    @test length(nb.cells) == 2
    @test nb.cells[1].code == "x = 1"
    @test occursin("md\"\"\"", nb.cells[2].code)  # markdown cell wrapped

    # Markdown that is already md"..." must not be double-wrapped.
    nb2 = P.notebook_source(["md\"already\""]; cell_types=["markdown"])
    @test !occursin("md\"\"\"\nmd\"already\"", nb2.cells[1].code)

    # ids are uuid4, not Cell's default uuid1 (time-based): cells made in a
    # tight loop still need discriminating prefixes -- see resolve_cell.
    many = P.notebook_source(fill("1", 20))
    @test length(unique(c.cell_id for c in many.cells)) == 20

    @test_throws ErrorException P.notebook_source(["a", "b"]; cell_types=["code"])
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

    @test P.sketch(Dict{Symbol,Any}(:type => :circular)) == "#= circular reference =#"
    # An unfamiliar tree type is summarised, never dumped.
    @test P.sketch(Dict{Symbol,Any}(:type => :SomethingNew)) == "<SomethingNew>"
end

@testset "the vocabulary has no synonyms" begin
    # Item 0 of the round-2 spec, enforced rather than remembered. `block`,
    # `new_source`, `cell_id` and `source` are the words this surface used to
    # speak; every one of them now has exactly one replacement.
    banned = ["block", "new_source", "source", "cell_id", "waited_s", "full",
              "edit_mode", "ephemeral", "finished", "errored"]
    for tool in P.ALL_TOOLS, p in tool.parameters
        @test !(p.name in banned)
    end

    # Everything that runs or waits takes wait_seconds, nothing else does, and
    # they all carry the SAME default -- one value flowing to one function.
    waits = Set(["open", "edit", "run", "read", "bond"])
    for tool in P.ALL_TOOLS
        w = [p for p in tool.parameters if p.name == "wait_seconds"]
        @test (length(w) == 1) == (tool.name in waits)
        isempty(w) || @test only(w).default == P.DEFAULT_WAIT
    end
    # Not 0: a fast cell should converge inside the call, so the common case
    # comes back complete without a follow-up read.
    @test P.DEFAULT_WAIT > 0

    # Ten tools, exactly these.
    @test Set(keys(TOOLS)) == Set(["start", "open", "list", "edit", "run",
                                   "read", "output", "bond", "export", "stop"])
end

# ---------------------------------------------------------------------------
# Server-backed. One Pluto server for most of it: starting one is slow.
# ---------------------------------------------------------------------------

const S = "test"

@testset "session lifecycle" begin
    r = call("start", Dict("session" => S))
    @test occursin("localhost:", r.host)
    @test !isempty(r.secret)

    # Tools must refuse clearly before a notebook exists, rather than throwing.
    @test call("read", Dict("session" => S)).error
    @test occursin("no session", call("read", Dict("session" => "absent")).message)

    @test isempty(call("list", Dict("session" => S)))   # nothing open yet
end

@testset "every tool refuses a nonexistent session cleanly" begin
    # Every handler resolves the session (or notebook) before touching any
    # other argument, so this must produce the same clean "no session"
    # message everywhere -- not a KeyError from some other required arg being
    # absent, and not a crash.
    for tool in P.ALL_TOOLS
        tool.name == "start" && continue   # start CREATES the session
        r = call(tool.name, Dict("session" => "absent"))
        @test r.error
        @test occursin("no session", r.message)
    end
end

@testset "every notebook-taking tool refuses a bad notebook ref cleanly" begin
    for tool in P.ALL_TOOLS
        any(p -> p.name == "notebook", tool.parameters) || continue
        r = call(tool.name, Dict("session" => S, "notebook" => "nonexistent-xyz.jl"))
        @test r.error
        @test occursin("no open notebook", r.message)
    end
end

@testset "start twice under the same name doesn't leak the first server" begin
    T = "restart-leak-test"
    call("start", Dict("session" => T))
    call("open", Dict("session" => T, "create" => true, "wait_seconds" => 90))
    old_worker = Pluto.WorkspaceManager.get_workspace(
        (P._session(T).session, P._notebook(T))).worker

    r2 = call("start", Dict("session" => T))            # same name, second time
    @test occursin("localhost:", r2.host)
    @test !Pluto.Malt.isrunning(old_worker)              # the old one is really gone
    @test call("read", Dict("session" => T)).error       # and so is its notebook

    call("stop", Dict("session" => T))
end

@testset "stop cleans up per-notebook state for every notebook" begin
    # CHANGES/SNAPSHOTS are keyed by (session, notebook_id), so cleanup cannot
    # be one delete!(dict, session_name). Spill directories are per notebook
    # too, and they hold output nobody wants surviving the session.
    T = "cleanup-multi-notebook-test"
    call("start", Dict("session" => T))
    call("open", Dict("session" => T, "create" => true, "wait_seconds" => 90))
    other = P.notebook_source(["q = 2"])
    other.path = tempname() * ".jl"
    Pluto.save_notebook(other)
    call("open", Dict("session" => T, "path" => other.path, "wait_seconds" => 90))
    @test count(k -> first(k) == T, keys(P.CHANGES)) == 2
    @test count(k -> first(k) == T, keys(P.SNAPSHOTS)) == 2

    spill = P.spill_dir(P._notebook(T))
    mkpath(spill); write(joinpath(spill, "leftover.txt"), "x")

    call("stop", Dict("session" => T))
    @test !any(k -> first(k) == T, keys(P.CHANGES))
    @test !any(k -> first(k) == T, keys(P.SNAPSHOTS))
    @test !isdir(spill)
end

@testset "open: create, and the record it returns" begin
    r = call("open", Dict("session" => S, "create" => true, "wait_seconds" => 120))
    @test is_record(r)
    @test r.status == "success"
    @test startswith(r.url, "http://localhost:")
    @test endswith(r.path, ".jl")
    @test isfile(r.path)
    # A pathless create is scratch: it must not land in the directory a person
    # keeps their real notebooks in.
    @test startswith(r.path, tempdir())
    # Wide layout, because a reviewer is more likely looking at a plot than
    # reading prose in a 700px column.
    @test any(c -> occursin("max-width", c.code), r.cells)
end

@testset "open: create with a name, and reopening it" begin
    path = joinpath(mktempdir(), "throughput experiment.jl")
    r = call("open", Dict("session" => S, "create" => true, "path" => path,
                          "wait_seconds" => 120))
    @test r.path == path
    call("edit", Dict("session" => S, "mode" => "insert",
                      "code" => "kept = 41 + 1", "wait_seconds" => 60))

    # Reopening the FILE gets the saved work back, cells and all.
    r2 = call("open", Dict("session" => S, "path" => path, "wait_seconds" => 120))
    @test is_record(r2)
    @test any(c -> c.name == "kept", r2.cells)
    @test cell_output(S, "kept") == "42"

    # open without a path and without create is a clear refusal, not a guess.
    @test call("open", Dict("session" => S)).error
end

@testset "edit: insert, replace, delete" begin
    call("open", Dict("session" => S, "create" => true, "wait_seconds" => 120))

    r = call("edit", Dict("session" => S, "mode" => "insert",
                          "code" => "a = 6", "wait_seconds" => 60))
    @test is_record(r)
    @test r.status == "success"
    @test only(c.name for c in r.cells) == "a"
    @test only(c.output for c in r.cells) == "6"

    call("edit", Dict("session" => S, "mode" => "insert",
                      "code" => "b = 7", "cell" => "a", "wait_seconds" => 60))
    call("edit", Dict("session" => S, "mode" => "insert",
                      "code" => "total = a * b", "cell" => "b", "wait_seconds" => 60))
    @test cell_output(S, "total") == "42"

    # markdown is wrapped for you
    m = call("edit", Dict("session" => S, "mode" => "insert",
                          "code" => "# a heading", "cell_type" => "markdown",
                          "wait_seconds" => 60))
    @test occursin("md\"\"\"", only(c.code for c in m.cells))

    d = call("edit", Dict("session" => S, "cell" => only(c.cell_id for c in m.cells),
                          "mode" => "delete", "wait_seconds" => 60))
    @test is_record(d)
    @test !any(c -> occursin("a heading", get(c, :code, "")),
               call("read", Dict("session" => S)).cells)

    # replace/delete without a cell is a refusal, not a crash.
    @test call("edit", Dict("session" => S, "code" => "x = 1")).error
end

@testset "cells reports the whole cascade, not just the target" begin
    # Editing `a` re-runs `total` cleanly. Reporting only the edited cell
    # describes the request; the cascade is what actually happened.
    r = call("edit", Dict("session" => S, "cell" => "a", "code" => "a = 10",
                          "wait_seconds" => 60))
    names = Set(c.name for c in r.cells)
    @test "a" in names
    @test "total" in names                     # a clean downstream re-run
    @test any(c -> c.name == "total" && c.output == "70", r.cells)
end

@testset "edit does not echo the code it was just given" begin
    # The caller wrote this text; sending it back is the one field of the
    # record they already have, and for a large cell it is the biggest.
    r = call("edit", Dict("session" => S, "mode" => "insert",
                          "code" => "echoed = 6 * 7", "wait_seconds" => 60))
    entry = only(c for c in r.cells if c.name == "echoed")
    @test !haskey(entry, :code)
    @test entry.output == "42"                  # everything asked for is still there

    # Replace is the same promise.
    r2 = call("edit", Dict("session" => S, "cell" => "echoed",
                           "code" => "echoed = 6 * 8", "wait_seconds" => 60))
    @test !haskey(only(c for c in r2.cells if c.name == "echoed"), :code)

    # Markdown is wrapped in md""" on the way in, so the stored code is NOT
    # what arrived -- that is news, not an echo, and it comes back.
    md = call("edit", Dict("session" => S, "mode" => "insert", "cell_type" => "markdown",
                           "code" => "a heading", "wait_seconds" => 60))
    entry_md = only(md.cells)
    @test haskey(entry_md, :code) && occursin("md\"\"\"", entry_md.code)

    # A cell the agent did not write is not an echo either: the cascade a
    # replace sets off has to arrive in full.
    call("edit", Dict("session" => S, "mode" => "insert",
                      "code" => "downstream_of_echoed = echoed + 1", "wait_seconds" => 60))
    r3 = call("edit", Dict("session" => S, "cell" => "echoed",
                           "code" => "echoed = 6 * 9", "wait_seconds" => 60))
    @test haskey(only(c for c in r3.cells if c.name == "downstream_of_echoed"), :code)

    for n in ("downstream_of_echoed", "echoed", entry_md.name)
        call("edit", Dict("session" => S, "cell" => n, "mode" => "delete",
                          "wait_seconds" => 60))
    end
end

@testset "edit: delete_on_success" begin
    before = length(call("read", Dict("session" => S)).cells)

    r = call("edit", Dict("session" => S, "mode" => "insert",
                          "code" => "a + b", "delete_on_success" => true, "wait_seconds" => 60))
    @test r.status == "success"
    # Reported by NAME, the way the agent addresses a cell -- not by a UUID it
    # never used. An unnamed cell is named by its id, so this one is its id.
    @test haskey(r, :deleted)
    @test r.deleted == only(c.name for c in r.cells)
    @test only(c.output for c in r.cells) == "17"       # the answer still comes back
    @test length(call("read", Dict("session" => S)).cells) == before
    @test !occursin("a + b", read(P._notebook(S).path, String))

    # A cell that FAILS stays put, so the agent can read it and remove it
    # deliberately -- a cell that vanished mid-error is worse.
    e = call("edit", Dict("session" => S, "mode" => "insert",
                          "code" => "error(\"probe blew up\")", "delete_on_success" => true,
                          "wait_seconds" => 60))
    @test e.status == "error"
    @test !haskey(e, :deleted)
    @test occursin("delete", e.hint)
    stuck = only(c.cell_id for c in e.cells)
    # An unnamed cell is named by its own id, so a compacted entry still
    # addresses it.
    @test any(c -> c.name == stuck, call("read", Dict("session" => S)).cells)
    call("edit", Dict("session" => S, "cell" => stuck, "mode" => "delete",
                      "wait_seconds" => 60))
    @test length(call("read", Dict("session" => S)).cells) == before

    # An explicit wait_seconds=0 returns before the result is in, so the flag
    # cannot fire: deletion at return time is the entire contract.
    z = call("edit", Dict("session" => S, "mode" => "insert",
                          "code" => "1 + 1", "delete_on_success" => true, "wait_seconds" => 0))
    @test z.status == "calculating"
    @test !haskey(z, :deleted)
    call("edit", Dict("session" => S, "cell" => only(c.cell_id for c in z.cells),
                      "mode" => "delete", "wait_seconds" => 60))
end

@testset "errors are reported as messages, not blobs" begin
    r = call("edit", Dict("session" => S, "mode" => "insert",
                          "code" => "broken = (", "wait_seconds" => 60))
    c = only(r.cells)
    @test c.status == "error"
    @test r.status == "error"                     # aggregated by the one rule
    @test occursin("parseerror", c.mime)
    @test !isempty(c.error)                       # a message, not a Dict dump
    @test !occursin("Dict", c.error)
    call("edit", Dict("session" => S, "cell" => c.cell_id, "mode" => "delete",
                      "wait_seconds" => 60))

    r2 = call("edit", Dict("session" => S, "mode" => "insert",
                           "code" => "boom = error(\"kaboom\")", "wait_seconds" => 60))
    c2 = only(r2.cells)
    @test c2.status == "error"
    @test occursin("kaboom", c2.error)
    @test occursin("stacktrace", c2.mime)
    call("edit", Dict("session" => S, "cell" => "boom", "mode" => "delete",
                      "wait_seconds" => 60))
end

@testset "run" begin
    r = call("run", Dict("session" => S, "cells" => ["total"], "wait_seconds" => 60))
    @test is_record(r)
    @test r.status == "success"
    @test any(c -> c.name == "total", r.cells)

    all_r = call("run", Dict("session" => S, "wait_seconds" => 60))   # whole notebook
    @test all_r.status == "success"
    @test length(all_r.cells) >= 3
end

@testset "short wait, then keep running" begin
    call("edit", Dict("session" => S, "mode" => "insert",
                      "code" => "slow = (sleep(3); 99)", "wait_seconds" => 0.2))
    r = call("read", Dict("session" => S, "cells" => ["slow"]))
    @test r.status in ("calculating", "success")

    # read(wait_seconds=N) is the follow-up: one call, not a poll loop.
    done = call("read", Dict("session" => S, "cells" => ["slow"], "wait_seconds" => 30))
    @test done.status == "success"
    @test done.waited_seconds >= 0
    @test only(done.cells).output == "99"
    call("edit", Dict("session" => S, "cell" => "slow", "mode" => "delete",
                      "wait_seconds" => 30))
end

@testset "a fast cell is not reported as still running" begin
    # The whole point of the Task-based wait: completion is istaskdone, not a
    # guess from busy flags that read "idle" before the run had even started.
    for _ in 1:5
        r = call("edit", Dict("session" => S, "mode" => "insert",
                              "code" => "quick = 1 + 1", "wait_seconds" => 30))
        @test r.status == "success"
        @test only(c.output for c in r.cells) == "2"
        call("edit", Dict("session" => S, "cell" => "quick", "mode" => "delete",
                          "wait_seconds" => 30))
    end
end

@testset "an error ends the wait early" begin
    t0 = time()
    r = call("edit", Dict("session" => S, "mode" => "insert",
                          "code" => "fails = error(\"nope\")", "wait_seconds" => 30))
    @test time() - t0 < 25                       # did not serve out the deadline
    @test r.status == "error"
    call("edit", Dict("session" => S, "cell" => "fails", "mode" => "delete",
                      "wait_seconds" => 30))
end

@testset "read: snapshot, subset, tree" begin
    r = call("read", Dict("session" => S))
    @test is_record(r)
    @test r.status == "success"
    # Every entry carries a name and a status, in either shape; a full one also
    # carries the code and the id.
    @test all(c -> haskey(c, :name) && haskey(c, :status), r.cells)
    @test all(c -> haskey(c, :unchanged_since) || (haskey(c, :code) && haskey(c, :cell_id)),
              r.cells)

    one = call("read", Dict("session" => S, "cells" => ["total"]))
    @test length(one.cells) == 1

    t = call("read", Dict("session" => S, "cells" => ["total"], "tree" => true))
    c = only(t.cells)
    @test "a" in c.upstream["a"]
    # `*` is a reference too, and correctly so: the tree is Pluto's own
    # reactivity graph, not a filtered view of the globals a person would name.
    @test issubset(["a", "b"], c.references)
    @test !any(r -> startswith(r, "PlutoRunner"), c.references)

    a = only(call("read", Dict("session" => S, "cells" => ["a"], "tree" => true)).cells)
    @test "total" in a.downstream["a"]
end

@testset "cells this session already saw compress, and since drops them" begin
    T = "dedup"
    call("start", Dict("session" => T))
    opened = call("open", Dict("session" => T, "create" => true, "wait_seconds" => 120))
    @test all(c -> haskey(c, :code), opened.cells)        # first sight: in full

    ins = call("edit", Dict("session" => T, "mode" => "insert", "code" => "base = 2",
                            "wait_seconds" => 60))
    # A cell the caller just wrote is the one exception: its code is not read
    # back to it (see "edit does not echo"), but the rest of the entry is full.
    @test !haskey(only(ins.cells), :code)
    @test haskey(only(ins.cells), :output)
    call("edit", Dict("session" => T, "mode" => "insert", "code" => "derived = base * 3",
                      "wait_seconds" => 60))

    # Looking again at state the session has already been given: every cell is
    # name, status, unchanged_since and nothing else. Compressed, not hidden --
    # the cascade stays countable.
    again = call("read", Dict("session" => T))
    @test length(again.cells) == 3
    @test all(c -> haskey(c, :unchanged_since) && !haskey(c, :code), again.cells)
    # ISO 8601 UTC, fixed width: lexicographic order IS chronological order.
    @test all(c -> c.unchanged_since <= again.timestamp, again.cells)

    # A real change comes back in full -- minus the code the caller just sent
    # -- and so does the cascade it caused.
    r = call("edit", Dict("session" => T, "cell" => "base", "code" => "base = 5",
                          "wait_seconds" => 60))
    changed = only(c for c in r.cells if get(c, :name, "") == "base")
    @test !haskey(changed, :code) && get(changed, :output, "") == "5"
    cascaded = only(c for c in r.cells if get(c, :name, "") == "derived")
    @test get(cascaded, :output, "") == "15"

    # Re-running a cell to the SAME answer is not a change. Pluto allocates a
    # fresh object and a fresh objectid; the fingerprint deliberately ignores
    # that, because it identifies the rendered output, not the object.
    call("run", Dict("session" => T, "cells" => ["derived"], "wait_seconds" => 60))
    @test haskey(only(call("read", Dict("session" => T, "cells" => ["derived"])).cells),
                 :unchanged_since)

    # `since` is the same comparison shown as a delta rather than a summary.
    # Empty is the honest answer when every record so far already delivered
    # everything -- an `edit` hands over its cascade, so there is no backlog.
    t = call("read", Dict("session" => T)).timestamp
    @test isempty(call("read", Dict("session" => T, "since" => t)).cells)

    # A float unix time is still a timestamp: transcripts and older clients
    # have them, and refusing one would only lose a delta. A string that is
    # not a timestamp is refused with a message that shows the shape wanted.
    unix = P.parse_timestamp(t)
    @test isempty(call("read", Dict("session" => T, "since" => unix)).cells)
    bad = call("read", Dict("session" => T, "since" => "yesterday"))
    @test bad.error && occursin("timestamp", bad.message)

    # A change made OUTSIDE the tools -- what a browser patch does -- was never
    # delivered, so it is genuinely new and arrives in full.
    nb = P._notebook(T)
    cell = P.resolve_cell(nb, "base")
    cell.code = "base = 7"
    Pluto.update_save_run!(P._session(T).session, nb, Pluto.Cell[cell]; run_async=false)
    delta = call("read", Dict("session" => T, "since" => t))
    @test is_record(delta)
    @test "base" in [c.name for c in delta.cells]
    @test all(c -> haskey(c, :code), delta.cells)         # deltas are never compact
    @test any(c -> get(c, :old_code, "") == "base = 5" && c.new_code == "base = 7",
              delta.cells)

    call("stop", Dict("session" => T))
    @test !any(k -> first(k) == T, keys(P.REPORTED))
end

@testset "a container that re-runs to the same value fingerprints the same" begin
    # The objectid case, isolated: ones(5) allocates a new array every run, so a
    # fingerprint over Pluto's raw tree body would call this changed forever.
    T = "dedup-objectid"
    call("start", Dict("session" => T))
    call("open", Dict("session" => T, "create" => true, "wait_seconds" => 120))
    call("edit", Dict("session" => T, "mode" => "insert", "code" => "vals = ones(5)",
                      "wait_seconds" => 60))
    call("read", Dict("session" => T, "cells" => ["vals"]))
    call("run", Dict("session" => T, "cells" => ["vals"], "wait_seconds" => 60))
    @test haskey(only(call("read", Dict("session" => T, "cells" => ["vals"])).cells),
                 :unchanged_since)
    call("stop", Dict("session" => T))
end

@testset "read: a human's browser edit comes back with old_code and new_code" begin
    t0 = call("read", Dict("session" => S)).timestamp

    # An edit made THROUGH our own tools is pre-marked as seen, so it must not
    # come back as a change: `since` reports what a HUMAN did, not an echo.
    call("edit", Dict("session" => S, "cell" => "a", "code" => "a = 5",
                      "wait_seconds" => 60))
    mine = call("read", Dict("session" => S, "since" => t0))
    @test !any(c -> haskey(c, :old_code), mine.cells)

    t1 = call("read", Dict("session" => S)).timestamp
    # A change made OUTSIDE our tools -- exactly what a browser patch does.
    nb = P._notebook(S)
    cell = P.resolve_cell(nb, "a")
    cell.code = "a = 9"
    Pluto.update_save_run!(P._session(S).session, nb, Pluto.Cell[cell]; run_async=false)

    theirs = call("read", Dict("session" => S, "since" => t1))
    @test is_record(theirs)
    edited = only(c for c in theirs.cells if get(c, :change, nothing) == "edited")
    @test edited.name == "a"
    @test edited.old_code == "a = 5"
    @test edited.new_code == "a = 9"
    # ...and the cascade it caused is in the same record, without a second call.
    @test any(c -> c.name == "total", theirs.cells)
end

@testset "reads reflect the live notebook" begin
    # Mutate the Notebook directly, the way Pluto's frontend patches do, and
    # confirm a read sees it with no refresh step of any kind.
    nb = P._notebook(S)
    P.resolve_cell(nb, "a").code = "a = 12345"
    @test any(c -> get(c, :code, "") == "a = 12345",
              call("read", Dict("session" => S)).cells)
    P.resolve_cell(nb, "a").code = "a = 6"
    call("run", Dict("session" => S, "cells" => ["a"], "wait_seconds" => 60))
end

@testset "output rendering: sketches, not dumps" begin
    # The insert's own record is where the sketch appears: a later read would
    # compact this cell, having already delivered it.
    r = call("edit", Dict("session" => S, "mode" => "insert",
                          "code" => "vec = collect(1.0:100000.0)", "wait_seconds" => 60))
    sketched = only(c.output for c in r.cells if get(c, :name, "") == "vec")
    @test occursin("Vector{Float64}", sketched)
    @test occursin("elements", sketched)
    @test !occursin("\n", sketched)              # one line for 100k elements
    @test length(sketched) < 400

    # `output` gives every element Pluto stored -- more than the sketch, and
    # still not a dump of Pluto's own Dict.
    full = cell_output(S, "vec")
    @test occursin("Vector{Float64}", full)
    @test length(full) > length(sketched)
    @test !occursin("MIME type", full)
    @test !occursin("Dict{Symbol", full)

    call("edit", Dict("session" => S, "mode" => "insert",
                      "code" => "tup = (x=1, y=\"two\", z=[1,2,3])", "wait_seconds" => 60))
    @test cell_output(S, "tup") == "(x = 1, y = \"two\", z = Int64[1, 2, 3])"

end

@testset "output: one cell, complete" begin
    r = call("output", Dict("session" => S, "cell" => "total"))
    @test r.cell == "total"
    @test r.output == "42"
    @test r.status == "success"

    # Text past the inline limit spills, and the payload names the path.
    # `Text` rather than a bare String on purpose: Pluto renders a String
    # through `repr` with :limit, so it arrives already shortened and there is
    # nothing left for us to spill. Text is stored whole, which is the case
    # this guard exists for.
    call("edit", Dict("session" => S, "mode" => "insert",
                      "code" => "long = Text(join(string.(1:20000), \"\\n\"))",
                      "wait_seconds" => 60))
    big = call("output", Dict("session" => S, "cell" => "long"))
    @test occursin("full output:", big.output)
    # The marker is `… (<size> total, full output: <path>)` -- take the path up
    # to the closing paren, not to the next space.
    path = match(r"full output: ([^)]+)\)", big.output)[1]
    @test isfile(path)
    @test filesize(path) > P.INLINE_LIMIT
    @test occursin("20000", big.output)              # the tail survived
    @test startswith(big.output, "1\n2\n3\n")        # ...and so did the head
    @test read(path, String) == join(string.(1:20000), "\n")   # the file is whole
    call("edit", Dict("session" => S, "cell" => "long", "mode" => "delete",
                      "wait_seconds" => 60))

    # A value Pluto ITSELF shortened comes back shortened, carrying Pluto's own
    # size marker. `output` never re-executes a cell, so the rest of that string
    # exists only in the worker: saying so beats pretending to be complete.
    call("edit", Dict("session" => S, "mode" => "insert",
                      "code" => "shortened = join(string.(1:20000), \"\\n\")",
                      "wait_seconds" => 60))
    s = call("output", Dict("session" => S, "cell" => "shortened"))
    @test occursin("bytes", s.output)                # Pluto's " ⋯ N bytes ⋯ "
    @test !occursin("\e[", s.output)                 # with its ANSI colouring stripped
    call("edit", Dict("session" => S, "cell" => "shortened", "mode" => "delete",
                      "wait_seconds" => 60))

    # A print blob is a log entry, and hits the same one truncation function.
    r = call("edit", Dict("session" => S, "mode" => "insert",
                          "code" => "printy = (println(\"p\"^9000); 3)", "wait_seconds" => 60))
    # The print may not have been flushed when the edit returned; whichever
    # record first carries it is the one to read, and a later read compacts a
    # cell it has already delivered.
    logs = get(only(c for c in r.cells if get(c, :name, "") == "printy"), :logs, nothing)
    for _ in 1:150
        logs === nothing || break
        logs = get(only(call("read", Dict("session" => S, "cells" => ["printy"])).cells),
                   :logs, nothing)
        logs === nothing && sleep(0.1)
    end
    @test logs !== nothing
    @test occursin("full output:", only(logs).msg)
    call("edit", Dict("session" => S, "cell" => "printy", "mode" => "delete",
                      "wait_seconds" => 60))

    @test call("output", Dict("session" => S, "cell" => "no-such-cell")).error
end

@testset "logs: structured, capped, counted" begin
    r = call("edit", Dict("session" => S, "mode" => "insert",
        "code" => "noisy = begin; for i in 1:100; @info \"step\" i=i; end; println(\"done\"); 7; end",
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
        c = only(call("read", Dict("session" => S, "cells" => ["noisy"])).cells)
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
    call("edit", Dict("session" => S, "cell" => "noisy", "mode" => "delete",
                      "wait_seconds" => 60))
end

@testset "AsPNG is injected, and survives Pluto bumping the workspace" begin
    r = call("edit", Dict("session" => S, "mode" => "insert",
                          "code" => "has_helper = isdefined(PlutoMCP, :AsPNG)",
                          "wait_seconds" => 60))
    @test only(c.output for c in r.cells) == "true"

    # Pluto makes a fresh Main.workspace#N on every reactive run, so a helper
    # defined only in the old module would be gone by the next call. This is
    # the regression: a SECOND run must still see it.
    r2 = call("edit", Dict("session" => S, "mode" => "insert",
                           "code" => "helper_type = string(PlutoMCP.AsPNG)",
                           "wait_seconds" => 60))
    @test occursin("AsPNG", only(c.output for c in r2.cells))
    for n in ("has_helper", "helper_type")
        call("edit", Dict("session" => S, "cell" => n, "mode" => "delete",
                          "wait_seconds" => 60))
    end
end

@testset "output refuses vector-image markup instead of pasting it" begin
    # A Plots figure stores SVG, which no MCP client can show. Handing back a
    # screenful of <path d="..."> is not a smaller version of the picture, it
    # is a picture nobody gets -- so `output` names the shape and the way out.
    # A type that can only show as SVG stands in for the plotting library.
    call("edit", Dict("session" => S, "mode" => "insert", "wait_seconds" => 60,
                      "code" => "struct TinySVG end"))
    rshow = call("edit", Dict("session" => S, "mode" => "insert", "wait_seconds" => 60,
                      "code" => "Base.show(io::IO, ::MIME\"image/svg+xml\", ::TinySVG) = " *
                                "print(io, \"<svg xmlns='http://www.w3.org/2000/svg'>\" * " *
                                "repeat(\"<path d='M0 0 L9 9'/>\", 200) * \"</svg>\")"))
    r0 = call("edit", Dict("session" => S, "mode" => "insert", "wait_seconds" => 60,
                           "code" => "svgfig = TinySVG()"))
    @test only(c.mime for c in r0.cells if c.name == "svgfig") == "image/svg+xml"

    r = call("output", Dict("session" => S, "cell" => "svgfig"))
    @test !occursin("<path", string(r))          # not one screenful of it, either
    @test r.mime == "image/svg+xml" && r.bytes > 1000
    @test occursin("AsPNG(svgfig)", r.hint)      # named, so it can be run as printed

    # The method cell defines no global, so it is addressed by id -- and it goes
    # FIRST: left behind, it would error the moment TinySVG stopped existing.
    for n in (only(c.cell_id for c in rshow.cells), "svgfig", "TinySVG")
        call("edit", Dict("session" => S, "cell" => n, "mode" => "delete",
                          "wait_seconds" => 60))
    end
end

@testset "AsPNG survives Pluto restarting the worker process" begin
    # Installing a package restarts the notebook PROCESS, not just the
    # workspace module -- so `Main.PlutoMCP` and the preamble entry both go
    # away, and injecting once at `open` is not enough. `unmake_workspace`
    # is that restart, without the minutes a real Pkg install would cost.
    nb = P._notebook(S)
    old_worker = Pluto.WorkspaceManager.get_workspace((P._session(S).session, nb)).worker
    Pluto.WorkspaceManager.unmake_workspace((P._session(S).session, nb); async=false, verbose=false)
    @test !Pluto.Malt.isrunning(old_worker)

    r = call("edit", Dict("session" => S, "mode" => "insert",
                          "code" => "helper_after_restart = string(PlutoMCP.AsPNG)",
                          "wait_seconds" => 120))
    # A restart re-runs the whole notebook, so the record is every cell, not one.
    @test occursin("AsPNG", only(c.output for c in r.cells if c.name == "helper_after_restart"))
    call("edit", Dict("session" => S, "cell" => "helper_after_restart",
                      "mode" => "delete", "wait_seconds" => 60))
end

@testset "bond: set slider/widget values" begin
    call("edit", Dict("session" => S, "mode" => "insert",
                      "code" => "slider = @bind slider html\"<input type=range>\"",
                      "wait_seconds" => 60))
    call("edit", Dict("session" => S, "mode" => "insert",
                      "code" => "doubled_bond = slider * 2", "wait_seconds" => 60))

    r = call("bond", Dict("session" => S, "name" => "slider", "value" => 7,
                          "wait_seconds" => 60))
    @test is_record(r)
    @test r.status == "success"
    @test r.bound == "slider"
    # The cascade the bond caused is in the record itself, without a re-read.
    @test any(c -> c.name == "doubled_bond" && c.output == "14", r.cells)

    r2 = call("bond", Dict("session" => S, "name" => "slider", "value" => 10,
                           "wait_seconds" => 60))
    @test any(c -> c.name == "doubled_bond" && c.output == "20", r2.cells)

    @test call("bond", Dict("session" => S, "name" => "not_a_bond", "value" => 1)).error

    # The value is passed through exactly as given, with no type coercion --
    # deliberately. Pluto's own transform_bond_value does no string->number
    # parsing (a browser sends the JSON number 7, never the string "7"), and
    # nothing in a string tells "the number 7, sent as a string" apart from
    # "the text '7', typed into a genuinely textual field". Both cases below
    # prove pass-through: the second only works BECAUSE it stayed a string.
    call("edit", Dict("session" => S, "mode" => "insert",
                      "code" => "greeting = @bind greeting html\"<input type=text>\"",
                      "wait_seconds" => 60))
    call("edit", Dict("session" => S, "mode" => "insert",
                      "code" => "shout = greeting * \"!\"", "wait_seconds" => 60))
    g = call("bond", Dict("session" => S, "name" => "greeting", "value" => "hello",
                          "wait_seconds" => 60))
    @test any(c -> c.name == "shout" && c.output == "\"hello!\"", g.cells)
    g2 = call("bond", Dict("session" => S, "name" => "greeting", "value" => "7",
                           "wait_seconds" => 60))
    @test any(c -> c.name == "shout" && c.output == "\"7!\"", g2.cells)

    for n in ("shout", "greeting", "doubled_bond", "slider")
        call("edit", Dict("session" => S, "cell" => n, "mode" => "delete",
                          "wait_seconds" => 60))
    end
end

@testset "export: self-contained HTML" begin
    r = call("export", Dict("session" => S))
    @test is_record(r)
    @test isfile(r.exported)
    @test r.bytes > 1000
    html = read(r.exported, String)
    @test occursin("<html", lowercase(html))
    rm(r.exported; force=true)

    out = tempname() * ".html"
    @test call("export", Dict("session" => S, "path" => out)).exported == out
    rm(out; force=true)
end

@testset "multiple notebooks per session" begin
    T = "multi"
    call("start", Dict("session" => T))
    one = call("open", Dict("session" => T, "create" => true, "wait_seconds" => 120))
    call("edit", Dict("session" => T, "mode" => "insert",
                      "code" => "which = 1", "wait_seconds" => 60))
    two = call("open", Dict("session" => T, "create" => true, "wait_seconds" => 120))
    call("edit", Dict("session" => T, "mode" => "insert",
                      "code" => "which = 2", "wait_seconds" => 60))

    l = call("list", Dict("session" => T))
    @test length(l) == 2
    @test count(n -> n.current, l) == 1

    # The second open is current; the first is still reachable by path.
    @test cell_output(T, "which") == "2"
    @test call("output", Dict("session" => T, "cell" => "which",
                              "notebook" => basename(one.path))).output == "1"

    # Regression: CHANGES/SNAPSHOTS are keyed per NOTEBOOK. A shared per-session
    # log would report every cell of the other notebook as freshly deleted the
    # moment either one fired a state change.
    t0 = call("read", Dict("session" => T)).timestamp
    call("edit", Dict("session" => T, "mode" => "insert",
                      "code" => "extra = 3", "wait_seconds" => 60))
    for ref in (one.path, two.path)
        r = call("read", Dict("session" => T, "notebook" => basename(ref), "since" => t0))
        @test !any(c -> get(c, :change, nothing) == "deleted", r.cells)
    end

    call("stop", Dict("session" => T))
end

@testset "a missing required argument errors instead of crashing" begin
    for tool in P.ALL_TOOLS
        req = [p.name for p in tool.parameters if p.required]
        isempty(req) && continue
        r = call(tool.name, Dict("session" => S))
        @test r isa JSON3.Object && r.error
    end
end

@testset "every running tool returns the one record" begin
    # The acceptance test from the spec, stated once and checked against the
    # live surface: if the agent needs a second parser, something is wrong.
    for (name, args) in (("read", Dict()),
                         ("run", Dict("cells" => ["total"], "wait_seconds" => 60)),
                         ("edit", Dict("cell" => "total", "code" => "total = a * b",
                                       "wait_seconds" => 60)),
                         ("export", Dict("path" => tempname() * ".html")))
        r = call(name, merge(Dict{String,Any}("session" => S), args))
        @test is_record(r)
        @test r.status in ("pending", "calculating", "success", "error")
        # A real server clock, for `since` -- ISO 8601 UTC with milliseconds.
        @test occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$", r.timestamp)
        @test r.waited_seconds >= 0
    end
end

@testset "stop narrows by argument" begin
    # A cell to interrupt: sleep long enough that the stop lands mid-run.
    call("edit", Dict("session" => S, "mode" => "insert",
                      "code" => "napping = (sleep(30); :done)", "wait_seconds" => 0.3))
    r = call("stop", Dict("session" => S, "notebook" => basename(P._notebook(S).path),
                          "cell" => "napping"))
    @test is_record(r)
    @test r.stopped == "cell"
    @test call("read", Dict("session" => S, "cells" => ["napping"],
                            "wait_seconds" => 20)).status in ("error", "success")
    call("edit", Dict("session" => S, "cell" => "napping", "mode" => "delete",
                      "wait_seconds" => 30))

    # stop(notebook): that notebook only, and its spill files with it.
    two = call("open", Dict("session" => S, "create" => true, "wait_seconds" => 120))
    spill = P.spill_dir(P._notebook(S))
    mkpath(spill); write(joinpath(spill, "x.txt"), "x")
    n = length(call("list", Dict("session" => S)))
    d = call("stop", Dict("session" => S, "notebook" => basename(two.path)))
    @test d.stopped == "notebook"
    @test length(call("list", Dict("session" => S))) == n - 1
    @test !isdir(spill)

    # stop(cell) without a notebook is a refusal, not a guess at which one.
    @test call("stop", Dict("session" => S, "cell" => "anything")).error

    # ...and with no arguments, everything.
    @test call("stop", Dict("session" => S)).stopped == "session"
    @test call("read", Dict("session" => S)).error
    @test call("stop", Dict("session" => S)).error      # stopping twice is refused
end
