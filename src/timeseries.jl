# Recording default-branch results over time and publishing a dashboard.
#
# Two phases, kept separate so a push race doesn't force re-benchmarking:
#   * record  — run the suite once for the current commit and write one record.
#   * publish — merge that record into the history file (upsert by commit sha),
#               refresh release tags, and write the dashboard assets.
# The workflow runs `record` once, then retries `publish` + git push in a loop.

const TIMESERIES_SCHEMA = "tachometer-timeseries"
const TIMESERIES_VERSION = 2   # v2: sharded storage (index.json + shard-YYYY.json)

_now_iso() = Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS\\Z")

# The measurement regime. Series recorded under different fingerprints are not
# directly comparable (different CPU/OS/Julia can shift timings), so it is stored
# with every record and shown in the dashboard.
function _fingerprint(script_hash; threads)
    cpu = try
        first(Sys.cpu_info()).model
    catch
        ""
    end
    return Dict(
        "os" => string(Sys.KERNEL),
        "arch" => string(Sys.ARCH),
        "julia" => string(VERSION),
        "threads" => threads,
        "cpu" => cpu,
        "suite" => script_hash,
    )
end

"""
    record_run(repo; script, env, threads, retune, verbose) -> Dict

Run the suite once for the current commit of `repo` and return a record (commit
metadata + per-benchmark minimum time/memory/allocs). Only finite values are
kept, so the record is always valid JSON.
"""
function record_run(
        repo::AbstractString;
        script::AbstractString = "benchmark/benchmarks.jl",
        env::AbstractDict = Dict{String, String}(),
        threads::Int = 1,
        retune::Bool = false,
        verbose::Bool = true,
    )
    repo = abspath(repo)
    # Benchmark the committed HEAD (checked out into a worktree), not the live
    # working tree, so uncommitted changes can never be attributed to the commit.
    rr = run_revision(repo, "HEAD", script; env, threads, retune, verbose)
    rr.ok || error("benchmark run failed:\n" * rr.log)

    benches = Dict{String, Any}()
    for (k, e) in rr.estimates
        (isfinite(e.time) && isfinite(e.memory) && isfinite(e.allocs)) || continue
        benches[k] = Dict("time" => e.time, "memory" => e.memory, "allocs" => e.allocs)
    end

    v = project_version(repo, rr.sha)
    return Dict(
        "commit" => rr.sha,
        "date" => _git_meta(repo, rr.sha, "%cI"),
        "date_unix" => tryparse(Int, _git_meta(repo, rr.sha, "%ct")),
        "recorded_at" => _now_iso(),
        "message" => _git_meta(repo, rr.sha, "%s"),
        "julia_version" => string(VERSION),
        "version" => v === nothing ? nothing : string(v),
        "fingerprint" => _fingerprint(rr.script_hash; threads),
        "benchmarks" => benches,
    )
end

function _git_meta(repo, sha, fmt)
    return try
        readchomp(pipeline(`git -C $repo show -s --format=$fmt $sha`; stderr = devnull))
    catch
        ""
    end
end

# --- sharded history storage -------------------------------------------------
#
# Layout under the data directory:
#   index.json         manifest: shard list, releases, package/repo metadata
#   shard-YYYY.json     {"records":[...]} for commits in calendar year YYYY (UTC)
#
# A record's shard is a deterministic function of its commit date, so upsert
# touches exactly one shard regardless of age. Past-year shards are therefore
# immutable: browsers cache them (HTTP 304) and git never re-stores them; only
# the current year's shard and the tiny manifest change on a normal publish.
#
# Release markers live in the manifest (recomputed from git tags every publish),
# not on records — so a tag created after a commit (e.g. by TagBot) shows up
# without rewriting any record shard.

# Sort/shard key: unix commit time (%ct). ISO strings with different timezone
# offsets do not sort lexicographically, so we always key on date_unix.
_record_time(r) = let u = get(r, "date_unix", nothing)
    u isa Real ? Int(u) : 0
end
_shard_name(date_unix::Integer) = "shard-" * string(Dates.year(Dates.unix2datetime(date_unix)))

# Load a JSON object, failing CLOSED if it exists but is unreadable/malformed —
# we must never silently discard an existing history by overwriting it. Returns
# `nothing` only when the file is absent.
function _load_json_object(path, what)
    isfile(path) || return nothing
    doc = try
        JSON.parsefile(path)
    catch e
        error("existing $(what) at $(path) is not valid JSON; refusing to overwrite it ($(e))")
    end
    doc isa AbstractDict || error("existing $(what) at $(path) is malformed; refusing to overwrite it")
    return doc
end

function load_index(data_dir, package, repo_url)
    doc = _load_json_object(joinpath(data_dir, "index.json"), "history index")
    if doc !== nothing
        (get(doc, "schema", nothing) == TIMESERIES_SCHEMA && get(doc, "version", nothing) == TIMESERIES_VERSION &&
            get(doc, "shards", nothing) isa AbstractVector) ||
            error("existing history index has an unrecognised schema/version; refusing to overwrite it")
        return doc
    end
    return Dict{String, Any}(
        "schema" => TIMESERIES_SCHEMA, "version" => TIMESERIES_VERSION,
        "package" => package, "repo_url" => repo_url,
        "shards" => String[], "releases" => Any[], "latest_fingerprint" => Dict{String, Any}(),
        "generated_at" => _now_iso(),
    )
