#=
Watching over the WebSocket, the way a person actually does.

Every other testset in runtests.jl proves the SERVER'S state is right by
reading `P._notebook()` directly -- the live `Pluto.Notebook` object this
package mutates. That is not what a human sees. RUNNING.md's whole claim is
that a browser learns about a change through Pluto's own push channel
(`Pluto.update_save_run!` calling `send_notebook_changes!`, embedded.jl's
comment at the top of the file), and nothing here has ever opened a real
WebSocket to check that the channel actually delivers -- so a regression in
it would pass every existing test while a person watching the notebook saw
nothing update, or had to reload the page to catch up.

This file is the missing piece: a client that speaks just enough of Pluto's
own browser protocol (`src/webserver/WebServer.jl` and `Dynamic.jl` in the
Pluto package) to behave like a connected tab, and a local mirror built
ONLY from what the server pushed over the socket -- never by asking the
tools. If that mirror disagrees with the live notebook, that disagreement
IS "not visible in the web UI", reproduced without a browser.

Reaches into Pluto's own webserver internals on purpose (`Pluto.HTTP`,
`Pluto.pack`/`unpack`, `Pluto.Firebasey`): there is no public API for
"connect a WebSocket and watch", because the browser is the only client
this protocol was ever meant to have. `Pluto.Firebasey.applypatch!` is the
same patcher the server itself carries -- reusing it, rather than
hand-rolling a second JSON-patch applier, is what makes the mirror
trustworthy: any patch a real browser's immer.js can apply, this can too.

Assumes runtests.jl's `P`, `TOOLS` and `call` are already defined --
this file is `include`d from there, not run standalone.
=#

# ---------------------------------------------------------------------------
# The client: enough of PlutoConnection.js to pass for a browser tab.
# ---------------------------------------------------------------------------

"""
    BrowserTab

A stand-in for one open browser tab. `state` is the notebook as this tab
would currently be rendering it -- Pluto's own `notebook_to_js` shape,
rebuilt by applying every patch the server has pushed, in order, with
Pluto's own `Firebasey.applypatch!`. Nothing here ever peeks at the real
`Notebook`; `state` is exactly what arrived on the wire, and nothing else.
"""
mutable struct BrowserTab
    ws::Any
    client_id::String
    state::Any
    lock::ReentrantLock
end

_short_id() = String(rand('a':'z', 12))

function _send!(tab::BrowserTab, type::AbstractString, body::AbstractDict;
                notebook_id=nothing, request_id::AbstractString=_short_id())
    d = Dict{String,Any}("type" => type, "client_id" => tab.client_id,
                         "request_id" => request_id, "body" => body)
    notebook_id === nothing || (d["notebook_id"] = string(notebook_id))
    Pluto.HTTP.send(tab.ws, Pluto.pack(d))
    nothing
end

"""
Fold one decoded server message into `tab.state`, if it is a `notebook_diff`.
Every other message type (`👋`, `pong`, ...) is not notebook state and is
ignored here -- this mirror only ever models what a browser tab RENDERS.
"""
function _apply!(tab::BrowserTab, msg)
    get(msg, "type", nothing) == "notebook_diff" || return nothing
    for pd in get(msg["message"], "patches", [])
        patch = Base.convert(Pluto.Firebasey.JSONPatch, pd)
        if isempty(patch.path)
            # A patch at the ROOT: Firebasey's own `applypatch!` refuses this
            # (`length(patch.path) == 0` throws "Impossible" for every patch
            # kind), because there is no in-place way to replace a variable
            # binding from inside a function. It is also the ONE patch a
            # freshly-connected tab ever receives: the full-state reply to
            # the empty `update_notebook` every real tab sends right after
            # connecting (see `open_browser_tab` below), computed as a plain
            # `Firebasey.diff` against nothing on the server's side.
            tab.state = patch.value
        else
            tab.state === nothing && (tab.state = Dict{Any,Any}())
            Pluto.Firebasey.applypatch!(tab.state, patch)
        end
    end
    nothing
end

