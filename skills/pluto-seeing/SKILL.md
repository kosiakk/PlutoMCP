---
name: pluto-seeing
description: How to actually look at data in a Pluto notebook without wasting context — tree sketches, statistics cells, UnicodePlots for shape, and AsPNG only when raster truth matters. Use when inspecting arrays, tables or plots through the pluto MCP tools.
---

# Seeing data in a Pluto notebook

You cannot see the screen. Everything you learn about a value arrives as text
you paid for. So look in this order, cheapest first, and stop as soon as the
question is answered.

## 1. The sketch you already have

Every record renders a container as one line:

```
Vector{Float64}, ≥30 elements: [0.12, 3.4, -0.9, 2.2, 0.03, 1.7, …, 9.8, 0.4, 2.1]
(a = 1, b = "two", c = Int64[1, 2, 3])
table, 4820 rows × 6 columns: (id::Int64, region::String, t::DateTime, …)
```

That is free — it is already in the record you were returned. It answers
"what shape is this", "what type", "roughly what magnitude". A `≥` means
Pluto truncated: the true length is one cell away, not a guess to make.

There is no expand protocol. If you want elements 4090–4110, that is a cell:
`x[4090:4110]`.

## 2. Statistics, not values

**An exact answer costs less than the raw data it came from.** Never dump an
array to find its maximum.

```
edit(mode="insert", delete_on_success=true, wait_seconds=15,
     code="quantile(residuals, [0.0, 0.01, 0.5, 0.99, 1.0])")
```

Good probes: `extrema`, `quantile`, `mean`/`std`, `count(isnan, x)`,
`sum(ismissing, col)`, `describe(df)`, `combine(groupby(df, :region), nrow)`,
`countmap`. Each returns a handful of numbers that answer a specific question.

## 3. UnicodePlots, for shape

When the question is *what does the distribution look like* — not a number but
a shape — a text plot costs 1–2 KB and no image tokens at all.

```
edit(mode="insert", delete_on_success=true, wait_seconds=30,
     code="using UnicodePlots; histogram(residuals; nbins=12, canvas=BlockCanvas)")
```

Use `histogram`, or pass `canvas=BlockCanvas` to `lineplot`/`scatterplot`. The
default Braille canvas packs more dots per character, which is exactly wrong
here: braille renders as dense unreadable glyphs in a text payload, while block
characters stay legible.

### Worked example

This is a real `histogram(x; nbins=12, canvas=BlockCanvas)` result:

```
                ┌                                        ┐
   [-4.0, -3.0) ┤▎ 1
   [-3.0, -2.0) ┤██▋ 26
   [-2.0, -1.0) ┤████████████▊ 123
   [-1.0,  0.0) ┤███████████████████████████████████  336
   [ 0.0,  1.0) ┤███████████████████████████████▌ 303
   [ 1.0,  2.0) ┤██████████▌ 101
   [ 2.0,  3.0) ┤█▏ 10
   [ 3.0,  4.0) ┤█▎ 11
   [ 4.0,  5.0) ┤██████████▍ 99
   [ 5.0,  6.0) ┤█▏ 10
                └                                        ┘
                                 Frequency
```

The correct reading: **this is bimodal, and that is the finding.** The main
mass is a roughly symmetric bell centred just below 0 (336 + 303 in the two
bins either side of zero, tapering to 1 at −4). But there is a clean second
bump at [4.0, 5.0) holding 99 points — about 10% of the sample — separated from
the main body by a genuine trough at [2.0, 4.0) where counts fall to 10 and 11.

That is a *population*, not a tail: a tail decays monotonically, and this one
goes down, stays down for two bins, then rises again by a factor of nine. The
next probe follows from the picture — `count(>(3.5), x)` to size it exactly,
then find what distinguishes those rows.

Note what the picture was *not* needed for: the mean, which would have averaged
the two populations into a number describing neither. Shape questions get
plots; quantity questions get statistics.

## 4. AsPNG, last

Only when raster truth matters: fine detail, colour, or checking what the human
is actually looking at.

```
edit(mode="insert", delete_on_success=true, wait_seconds=60,
     code="PlutoMCP.AsPNG(fig)")
```

`AsPNG` is injected into every notebook workspace. It has to exist because
Pluto stores **one** rendered MIME per cell, chosen by its own preference —
SVG for Plots, HTML for some backends — and `output` never re-executes a cell.
So PNG bytes exist only if some cell rendered them, and `AsPNG(fig)` is the
cell that does. Calling `output` on a plotting cell whose stored format is SVG
gives you 100 KB of markup no client can display.

Other formats (WebP, PDF) are a cell calling the plotting library's own save
function, never a tool feature.

## What not to do

- Do not print an array to inspect it. Sketch, then statistics, then a plot.
- Do not ask for a plot when a number would answer the question.
- Do not leave probe cells behind: `delete_on_success=true`, and clean up the
  ones that errored.
- Do not use `println` in a loop to trace a computation. `@info` with key-value
  pairs survives truncation entry by entry; a print blob loses its middle.