end

const _SHARD_RE = r"^shard-[0-9]+$"

function load_shard(data_dir, name)
    occursin(_SHARD_RE, String(name)) || error("invalid shard name: $(repr(name))")
    doc = _load_json_object(joinpath(data_dir, name * ".json"), "history shard")
    doc === nothing && return Any[]
    get(doc, "records", nothing) isa AbstractVector ||
        error("existing history shard $(name) is malformed; refusing to overwrite it")
    return doc["records"]
end

# Read every record across all shards, chronologically. Read-only and lenient
# (used to derive the noise model on a PR): a missing/foreign index or a broken
# shard yields fewer records rather than failing the PR job.
function load_all_records(data_dir)
    isdir(data_dir) || return Any[]
    idx = try
        _load_json_object(joinpath(data_dir, "index.json"), "history index")
    catch
        return Any[]
    end
    (idx isa AbstractDict && get(idx, "schema", nothing) == TIMESERIES_SCHEMA &&
        get(idx, "shards", nothing) isa AbstractVector) || return Any[]
    recs = Any[]
    for s in idx["shards"]
        (s isa AbstractString && occursin(_SHARD_RE, s)) || continue   # ignore bogus names
        append!(recs, try
            load_shard(data_dir, s)
        catch
            Any[]
        end)
    end
    sort!(recs; by = _record_time)
    return recs
end

# True if the data dir has shard files but no index — a corrupted/partial state
# we must not clobber by starting fresh.
_orphan_shards(data_dir) = !isfile(joinpath(data_dir, "index.json")) &&
    isdir(data_dir) && any(f -> startswith(f, "shard-") && endswith(f, ".json"), readdir(data_dir))

# All `vX.Y.Z` release tags as {tag, commit, date_unix}, sorted by version. This
# replaces per-record tags, so it is recomputed cheaply on every publish.
function _releases(repo)
    # Only tags merged into the current (default-branch) HEAD, so a side-branch
    # release tag doesn't show up as a marker.
    out = try
        readchomp(pipeline(`git -C $repo tag --list "v*" --merged HEAD`; stderr = devnull))
    catch
        return Any[]
    end
    rels = Any[]
    for t in split(out, '\n'; keepempty = false)
        occursin(_RELEASE_TAG_RE, t) || continue
        sha = try
            readchomp(pipeline(`git -C $repo rev-list -n 1 $t`; stderr = devnull))
        catch
            continue
        end
        du = tryparse(Int, try
            readchomp(pipeline(`git -C $repo show -s --format=%ct "$(t)^{commit}"`; stderr = devnull))
        catch
            ""
        end)
        push!(rels, Dict("tag" => t, "commit" => sha, "date_unix" => du))
    end
    sort!(rels; by = r -> VersionNumber(r["tag"][2:end]))
    return rels
end

"""
    publish(record_file, data_dir, dashboard_dir, repo; repo_url, package)

Merge the record in `record_file` into its year shard under `data_dir`, refresh
the release list in the manifest, and (over)write the dashboard assets into
`dashboard_dir`. A `nothing`/empty `record_file` is a refresh-only publish (e.g.
on a tag push): only the manifest's releases are recomputed, no shard changes.
"""
function publish(record_file, data_dir, dashboard_dir, repo; repo_url, package)
    repo = abspath(repo)
    mkpath(data_dir)
    _orphan_shards(data_dir) &&
        error("data dir $(data_dir) has shard files but no index.json; refusing to publish over a corrupted history")
    idx = load_index(data_dir, package, repo_url)
    idx["package"] = package
    idx["repo_url"] = repo_url

    if record_file !== nothing && !isempty(record_file)
        isfile(record_file) || error("record file not found: $(record_file)")
        rec = JSON.parsefile(record_file)
        name = _shard_name(_record_time(rec))
        recs = load_shard(data_dir, name)
        i = findfirst(r -> get(r, "commit", nothing) == rec["commit"], recs)  # upsert by sha
        i === nothing ? push!(recs, rec) : (recs[i] = rec)
        sort!(recs; by = _record_time)
        open(joinpath(data_dir, name * ".json"), "w") do io
            JSON.print(io, Dict("records" => recs))
        end
        name in idx["shards"] || push!(idx["shards"], name)
        sort!(idx["shards"])
        idx["latest_fingerprint"] = get(rec, "fingerprint", get(idx, "latest_fingerprint", Dict{String, Any}()))
    end

    idx["releases"] = _releases(repo)
    idx["generated_at"] = _now_iso()
    open(joinpath(data_dir, "index.json"), "w") do io
        JSON.print(io, idx)
    end
    write_dashboard(dashboard_dir)
    return data_dir
end

# Copy the (overwriteable) dashboard assets from the package into `dir`.
function write_dashboard(dir)
    src = joinpath(pkgdir(@__MODULE__), "dashboard")
    mkpath(dir)
    for f in ("index.html", "uPlot.iife.min.js", "uPlot.min.css")
        cp(joinpath(src, f), joinpath(dir, f); force = true)
    end
    return dir
end
