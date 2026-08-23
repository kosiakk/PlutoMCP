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

"A notebook parsed from source, with no server involved."
function offline_notebook(cells::Vector{String};
                          cell_types::Vector{String}=fill("code", length(cells)))
    path = tempname() * ".jl"
    write(path, P.notebook_source(cells; cell_types))
    Pluto.load_notebook_nobackup(path)
end

# ---------------------------------------------------------------------------
# Pure: no Pluto server, fast.
# ---------------------------------------------------------------------------

@testset "notebook_source" begin
    src = P.notebook_source(["x = 1", "# heading"]; cell_types=["code", "markdown"])
    @test occursin("### A Pluto.jl notebook ###", src)
    @test occursin("x = 1", src)
    @test occursin("md\"\"\"", src)              # markdown cell wrapped
    @test occursin("# ╔═╡ Cell order:", src)
    @test count("# ╔═╡ ", src) == 3             # two cells + the order header
    @test Meta.parseall(src) isa Expr           # a notebook file is valid Julia

    # Markdown that is already md"..." must not be double-wrapped.
    s2 = P.notebook_source(["md\"already\""]; cell_types=["markdown"])
    @test !occursin("md\"\"\"\nmd\"already\"", s2)

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
    nb = offline_notebook(["a = 1", "b = 2", "md\"x\""])
    id_md = string(nb.cells[3].cell_id)

    @test P.resolve_cell(nb, "a").code == "a = 1"              # by name
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

# ---------------------------------------------------------------------------
# Server-backed. One Pluto server for all of it: starting one is slow.
# ---------------------------------------------------------------------------

const S = "test"

@testset "session lifecycle" begin
    r = call("start", Dict("session" => S))
    @test occursin("localhost:", r.host)
    @test !isempty(r.secret)

    # Tools must refuse clearly before a notebook exists, rather than throwing.
    @test call("read", Dict("session" => S)).error
    @test occursin("no session", call("read", Dict("session" => "absent")).message)
end

@testset "create and read" begin
    r = call("create", Dict("session" => S, "block" => 60,
        "cells" => ["a = 6", "b = 7", "prod = a * b", "md\"# title\""],
        "cell_types" => ["code", "code", "code", "markdown"]))
    @test r.finished
    @test length(r.cells) == 5                 # the four requested + the wide-layout style cell
    @test occursin("/edit?id=", r.url)
    @test isfile(r.path)
    @test occursin("max-width", r.cells[1].code)   # prepended automatically

    names = [c.name for c in call("read", Dict("session" => S))]
    @test names[2:4] == ["a", "b", "prod"]
    @test !P.is_name(names[5])                 # markdown keeps its UUID

    @test call("output", Dict("session" => S, "cell_id" => "prod")).body == "42"
end

@testset "reactivity" begin
    # Editing one cell must re-run what depends on it.
    r = call("edit", Dict("session" => S, "cell_id" => "a",
                          "new_source" => "a = 100", "block" => 60))
    @test r.finished
    @test isempty(r.errored)
    @test call("output", Dict("session" => S, "cell_id" => "prod")).body == "700"
end

@testset "insert and delete" begin
    before = length(call("read", Dict("session" => S)))

    r = call("edit", Dict("session" => S, "edit_mode" => "insert",
                          "cell_id" => "prod", "new_source" => "extra = prod + 1",
                          "block" => 60))
    @test r.cells[1].name == "extra"
    @test call("output", Dict("session" => S, "cell_id" => "extra")).body == "701"
    @test length(call("read", Dict("session" => S))) == before + 1

    d = call("edit", Dict("session" => S, "edit_mode" => "delete", "cell_id" => "extra"))
    @test d.remaining == before
    @test call("output", Dict("session" => S, "cell_id" => "extra")).error
end

