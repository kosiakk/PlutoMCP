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

Which to reach for, and in this order: the sketch answers *what shape is
this*, `output` answers *what is this exactly* (a nested `…` and every element
of a long array included), and a probe cell answers *what about this part* —
`x[4090:4110]`, `describe(df)`. Ask `output` for a 100k-element array and you
get all 100k, spilled to a file; that is usually the wrong question.

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
ask for the figure: `output(cell="residual_fit", mime="image/png")`.

**A picture is cheaper than a text plot of the same data.** Vision input is
billed by pixel area, roughly `width × height / 750`, and file size is
irrelevant — a 20 KB PNG at 600×400 is ~320 tokens, 300×200 is ~80. The same
plot as a braille canvas is ~5 KB of text and on the order of 2000 tokens,
because braille codepoints tokenize badly and every blank `⠀` is a character.
Six times the cost to see less.

## 4. Counts, when the shape is a distribution

`fit(Histogram, x, edges).weights` from StatsBase gives you the bin counts with
no plotting package at all, and the counts are where the finding is:

```
edges  -4  -3  -2  -1   0    1    2   3   4   5   6
counts   1  26 123 336  303 101  10  11  99  10
```

Read it: **bimodal, and that is the finding.** A symmetric bell centred just
below zero (336 + 303 either side, tapering to 1 at −4), then a genuine trough
at [2, 4) where counts fall to 10 and 11, then a clean second bump of 99 —
about 10% of the sample. A tail decays monotonically; this goes down, stays
down for two bins, and rises again by a factor of nine. That is a population.

The next probe follows from it: `count(>(3.5), x)` to size it exactly, then
find what distinguishes those rows. Note what no plot was needed for — and what
the mean would have done here, averaging two populations into a number
describing neither.

`using UnicodePlots` draws the same thing with bars, but installing it writes a
dependency into the notebook file that outlives your probe cell. Counts read
better anyway.

## What not to do

- Do not print an array to inspect it. Sketch, then statistics, then a plot.
- Do not ask for a plot when a number would answer the question.
- Do not install a plotting package to look at a shape. The dependency outlives
  the probe cell, in somebody else's notebook file.
- Do not leave probe cells behind: `delete_on_success=true`, and clean up the
  ones that errored.
- Do not use `println` in a loop to trace a computation. `@info` with key-value
  pairs survives truncation entry by entry; a print blob loses its middle.
