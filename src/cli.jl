# The single entrypoint the GitHub Action calls: read configuration from the
# environment, run the comparison, and write the report + step outputs.
#
# Every knob has an env var so `action.yml` is a thin wrapper. This function does
# not fail the job on a regression; the action gates in a separate final step
# (after the artifact is uploaded), keeping gating independent of comment posting.

"""
    main(; io=stdout) -> Report

Read `TACHOMETER_*` environment variables, run [`compare`](@ref), write
`report.md`/`report.json` to `TACHOMETER_OUTPUT_DIR`, and set GitHub step
outputs (`status`, `regressed`, `report`, `summary`).
"""
function main(; io = stdout)
    mode = _env("TACHOMETER_MODE", "compare")
    mode == "record" && return _main_record(io)
    mode == "publish" && return _main_publish(io)
    mode == "render" && return _main_render(io)
    mode == "compare" || error("unknown TACHOMETER_MODE=$(mode) (expected compare/record/publish/render)")

    repo = _env("TACHOMETER_PACKAGE", pwd())
    baseline = _env("TACHOMETER_BASELINE", "origin/master")
    target_raw = _env("TACHOMETER_TARGET", "workingtree")
    target = target_raw in ("workingtree", "working-tree", "") ? WORKINGTREE : target_raw
    script = _env("TACHOMETER_SCRIPT", "benchmark/benchmarks.jl")
    outdir = _env("TACHOMETER_OUTPUT_DIR", joinpath(repo, "tachometer-report"))
    verbose = _envb("TACHOMETER_VERBOSE", true)

    report = compare(repo;
        baseline, target, script,
        backend = Symbol(_envs("TACHOMETER_BACKEND", "auto")),
        valgrind = _envs("TACHOMETER_VALGRIND", "valgrind"),
        time_tolerance = _envf("TACHOMETER_TIME_TOLERANCE", 0.05),
        memory_tolerance = _envf("TACHOMETER_MEMORY_TOLERANCE", 0.05),
        instr_tolerance = _envf("TACHOMETER_INSTR_TOLERANCE", 0.01),
        time_guard_tolerance = _envf("TACHOMETER_TIME_GUARD_TOLERANCE", 0.25),
        time_floor = _env("TACHOMETER_TIME_FLOOR", "1us"),
        memory_floor = _envf("TACHOMETER_MEMORY_FLOOR", 0.0),
        instr_floor = _envf("TACHOMETER_INSTR_FLOOR", 1000.0),
        nruns = _envi("TACHOMETER_NRUNS", 1),
        threads = _envi("TACHOMETER_THREADS", 1),
        verbose,
        stream = _envb("TACHOMETER_STREAM", verbose),
        io,
        run_url = _env("TACHOMETER_RUN_URL", ""),
        marker = _env("TACHOMETER_MARKER", "tachometer"),
        noise_history = _emptyto_nothing(_env("TACHOMETER_NOISE_HISTORY", "")),
        noise_factor = _envf("TACHOMETER_NOISE_FACTOR", 3.0),
        noise_min_samples = _envi("TACHOMETER_NOISE_MIN_SAMPLES", 5),
        release_baseline = _envb("TACHOMETER_RELEASE_BASELINE", true),
    )

    paths = write_report(outdir, report)
    set_output("status", report.status)
    set_output("regressed", report.status === :regressed)
    set_output("suite_changed", report.meta.suite_changed)
    set_output("report", paths.md)
    set_output("summary", oneline(report))

    println(io, "Tachometer: ", oneline(report))
    println(io, "Report written to ", paths.md)

    # This does not exit on a regression. Gating (failing the job) is a separate
    # final step in the action, run after the report artifact is uploaded, so it
    # is independent of comment posting.
    return report
end

# Re-render a comment from a (possibly untrusted) report.json in the trusted job.
function _main_render(io)
    in_json = _env("TACHOMETER_REPORT_IN", "")
    out_md = _env("TACHOMETER_REPORT_OUT", "")
    (isempty(in_json) || isempty(out_md)) && error("TACHOMETER_REPORT_IN and TACHOMETER_REPORT_OUT are required for render")
    # The trusted reporter passes the marker it validated; forcing it here keeps
    # the comment's embedded marker identical to the sticky search needle.
    render_report_file(in_json, out_md;
        marker = _emptyto_nothing(_env("TACHOMETER_MARKER", "")),
        run_url = _emptyto_nothing(_env("TACHOMETER_RUN_URL", "")))
    println(io, "Tachometer: re-rendered ", in_json, " -> ", out_md)
    return out_md
end

# Time-series modes ---------------------------------------------------------

# Benchmark the current commit and write a single record to TACHOMETER_RECORD_OUT.
function _main_record(io)
    repo = _env("TACHOMETER_PACKAGE", pwd())
    out = _env("TACHOMETER_RECORD_OUT", joinpath(repo, "tachometer-record.json"))
    verbose = _envb("TACHOMETER_VERBOSE", true)
    rec = record_run(repo;
        script = _env("TACHOMETER_SCRIPT", "benchmark/benchmarks.jl"),
        backend = resolve_backend(Symbol(_envs("TACHOMETER_BACKEND", "auto"));
            valgrind = _envs("TACHOMETER_VALGRIND", "valgrind")),
        valgrind = _envs("TACHOMETER_VALGRIND", "valgrind"),
        threads = _envi("TACHOMETER_THREADS", 1),
        verbose,
        stream = _envb("TACHOMETER_STREAM", verbose),
        io,
    )
    mkpath(dirname(abspath(out)))
    open(out, "w") do f
        JSON.print(f, rec)
    end
    println(io, "Tachometer: recorded ", length(rec["benchmarks"]), " benchmarks for ",
        first(rec["commit"], 7), " -> ", out)
    return rec
end

# Merge TACHOMETER_RECORD_IN into the history file and write the dashboard.
function _main_publish(io)
    repo = _env("TACHOMETER_PACKAGE", pwd())
    record_file = _emptyto_nothing(_env("TACHOMETER_RECORD_IN", ""))
    data_dir = _env("TACHOMETER_DATA_DIR", "")
    isempty(data_dir) && error("TACHOMETER_DATA_DIR (the data/ directory) is required for publish")
    dashboard_dir = _env("TACHOMETER_DASHBOARD_DIR", dirname(abspath(data_dir)))
    publish(record_file, data_dir, dashboard_dir, repo;
        repo_url = _env("TACHOMETER_REPO_URL", ""),
        package = _env("TACHOMETER_PACKAGE_NAME", _pkgname(abspath(repo))),
    )
    println(io, "Tachometer: published data -> ", data_dir, " and dashboard -> ", dashboard_dir)
    return data_dir
end

_env(name, default) = get(ENV, name, default)
_envs(name, default) = haskey(ENV, name) && !isempty(ENV[name]) ? ENV[name] : default
_emptyto_nothing(s) = isempty(s) ? nothing : s
_envf(name, default) = haskey(ENV, name) && !isempty(ENV[name]) ? parse(Float64, ENV[name]) : default
_envi(name, default) = haskey(ENV, name) && !isempty(ENV[name]) ? parse(Int, ENV[name]) : default
_envb(name, default) = haskey(ENV, name) && !isempty(ENV[name]) ? lowercase(ENV[name]) in ("1", "true", "yes") : default
