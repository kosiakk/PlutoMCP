#=
Everything that turns a live `Pluto.Cell` into the record the agent reads.

Two rules govern this file.

**One truncation function.** Every path that puts text into an MCP payload goes
through `truncate_payload`. Not "most paths": a single 40 MB `println` blob is
enough to blow a context window, and the only way to be sure is to have one
door. Oversize text spills to a file and the payload names the path — the
client and the server share a machine (stdio transport), and Claude Code reads
and greps a local file better than any paging protocol could.

**Sketches, not dumps.** Pluto's own tree/table objects are structured data,
built for its frontend's expandable viewer. Rendering them with `string()`
produces a page of Dict syntax that says less than one honest line. `sketch`
renders one line instead, one level deep, and never recurses. Expanding is not
a protocol here: the agent writes `x[4090:4110]` in a throwaway cell.
=#

# --------------------------------------------------------------- truncation --

# 2 KB inline is roughly a screenful of text: enough for a result, a schema, an
# error and a short stack, and small enough that a notebook full of them still
# fits in one record.
const INLINE_LIMIT = 2048
const HEAD_BYTES = 1024
const TAIL_BYTES = 1024

"Per-notebook directory for text that was too big to inline. Swept on `stop`."
spill_dir(nb::Pluto.Notebook) = joinpath(tempdir(), "plutomcp", string(nb.notebook_id))

_slug(s) = replace(String(s), r"[^A-Za-z0-9_.-]" => "_")

"""Longest prefix of `s` that fits in `n` bytes without splitting a character."""
function _head_bytes(s::AbstractString, n::Integer)
    ncodeunits(s) <= n && return SubString(s, 1)
    i = thisind(s, n)                       # start of the character covering byte n
    i == 0 && return SubString(s, 1, 0)
    # That character may extend past byte n; if so it does not fit, so drop it.
    SubString(s, 1, nextind(s, i) - 1 > n ? prevind(s, i) : i)
end

"""Longest suffix of `s` that fits in `n` bytes without splitting a character."""
function _tail_bytes(s::AbstractString, n::Integer)
    N = ncodeunits(s)
    N <= n && return SubString(s, 1)
    i = thisind(s, N - n + 1)
    i < N - n + 1 && (i = nextind(s, i))    # that character started before the window
    SubString(s, i)
end

"""
    truncate_payload(text; nb=nothing, label="cell", kind="output") -> String

The single guard on every text path into an MCP payload.

At most `INLINE_LIMIT` bytes: returned unchanged. Larger: head, a marker line,
tail. Head AND tail, because a tail holds the error and the final result, and a
head-only truncation reliably throws away the part worth reading.

With a notebook in hand the full text is written to the notebook's spill
directory and the marker names the path, which is the whole paging story.
"""
function truncate_payload(raw::AbstractString; nb::Union{Nothing,Pluto.Notebook}=nothing,
                          label::AbstractString="cell", kind::AbstractString="output")
    # Pluto's own display truncation marks the gap with ANSI colour codes,
    # which are noise to a reader that is not a terminal. Stripped here rather
    # than at each call site, since this is the one door text comes through.
    text = replace(raw, r"\e\[[0-9;]*[A-Za-z]" => "")
    n = ncodeunits(text)
    n <= INLINE_LIMIT && return String(text)
    path = nothing
    if nb !== nothing
        try
            dir = spill_dir(nb)
            mkpath(dir)
            path = joinpath(dir, "$(_slug(label))-$(_slug(kind)).txt")
            write(path, text)
        catch
            # A spill is a convenience, never a reason to fail the call: a
            # read-only or full tmpdir should still get the head and the tail.
            path = nothing
        end
    end
    marker = path === nothing ?
        "… ($(Base.format_bytes(n)) total, middle omitted)" :
        "… ($(Base.format_bytes(n)) total, full output: $path)"
    string(_head_bytes(text, HEAD_BYTES), "\n", marker, "\n", _tail_bytes(text, TAIL_BYTES))
end

# ------------------------------------------------------------------ sketches --

# How many of Pluto's already-truncated elements to keep on the sketch line.
const SKETCH_HEAD = 6
const SKETCH_TAIL = 3

_is_more(e) = e isa AbstractString && e == "more"

