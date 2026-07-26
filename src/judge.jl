# Turning per-revision estimates into verdicts, and the `compare` entrypoint.
#
# Classification is stricter than a plain ratio-vs-tolerance test:
#
#   * A time regression needs the ratio to clear `1 + tolerance` AND the absolute
#     change to clear `time_floor` nanoseconds. The floor is on the change, not
#     the benchmark's size: with a 1 µs floor a 100 ns -> 1.5 µs change trips it,
#     a 100 ns -> 500 ns change does not.
#   * Getting faster while allocating more is a `:tradeoff`, not a regression.
#   * Memory has a relative + absolute-byte gate (`memory_tolerance` defaults to
#     5%, so a small bookkeeping change is not reported even though allocation
#     counts are deterministic); a zero-allocation baseline turning non-zero is
#     always a regression, regardless of tolerance.
#   * With `nruns > 1` the verdict must hold in every run; `confirmations` records
#     how many runs agreed.

using Statistics: median

"""
    compare(repo; baseline, target=WORKINGTREE, script="benchmark/benchmarks.jl",
            time_tolerance=0.05, memory_tolerance=0.05,
            time_floor="1us", memory_floor=0, nruns=1,
            env=Dict(), threads=1, retune=false, verbose=true, stream=verbose,
            run_url="", marker="tachometer") -> Report

Benchmark `repo` (a path to a git working copy of the package) at two revisions
and report the performance difference. `baseline`/`target` are git refs, or the
[`WORKINGTREE`](@ref) sentinel for the live working tree.

`verbose` (default `true`) makes each benchmark subprocess name the benchmarks as
it runs them, and `stream` (following `verbose`) forwards that output to `io` as
it is produced, so a long comparison can be watched instead of going silent until
it finishes. Set both to `false` for quiet runs.
"""
function compare(
        repo::AbstractString;
        baseline,
        target = WORKINGTREE,
        script::AbstractString = "benchmark/benchmarks.jl",
        time_tolerance::Real = 0.05,
        memory_tolerance::Real = 0.05,
        time_floor = "1us",
        memory_floor = 0,
        nruns::Integer = 1,
        env::AbstractDict = Dict{String, String}(),
        threads::Int = 1,
        retune::Bool = false,
        verbose::Bool = true,
        stream::Bool = verbose,
        io::IO = stdout,
        run_url::AbstractString = "",
        marker::AbstractString = "tachometer",
        noise_history = nothing,   # path to the default-branch time-series data dir (read-only)
        noise_factor::Real = 3.0,
        noise_min_samples::Integer = 5,
        noise_cap::Real = 0.5,
        release_baseline::Bool = false,
    )
    repo = abspath(repo)
    nruns = max(1, Int(nruns))
    tfloor = _as_ns(time_floor)
    mfloor = Float64(memory_floor)

    # No baseline (e.g. the action couldn't find a merge-base with the base
    # branch) is a yellow "not comparable" state, never a fabricated comparison.
    if baseline isa AbstractString && isempty(strip(baseline))
        meta = Meta(; package = _pkgname(repo), target_ref = target === WORKINGTREE ? "working tree" : string(target),
            marker, run_url, timestamp = _now())
        return Report(:not_comparable, Measurement[], meta,
            "No baseline revision was provided or could be determined (for example, no common ancestor with the base branch).")
    end

    # If asked, and the target bumps the version, swap the baseline for the last
    # release tag so accumulated regressions since that release are caught.
    note = ""
    if release_baseline
        baseline, note = _release_baseline(repo, baseline, target)
    end

    baseline_runs = Vector{RevisionRun}()
    target_runs = Vector{RevisionRun}()
    # Interleave baseline/target within each pass so both see similar machine
    # conditions (thermal, host load), alternating order pass to pass.
    for i in 1:nruns
        first_baseline = isodd(i)
        stream && nruns > 1 && println(io, "[tachometer] pass $(i)/$(nruns)")
        if first_baseline
            push!(baseline_runs, run_revision(repo, baseline, script; env, threads, retune, verbose, stream, io))
            push!(target_runs, run_revision(repo, target, script; env, threads, retune, verbose, stream, io))
        else
            push!(target_runs, run_revision(repo, target, script; env, threads, retune, verbose, stream, io))
            push!(baseline_runs, run_revision(repo, baseline, script; env, threads, retune, verbose, stream, io))
        end
    end

    meta = Meta(;
        package = _pkgname(repo),
        baseline_ref = string(baseline),
        baseline_sha = baseline_runs[1].sha,
        target_ref = target === WORKINGTREE ? "working tree" : string(target),
        target_sha = target_runs[1].sha * (target_runs[1].dirty ? "+dirty" : ""),
        julia_version = string(VERSION),
        estimator = "minimum",
        time_tolerance, memory_tolerance,
        time_floor_ns = tfloor, memory_floor_bytes = mfloor,
        nruns = Int(nruns),
        suite_changed = _suite_changed(baseline_runs, target_runs),
        run_url, marker,
        timestamp = _now(),
        note,
    )

    # Bail out to yellow states before attempting a comparison.
    failed = filter(r -> !r.ok, vcat(baseline_runs, target_runs))
    if !isempty(failed)
        return Report(:errored, Measurement[], meta,
            "One or more benchmark runs failed to complete.\n\n" * first(failed).log)
    end

    # The noise model is derived ONLY from the default-branch time series (if a
    # data dir was provided); this run never writes to it, so a PR cannot train it.
    # Restrict to this run's measurement regime so a Julia/OS/runner migration on
    # master cannot inflate the learned band.
    records = noise_history === nothing ? Any[] : load_all_records(noise_history)
    regime = (string(Sys.KERNEL), string(Sys.ARCH), string(VERSION), string(threads))
    model = build_noise_from_history(records; regime,
        min_samples = Int(noise_min_samples), factor = noise_factor, cap = noise_cap)

    measurements = _judge(baseline_runs, target_runs, model;
        time_tolerance, memory_tolerance, time_floor = tfloor, memory_floor = mfloor,
        nruns = Int(nruns))

    if isempty(measurements)
        return Report(:not_comparable, measurements, meta,
            "No benchmarks were found to compare.")
    end
    comparable = any(m -> m.verdict in (:regression, :improvement, :invariant, :tradeoff), measurements)
    if !comparable
        return Report(:not_comparable, measurements, meta,
            "The two revisions share no benchmarks in common.")
    end

    status = any(m -> m.verdict === :regression, measurements) ? :regressed : :ok
    return Report(status, measurements, meta, "")
