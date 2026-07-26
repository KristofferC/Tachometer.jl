# Running a benchmark suite for one revision of a package, in isolation.
#
# This does not go through PkgBenchmark: keeping the git and subprocess handling
# here means the caller's working tree and environment are never mutated, and
# baseline/target runs can be interleaved for the paired reruns in judge.jl.
#
# For each revision:
#   1. check the source out at that revision into a throwaway `git worktree`
#      (or use the live working tree for the `:workingtree` sentinel),
#   2. build a fresh temporary project that `dev`s the package from that source
#      plus the suite's own dependencies (copied, never mutated),
#   3. run `benchmark/benchmarks.jl` (which must define `const SUITE`) in a
#      separate process and serialise the `BenchmarkGroup` to JSON,
#   4. load it back and reduce it to per-benchmark `Estimate`s.

using BenchmarkTools: BenchmarkTools, BenchmarkGroup, leaves
using SHA: sha256

"""
    WORKINGTREE

Sentinel `target`/`baseline` value meaning "use the package's current working
tree as-is" (including uncommitted changes) rather than checking out a git ref.
Handy locally: edit the source, then compare it against a committed baseline.
"""
const WORKINGTREE = :workingtree

struct RevisionRun
    sha::String
    dirty::Bool
    estimates::Dict{String, Estimate}
    script_hash::String
    ok::Bool
    log::String
end

git(repo, args...) = readchomp(`git -C $repo $(collect(args))`)

function resolve_sha(repo::AbstractString, rev)
    rev === WORKINGTREE && return (git(repo, "rev-parse", "HEAD"), _is_dirty(repo))
    return (git(repo, "rev-parse", string(rev)), false)
end

_is_dirty(repo) = !isempty(readchomp(`git -C $repo status --porcelain`))

# The top-level `version` of Project.toml at a given revision, or `nothing` if it
# can't be read/parsed. Parsed as TOML so only the real top-level key is read.
function project_version(repo::AbstractString, rev)
    content = try
        rev === WORKINGTREE ? read(joinpath(repo, "Project.toml"), String) :
            readchomp(pipeline(`git -C $repo show $(string(rev)):Project.toml`; stderr = devnull))
    catch
        return nothing
    end
    d = try
        TOML.parse(content)
    catch
        return nothing
    end
    v = get(d, "version", nothing)
    return v isa AbstractString ? tryparse(VersionNumber, v) : nothing
end

const _RELEASE_TAG_RE = r"^v[0-9]+\.[0-9]+\.[0-9]+$"

# Release tags (strictly `vX.Y.Z`) that are ancestors of `ref`, as (version, tag)
# pairs. Restricting to exact `vX.Y.Z` skips stray tags like `v-next` and makes
# the tag name safe to embed in the comment.
function _release_tags(repo::AbstractString, ref::AbstractString)
    out = try
        readchomp(pipeline(`git -C $repo tag --list "v*" --merged $ref`; stderr = devnull))
    catch
        return Tuple{VersionNumber, String}[]
    end
    pairs = Tuple{VersionNumber, String}[]
    for t in split(out, '\n'; keepempty = false)
        occursin(_RELEASE_TAG_RE, t) || continue
        v = tryparse(VersionNumber, t[2:end])
        v === nothing || push!(pairs, (v, t))
    end
    return pairs
end

# The highest-version release tag reachable from `rev` (optionally strictly below
# a given version), chosen by semantic version rather than graph proximity. Needs
# tags to be present (checkout with fetch-depth: 0).
function last_release_tag(repo::AbstractString, rev; below::Union{VersionNumber, Nothing} = nothing)
    ref = rev === WORKINGTREE ? "HEAD" : string(rev)
    tags = _release_tags(repo, ref)
    below === nothing || (tags = filter(p -> p[1] < below, tags))
    isempty(tags) && return nothing
    return last(sort(tags; by = first))[2]
end

