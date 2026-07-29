# Per-benchmark noise model, derived from the DEFAULT-BRANCH time series.
#
# The model estimates how much each benchmark naturally moves run-to-run on the
# main branch, and widens that benchmark's time tolerance to `factor × jitter`,
# capped so the band can never grow large enough to hide a substantial
# regression. A PR change that lands inside the learned band is downgraded to
# invariant but still listed (see the "suppressed as noise" section in report.jl).
#
# Crucially, the model is built ONLY from recorded master history — pull requests
# consume it read-only and never write to it, so a noisy or adversarial PR cannot
# train the tool to accept regressions. The jitter estimate is the median of the
# absolute consecutive relative differences of a benchmark's master time series,
# which is robust to the occasional genuine step (an optimisation or a real
# regression merged to master) while still capturing run-to-run noise.

using Statistics: median

struct NoiseModel
    spread::Dict{String, Float64}   # learned robust jitter (relative) per benchmark key
    count::Dict{String, Int}        # samples backing each estimate
    min_samples::Int
    factor::Float64
    cap::Float64                    # hard upper bound on the widened tolerance
end

NoiseModel(; min_samples::Int = 5, factor::Real = 3.0, cap::Real = 0.5) =
    NoiseModel(Dict{String, Float64}(), Dict{String, Int}(), min_samples, Float64(factor), Float64(cap))

"""
    effective_time_tolerance(model, key, global_tol) -> Float64

The time tolerance to apply to `key`: the global tolerance, widened toward the
learned noise band (`factor × jitter`) once enough samples exist, but never
beyond `model.cap`. The cap guarantees a large enough real regression always
fires regardless of history.
"""
function effective_time_tolerance(model::NoiseModel, key::AbstractString, global_tol::Real)
    haskey(model.spread, key) || return Float64(global_tol)
    model.count[key] >= model.min_samples || return Float64(global_tol)
    widened = max(Float64(global_tol), model.factor * model.spread[key])
    return min(widened, max(Float64(global_tol), model.cap))
end

# The measurement regime that meaningfully shifts absolute timings: OS, arch,
# Julia version, thread count, and measurement backend (perf syscalls in the
# timed window vs plain clocks shift small benchmarks). CPU is deliberately
# excluded — it varies within a hosted-runner class and that variation is
# exactly the jitter we want to learn. Old records without a backend field get
# "", so histories recorded before the field existed match only comparisons
# that also lack it.
_regime(fp) = fp isa AbstractDict ?
    (string(get(fp, "os", "")), string(get(fp, "arch", "")), string(get(fp, "julia", "")),
        string(get(fp, "threads", "")), string(get(fp, "backend", ""))) :
    ("", "", "", "", "")

"""
    build_noise_from_history(records; regime=nothing, min_samples=5, factor=3.0, cap=0.5) -> NoiseModel

Build the model from default-branch time-series `records` (as stored in the
timeseries shards, chronologically ordered): for each benchmark, the jitter is
the median of the absolute consecutive relative differences of its `time` series.
`records` is a vector of dicts each with a `"benchmarks"` map of
`key => Dict("time" => ns, …)`. If `regime` (an [`_regime`](@ref) tuple) is given,
only records from that same measurement regime are used, so a Julia/OS/runner
migration on master cannot inflate the learned band.
"""
function build_noise_from_history(records; regime = nothing, min_samples::Int = 5, factor::Real = 3.0, cap::Real = 0.5)
    series = Dict{String, Vector{Float64}}()
    for r in records
        regime === nothing || _regime(get(r, "fingerprint", nothing)) == regime || continue
        b = get(r, "benchmarks", nothing)
        b isa AbstractDict || continue
        for (k, v) in b
            t = v isa AbstractDict ? get(v, "time", nothing) : nothing
            (t isa Real && isfinite(t) && t > 0) || continue
            push!(get!(series, k, Float64[]), Float64(t))
        end
    end
    spread = Dict{String, Float64}()
    count = Dict{String, Int}()
    for (k, ts) in series
        count[k] = length(ts)
        length(ts) >= 2 || continue
        rel = Float64[]
        for i in 2:length(ts)
            ts[i - 1] > 0 && push!(rel, abs(ts[i] - ts[i - 1]) / ts[i - 1])
        end
        spread[k] = isempty(rel) ? 0.0 : median(rel)
    end
    return NoiseModel(spread, count, min_samples, Float64(factor), Float64(cap))
end
