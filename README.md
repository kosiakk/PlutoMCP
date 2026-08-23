# PlutoMCP

**Let Claude do the analysis in a notebook that cannot lie about how it got there.**

You ask a question about your data.
Claude writes the code, runs it, looks at the plot, notices the thing you would have noticed, and writes the paragraph explaining it — while you watch, in your browser, cell by cell.
What you are left with is one file that re-runs from nothing and produces the same figures on a machine that has never seen your project.

Not a transcript of a conversation.
Not a notebook that worked in the order somebody happened to click.
A program.

## The problem with notebooks

Everyone who has inherited a notebook knows the feeling.
The plot is beautiful, the code is right there, and it does not run.

Cell 12 uses a variable defined in cell 40, which was deleted an hour ago but still lives in the kernel.
The output of cell 7 was produced by code that no longer exists.
`pandas` is a different version now.
Restart and Run All is an act of faith, and the faith is usually misplaced.

This is not a discipline problem.
It is what happens when a document has hidden state — and it gets worse when the author is an AI, because an agent editing such a notebook is guessing about a kernel it cannot see, and its guesses look exactly like results.

## What Pluto does about it

[Pluto.jl](https://plutojl.org) is a reactive notebook for Julia — think of a spreadsheet.
Change a cell and everything depending on it recalculates, immediately, by itself.
Nothing else can be true, because there is nothing else to be true: the notebook *is* its state.

That one idea removes a whole category of failure.

- **No execution order.** Cells run in dependency order, computed by Pluto, not by where they sit on the page.
- **No stale outputs.** A result you can see was produced by the code you can see.
- **No hidden variables.** Delete the cell and the variable goes with it.
- **The environment travels with the file.** Write `using DataFrames` and Pluto installs it, then records the exact resolved versions *inside the notebook*. One `.jl` file is the code, the outputs and a pinned environment that still resolves next year.
- **It is a Julia file.** It parses, it diffs, it merges, it runs as a script.

Provenance is not something this notebook ships alongside the result.
It *is* the result, and there is nothing else to keep.

## Why this matters more for an AI than for you

You can look at the screen.
Claude cannot — everything it learns about your data arrives as text it paid for, so a notebook that hides state costs it accuracy and a notebook that dumps state costs it context.

Pluto turns out to be the format an agent should have been using all along.

- **The dependency graph is queryable.** "What breaks if I change this?" has an exact answer rather than a grep.
- **Cells have names.** `abl = read_curve(...)` is the cell named `abl` — a name that survives edits and insertions, unlike a position or an opaque id.
- **One edit is the whole operation.** Change a cell and everything downstream re-runs. There is no "now re-run these seven others" for an agent to get wrong.
- **The file is the memory.** Context runs out; the notebook does not.

## What it feels like

```
you     ▸  the latencies in requests.csv look bimodal to me — is that real?

Claude  ▸  edit: readings = CSV.read("requests.csv", DataFrame)
           edit: fit(Histogram, readings.ms, 0:25:500).weights
           → [1154, 903, 214, 31, 10, 11, 99, 118, …]

           There is a trough at 100–150 ms and a second bump after it.
           Not a tail — a tail decays. Let me size it.

           edit: slow_share = count(>(125), readings.ms) / nrow(readings)
           → 0.118

           edit: md"## 11.8% of requests take a different path …"
           edit: histogram(readings.ms, bins=60, ...)
           output(mime="image/png")  ▸  [Claude looks at the plot it just made]
```

Meanwhile, in your browser, the notebook fills in.
You disagree with a bin width and change it yourself; Claude sees your edit on its next call — including the code you replaced — and can pick up the argument.

Two people editing one document, one of whom types quickly.

## Why Julia

Because it is quick to write and quick to run, so you stop choosing between the two.
Loops are fast, which means the honest implementation is also the fast one.
The plotting is excellent, the statistics libraries are first-rate, and the package manager pins environments that genuinely reproduce.

And because Claude writes good Julia.
The niche-language objection was a hiring problem, and you are not hiring — you are asking.

## Try it

Julia 1.10 or newer, and two commands:

```sh
claude plugin marketplace add kosiakk/PlutoMCP
```

```sh
claude plugin install pluto@plutomcp
```

Restart Claude Code, then ask for something:

> Simulate a month of sensor readings with a slow calibration drift partway through, then find the drift as if you did not know it was there. Leave it as a Pluto notebook I can read.

Claude hands you a URL.
Open it and watch.

When it finishes you have a `.jl` file that re-runs from scratch, an HTML export with every figure embedded, and a notebook whose argument you can follow top to bottom — because it was written to be read, not scrolled past.

## Where this sits

Anthropic's [Claude Science](https://claude.com/product/claude-science) gives every artifact its history: the exact code, the environment and the conversation that produced it, kept beside the result.

PlutoMCP takes the other road.
The artifact needs no history, because the artifact re-runs.
One file, no kernel to trust, no conversation to keep, nothing to reconcile — and a human watching it happen rather than reviewing it afterwards.

Small tool, narrow claim, and it holds: **if a figure is in the notebook, the code in the notebook made it.**

## More

- [RUNNING.md](RUNNING.md) — the manual: every tool, the record, the guarantees.
- [SPEC.md](SPEC.md) — the design record, including the long list of things deliberately left out.
- MIT licensed. A Julia package and a client-agnostic MCP server, with a Claude Code plugin on top.