# Release gate: when the target's version is *higher* than the baseline's, compare
# against the previous release instead, so regressions accumulated over the whole
# release cycle are caught. The previous release is the highest `vX.Y.Z` tag
# reachable from the target and strictly below its version — so a target that is
# itself tagged is never compared against itself. Returns the (possibly replaced)
# baseline and a note for the report (empty when nothing changed).
function _release_baseline(repo::AbstractString, baseline, target)
    tv = project_version(repo, target)
    bv = project_version(repo, baseline)
    (tv === nothing || bv === nothing || !(tv > bv)) && return baseline, ""
    tag = last_release_tag(repo, target; below = tv)
    # A raised version with no discoverable previous release (first release, or a
    # shallow clone missing tags): surface it rather than silently falling back.
    tag === nothing && return baseline,
        "This PR raises the version ($(bv) → $(tv)) but no previous `vX.Y.Z` release tag was found (a shallow clone?); comparing against the usual baseline instead."
    return tag, "This PR bumps the version ($(bv) → $(tv)); comparing against the last release `$(tag)` to catch regressions accumulated since then."
end

# Hash the suite so we can warn when the benchmark definitions differ between
# revisions (a PR that edits benchmarks can otherwise silently compare apples to
# oranges). Covers every `*.jl` in the entrypoint's directory (sorted), so a
# change in an `include`d helper is detected too, not just the entrypoint.
function _script_hash(dir::AbstractString, script::AbstractString)
    path = joinpath(dir, script)
    isfile(path) || return ""
    bdir = dirname(path)
    buf = IOBuffer()
    for f in sort(readdir(bdir))
        endswith(f, ".jl") || continue
        p = joinpath(bdir, f)
        isfile(p) || continue
        write(buf, f)
        write(buf, read(p))
    end
    return bytes2hex(sha256(take!(buf)))
end

"""
    run_revision(repo, rev, script; env, threads, retune, verbose) -> RevisionRun

Run the suite for one revision. Never mutates `repo`.

`verbose` (default `true`) is passed to `BenchmarkTools.run`, so the subprocess
log names each benchmark as it is executed. The log is only surfaced when the run
fails, where that progress is what tells you *which* benchmark broke or hung.
"""
function run_revision(
        repo::AbstractString, rev, script::AbstractString;
        env::AbstractDict = Dict{String, String}(),
        threads::Int = 1,
        retune::Bool = false,
        verbose::Bool = true,
    )
    # Any failure (bad ref, worktree/subprocess/deserialisation error) becomes a
    # clean `ok = false` run so the caller can report a yellow state instead of
    # crashing. Only the measured SHA is trusted, and the worktree is checked out
    # at that resolved SHA (not the possibly-moving ref).
    local sha, dirty
    try
        sha, dirty = resolve_sha(repo, rev)
    catch e
        return RevisionRun("", false, Dict{String, Estimate}(), "", false,
            "could not resolve revision $(repr(rev)): $(sprint(showerror, e))")
    end

    worktree = nothing
    outfile = ""
    driver = ""
    try
        srcdir = if rev === WORKINGTREE
            repo
        else
            worktree = mktempdir(; prefix = "tachometer_wt_")
            run(`git -C $repo worktree add --quiet --detach $worktree $sha`)
            worktree
        end

        script_hash = _script_hash(srcdir, script)
        isfile(joinpath(srcdir, script)) ||
            return RevisionRun(sha, dirty, Dict{String, Estimate}(), script_hash, false,
                "benchmark script `$script` not found at revision $(_short(sha))")

        outfile = tempname() * ".json"
        driver = _write_driver(srcdir, script, outfile, retune, verbose)
        proc = _run_julia(driver, _subprocess_env(env, threads))
        if !success(proc.code)
            return RevisionRun(sha, dirty, Dict{String, Estimate}(), script_hash, false, _tail(proc.log))
        end
        isfile(outfile) ||
            return RevisionRun(sha, dirty, Dict{String, Estimate}(), script_hash, false,
                "subprocess produced no results file\n" * _tail(proc.log))

        estimates = _load_estimates(outfile)
        return RevisionRun(sha, dirty, estimates, script_hash, true, _tail(proc.log))
    catch e
        return RevisionRun(sha, dirty, Dict{String, Estimate}(), "", false,
            "error while benchmarking $(_short(sha)): $(sprint(showerror, e))")
    finally
        isempty(driver) || rm(driver; force = true)
        isempty(outfile) || rm(outfile; force = true)
        if worktree !== nothing
            try
                run(`git -C $repo worktree remove --force $worktree`)
            catch
                rm(worktree; force = true, recursive = true)
            end
        end
    end
end

_short(sha) = sha[1:min(7, length(sha))]