"""
    open_browser_tab(s, nb) -> BrowserTab

Connect to the running server exactly as a real browser tab does: a
`secret`-guarded WebSocket, then `PlutoConnection.js`'s own handshake --
`connect` with no notebook (the session-level 👋), `connect` naming this
notebook (sets `client.connected_notebook` server-side, which is what makes
`send_notebook_changes!` start including this client at all), and finally
the same EMPTY `update_notebook` `Editor.js` sends right after connecting
(`send("update_notebook", {updates: []}, ...)`) purely to make the server
hand back a full snapshot as this tab's first `notebook_diff` -- the
bootstrap a real page load always gets, and the one this suite needs too.
"""
function open_browser_tab(s, nb::Pluto.Notebook)
    url = "ws://$(s.host)/?secret=$(s.secret)"
    ready = Channel{Any}(1)
    client_id = _short_id()
    @async begin
        try
            Pluto.HTTP.WebSockets.open(url) do ws
                tab = BrowserTab(ws, client_id, nothing, ReentrantLock())
                put!(ready, tab)
                for raw in ws
                    msg = Pluto.unpack(raw)
                    lock(tab.lock) do
                        _apply!(tab, msg)
                    end
                end
            end
        catch e
            isready(ready) || put!(ready, e)
        end
    end
    tab = take!(ready)
    tab isa Exception && throw(tab)
    _send!(tab, "connect", Dict{String,Any}())
    _send!(tab, "connect", Dict{String,Any}(); notebook_id=nb.notebook_id)
    _send!(tab, "update_notebook", Dict{String,Any}("updates" => Any[]); notebook_id=nb.notebook_id)
    tab
end

"Close a tab's WebSocket -- the one thing a `finally` in every testset below does."
close_browser_tab(tab::BrowserTab) =
    (Pluto.HTTP.WebSockets.isclosed(tab.ws) || close(tab.ws); nothing)

"""
    tab_sees(cond, tab; wait_seconds=10.0) -> Bool

Poll `cond(tab.state)` until it is true or `wait_seconds` elapses.

This is the entire point of the module, stated as one function: what a
person does with a tab that has not caught up is refresh the page, and
there is deliberately no such step anywhere in this file -- only time. If
`cond` never becomes true within `wait_seconds`, that IS "had to refresh",
reproduced without a browser to click reload in.
"""
function tab_sees(cond, tab::BrowserTab; wait_seconds::Real=10.0)
    t0 = time()
    while time() - t0 < wait_seconds
        lock(() -> cond(tab.state), tab.lock) && return true
        sleep(0.05)
    end
    false
end

# Readers over the mirrored state, in the vocabulary notebook_to_js itself
# uses (see Dynamic.jl) -- cell_id keys throughout, because that is the only
# handle a diff's patches ever carry. `state` is `nothing` until the very
# first patch lands (the bootstrap reply can trail the connect by a beat),
# and every reader here treats that the same as "nothing to show yet" rather
# than throwing -- the tab is allowed to still be catching up; `tab_sees` is
# what decides how long that is allowed to take.
_cell_inputs(state) = state === nothing ? Dict() : something(get(state, "cell_inputs", nothing), Dict())
_cell_results(state) = state === nothing ? Dict() : something(get(state, "cell_results", nothing), Dict())

"The CODE a tab is currently showing for a cell -- `nothing` if the tab has no such cell at all."
tab_code(state, cell_id::AbstractString) =
    get(get(_cell_inputs(state), cell_id, Dict()), "code", nothing)

"The rendered output body a tab would draw for a cell -- Pluto's own tree/value shape, not this package's summary."
tab_output(state, cell_id::AbstractString) =
    get(get(get(_cell_results(state), cell_id, Dict()), "output", Dict()), "body", nothing)

"The value a tab has for one `@bind`-ed name."
tab_bond_value(state, name::AbstractString) =
    state === nothing ? nothing : get(get(get(state, "bonds", Dict()), name, Dict()), "value", nothing)

# ---------------------------------------------------------------------------
# _run_lock itself: a direct, deterministic proof of the fix's primitive.
#
# No server, no worker, no timing-dependent race to hope for -- Channel-based
# Tokens block exactly, so a second `withtoken` call on the SAME notebook's
# lock cannot complete before the first releases, provably rather than
# probably. The end-to-end proof that this actually keeps a browser's mirror
# correct under concurrent edits lives in the WebSocket testset below; this
# one is just fast and never flaky.
# ---------------------------------------------------------------------------

@testset "_run_lock serializes concurrent calls into the same notebook" begin
    nb = P.notebook_source(String[])
    order = Int[]
    ready = Channel{Bool}(1)
    release = Channel{Bool}(1)

    t1 = @async Pluto.withtoken(P._run_lock(nb)) do
        push!(order, 1)
        put!(ready, true)     # t1 is holding the lock from here on
        take!(release)        # ...until the test lets it go
        push!(order, 2)
    end
    take!(ready)

    t2 = @async Pluto.withtoken(P._run_lock(nb)) do
        push!(order, 3)
    end
    sleep(0.05)                # let t2 reach the same token and block on it
    @test !istaskdone(t1)      # still holding, on purpose
    @test !istaskdone(t2)      # blocked behind t1 -- not merely slow, blocked
    @test order == [1]

    put!(release, true)
    Base.wait(t1)
    Base.wait(t2)
    @test order == [1, 2, 3]   # t2's body never ran until t1 fully released

    # A different notebook's lock is a different Token: no cross-notebook blocking.
    nb2 = P.notebook_source(String[])
    @test P._run_lock(nb2) !== P._run_lock(nb)