@testset "errors are reported" begin
    r = call("edit", Dict("session" => S, "cell_id" => "b",
                          "new_source" => "b = sqrt(-1)", "block" => 60))
    @test "b" in r.errored
    @test r.cells[1].errored

    # The error comes back structured, not stringified into a blob.
    out = call("output", Dict("session" => S, "cell_id" => "b"))
    @test out.errored
    @test out.kind == "runtime_error"
    @test occursin("DomainError", out.message)
    @test !isempty(out.stacktrace)

    # A fresh cell with a syntax error gets its own mime, flagged separately.
    r3 = call("edit", Dict("session" => S, "edit_mode" => "insert",
                           "new_source" => "broken = (", "block" => 60))
    id2 = r3.cells[1].cell_id
    out2 = call("output", Dict("session" => S, "cell_id" => id2))
    @test out2.errored
    @test out2.kind == "parse_error"
    @test !isempty(out2.diagnostics)
    call("edit", Dict("session" => S, "cell_id" => id2, "edit_mode" => "delete"))

    call("edit", Dict("session" => S, "cell_id" => "b",
                      "new_source" => "b = 7", "block" => 60))
    @test isempty(call("run", Dict("session" => S, "cells" => ["b"], "block" => 60)).errored)
end

@testset "logs" begin
    call("edit", Dict("session" => S, "edit_mode" => "insert",
                      "new_source" => "loud = (println(\"stdout line\"); @info \"info line\"; 1)",
                      "block" => 60))
    out = call("output", Dict("session" => S, "cell_id" => "loud"))
    @test !isempty(out.logs)

    read_logs = [c.logs for c in call("read", Dict("session" => S)) if c.name == "loud"]
    @test !isempty(only(read_logs))

    call("edit", Dict("session" => S, "cell_id" => "loud", "edit_mode" => "delete"))
end

@testset "execute: ephemeral eval" begin
    call("edit", Dict("session" => S, "edit_mode" => "insert",
                      "new_source" => "probed = 6 * 7", "block" => 60))

    r = call("execute", Dict("session" => S, "expr" => "probed + 1"))
    @test r.value == "43"

    r2 = call("execute", Dict("session" => S, "expr" => "typeof(probed)"))
    @test occursin("Int", r2.value)   # the value is the type itself, e.g. "Int64"

    # Nothing was added to the notebook.
    before = length(call("read", Dict("session" => S)))
    call("execute", Dict("session" => S, "expr" => "probed * 2"))
    @test length(call("read", Dict("session" => S))) == before

    @test call("execute", Dict("session" => S, "expr" => "1 +")).error   # parse error
    @test call("execute", Dict("session" => S, "expr" => "undefined_name_xyz")).error

    call("edit", Dict("session" => S, "cell_id" => "probed", "edit_mode" => "delete"))
end

@testset "unknown references" begin
    @test call("edit", Dict("session" => S, "cell_id" => "nope",
                            "new_source" => "1")).error
    @test occursin("no cell named", call("output",
        Dict("session" => S, "cell_id" => "nope")).message)
end

@testset "short block, then async" begin
    call("edit", Dict("session" => S, "edit_mode" => "insert",
                      "new_source" => "slow = (sleep(8); :done)", "block" => 0.1))

    # A deliberately short block must NOT claim the cell finished.
    t0 = time()
    r = call("run", Dict("session" => S, "cells" => ["slow"], "block" => 1))
    @test !r.finished
    @test "slow" in r.still_running
    @test time() - t0 < 4                       # returned near the deadline

    # status waits for it, and then reports idle.
    st = call("status", Dict("session" => S, "block" => 60))
    @test st.idle
    @test isempty(st.running)
    @test call("output", Dict("session" => S, "cell_id" => "slow")).body == ":done"

    call("edit", Dict("session" => S, "cell_id" => "slow", "edit_mode" => "delete"))
end

@testset "a fast cell is not reported as still running" begin
    # The inverse of the above, and the bug that motivated timestamp-based
    # completion: a run must not report success before it has even started.
    r = call("edit", Dict("session" => S, "cell_id" => "a",
                          "new_source" => "a = 3", "block" => 60))
    @test r.finished
    @test call("output", Dict("session" => S, "cell_id" => "prod")).body == "21"
end

@testset "an error ends the wait" begin
    # Pluto runs a notebook's cells SEQUENTIALLY in one worker, so an error
    # cannot be reported before the cell producing it has had its turn. What is
    # guaranteed: once an error appears, the call returns with it rather than
    # serving out the remaining deadline.
    r = call("edit", Dict("session" => S, "cell_id" => "a",
                          "new_source" => "a = error(\"boom\")", "block" => 30))
    @test "a" in r.errored
    @test any(c -> c.errored, r.cells)

    # Dependents of a broken cell are reported as errored too, not as fine.
    @test "prod" in call("status", Dict("session" => S)).errored

    call("edit", Dict("session" => S, "cell_id" => "a",
                      "new_source" => "a = 6", "block" => 60))
    @test isempty(call("status", Dict("session" => S)).errored)
