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
        time_tolerance = _env_nonempty("TACHOMETER_TIME_TOLERANCE", "5%"),
        memory_tolerance = _env_nonempty("TACHOMETER_MEMORY_TOLERANCE", "5%"),
        time_floor = _env("TACHOMETER_TIME_FLOOR", "1us"),
        memory_floor = _env_nonempty("TACHOMETER_MEMORY_FLOOR", "0"),
        nruns = _envi("TACHOMETER_NRUNS", 1),
        threads = _envi("TACHOMETER_THREADS", 1),
        retune = _envb("TACHOMETER_RETUNE", false),
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
        threads = _envi("TACHOMETER_THREADS", 1),
        retune = _envb("TACHOMETER_RETUNE", false),
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

# Pkg app entrypoint (`pkg> app add ...` gives a `tachometer` executable):
# `tachometer [mode] [--option=value ...]` where every --option=value sets the
# corresponding TACHOMETER_<OPTION> env var, so the app is the same CLI as the
# action. Unlike the action, compare defaults to the documented local behavior:
# baseline HEAD (vs the working tree) and no release-baseline swap.
@static if isdefined(Base, Symbol("@main"))
    const _APP_HELP = """
        Tachometer — benchmark a package at two git revisions and report the difference.

        Usage: tachometer [mode] [--option=value ...]

        Modes (default: compare):
          compare   benchmark baseline vs target and report
          record    benchmark the current commit into a time-series record
          publish   merge a record into the history and write the dashboard
          render    re-render a report.json into Markdown

        Options map to the TACHOMETER_* environment variables read by
        `Tachometer.main` (the action's inputs): --baseline=v1.2.0 sets
        TACHOMETER_BASELINE, --output-dir=out sets TACHOMETER_OUTPUT_DIR, etc.
        Run from a git working copy of the package. Exits 1 when compare finds
        a regression."""

    function (@main)(args)
        for arg in args
            if arg in ("-h", "--help")
                println(_APP_HELP)
                return 0
            elseif (m = match(r"^--([a-z][a-z0-9_-]*)=(.*)$", arg)) !== nothing
                ENV["TACHOMETER_" * uppercase(replace(m[1], '-' => '_'))] = m[2]
            elseif arg in ("compare", "record", "publish", "render")
                ENV["TACHOMETER_MODE"] = arg
            else
                println(stderr, "tachometer: unexpected argument '", arg, "' (try --help)")
                return 2
            end
        end
        if _env("TACHOMETER_MODE", "compare") == "compare"
            get!(ENV, "TACHOMETER_BASELINE", "HEAD")
            get!(ENV, "TACHOMETER_RELEASE_BASELINE", "false")
        end
        report = main()
        return report isa Report && report.status === :regressed ? 1 : 0
    end
end

_env(name, default) = get(ENV, name, default)
_env_nonempty(name, default) = let value = get(ENV, name, "")
    isempty(value) ? default : value
end
_emptyto_nothing(s) = isempty(s) ? nothing : s
_envf(name, default) = haskey(ENV, name) && !isempty(ENV[name]) ? parse(Float64, ENV[name]) : default
_envi(name, default) = haskey(ENV, name) && !isempty(ENV[name]) ? parse(Int, ENV[name]) : default
_envb(name, default) = haskey(ENV, name) && !isempty(ENV[name]) ? lowercase(ENV[name]) in ("1", "true", "yes") : default