"""Render `[a, b, …, y, z]` from already-formatted element strings.

`full` keeps every element Pluto sent instead of trimming to head and tail. The
record wants one line; `output` wants everything there is, and everything there
is means the elements Pluto chose to store, since the value itself lives in the
worker.
"""
function _joined(vals::Vector{String}, truncated::Bool; full::Bool=false)
    if !full && length(vals) > SKETCH_HEAD + SKETCH_TAIL
        # When Pluto ALREADY truncated, the elements it sent are a head plus the
        # container's real last one. Trimming a "tail" off that head puts
        # elements 7 and 8 next to element 20 and calls them the end of the
        # array — a display that is not merely short but wrong. Keep the head
        # and the genuine last element; the middle is honestly absent.
        vals = truncated ? [vals[1:SKETCH_HEAD]; "…"; vals[end]] :
                           [vals[1:SKETCH_HEAD]; "…"; vals[end-SKETCH_TAIL+1:end]]
    elseif truncated
        vals = [vals[1:end-1]; "…"; vals[end]]
    end
    join(vals, ", ")
end

"""
One formatted leaf `(body, mime)` from a tree object.

A leaf whose body is itself a Dict is a nested container; it gets its own
one-line sketch at depth+1, and anything deeper than that is `…`. This is the
"one level of fields, no recursion" rule, enforced by construction rather than
by hoping the data is shallow.

`full` is `output` asking for everything, and it lifts the depth rule as well
as the element trim — otherwise `(trimmed = (est = 0.94, ci = …))` is all
`output` can ever say about a nested result, which is exactly what the record
already said. `MAX_FULL_DEPTH` still stops it: Pluto's own tree is depth
limited, and an unbounded walk is a promise this cannot keep.
"""
const MAX_FULL_DEPTH = 4

function _leaf(x, depth::Int; full::Bool=false)
    _is_more(x) && return "…"
    if x isa Tuple && length(x) == 2
        body, _ = x
        if body isa AbstractDict
            deep = full ? depth >= MAX_FULL_DEPTH : depth >= 1
            return deep ? "…" : sketch(body, depth + 1; full)
        end
        return body isa AbstractString ? body : string(body)
    end
    string(x)
end

# The type name Pluto puts in :prefix, cleaned up. For a plain Vector it is the
# ELEMENT type ("Float64"), flagged by an empty :prefix_short; for anything else
# it is already the container's own description ("2×3 Matrix{Float64}: ").
function _container_type(b::AbstractDict)
    p = rstrip(String(get(b, :prefix, "")), [' ', ':'])
    get(b, :prefix_short, nothing) == "" ? "Vector{$p}" : p
end

"""
    sketch(body::AbstractDict, depth=0) -> String

One line for one of Pluto's tree/table objects.

At depth 0 it reads as a description: type, count, head … tail. Nested one
level in it collapses to Julia's own array-literal shape (`Float64[1.0, 2.0]`),
which stays readable inside a struct's field list. There is no depth 2.
"""
function sketch(b::AbstractDict, depth::Int=0; full::Bool=false)
    t = get(b, :type, nothing)
    t === :circular && return "#= circular reference =#"
    haskey(b, :rows) && return _sketch_table(b)

    els = collect(get(b, :elements, []))
    truncated = any(_is_more, els)
    shown = [e for e in els if !_is_more(e)]

    if t === :Array || t === :Set
        vals = String[_leaf(e isa Tuple ? last(e) : e, depth; full) for e in shown]
        depth >= 1 && return string(rstrip(String(get(b, :prefix, "")), [' ', ':']),
                                    "[", _joined(vals, truncated; full), "]")
        return string(_container_type(b), ", ", _count(length(shown), truncated),
                      ": [", _joined(vals, truncated; full), "]")
    elseif t === :Dict
        # elements are ((keybody, keymime), (valbody, valmime))
        vals = String[string(_leaf(first(e), depth; full), " => ", _leaf(last(e), depth; full))
                      for e in shown if e isa Tuple]
        depth >= 1 && return string("Dict(", _joined(vals, truncated; full), ")")
        return string(_container_type(b), ", ", _count(length(shown), truncated; unit="entries"),
                      ": {", _joined(vals, truncated; full), "}")
    elseif t === :Tuple
        return string("(", _joined(String[_leaf(last(e), depth; full) for e in shown if e isa Tuple],
                                   truncated; full), ")")
    elseif t === :NamedTuple
        return string("(", join(String[string(first(e), " = ", _leaf(last(e), depth; full))
                                       for e in shown if e isa Tuple], ", "), ")")
    elseif t === :struct
        return string(get(b, :prefix_short, get(b, :prefix, "struct")), "(",
                      join(String[string(first(e), " = ", _leaf(last(e), depth; full))
                                  for e in shown if e isa Tuple], ", "), ")")
    elseif t === :Pair
        kv = get(b, :key_value, nothing)
        kv isa Tuple && length(kv) == 2 &&
            return string(_leaf(first(kv), depth), " => ", _leaf(last(kv), depth))
    end
    # An unknown tree type is still better summarised than dumped.
    string("<", something(t, "object"), ">")