function _subprocess_env(env, threads)
    e = copy(ENV)
    # Pin threading for reproducibility. These are set *before* the caller's env
    # so an inherited JULIA_NUM_THREADS can't silently override the requested
    # value, while an explicit entry in `env` still wins.
    e["JULIA_NUM_THREADS"] = string(threads)
    e["OPENBLAS_NUM_THREADS"] = "1"
    e["OMP_NUM_THREADS"] = "1"
    for (k, v) in env
        e[string(k)] = string(v)
    end
    return e
end

# The subprocess driver. It builds an ephemeral project (so the caller's repo is
# untouched), dev-installs the package from `srcdir`, runs the suite and saves it.
function _write_driver(srcdir, script, outfile, retune, verbose)
    benchdir = dirname(joinpath(srcdir, script))
    scriptpath = joinpath(srcdir, script)
    code = """
    using Pkg
    const _SRC = $(repr(srcdir))
    const _BENCHDIR = $(repr(benchdir))
    const _SCRIPT = $(repr(scriptpath))
    const _OUT = $(repr(outfile))
    const _RETUNE = $(repr(retune))
    const _VERBOSE = $(repr(verbose))

    env = mktempdir(; prefix = "tachometer_env_")
    # Seed the ephemeral environment from the suite's own Project.toml when it
    # has one (to get suite-only deps like DataFrames), copied so we never write
    # into the source tree. Otherwise start from an empty project.
    for f in ("Project.toml", "Manifest.toml", "JuliaProject.toml", "JuliaManifest.toml")
        p = joinpath(_BENCHDIR, f)
        isfile(p) && cp(p, joinpath(env, f); force = true)
    end
    Pkg.activate(env; io = devnull)
    # Point the package at *this* revision's source and make sure BenchmarkTools
    # is available regardless of what the suite project declared.
    Pkg.develop(PackageSpec(path = _SRC); io = devnull)
    try
        Pkg.add("BenchmarkTools"; io = devnull, preserve = Pkg.PRESERVE_ALL)
    catch
        Pkg.add("BenchmarkTools"; io = devnull)
    end
    Pkg.instantiate(; io = devnull)

    using BenchmarkTools
    Base.include(Main, _SCRIPT)
    isdefined(Main, :SUITE) || error("benchmark script did not define `SUITE`")
    suite = Main.SUITE::BenchmarkGroup

    paramsfile = joinpath(_BENCHDIR, "tune.json")
    if !_RETUNE && isfile(paramsfile)
        loadparams!(suite, BenchmarkTools.load(paramsfile)[1], :evals, :samples)
    else
        tune!(suite)
    end

    results = run(suite; verbose = _VERBOSE)
    BenchmarkTools.save(_OUT, results)
    """
    path = tempname() * ".jl"
    write(path, code)
    return path
end

function _run_julia(driver, env)
    # Use the full julia_cmd so a custom sysimage (-J) and similar flags survive.
    # The driver activates its own temp project, so no --project here.
    julia = Base.julia_cmd()
    buf = IOBuffer()
    cmd = pipeline(setenv(`$julia --startup-file=no $driver`, env);
        stdout = buf, stderr = buf)
    code = try
        run(cmd; wait = true)
    catch e
        e isa ProcessFailedException ? e.procs[1] : rethrow()
    end
    return (; code, log = String(take!(buf)))
end

success(code::Base.Process) = code.exitcode == 0

function _load_estimates(file)
    group = BenchmarkTools.load(file)[1]::BenchmarkGroup
    est = minimum(group)   # robust against positive within-trial noise
    out = Dict{String, Estimate}()
    for (ids, trial) in leaves(est)
        key = join(_keypart.(ids), "/")
        out[key] = Estimate(
            Float64(BenchmarkTools.time(trial)),
            Float64(BenchmarkTools.memory(trial)),
            Float64(BenchmarkTools.allocs(trial)),
        )
    end
    return out
end

# BenchmarkGroup keys are often tuples like `("spatial-dim", 2)`; render those as
# `spatial-dim=2` instead of the raw tuple `repr` so the report reads cleanly.
_keypart(x) = x isa Tuple ? join(string.(x), "=") : string(x)

function _tail(s::AbstractString; n = 40, chars = 4000)
    lines = split(s, '\n')
    length(lines) > n && (s = "…\n" * join(lines[(end - n + 1):end], '\n'))
    length(s) > chars && (s = "…" * last(s, chars))   # char-based: Unicode-safe
    return s
end