end

# ---------------------------------------------------------------------------

function _judge(baseline_runs, target_runs, model::NoiseModel; time_tolerance, memory_tolerance,
        time_floor, memory_floor, nruns)
    allkeys = sort!(collect(union((Set(keys(r.estimates)) for r in vcat(baseline_runs, target_runs))...)))
    ms = Measurement[]
    for key in allkeys
        b = [get(r.estimates, key, nothing) for r in baseline_runs]
        t = [get(r.estimates, key, nothing) for r in target_runs]
        in_baseline = any(!isnothing, b)
        in_target = any(!isnothing, t)

        if in_target && !in_baseline
            push!(ms, Measurement(key, nothing, _repr_est(t), nothing, nothing, :added, :none, nruns, nruns, NaN, false))
            continue
        elseif in_baseline && !in_target
            push!(ms, Measurement(key, _repr_est(b), nothing, nothing, nothing, :removed, :none, nruns, nruns, NaN, false))
            continue
        end

        # Align baseline/target by pass index; only passes where BOTH ran count.
        pairs = Tuple{Estimate, Estimate}[(bi, ti) for (bi, ti) in zip(b, t)
            if bi !== nothing && ti !== nothing]
        if isempty(pairs)
            # Present in both revisions but never in the same pass, so there is
            # nothing to compare. Marked :uncompared so it does not count as a
            # comparison; it is listed in the uncompared section.
            push!(ms, Measurement(key, _repr_est(b), _repr_est(t), nothing, nothing,
                :uncompared, :none, 0, 0, time_tolerance, false))
            continue
        end
        be = _repr_est(first.(pairs))
        te = _repr_est(last.(pairs))
        # Displayed ratios are derived from the displayed representative values, so
        # the "before → after (±%)" the reader sees is always self-consistent.
        tr = be.time == 0 ? 1.0 : te.time / be.time
        mr = be.memory == 0 ? (te.memory == 0 ? 1.0 : NaN) : te.memory / be.memory

        # Adaptive, per-benchmark time tolerance from the learned noise band.
        eff_tol = effective_time_tolerance(model, key, time_tolerance)
        time_v, time_conf = _classify_time(pairs, eff_tol, time_floor, nruns)
        time_v_global, _ = _classify_time(pairs, time_tolerance, time_floor, nruns)
        # Suppressed = would fire at the global tolerance but sits inside the noise band.
        suppressed = time_v_global === :regression && time_v !== :regression
        mem_v, mem_conf = _classify_memory(pairs, memory_tolerance, memory_floor, nruns)

        verdict, reason = _combine(time_v, mem_v)
        conf = verdict === :regression ? (reason === :memory ? mem_conf : time_conf) :
            verdict === :tradeoff ? min(time_conf, mem_conf) :   # both halves must hold
            verdict === :improvement ? max(time_conf, mem_conf) : length(pairs)
        push!(ms, Measurement(key, be, te, tr, mr, verdict, reason, conf, nruns, eff_tol, suppressed))
    end
    return ms