end

# Pluto's tree object carries the elements it chose to send, not the container's
# length -- the value itself lives in the worker process. So say "≥" when Pluto
# truncated rather than inventing a total. The exact number is one throwaway
# cell away (`length(x)`), and honest beats confident.
function _count(n::Int, truncated::Bool; unit="elements")
    truncated && return "≥$n $unit"
    "$n $(n == 1 ? (unit == "entries" ? "entry" : "element") : unit)"
end

"""Tables get a shape line: columns with types, and the true row count."""
function _sketch_table(b::AbstractDict)
    rows = collect(get(b, :rows, []))
    schema = get(b, :schema, nothing)
    cols = if schema isa AbstractDict
        names, types = get(schema, :names, String[]), get(schema, :types, String[])
        join([_is_more(n) ? "…" : string(n, "::", i <= length(types) ? types[i] : "?")
              for (i, n) in enumerate(names)], ", ")
    else
        "unknown schema"
    end
    # When Pluto truncated the rows it appends the LAST row, indexed by its real
    # position -- so unlike an array, a table's true row count is knowable.
    real = [r for r in rows if r isa Tuple && !_is_more(r)]
    n = isempty(real) ? 0 : maximum(first(r) for r in real)
    "table, $n rows × $(schema isa AbstractDict ? length(get(schema, :names, [])) : 0) columns: ($cols)"
end

# ---------------------------------------------------------------------- logs --

# Pluto captures `@info`/`@warn`/`@error`/`println` per cell as discrete
# entries. Keeping the LAST 20 mirrors what a person scrolling a cell wants:
# a loop's first iteration is rarely the interesting one.
const LOGS_KEPT = 20

_logtext(x) = x isa Tuple && length(x) == 2 ?
    (first(x) isa AbstractDict ? sketch(first(x)) : string(first(x))) : string(x)

# Pluto captures `print`/`println` as a log entry at a private level rather than
# a separate stream. "LogLevel(-555)" tells the agent nothing; "Stdout" does.
_loglevel(e) = (l = string(get(e, "level", "Info")); startswith(l, "LogLevel(") ? "Stdout" : l)

"""
    render_logs(nb, c, label) -> (entries, dropped)

Structured log entries for one cell, newest-relevant last, capped. The full log
spills next to the cell's output when entries are dropped, so `+312 earlier
entries` is a pointer rather than a loss.
"""
function render_logs(nb::Pluto.Notebook, c::Pluto.Cell, label::AbstractString)
    logs = c.logs
    isempty(logs) && return (NamedTuple[], nothing)
    # kind carries the entry's index: two oversize messages in one cell would
    # otherwise spill to the same path, and the second would silently overwrite
    # the file the first one's marker points at.
    one(e, i) = (level = _loglevel(e),
                 msg = truncate_payload(_logtext(get(e, "msg", ""));
                                        nb, label, kind="log$i"),
                 kwargs = Dict{String,String}(
                     string(first(kv)) => _logtext(last(kv))
                     for kv in get(e, "kwargs", ()) if kv isa Tuple && length(kv) == 2))
    first_kept = max(0, length(logs) - LOGS_KEPT)
    kept = [one(logs[i], i) for i in (first_kept + 1):length(logs)]
    n = length(logs) - length(kept)
    n == 0 && return (kept, nothing)
    path = try
        dir = spill_dir(nb); mkpath(dir)
        p = joinpath(dir, "$(_slug(label))-logs.txt")
        open(p, "w") do io
            for e in logs
                println(io, _loglevel(e), ": ", _logtext(get(e, "msg", "")),
                        (" " * join(["$(first(kv))=$(_logtext(last(kv)))"
                                     for kv in get(e, "kwargs", ()) if kv isa Tuple], " ")))
            end
        end
        p
    catch
        nothing
    end
    (kept, path === nothing ? "+$n earlier entries dropped" : "+$n earlier entries → $path")
end

# -------------------------------------------------------------- fingerprints --

