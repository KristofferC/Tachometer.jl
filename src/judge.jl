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
            backend=:auto,
            time_tolerance=0.05, memory_tolerance=0.05, instr_tolerance=0.01,
            time_floor="1us", memory_floor=0, instr_floor=1000, nruns=1,
            env=Dict(), threads=1, verbose=true, stream=verbose,
            run_url="", marker="tachometer") -> Report

Benchmark `repo` (a path to a git working copy of the package) at two revisions
and report the performance difference. `baseline`/`target` are git refs, or the
[`WORKINGTREE`](@ref) sentinel for the live working tree.

`backend` selects how the suite is measured: `:perf` (hardware instruction
counters), `:callgrind` (valgrind simulation — deterministic, works on
PMU-less CI runners, ~50× slower), `:time` (wall clock only), or `:auto`
(perf if available, else callgrind if valgrind is installed, else time). It is
resolved once, before either revision runs; an explicitly requested backend
that cannot run is an error, never a silent downgrade.

When the backend counts instructions, the instruction count becomes an
additional judged metric with its own (much tighter) `instr_tolerance` and
absolute `instr_floor` delta. Wall time stays judged alongside on `:perf`
(counts can miss cache/frequency effects); under `:callgrind` time is
simulated garbage and is not judged or shown. Instruction judging is skipped
when `threads > 1` (perf counts only the calling thread).

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
        backend::Symbol = :auto,
        valgrind::AbstractString = "valgrind",
        time_tolerance::Real = 0.05,
        memory_tolerance::Real = 0.05,
        instr_tolerance::Real = 0.01,
        time_guard_tolerance::Real = 0.25,
        time_floor = "1us",
        memory_floor = 0,
        instr_floor::Real = 1000,
        nruns::Integer = 1,
        env::AbstractDict = Dict{String, String}(),
        threads::Int = 1,
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
    ifloor = Float64(instr_floor)
    # Resolved once, before either revision, so baseline and target are always
    # measured the same way.
    backend = resolve_backend(backend; valgrind)
    verbose && println(io, "[tachometer] measurement backend: ", backend)

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
            push!(baseline_runs, run_revision(repo, baseline, script; backend, valgrind, env, threads, verbose, stream, io))
            push!(target_runs, run_revision(repo, target, script; backend, valgrind, env, threads, verbose, stream, io))
        else
            push!(target_runs, run_revision(repo, target, script; backend, valgrind, env, threads, verbose, stream, io))
            push!(baseline_runs, run_revision(repo, baseline, script; backend, valgrind, env, threads, verbose, stream, io))
        end
    end

    meta = Meta(;
        package = _pkgname(repo),
        baseline_ref = string(baseline),
        baseline_sha = baseline_runs[1].sha,
        target_ref = target === WORKINGTREE ? "working tree" : string(target),
        target_sha = target_runs[1].sha * (target_runs[1].dirty ? "+dirty" : ""),
        julia_version = string(VERSION),
        backend = string(backend),
        estimator = "minimum",
        time_tolerance, memory_tolerance, instr_tolerance, time_guard_tolerance,
        time_floor_ns = tfloor, memory_floor_bytes = mfloor, instr_floor = ifloor,
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
    regime = (string(Sys.KERNEL), string(Sys.ARCH), string(VERSION), string(threads), string(backend))
    model = build_noise_from_history(records; regime,
        min_samples = Int(noise_min_samples), factor = noise_factor, cap = noise_cap)

    # Instruction judging needs both sides measured by the same counting
    # backend and a single benchmark thread (perf counts the calling thread).
    judge_instr = backend in (:perf, :callgrind) && threads == 1 &&
        all(r -> r.backend == string(backend), vcat(baseline_runs, target_runs))
    # When instructions carry the verdict, time is demoted to a *guard* with a
    # deliberately loose tolerance: it exists to catch slowdowns invisible to
    # instruction counts (cache locality, frequency effects) — which are large —
    # not to re-import wall-clock noise into an otherwise deterministic gate.
    ttol = judge_instr ? max(Float64(time_tolerance), Float64(time_guard_tolerance)) :
        Float64(time_tolerance)
    measurements = _judge(baseline_runs, target_runs, model;
        time_tolerance = ttol, memory_tolerance, instr_tolerance,
        time_floor = tfloor, memory_floor = mfloor, instr_floor = ifloor,
        nruns = Int(nruns), judge_instr, judge_time = time_judged(meta))

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
        instr_tolerance = 0.01, time_floor, memory_floor, instr_floor = 1000.0, nruns,
        judge_instr::Bool = false, judge_time::Bool = true)
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
        ir = (hasinstr(be) && hasinstr(te)) ?
            (be.instructions == 0 ? 1.0 : te.instructions / be.instructions) : nothing

        # Instructions: near-deterministic, so a flat tolerance with an absolute
        # delta floor; only when both sides were counted by the same backend.
        instr_v, instr_conf = judge_instr && ir !== nothing ?
            _classify_instr(pairs, instr_tolerance, instr_floor, nruns) : (:invariant, length(pairs))

        # Time: adaptive per-benchmark tolerance from the learned noise band.
        # Not judged at all under callgrind (simulated time is meaningless).
        eff_tol = effective_time_tolerance(model, key, time_tolerance)
        if judge_time
            time_v, time_conf = _classify_time(pairs, eff_tol, time_floor, nruns)
            time_v_global, _ = _classify_time(pairs, time_tolerance, time_floor, nruns)
            # Suppressed = would fire at the global tolerance but sits inside the noise band.
            suppressed = time_v_global === :regression && time_v !== :regression
        else
            time_v, time_conf = :invariant, length(pairs)
            suppressed = false
        end
        mem_v, mem_conf = _classify_memory(pairs, memory_tolerance, memory_floor, nruns)

        verdict, reason = _combine(instr_v, time_v, mem_v)
        conf = verdict === :regression ?
            (reason === :instructions ? instr_conf : reason === :memory ? mem_conf : time_conf) :
            verdict === :tradeoff ? min(max(instr_conf, time_conf), mem_conf) :  # both halves must hold
            verdict === :improvement ? max(instr_conf, time_conf, mem_conf) : length(pairs)
        push!(ms, Measurement(key, be, te, tr, mr, ir, verdict, reason, conf, nruns, eff_tol, suppressed))
    end
    return ms