end

@testset "status reports a real diff" begin
    s1 = call("status", Dict("session" => S))
    @test s1.idle

    # An edit made THROUGH our own tools is pre-marked as seen (see
    # `_mark_seen!`), so it must not reappear as a "change" -- status exists to
    # report what a HUMAN did, not to echo the agent's own actions back to it.
    call("edit", Dict("session" => S, "cell_id" => "a",
                      "new_source" => "a = 5", "block" => 60))
    s2 = call("status", Dict("session" => S, "since" => s1.now))
    @test isempty(s2.changes)

    # A change made OUTSIDE our own tools -- exactly what a browser patch does
    # -- is not pre-marked, so the event hook reports it with old and new source.
    nb = P._notebook(S)
    cell = P.resolve_cell(nb, "a")
    cell.code = "a = 9"
    Pluto.update_save_run!(P._session(S).session, nb, Pluto.Cell[cell]; run_async=false)
    s3 = call("status", Dict("session" => S, "since" => s2.now))
    @test length(s3.changes) == 1
    ch = s3.changes[1]
    @test ch.name == "a"
    @test ch.kind == "edited"
    @test ch.old_source == "a = 5"
    @test ch.new_source == "a = 9"
end

@testset "reads reflect the live notebook" begin
    # Simulate a human editing in the browser: mutate the Notebook directly, the
    # way Pluto's frontend patches do, and confirm a read sees it with no
    # refresh step of any kind.
    nb = P._notebook(S)
    cell = P.resolve_cell(nb, "a")
    cell.code = "a = 12345"
    @test any(c -> c.code == "a = 12345", call("read", Dict("session" => S)))
end

@testset "png" begin
    call("edit", Dict("session" => S, "edit_mode" => "insert",
                      "new_source" => "using Plots", "block" => 300))
    call("edit", Dict("session" => S, "edit_mode" => "insert",
                      "new_source" => "fig = plot(1:10, (1:10).^2)", "block" => 120))

    img = TOOLS["png"].handler(Dict("session" => S, "cell_id" => "fig"))
    @test img isa P.ImageContent
    @test img.mime_type == "image/png"
    @test length(img.data) > 1000
    @test img.data[1:4] == UInt8[0x89, 0x50, 0x4e, 0x47]   # PNG magic

    # The temporary render cell must not be left behind.
    @test all(c -> !occursin("savefig", c.code), call("read", Dict("session" => S)))

    # `output` on a plot returns either a viewable image, or — for SVG, which is
    # text and would otherwise be dumped in full — a summary pointing at `png`.
    out = call("output", Dict("session" => S, "cell_id" => "fig"))
    if out isa P.ImageContent
        @test startswith(out.mime_type, "image/")
        @test !isempty(out.data)
    else
        @test out.mime == "image/svg+xml"
        @test occursin("withheld", out.body)
        @test out.bytes > 0
        raw = call("output", Dict("session" => S, "cell_id" => "fig", "raw" => true))
        @test occursin("<svg", lowercase(raw.body))     # raw=true really returns it
    end
end

@testset "export: self-contained HTML" begin
    r = call("export", Dict("session" => S))
    @test endswith(r.path, ".html")
    @test r.bytes > 0
    html = read(r.path, String)
    @test occursin("<html", lowercase(html))
    @test occursin("data:text/julia", html)      # the .jl source is embedded
    rm(r.path; force=true)
end

@testset "open an existing notebook" begin
    path = tempname() * ".jl"
    write(path, P.notebook_source(["q = 21", "doubled = q * 2"]))
    r = call("open", Dict("session" => S, "path" => path))
    @test length(r.cells) == 2
    @test call("output", Dict("session" => S, "cell_id" => "doubled")).body == "42"
end

@testset "stop" begin
    @test call("stop", Dict("session" => S)).ok
    @test call("read", Dict("session" => S)).error       # session is gone
end
