# Core data model for a benchmark comparison.
#
# The pipeline is: run.jl produces `Estimate`s per revision -> judge.jl turns a
# baseline/target pair (possibly repeated over several runs) into `Measurement`s
# and a `Report` -> report.jl renders the `Report` to markdown.

"""
    Estimate

A single benchmark's summary statistic for one revision: wall-clock `time` in
nanoseconds, `memory` in bytes, and allocation count `allocs`. `nothing` fields
mean the benchmark was not present in that revision.
"""
struct Estimate
    time::Float64      # ns
    memory::Float64    # bytes
    allocs::Float64
end

# Verdict for a single benchmark. One of:
#   :regression :improvement :invariant :added :removed :uncompared
# and a `reason` describing what moved: :time, :memory, :both, :none.

"""
    Measurement

The comparison of one benchmark (identified by its `/`-joined `key`) between the
baseline and target revisions.

`time_ratio`/`mem_ratio` are `target / baseline` (a value `> 1` means the target
is slower / allocates more). `confirmations` is how many of the `nruns` repeated
runs independently agreed with the headline verdict — used to guard against
one-off noise on shared CI runners.
"""
struct Measurement
    key::String
    baseline::Union{Estimate, Nothing}
    target::Union{Estimate, Nothing}
    time_ratio::Union{Float64, Nothing}
    mem_ratio::Union{Float64, Nothing}
    verdict::Symbol
    reason::Symbol
    confirmations::Int
    nruns::Int
    eff_time_tol::Float64   # per-benchmark time tolerance actually applied (>= global when noisy)
    suppressed::Bool        # would regress at the global tolerance, but sits inside the learned noise band
end

"""
    Meta

How the comparison was produced, shown in the report footer so a reader can
reproduce the numbers.
"""
struct Meta
    package::String
    baseline_ref::String
    baseline_sha::String
    target_ref::String
    target_sha::String
    julia_version::String
    estimator::String
    time_tolerance::Float64
    memory_tolerance::Float64
    time_floor_ns::Float64
    memory_floor_bytes::Float64
    nruns::Int
    suite_changed::Bool
    run_url::String
    marker::String
    timestamp::String
    note::String
end

function Meta(;
        package::AbstractString = "",
        baseline_ref::AbstractString = "",
        baseline_sha::AbstractString = "",
        target_ref::AbstractString = "",
        target_sha::AbstractString = "",
        julia_version::AbstractString = string(VERSION),
        estimator::AbstractString = "minimum",
        time_tolerance::Real = 0.05,
        memory_tolerance::Real = 0.01,
        time_floor_ns::Real = 1000.0,
        memory_floor_bytes::Real = 0.0,
        nruns::Integer = 1,
        suite_changed::Bool = false,
        run_url::AbstractString = "",
        marker::AbstractString = "tachometer",
        timestamp::AbstractString = "",
        note::AbstractString = "",
    )
    return Meta(
        package, baseline_ref, baseline_sha, target_ref, target_sha,
        julia_version, estimator, Float64(time_tolerance), Float64(memory_tolerance),
        Float64(time_floor_ns), Float64(memory_floor_bytes), Int(nruns),
        suite_changed, run_url, marker, timestamp, note,
    )
end

"""
    Report

The full result of a comparison. `status` is the single most important field:

* `:ok`             — the comparison ran and found no regressions.
* `:regressed`      — at least one benchmark regressed beyond tolerance.
* `:not_comparable` — no baseline / no common ancestor / nothing to compare.
* `:errored`        — benchmarks failed to build or run.

`:not_comparable` and `:errored` are *yellow* states, never reported as success.
"""
struct Report
    status::Symbol
    measurements::Vector{Measurement}
    meta::Meta
    message::String
end

# --- convenience accessors used by the renderer and CLI --------------------

regressions(r::Report)  = filter(m -> m.verdict === :regression, r.measurements)
improvements(r::Report) = filter(m -> m.verdict === :improvement, r.measurements)
invariants(r::Report)   = filter(m -> m.verdict === :invariant, r.measurements)
added(r::Report)        = filter(m -> m.verdict === :added, r.measurements)
removed(r::Report)      = filter(m -> m.verdict === :removed, r.measurements)
suppressed(r::Report)   = filter(m -> m.suppressed, r.measurements)
compared(r::Report)     = filter(m -> m.verdict in (:regression, :improvement, :invariant), r.measurements)