"""
Strip the parts of a Pluto tree object that identify the OBJECT rather than
what was rendered.

`:objectid` is the address Pluto's frontend uses to ask for more rows. Re-running
`v = ones(5)` allocates a new array and therefore a new objectid, with byte-identical
output -- and a fingerprint that included it would call that a change on every
single run, which is exactly the case dedup exists to collapse.
"""
_identity(x) = x
_identity(b::Vector{UInt8}) = b                       # image bytes: hash as-is
_identity(d::AbstractDict) =
    Dict(k => _identity(v) for (k, v) in d if k !== :objectid && k != "objectid")
_identity(t::Tuple) = map(_identity, t)
_identity(v::AbstractVector) = map(_identity, v)

"""
    cell_fingerprint(c) -> UInt64

Identity of everything a record would say about this cell, taken BEFORE any
truncation: code, status, mime, output body, logs.

Before truncation on purpose. Two different 40 MB outputs share a head and a
tail, so fingerprinting the payload would report them as the same cell. The
fingerprint answers "would the agent read anything new", and the agent reads the
truncated form only because we shortened the real one.
"""
function cell_fingerprint(c::Pluto.Cell)
    h = hash(c.code, UInt64(0x9e3779b9))
    h = hash(cell_status(c), h)
    h = hash(string(c.output.mime), h)
    h = try
        hash(_identity(c.output.body), h)
    catch
        # A body Pluto built out of something unhashable is rare and not worth
        # failing a record over; fall back to its printed form.
        hash(string(c.output.body), h)
    end
    for e in c.logs
        h = hash(_loglevel(e), h)
        h = hash(_logtext(get(e, "msg", "")), h)
        for kv in get(e, "kwargs", ())
            kv isa Tuple && length(kv) == 2 &&
                (h = hash(string(first(kv)), hash(_logtext(last(kv)), h)))
        end
    end
    h
end

# --------------------------------------------------------------- cell output --

"""
    render_output(nb, c, label) -> NamedTuple

The rendered-output half of a cell record: `mime` always, plus `output` for
anything textual, and `error` for a cell that failed.

`mime` alone for the two kinds of output that are not worth words: binary,
whose picture the `output` tool returns as MCP image content, and `text/html`,
whose rendering is the agent's own markdown or markup handed back to it.

Errors are pulled apart rather than stringified: Pluto already hands back a
structured parse error or stack trace, and flattening it into a blob only makes
the agent re-parse what it was given.
"""
function render_output(nb::Pluto.Notebook, c::Pluto.Cell, label::AbstractString)
    mime = string(c.output.mime)
    body = c.output.body
    short(t) = truncate_payload(t; nb, label)

    if mime == "application/vnd.pluto.parseerror+object"
        return (mime = mime, error = short(_parse_error_text(body)))
    elseif mime == "application/vnd.pluto.stacktrace+object"
        return (mime = mime, error = short(_stacktrace_text(body)))
    elseif body isa AbstractDict
        return (mime = mime, output = short(sketch(body)))
    elseif mime == "text/html"
        # Rendered text never comes back. A markdown or `html"…"` cell's output
        # IS the code the agent wrote, re-encoded: the markup is Pluto's
        # presentation for the human's browser, and the extracted text is that
        # same prose with the formatting removed. Neither tells the author
        # anything, and both are paid for by the token.
        #
        # A cell that interpolates a value (md"the mean is $(m)") needs no
        # special case: the fingerprint covers the rendered body, so the cell
        # re-reports when `m` moves, and `output` is there to be asked.
        return (mime = mime,)
    elseif body isa Vector{UInt8}
        # The mime is the whole signal: the picture itself is one `output` call
        # away, as real MCP image content. A byte count is a number nobody can
        # look at.
        return (mime = mime,)
    elseif body === nothing
        return (mime = mime, output = "")
    end
    (mime = mime, output = short(body isa AbstractString ? body : string(body)))
end

_parse_error_text(body) = body isa AbstractDict ?
    join([string(get(d, :message, get(d, "message", "syntax error")),
                 " (line ", get(d, :line, get(d, "line", "?")), ")")
          for d in get(body, :diagnostics, get(body, "diagnostics", []))], "\n") :
    string(body)

function _stacktrace_text(body)
    body isa AbstractDict || return string(body)
    msg = get(body, :msg, get(body, "msg", ""))
    frames = get(body, :stacktrace, get(body, "stacktrace", []))
    lines = String[string(msg)]
    for f in frames
        f isa AbstractDict || continue
        fn = get(f, :call, get(f, "call", get(f, :func, get(f, "func", "?"))))
        file = get(f, :file, get(f, "file", ""))
        line = get(f, :line, get(f, "line", ""))
        push!(lines, "  $fn at $(basename(string(file))):$line")
    end
    join(lines, "\n")
end
