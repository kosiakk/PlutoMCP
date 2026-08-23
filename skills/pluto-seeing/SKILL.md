---
name: pluto-seeing
description: How to actually look at data in a Pluto notebook without wasting context — tree sketches, statistics cells, histogram counts, and the picture itself when shape is the question. Use when inspecting arrays, tables or plots through the pluto MCP tools.
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

That is Pluto's own summary — the same one a human sees in the browser. A
nested field shown as `…` — `(trimmed = (est = 0.94, ci = …))` — is the record
being brief, not the value being unavailable. `output(cell="robust",
mime="text/plain")` gives you the value as Julia prints it, complete.

Which to reach for: the sketch answers *what shape is this*, `output` answers
*what is this exactly*, and a probe cell answers *what about this part* —
`x[4090:4110]`, `describe(df)`. Ask `output` for a 100k-element array and you
will get all 100k, spilled to a file; that is usually the wrong question.

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

## 3. The picture, when shape is the question

When the question is *what does this look like* — not a number but a shape —
ask for the figure. `output` on a cell whose value is a plot renders it and
returns the image:

```
output(cell="residual_fit", mime="image/png")
```

Pluto stores one rendered MIME per cell and prefers SVG, which is markup no
client can display; `output` asks the figure's own library for a PNG instead.
No cell, no round trip.

**A picture is cheaper than a text plot of the same data.** Vision input is
billed by pixel area, roughly `width × height / 750`, and file size is
irrelevant — a 20 KB PNG at 600×400 is ~320 tokens, 300×200 is ~80. The same
plot as a braille canvas is ~5 KB of text and on the order of 2000 tokens,
because braille codepoints tokenize badly and every blank `⠀` is a character.
Six times the cost to see less.

For a figure that is not a cell's own value — one built inside a `let`, or a
subplot — `PlutoMCP.AsPNG(fig)` in a `delete_on_success` cell renders anything
showable. It is injected into every notebook workspace, and it exists because
Pluto's MIME preference is not the agent's.

Other formats (WebP, PDF) are a cell calling the plotting library's own save
function, never a tool feature.

## 4. Text plots, rarely

A unicode canvas is worth it in one case: the notebook has **no** plotting
library and the question does not justify adding one. `using UnicodePlots`
makes Pluto install the package and write it into the notebook file's
environment — permanently, even after the probe cell is deleted. That is a real
edit to somebody's notebook in exchange for a picture you can barely read.

The exception is `histogram`, which prints counts beside the bars. That is data
with a shape attached rather than a rendering, and it reads well:

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

Note what it was *not* needed for: the mean, which would have averaged the two
populations into a number describing neither. And note that every word of that
reading came from the counts, not from the bars — which is why
`fit(Histogram, x, edges).weights` from StatsBase answers the same question
with no plotting package at all, and belongs in step 2.

## What not to do

- Do not print an array to inspect it. Sketch, then statistics, then a plot.
- Do not ask for a plot when a number would answer the question.
- Do not install a plotting package to look at a shape. The dependency outlives
  the probe cell, in somebody else's notebook file.
- Do not leave probe cells behind: `delete_on_success=true`, and clean up the
  ones that errored.
- Do not use `println` in a loop to trace a computation. `@info` with key-value
  pairs survives truncation entry by entry; a print blob loses its middle.
