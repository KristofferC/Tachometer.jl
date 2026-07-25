"""
    Tachometer

Benchmark a Julia package at two git revisions and report the difference.

Given a git working copy of a package with a `benchmark/benchmarks.jl` that
defines `const SUITE = BenchmarkGroup()`, [`compare`](@ref) runs the suite for two
revisions (each in a temporary `git worktree` and a separate process), classifies
each benchmark, and returns a [`Report`](@ref). [`render`](@ref) turns that report
into a pull request comment.
"""
module Tachometer

using Dates: Dates
using JSON: JSON
using TOML: TOML

export compare, render, Report, Measurement

include("types.jl")
include("noise.jl")
include("run.jl")
include("judge.jl")
include("report.jl")
include("github.jl")
include("timeseries.jl")
include("cli.jl")

end # module
