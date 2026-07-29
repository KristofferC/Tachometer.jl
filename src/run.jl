# Running a benchmark suite for one revision of a package, in isolation.
#
# Keeping the git and subprocess handling here means the caller's working tree
# and environment are never mutated, and baseline/target runs can be
# interleaved for the paired reruns in judge.jl.
#
# For each revision:
#   1. check the source out at that revision into a throwaway `git worktree`
#      (or use the live working tree for the `:workingtree` sentinel),
#   2. *prepare* (native): build a fresh temporary project that `dev`s the
#      package from that source plus Odometer and the suite's own dependencies
#      (copied, never mutated), instantiate and precompile it,
#   3. *run*: execute `benchmark/benchmarks.jl` (which must define
#      `const SUITE = BenchmarkGroup()`, using Odometer) in a separate process —
#      wrapped in `valgrind --tool=callgrind` for the callgrind backend — and
#      save the results as JSON,
#   4. load them back and reduce to per-benchmark `Estimate`s (minimum over
#      samples, instructions included when the backend counts them).
#
# The prepare/run split exists for callgrind: Pkg operations and precompilation
# must happen natively (precompiled for the CPU target valgrind supports), so
# the simulated process only loads caches and measures.

using Odometer: Odometer
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
    backend::String         # backend the results were measured with ("" when unknown)
    threads::Int            # Threads.nthreads() reported by the measuring child
    ok::Bool
    log::String
end

RevisionRun(sha, dirty, estimates, script_hash, ok::Bool, log) =
    RevisionRun(sha, dirty, estimates, script_hash, "", 1, ok, log)
RevisionRun(sha, dirty, estimates, script_hash, backend::AbstractString, ok::Bool, log) =
    RevisionRun(sha, dirty, estimates, script_hash, backend, 1, ok, log)

"""
    resolve_backend(backend; valgrind = "valgrind") -> Symbol

Resolve `:auto` to a concrete measurement backend for this machine — `:perf`
when hardware counters are available, else `:callgrind` when a valgrind binary
is on the PATH, else `:time` — and validate an explicitly requested backend,
erroring (never silently downgrading) when it cannot run.
"""
function resolve_backend(backend::Symbol; valgrind::AbstractString = "valgrind")
    if backend === :auto
        Odometer.perf_available() && return :perf
        Sys.which(valgrind) === nothing || return :callgrind
        return :time
    elseif backend === :perf
        Odometer.perf_available() ||
            error("backend :perf requested but hardware performance counters are unavailable " *
                "(no PMU — e.g. a hosted CI runner — or perf_event_paranoid too restrictive); " *
                "use backend=:callgrind there instead")
        return :perf
    elseif backend === :callgrind
        Sys.which(valgrind) === nothing &&
            error("backend :callgrind requested but `$valgrind` was not found on the PATH")
        return :callgrind
    elseif backend === :time
        return :time
    end
    throw(ArgumentError("unknown backend $(repr(backend)) (expected :auto, :perf, :callgrind or :time)"))
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
    run_revision(repo, rev, script; backend=:time, env, threads, verbose, stream, io) -> RevisionRun

Run the suite for one revision. Never mutates `repo`. `backend` must be a
concrete backend (`:perf`, `:callgrind`, `:time` — resolve `:auto` first with
[`resolve_backend`](@ref)).