end

# Median-of-runs representative estimate (or nothing if never present).
function _repr_est(xs)
    present = collect(skipnothing(xs))
    isempty(present) && return nothing
    instr = [e.instructions for e in present if hasinstr(e)]
    return Estimate(
        median(getfield.(present, :time)),
        median(getfield.(present, :memory)),
        median(getfield.(present, :allocs)),
        length(instr) == length(present) ? median(instr) : NaN,
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

# Instruction counts are near-deterministic, so classification is a plain
# ratio-vs-tolerance test with an absolute delta floor (to absorb the few
# hundred instructions of harness/GC-trigger jitter on tiny benchmarks). A pass
# where either side lacks counts cannot confirm a change, and unanimity across
# all `nruns` passes is required, as for time.
function _classify_instr(pairs, tol, floor_insns, nruns)
    reg = imp = 0
    for (bi, ti) in pairs
        (hasinstr(bi) && hasinstr(ti)) || continue
        r = bi.instructions == 0 ? 1.0 : ti.instructions / bi.instructions
        d = abs(ti.instructions - bi.instructions)
        if r > 1 + tol && d >= floor_insns
            reg += 1
        elseif r < 1 - tol && d >= floor_insns
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
# The reason names the metric that fired, or :multiple when more than one did.
#
# The one exception is a benchmark that did *less work / got faster* while
# allocating more: that is a deliberate trade-off far more often than it is a
# defect, so it becomes `:tradeoff` — surfaced in the report for a human to
# weigh, but not a regression and not something to fail a build over. The
# reverse (leaner, but slower or more instructions) stays a regression: work and
# time are the headline metrics, and a byte saved must not buy the right to be
# slower unnoticed.
function _combine(instr_v, time_v, mem_v)
    regs = Symbol[]
    instr_v === :regression && push!(regs, :instructions)
    time_v === :regression && push!(regs, :time)
    mem_v === :regression && push!(regs, :memory)
    imps = Symbol[]
    instr_v === :improvement && push!(imps, :instructions)
    time_v === :improvement && push!(imps, :time)
    mem_v === :improvement && push!(imps, :memory)

    if regs == [:memory] && (instr_v === :improvement || time_v === :improvement)
        return :tradeoff, :memory
    elseif !isempty(regs)
        return :regression, length(regs) == 1 ? only(regs) : :multiple
    elseif !isempty(imps)
        return :improvement, length(imps) == 1 ? only(imps) : :multiple
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