end

# Median-of-runs representative estimate (or nothing if never present).
function _repr_est(xs)
    present = collect(skipnothing(xs))
    isempty(present) && return nothing
    return Estimate(
        median(getfield.(present, :time)),
        median(getfield.(present, :memory)),
        median(getfield.(present, :allocs)),
    )
end

skipnothing(xs) = (x for x in xs if x !== nothing)

# A change verdict must hold in *every one of the `nruns` requested passes*: in
# each pass the ratio must clear the tolerance AND the absolute change must clear
# the floor. Requiring `nruns` (not just the aligned pairs) means a benchmark that
# is missing from a pass — so fewer pairs than requested — can never be reported
# as a confirmed change; it stays invariant. A one-off blip in a single pass also
# cannot produce a confirmed regression.
function _classify_time(pairs, tol, floor_ns, nruns)
    reg = imp = 0
    for (bi, ti) in pairs
        r = bi.time == 0 ? 1.0 : ti.time / bi.time
        d = abs(ti.time - bi.time)
        if r > 1 + tol && d >= floor_ns
            reg += 1
        elseif r < 1 - tol && d >= floor_ns
            imp += 1
        end
    end
    reg == nruns && return :regression, reg
    imp == nruns && return :improvement, imp
    return :invariant, length(pairs)
end

function _classify_memory(pairs, tol, floor_bytes, nruns)
    # Every pass is classified (including zero-baseline passes); a change requires
    # unanimity across ALL `nruns` requested passes.
    reg = imp = 0
    for (bi, ti) in pairs
        b, t = bi.memory, ti.memory
        if b == 0 && t == 0
            # invariant pass
        elseif b == 0 && t > 0
            reg += 1   # zero-allocation baseline turned non-zero is always a regression (floor does not apply)
        else
            r = t / b
            d = abs(t - b)
            if r > 1 + tol && d >= floor_bytes && t > b
                reg += 1
            elseif r < 1 - tol && d >= floor_bytes && t < b
                imp += 1
            end
        end
    end
    reg == nruns && return :regression, reg
    imp == nruns && return :improvement, imp
    return :invariant, length(pairs)
end

# A regression anywhere wins; otherwise an improvement; otherwise invariant.
#
# The one exception is a benchmark that got *faster* while allocating more: that
# is a deliberate trade-off far more often than it is a defect, so it becomes
# `:tradeoff` — surfaced in the report for a human to weigh, but not a regression
# and not something to fail a build over. The reverse (slower, but leaner) stays a
# regression: time is the headline metric, and a byte saved must not buy the right
# to be slower unnoticed.
function _combine(time_v, mem_v)
    if time_v === :regression && mem_v === :regression
        return :regression, :both
    elseif time_v === :regression
        return :regression, :time
    elseif mem_v === :regression && time_v === :improvement
        return :tradeoff, :memory
    elseif mem_v === :regression
        return :regression, :memory
    elseif time_v === :improvement && mem_v === :improvement
        return :improvement, :both
    elseif time_v === :improvement
        return :improvement, :time
    elseif mem_v === :improvement
        return :improvement, :memory
    end
    return :invariant, :none
end

# ---------------------------------------------------------------------------

# Parse a time floor given as a number (ns) or a string like "1us", "500ns", "2ms".
function _as_ns(x::Real)
    return Float64(x)
end
function _as_ns(s::AbstractString)
    s = strip(s)
    m = match(r"^([0-9.]+)\s*(ns|us|µs|μs|ms|s)?$", s)
    m === nothing && error("cannot parse time floor: $(repr(s))")
    val = parse(Float64, m.captures[1])
    unit = m.captures[2]
    factor = unit === nothing ? 1.0 :
        unit == "ns" ? 1.0 :
        unit in ("us", "µs", "μs") ? 1e3 :
        unit == "ms" ? 1e6 : 1e9
    return val * factor
end

function _suite_changed(baseline_runs, target_runs)
    bh = baseline_runs[1].script_hash
    th = target_runs[1].script_hash
    return !isempty(bh) && !isempty(th) && bh != th
end

function _pkgname(repo)
    p = joinpath(repo, "Project.toml")
    if isfile(p)
        for line in eachline(p)
            m = match(r"^name\s*=\s*\"(.*)\"", line)
            m === nothing || return m.captures[1]
        end
    end
    return basename(rstrip(repo, '/'))
end

_now() = Dates.format(Dates.now(Dates.UTC), "yyyy-mm-dd HH:MM 'UTC'")