`verbose` (default `true`) makes the subprocess name each benchmark as it
executes it. `stream` (default: follows `verbose`) forwards the subprocess
output to `io` line by line *while it runs*, so a long suite can be watched as
it progresses instead of going quiet for minutes. The output is captured either
way; the captured tail is what a failed run reports.
"""
function run_revision(
        repo::AbstractString, rev, script::AbstractString;
        backend::Symbol = :time,
        valgrind::AbstractString = "valgrind",
        env::AbstractDict = Dict{String, String}(),
        threads::Int = 1,
        verbose::Bool = true,
        stream::Bool = verbose,
        io::IO = stdout,
    )
    backend in (:perf, :callgrind, :time) ||
        throw(ArgumentError("backend must be concrete (:perf, :callgrind or :time); resolve :auto first"))
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
    tmpfiles = String[]
    envdir = ""
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

        prefix = "[$(_short(sha))] "
        subenv = _subprocess_env(env, threads)

        # Phase 1 (native): build the ephemeral project and precompile it. For
        # callgrind, precompile for the CPU target valgrind's virtual CPU
        # supports, so the simulated process loads caches instead of compiling.
        envdir = mktempdir(; prefix = "tachometer_env_")
        prep = _write_prepare_driver(srcdir, script, envdir)
        push!(tmpfiles, prep)
        strip_cpu_target = backend === :callgrind
        prepenv = copy(subenv)
        backend === :callgrind && (prepenv["JULIA_CPU_TARGET"] = Odometer.CALLGRIND_CPU_TARGET)
        proc = _run_julia(setenv(_julia_cmd(prep; strip_cpu_target), _envvec(prepenv)); stream, io, prefix)
        success(proc.code) ||
            return RevisionRun(sha, dirty, Dict{String, Estimate}(), script_hash, false,
                "environment preparation failed\n" * _tail(proc.log))

        # Phase 2: run the suite (under callgrind when asked).
        outfile = tempname() * ".json"
        driver = _write_run_driver(srcdir, script, envdir, outfile, backend, verbose)
        push!(tmpfiles, driver)
        # The environment is applied to the *inner* julia command, so the extra
        # variables `callgrind_cmd` adds on top survive. The callgrind output
        # directory lives inside envdir, which is removed in the finally below.
        cmd = if backend === :callgrind
            # A single GC thread keeps the simulated process deterministic and cheap.
            Odometer.callgrind_cmd(setenv(_julia_cmd(driver, `--gcthreads=1`; strip_cpu_target), _envvec(subenv));
                valgrind, outdir = mkpath(joinpath(envdir, "callgrind-out")))
        else
            setenv(_julia_cmd(driver), _envvec(subenv))
        end
        proc = _run_julia(cmd; stream, io, prefix)
        if !success(proc.code)
            return RevisionRun(sha, dirty, Dict{String, Estimate}(), script_hash, false, _tail(proc.log))
        end
        isfile(outfile) ||
            return RevisionRun(sha, dirty, Dict{String, Estimate}(), script_hash, false,
                "subprocess produced no results file\n" * _tail(proc.log))

        estimates, run_backend, run_threads = _load_estimates(outfile)
        # An empty suite has no provenance to check; let the caller's normal
        # "no benchmarks found" path report it.
        if !isempty(estimates) && run_backend != string(backend)
            return RevisionRun(sha, dirty, Dict{String, Estimate}(), script_hash, false,
                "requested backend `$backend` but results were measured with `$run_backend`")
        end
        return RevisionRun(sha, dirty, estimates, script_hash,
            isempty(estimates) ? string(backend) : run_backend, run_threads, true, _tail(proc.log))
    catch e
        return RevisionRun(sha, dirty, Dict{String, Estimate}(), "", false,
            "error while benchmarking $(_short(sha)): $(sprint(showerror, e))")
    finally
        foreach(f -> rm(f; force = true), tmpfiles)
        isempty(outfile) || rm(outfile; force = true)
        isempty(envdir) || rm(envdir; force = true, recursive = true)
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

# The Odometer source to `dev` into the ephemeral suite environment: the same
# copy this process loaded, so parent and subprocess agree on the format.
_odometer_src() = dirname(dirname(pathof(Odometer)))

# Phase-1 driver: build the ephemeral project (so the caller's repo is
# untouched), dev-install the package and Odometer, instantiate + precompile.
function _write_prepare_driver(srcdir, script, envdir)
    benchdir = dirname(joinpath(srcdir, script))
    code = """
    using Pkg
    const _SRC = $(repr(srcdir))
    const _BENCHDIR = $(repr(benchdir))
    const _ENV = $(repr(envdir))
    const _ODOMETER = $(repr(_odometer_src()))

    # Seed the ephemeral environment from the suite's own Project.toml when it
    # has one (to get suite-only deps like DataFrames), copied so we never write
    # into the source tree. Otherwise start from an empty project.
    for f in ("Project.toml", "Manifest.toml", "JuliaProject.toml", "JuliaManifest.toml")
        p = joinpath(_BENCHDIR, f)
        isfile(p) && cp(p, joinpath(_ENV, f); force = true)
    end
    Pkg.activate(_ENV; io = devnull)
    # Point the package at *this* revision's source and make sure Odometer is
    # available regardless of what the suite project declared.
    Pkg.develop([PackageSpec(path = _SRC), PackageSpec(path = _ODOMETER)]; io = devnull)
    Pkg.instantiate(; io = devnull)
    Pkg.precompile(; io = devnull)
    """
    path = tempname() * ".jl"
    write(path, code)
    return path
end

# Phase-2 driver: run the suite in the prepared environment and save results.
function _write_run_driver(srcdir, script, envdir, outfile, backend, verbose)
    scriptpath = joinpath(srcdir, script)
    code = """
    using Pkg
    Pkg.activate($(repr(envdir)); io = devnull)
    using Odometer
    Base.include(Main, $(repr(scriptpath)))
    isdefined(Main, :SUITE) || error("benchmark script did not define `SUITE`")
    suite = Main.SUITE::BenchmarkGroup
    results = run(suite; backend = $(repr(backend)), verbose = $(repr(verbose)))
    Odometer.save($(repr(outfile)), results)
    """
    path = tempname() * ".jl"
    write(path, code)
    return path
end

# Use the full julia_cmd so a custom sysimage (-J) and similar flags survive.
# The drivers activate their own temp project, so no --project here.
#
# `strip_cpu_target` matters more than it looks: `Base.julia_cmd()` bakes in
# `-C native`, and the command-line flag beats the JULIA_CPU_TARGET environment
# variable — including in the workers `Pkg.precompile` spawns, which inherit
# the parent's resolved target. For callgrind runs the multi-target string in
# JULIA_CPU_TARGET must win (it is not legal as a plain `-C` execution flag),
# or the prepare phase precompiles caches the simulated process cannot load and
# the measure phase silently recompiles everything inside the simulator.
function _julia_cmd(driver, extra::Cmd = ``; strip_cpu_target::Bool = false)
    julia = Base.julia_cmd()
    strip_cpu_target && (julia = Cmd(_strip_cpu_target(julia.exec)))
    return `$julia --startup-file=no $extra $driver`
end

# Remove `-C x` / `-Cx` / `--cpu-target x` / `--cpu-target=x` from an argv.
function _strip_cpu_target(exec::Vector{String})
    out = String[]
    skip = false
    for a in exec
        skip && (skip = false; continue)
        if a == "-C" || a == "--cpu-target"
            skip = true
        elseif startswith(a, "-C") || startswith(a, "--cpu-target=")
        else
            push!(out, a)
        end
    end
    return out
end

_envvec(env) = String[string(k) * "=" * string(v) for (k, v) in env]

function _run_julia(cmd::Base.AbstractCmd; stream::Bool = false, io::IO = stdout, prefix::AbstractString = "")
    buf = IOBuffer()
    # stdout and stderr share one pipe so the log keeps them in the order they
    # were written, and a reader task drains it as the subprocess writes: it must
    # never fill, or the subprocess would block on a full pipe and hang.
    out = Pipe()
    cmd = pipeline(cmd; stdout = out, stderr = out)
    proc = run(cmd; wait = false)
    close(out.in)   # the parent holds no write end, so the reader sees EOF at exit
    reader = @async try
        for line in eachline(out)
            println(buf, line)
            if stream
                println(io, prefix, line)
                flush(io)
            end
        end
    catch
        # A broken pipe must not take the run down: the exit status and whatever
        # was captured before the break are still the useful signal.
    end
    wait(proc)
    wait(reader)
    return (; code = proc, log = String(take!(buf)))
end

success(code::Base.Process) = code.exitcode == 0

# Reduce saved Odometer results to per-benchmark Estimates (minimum over
# samples — robust against positive within-trial noise; Odometer already
# excludes compile-contaminated and unreliable samples when clean ones exist).
# Also returns the backend the results were measured with (uniform across
# leaves by construction — one `run(suite)` — so the last one wins).
function _load_estimates(file)
    group = Odometer.load(file)
    out = Dict{String, Estimate}()
    backend = ""
    threads = 1
    for (ids, trial) in Odometer.leaves(group)
        key = join(_keypart.(ids), "/")
        m = minimum(trial)
        out[key] = Estimate(m.time, m.bytes, m.allocs, m.instructions)
        backend = string(trial.provenance.backend)
        # The child's actual thread count, not the requested one: instruction
        # judging must be gated on what really ran.
        threads = max(threads, trial.provenance.threads)
    end
    return out, backend, threads
end

# Group keys are often tuples like `("spatial-dim", 2)`; render those as
# `spatial-dim=2` instead of the raw tuple `repr` so the report reads cleanly.
# (Odometer.keystring does the same; keys loaded from JSON are already strings.)
_keypart(x) = x isa Tuple ? join(string.(x), "=") : string(x)

function _tail(s::AbstractString; n = 40, chars = 4000)
    lines = split(s, '\n')
    length(lines) > n && (s = "…\n" * join(lines[(end - n + 1):end], '\n'))
    length(s) > chars && (s = "…" * last(s, chars))   # char-based: Unicode-safe
    return s
end