end

# ---------------------------------------------------------------------------
# The end-to-end tests: one notebook, one worker, one primary tab, shared
# across every scenario below (a second tab is opened only where the point
# IS reconnecting) -- opening a notebook is the expensive part of this
# suite, not watching one.
# ---------------------------------------------------------------------------

@testset "a connected browser tab: edits, reconnects, bonds and deletions" begin
    call("open", Dict("create" => true, "wait_seconds" => 90))
    nb = P._notebook()
    tab = open_browser_tab(P.session(), nb)
    try
        @testset "ordinary edits need no refresh" begin
            # The ordinary loop: edit, then the next edit, exactly as documented.
            call("edit", Dict("code" => "watched_a = 6"))
            call("edit", Dict("code" => "watched_b = 7"))
            call("edit", Dict("code" => "watched_total = watched_a * watched_b"))

            # Every cell the agent wrote is visible by NAME -- its actual
            # source, not a placeholder -- and its computed result, with no
            # reconnect.
            for name in ("watched_a", "watched_b", "watched_total")
                id = string(P.resolve_cell(nb, name).cell_id)
                @test tab_sees(st -> tab_code(st, id) == P.resolve_cell(nb, name).code, tab)
            end
            # `output.body` is Pluto's own RENDERING of the value -- text/plain's
            # display form, a string -- never the Julia value itself; see
            # SPEC.md's "the record is Pluto's rendering". "42", not 42.
            total_id = string(P.resolve_cell(nb, "watched_total").cell_id)
            @test tab_sees(st -> tab_output(st, total_id) == "42", tab)

            # A human's browser edit (simulated the way the rest of this suite
            # does, directly on the live Notebook) reaches the SAME tab too --
            # the point of embedded.jl's "no websocket, no protocol" design is
            # that both directions ride the one live object.
            cell = P.resolve_cell(nb, "watched_a")
            cell.code = "watched_a = 100"
            Pluto.update_save_run!(P.session().session, nb, Pluto.Cell[cell]; run_async=false)
            @test tab_sees(st -> tab_output(st, total_id) == "700", tab)
        end

        @testset "a tab that connects after the fact still needs no refresh" begin
            # Nobody was watching while this cell was written -- a SECOND tab
            # connects only now, the way opening a notebook someone already
            # authored does. Cheap: it is a new WebSocket against the notebook
            # already open above, not a new worker.
            call("edit", Dict("code" => "already_here = 99"))
            late_tab = open_browser_tab(P.session(), nb)
            try
                id = string(P.resolve_cell(nb, "already_here").cell_id)
                @test tab_sees(st -> tab_output(st, id) == "99", late_tab)
            finally
                close_browser_tab(late_tab)
            end
        end

        @testset "a bond update reaches the tab the same way" begin
            call("edit", Dict("code" => "slider = @bind slider html\"<input type=range>\""))
            call("edit", Dict("code" => "doubled = slider * 2"))
            doubled_id = string(P.resolve_cell(nb, "doubled").cell_id)
            @test tab_sees(st -> tab_output(st, doubled_id) !== nothing, tab)

            call("bond", Dict("name" => "slider", "value" => 21))
            @test tab_sees(st -> tab_output(st, doubled_id) == "42", tab)
            @test tab_sees(st -> tab_bond_value(st, "slider") == 21, tab)

            call("bond", Dict("name" => "slider", "value" => 5))
            @test tab_sees(st -> tab_output(st, doubled_id) == "10", tab)
        end

        @testset "a deletion reaches the tab too" begin
            call("edit", Dict("code" => "doomed = 1"))
            doomed_id = string(P.resolve_cell(nb, "doomed").cell_id)
            @test tab_sees(st -> tab_code(st, doomed_id) == "doomed = 1", tab)

            call("edit", Dict("cell" => "doomed", "code" => ""))
            # Deleted server-side means gone from the tab's cell_inputs too --
            # Firebasey's RemovePatch, applied the same way a browser's would be.
            @test tab_sees(st -> !haskey(_cell_inputs(st), doomed_id), tab)
        end
    finally
        close_browser_tab(tab)
        call("stop", Dict("notebook" => basename(nb.path)))
    end
end
