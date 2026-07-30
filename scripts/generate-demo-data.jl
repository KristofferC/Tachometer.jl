# Generate a synthetic benchmark history and write a self-contained demo
# dashboard site (dashboard assets + data/) into a directory.
#
# This exists so the repository can host an example dashboard on GitHub Pages
# (see .github/workflows/demo-dashboard.yml) without waiting months for real
# history to accumulate. The numbers are fake but shaped like real history:
# run-to-run noise, a regression that later gets fixed, a memory blow-up, a
# slow drift, an improvement, a benchmark added midway, release tags, and two
# measurement-environment changes (runner swap, Julia minor bump). Two commits
# contain partial uploads so the dashboard also demonstrates sparse histories.
#
# The RNG is seeded, so the shape of the history is reproducible; the timeline
# always ends at the day the script runs.
#
# Usage:
#   julia --project=<Tachometer dir> --startup-file=no scripts/generate-demo-data.jl <outdir>
#
# Preview locally (the page fetches data/, so serve it instead of file://):
#   python3 -m http.server --directory <outdir> 8000

using JSON
using Dates
using Random

# --- the story ----------------------------------------------------------------

# A fake FEM-style package, matching the benchmark names used in the README.
# (key, time ns, memory B, allocs); σ is the lognormal run-to-run noise on time,
# drift is a per-commit multiplicative creep, `from` is the fraction of the
# history at which the benchmark first exists.
struct Bench
    key::String
    time::Float64
    mem::Float64
    allocs::Float64
    sigma::Float64
    drift::Float64
    from::Float64
end
Bench(key, time, mem, allocs; sigma = 0.010, drift = 0.0, from = 0.0) =
    Bench(key, time, mem, allocs, sigma, drift, from)

const BENCHES = [
    Bench("assembly/global", 11.8e6, 6.9e6, 15_240),
    Bench("assembly/local", 148.0e3, 96.0e3, 210; sigma = 0.013),
    Bench("assembly/sparsity_pattern", 3.4e6, 4.2e6, 33_000),
    Bench("mesh/generate", 2.6e6, 1.9e6, 8_400),
    Bench("mesh/refine", 5.1e6, 3.4e6, 12_600; from = 0.62),
    Bench("mesh/vertex_neighbors", 640.0e3, 512.0e3, 1_020; sigma = 0.014),
    Bench("dofs/close!", 9.4e3, 1_024.0, 18; sigma = 0.017),
    Bench("dofs/renumber!", 210.0e3, 131_072.0, 96; sigma = 0.014),
    Bench("dofs/distribute", 1.35e6, 850.0e3, 4_800),
    Bench("solve/cg", 148.0e6, 12.6e6, 420; sigma = 0.008),
    Bench("solve/cholesky", 1.24e9, 310.0e6, 88; sigma = 0.007),
    Bench("solve/apply_bc!", 86.0e3, 0.0, 0; sigma = 0.015),
    Bench("io/export_vtk", 24.0e6, 18.0e6, 96_000; drift = 0.0009),  # slow creep
    Bench("sparse_matvec", 820.0, 0.0, 0; sigma = 0.016),            # ungrouped
]

# Step changes, at a fraction of the history: (frac, key, ×time, ×mem, ×allocs, message).
const EVENTS = [
    (0.22, "assembly/global", 1.38, 1.0, 1.0, "Support mixed celltypes in global assembly"),
    (0.30, "assembly/global", 0.70, 1.0, 1.0, "Hoist sparsity lookup out of the assembly inner loop"),
    (0.36, "solve/cg", 0.78, 1.0, 1.0, "Precondition CG with diagonal scaling"),
    (0.50, "dofs/close!", 1.09, 4.2, 6.0, "Track constraint dependencies for incremental close!"),
    (0.62, "mesh/refine", 1.0, 1.0, 1.0, "Add adaptive refinement (and a benchmark for it)"),
    (0.90, "mesh/generate", 0.84, 1.0, 1.0, "Avoid quadratic lookup in mesh generation"),
]

# (frac, tag) — the record at that point becomes the tagged release commit.
const RELEASES = [(0.06, "v0.8.0"), (0.38, "v0.9.0"), (0.52, "v0.9.1"), (0.85, "v1.0.0")]

# Measurement regimes: x86 runner → arm runner at 0.45, Julia 1.10 → 1.11 at 0.75.
const ENV_CHANGES = [0.45, 0.75]
fingerprint(seg, suite) = Dict(
    "os" => "Linux",
    "arch" => seg == 1 ? "x86_64" : "aarch64",
    "julia" => seg == 1 ? "1.10.4" : (seg == 2 ? "1.10.8" : "1.11.3"),
    "threads" => 1,
    "cpu" => seg == 1 ? "AMD EPYC 7763 64-Core Processor" : "Neoverse-N2",
    "suite" => suite,
)

const MESSAGES = [
    "Fix off-by-one in boundary iterator",
    "Refactor grid interface",
    "Add tests for mixed grids",
    "Improve error message for closed ConstraintHandler",
    "Support tensor-valued interpolations",
    "Simplify facet quadrature dispatch",
    "Handle empty cell sets in addcellset!",
    "Update dependencies",
    "Docs: clarify dof ordering",
    "CI: bump action versions",
    "Remove unused helper in iterators",
    "Fix typo in error message",
    "Add benchmark for sparse matvec",
    "Test on Julia nightly",
    "Inline hot path in shape_value",
    "Cleanup: remove dead code in exporter",
    "Generalize apply! to AbstractVector",
    "Fix world age issue in evaluate_at_points",
    "Reduce latency of first assembly",
    "Add example: incompressible elasticity",
]

# --- generation ---------------------------------------------------------------

_iso(dt) = Dates.format(dt, "yyyy-mm-ddTHH:MM:SS") * "Z"
hexstr(rng, n) = randstring(rng, "0123456789abcdef", n)

function generate()
    rng = Random.Xoshiro(0x7ac0)

    # Commit timeline: a few commits per week for ~16 months, ending today.
    stop = DateTime(Dates.today())
    dates = DateTime[]
    t = stop - Day(500) + Hour(9)
    while t < stop
        push!(dates, t)
        t += Day(rand(rng, (1, 2, 2, 3, 3, 4, 5, 7))) + Hour(rand(rng, -6:8))
    end
    n = length(dates)
    at(f) = clamp(round(Int, f * n), 1, n)

    events = Dict(at(f) => (key, tm, mm, am, msg) for (f, key, tm, mm, am, msg) in EVENTS)
    envidx = [at(f) for f in ENV_CHANGES]
    relidx = Dict(at(f) => tag for (f, tag) in RELEASES)
    partialidx = Dict(
        at(0.68) => ["assembly/global", "solve/cg"],
        at(0.70) => ["mesh/generate", "io/export_vtk"],
    )
    # Project version at record i: the tag at a release commit, otherwise the
    # next release's version with -DEV (a plausible development sequence).
    function version_at(i)
        haskey(relidx, i) && return relidx[i][2:end]
        for (f, tag) in RELEASES
            at(f) > i && return tag[2:end] * "-DEV"
        end
        v = VersionNumber(RELEASES[end][2][2:end])
        return string(v.major, ".", v.minor, ".", v.patch + 1, "-DEV")
    end

    # Per-benchmark state: cumulative step multipliers, per-regime machine factors.
    tmul = Dict(b.key => 1.0 for b in BENCHES)
    memmul = Dict(b.key => 1.0 for b in BENCHES)
    allocmul = Dict(b.key => 1.0 for b in BENCHES)
    envt = Dict(b.key => 1.0 for b in BENCHES)
    envm = Dict(b.key => 1.0 for b in BENCHES)

    suite = hexstr(rng, 64)
    seg = 1
    records = Any[]
    releases = Any[]
    for i in 1:n
        msg = rand(rng, MESSAGES)
        if haskey(events, i)
            key, tm, mm, am, emsg = events[i]
            tmul[key] *= tm; memmul[key] *= mm; allocmul[key] *= am
            msg = emsg
            key == "mesh/refine" && (suite = hexstr(rng, 64))  # suite edited: hash changes
        end
        if i in envidx
            seg += 1
            for b in BENCHES  # a different machine/Julia shifts every benchmark
                envt[b.key] *= seg == 2 ? 0.55 + 0.40 * rand(rng) : 0.90 + 0.18 * rand(rng)
                seg == 3 && (envm[b.key] *= 0.94 + 0.10 * rand(rng))
            end
        end
        haskey(relidx, i) && (msg = "Bump version to " * relidx[i])

        sha = hexstr(rng, 40)
        du = floor(Int, datetime2unix(dates[i]))
        haskey(relidx, i) &&
            push!(releases, Dict("tag" => relidx[i], "commit" => sha, "date_unix" => du))

        benches = Dict{String, Any}()
        for b in BENCHES
            i >= at(b.from) || continue
            spike = rand(rng) < 0.04 ? 1.0 + 0.06 * rand(rng) : 1.0
            time = b.time * tmul[b.key] * envt[b.key] * (1.0 + b.drift)^i *
                exp(b.sigma * randn(rng)) * spike
            benches[b.key] = Dict(
                "time" => round(time; digits = 3),
                "memory" => round(Int, b.mem * memmul[b.key] * envm[b.key]),
                "allocs" => round(Int, b.allocs * allocmul[b.key] * envm[b.key]),
            )
        end
        coverage = "snapshot"
        if haskey(partialidx, i)
            selected = partialidx[i]
            benches = Dict(key => benches[key] for key in selected if haskey(benches, key))
            coverage = "partial"
            msg = "Run selected benchmarks: " * join(selected, ", ")
        end

        push!(records, Dict(
            "commit" => sha,
            "date" => _iso(dates[i]),
            "date_unix" => du,
            "recorded_at" => _iso(dates[i] + Minute(38)),
            "message" => msg,
            "julia_version" => fingerprint(seg, suite)["julia"],
            "version" => version_at(i),
            "fingerprint" => fingerprint(seg, suite),
            "benchmarks" => benches,
            "coverage" => coverage,
            "removed_benchmarks" => String[],
        ))
    end
    return records, releases
end

# --- output -------------------------------------------------------------------
#
# Same layout `Tachometer.publish` writes: data/index.json + data/shard-YYYY.json
# next to the dashboard assets (see src/timeseries.jl).

function write_site(outdir, records, releases)
    marker = joinpath(outdir, ".tachometer-demo")
    generated_paths = ("index.html", "uPlot.iife.min.js", "uPlot.min.css", "data")
    if !isfile(marker) && any(path -> ispath(joinpath(outdir, path)), generated_paths)
        error("refusing to overwrite a dashboard that was not created by this demo generator: $outdir")
    end

    datadir = joinpath(outdir, "data")
    mkpath(datadir)

    shards = Dict{String, Vector{Any}}()
    for r in records
        name = "shard-" * string(Dates.year(Dates.unix2datetime(r["date_unix"])))
        push!(get!(Vector{Any}, shards, name), r)
    end
    for (name, recs) in shards
        open(joinpath(datadir, name * ".json"), "w") do io
            JSON.print(io, Dict("records" => recs))
        end
    end

    index = Dict(
        "schema" => "tachometer-timeseries", "version" => 3,
        "package" => "Example.jl",
        "repo_url" => nothing,  # fake commits: no links rather than dead links
        "shards" => sort(collect(keys(shards))),
        "releases" => releases,
        "latest_fingerprint" => records[end]["fingerprint"],
        "generated_at" => _iso(Dates.now(Dates.UTC)),
    )
    open(joinpath(datadir, "index.json"), "w") do io
        JSON.print(io, index)
    end

    dashboard = joinpath(@__DIR__, "..", "dashboard")
    for f in ("index.html", "uPlot.iife.min.js", "uPlot.min.css")
        cp(joinpath(dashboard, f), joinpath(outdir, f); force = true)
    end
    touch(marker)
    touch(joinpath(outdir, ".nojekyll"))
    return length(records)
end

isempty(ARGS) && (println(stderr, "usage: julia generate-demo-data.jl <outdir>"); exit(1))
records, releases = generate()
n = write_site(abspath(ARGS[1]), records, releases)
println("wrote demo site with $n records and $(length(releases)) releases to $(abspath(ARGS[1]))")
