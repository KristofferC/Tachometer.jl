# Recording default-branch results over time and publishing a dashboard.
#
# Two phases, kept separate so a push race doesn't force re-benchmarking:
#   * record  — run the suite once for the current commit and write one record.
#   * publish — merge that record into the history file (upsert by commit sha),
#               refresh release tags, and write the dashboard assets.
# The workflow runs `record` once, then retries `publish` + git push in a loop.

const TIMESERIES_SCHEMA = "tachometer-timeseries"
const TIMESERIES_VERSION = 3   # v3: snapshot/partial record coverage
const TIMESERIES_READ_VERSIONS = (2, 3)
const RECORD_COVERAGES = ("snapshot", "partial")
const _STAT_KEYS = ("time", "memory", "allocs", "instructions")
const _COMMIT_RE = r"^[0-9a-f]{7,40}$"

_now_iso() = Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS\\Z")

# The measurement regime. Series recorded under different fingerprints are not
# directly comparable (different CPU/OS/Julia can shift timings), so it is stored
# with every record and shown in the dashboard.
function _fingerprint(script_hash; threads)
    f = default_fingerprint(; threads)
    f["suite"] = script_hash
    return f
end

"""
    default_fingerprint(; threads = Threads.nthreads()) -> Dict

The measurement regime of the current machine: OS kernel, architecture, Julia
version, thread count, and CPU model. Stored with every record; the dashboard
marks the commits where the regime changed, so a runner swap is not mistaken
for a performance change. Extra keys (e.g. `"backend"`) may be added.
"""
function default_fingerprint(; threads::Integer = Threads.nthreads())
    return Dict{String, Any}(
        "os" => string(Sys.KERNEL),
        "arch" => string(Sys.ARCH),
        "julia" => string(VERSION),
        "threads" => threads,
        "cpu" => _raw_cpu_model(),
    )
end

"""
    record_run(repo; script, env, threads, retune, verbose, stream, io) -> Dict

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
        stream::Bool = verbose,
        io::IO = stdout,
    )
    repo = abspath(repo)
    # Benchmark the committed HEAD (checked out into a worktree), not the live
    # working tree, so uncommitted changes can never be attributed to the commit.
    rr = run_revision(repo, "HEAD", script; env, threads, retune, verbose, stream, io)
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
        "coverage" => "snapshot",
        "removed_benchmarks" => String[],
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
# touches exactly one shard regardless of age. Normally only the current year's
# shard and the tiny manifest change; a correction or backfill can rewrite an
# older shard, which a static host may keep cached briefly.
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
        (get(doc, "schema", nothing) == TIMESERIES_SCHEMA &&
            get(doc, "version", nothing) in TIMESERIES_READ_VERSIONS &&
            get(doc, "shards", nothing) isa AbstractVector) ||
            error("existing history index has an unrecognised schema/version; refusing to overwrite it")
        # v3 only adds optional per-record coverage. Missing coverage means
        # snapshot, so a v2 manifest can be upgraded without touching shards.
        doc["version"] = TIMESERIES_VERSION
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

# Load the manifest for writing, refusing to start fresh over a corrupted dir.
function _open_index(data_dir, package, repo_url)
    mkpath(data_dir)
    _orphan_shards(data_dir) &&
        error("data dir $(data_dir) has shard files but no index.json; refusing to publish over a corrupted history")
    return load_index(data_dir, package, repo_url)
end

function _record_coverage(rec)
    coverage = get(rec, "coverage", "snapshot")
    coverage in RECORD_COVERAGES ||
        error("record coverage must be \"snapshot\" or \"partial\", got $(repr(coverage))")
    return coverage
end

function _removed_benchmarks(rec)
    removed = get(rec, "removed_benchmarks", String[])
    removed isa AbstractVector ||
        error("record \"removed_benchmarks\" must be an array of benchmark names")
    out = String[]
    for name in removed
        name isa AbstractString && !isempty(name) ||
            error("removed benchmark names must be non-empty strings, got $(repr(name))")
        key = String(name)
        key in out && error("removed benchmark name $(repr(key)) is duplicated")
        push!(out, key)
    end
    return out
end

function _validate_history_record(record)
    record isa AbstractDict || error("record must be a JSON object")
    sha = get(record, "commit", nothing)
    sha isa AbstractString && occursin(_COMMIT_RE, sha) ||
        error("record \"commit\" must be a lowercase 7–40 char hex sha; build records with make_record")
    date_unix = get(record, "date_unix", nothing)
    valid_date = date_unix isa Real && !(date_unix isa Bool) && isfinite(date_unix) &&
        isinteger(date_unix) && typemin(Int) <= date_unix <= typemax(Int)
    valid_date ||
        error("record \"date_unix\" must be integer unix seconds; build records with make_record")

    benchmarks = get(record, "benchmarks", nothing)
    benchmarks isa AbstractDict ||
        error("record \"benchmarks\" must be an object; build records with make_record")
    for (name, stats) in benchmarks
        name isa AbstractString && !isempty(name) ||
            error("record benchmark names must be non-empty strings")
        stats isa AbstractDict && !isempty(stats) ||
            error("record benchmark $(repr(name)) must contain statistics")
        for (stat, value) in stats
            stat isa AbstractString && stat in _STAT_KEYS ||
                error("record benchmark $(repr(name)) has unknown statistic $(repr(stat))")
            value isa Real && !(value isa Bool) && isfinite(value) && value >= 0 ||
                error("record statistic $(repr(stat)) for $(repr(name)) must be a non-negative finite number")
        end
    end

    coverage = _record_coverage(record)
    removed = _removed_benchmarks(record)
    coverage == "snapshot" && !isempty(removed) &&
        error("record \"removed_benchmarks\" is only valid with partial coverage")
    any(name -> haskey(benchmarks, name), removed) &&
        error("a benchmark cannot be both measured and removed in one record")
    isempty(benchmarks) && isempty(removed) &&
        error("record must measure or remove at least one benchmark")
    return record
end

# Apply a partial update to an existing record for the same commit. A snapshot
# remains a snapshot after a partial update because its complete benchmark set
# is still known; two partial uploads remain partial.
function _merge_partial_record(existing, incoming)
    get(existing, "fingerprint", Dict()) == get(incoming, "fingerprint", Dict()) ||
        error("cannot merge partial results for commit $(incoming["commit"]): measurement fingerprints differ")

    merged = Dict{String, Any}(String(k) => v for (k, v) in existing)
    benches = Dict{String, Any}(String(k) => v for (k, v) in get(existing, "benchmarks", Dict()))
    coverage = _record_coverage(existing)
    removed = coverage == "partial" ? Set(_removed_benchmarks(existing)) : Set{String}()

    for name in _removed_benchmarks(incoming)
        delete!(benches, name)
        push!(removed, name)
    end
    for (name, stats) in incoming["benchmarks"]
        key = String(name)
        benches[key] = stats
        delete!(removed, key)
    end

    # Incoming commit/date/runtime metadata is authoritative, but the defaults
    # for optional display fields should not erase useful existing metadata.
    for (key, value) in incoming
        key in ("benchmarks", "coverage", "removed_benchmarks") && continue
        key == "message" && value == "" && continue
        key in ("version", "julia_version") && value === nothing && continue
        merged[String(key)] = value
    end
    merged["benchmarks"] = benches
    merged["coverage"] = coverage
    merged["removed_benchmarks"] = coverage == "partial" ? sort!(collect(removed)) : String[]
    return merged
end

# Upsert one record by commit sha. Normally this touches only the target year;
# if a corrected commit date moves an existing record to another year, remove
# the old copy too. Does not write the manifest.
function _upsert_record!(data_dir, idx, rec)
    target = _shard_name(_record_time(rec))
    names = String[]
    for name in idx["shards"]
        name isa AbstractString || error("existing history index has a non-string shard name")
        push!(names, String(name))
    end
    length(unique(names)) == length(names) ||
        error("existing history index lists the same shard more than once")
    for name in names
        isfile(joinpath(data_dir, name * ".json")) ||
            error("existing history index lists missing shard $(name); refusing to overwrite a corrupted history")
    end
    target in names || push!(names, target)
    sort!(names)

    # Load everything before writing anything, so a malformed old shard cannot
    # leave a corrected record half-moved.
    shards = Dict(name => load_shard(data_dir, name) for name in names)
    old_locations = String[]
    matches = Any[]
    for name in names
        recs = shards[name]
        kept = Any[]
        for existing in recs
            if get(existing, "commit", nothing) == rec["commit"]
                push!(matches, existing)
            else
                push!(kept, existing)
            end
        end
        length(kept) == length(recs) || push!(old_locations, name)
        shards[name] = kept
    end
    length(matches) <= 1 ||
        error("commit $(rec["commit"]) appears more than once in the existing history")
    stored = _record_coverage(rec) == "partial" && !isempty(matches) ?
        _merge_partial_record(only(matches), rec) : rec
    push!(shards[target], stored)
    foreach(recs -> sort!(recs; by = _record_time), values(shards))

    # Write the new copy first. An interrupted correction may temporarily leave
    # a duplicate, but never removes the only copy.
    for name in vcat(target, filter(!=(target), old_locations))
        open(joinpath(data_dir, name * ".json"), "w") do io
            JSON.print(io, Dict("records" => shards[name]))
        end
    end

    target in idx["shards"] || push!(idx["shards"], target)
    sort!(idx["shards"])
    newest = nothing
    for name in names, candidate in shards[name]
        (newest === nothing || _record_time(candidate) >= _record_time(newest)) && (newest = candidate)
    end
    idx["latest_fingerprint"] =
        newest === nothing ? Dict{String, Any}() : get(newest, "fingerprint", Dict{String, Any}())
    return idx
end

function _write_index(data_dir, idx)
    idx["generated_at"] = _now_iso()
    open(joinpath(data_dir, "index.json"), "w") do io
        JSON.print(io, idx)
    end
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
    rec = nothing
    if record_file !== nothing && !isempty(record_file)
        isfile(record_file) || error("record file not found: $(record_file)")
        rec = JSON.parsefile(record_file)
        _validate_history_record(rec)
    end

    idx = _open_index(data_dir, package, repo_url)
    idx["package"] = package
    idx["repo_url"] = repo_url

    rec === nothing || _upsert_record!(data_dir, idx, rec)

    idx["releases"] = _releases(repo)
    _write_index(data_dir, idx)
    write_dashboard(dashboard_dir)
    return data_dir
end

"""
    write_dashboard(dir) -> dir

Copy the static dashboard assets (`index.html` plus the vendored uPlot files)
into `dir`, overwriting existing copies. The page loads its history from a
`data/` directory next to `index.html` (see [`add_record!`](@ref)) and needs no
build step or server application. Even for local use, serve the directory over
HTTP rather than opening `index.html` as a `file://` URL.
"""
function write_dashboard(dir)
    src = joinpath(pkgdir(@__MODULE__), "dashboard")
    mkpath(dir)
    for f in ("index.html", "uPlot.iife.min.js", "uPlot.min.css")
        cp(joinpath(src, f), joinpath(dir, f); force = true)
    end
    return dir
end

# --- bring-your-own-runner API -------------------------------------------------
#
# For projects that use their own benchmarking framework and only want the
# dashboard: build a record from measurements you already have (`make_record`),
# merge it into the published history (`add_record!`), and copy the static page
# next to it (`write_dashboard`). The storage is plain JSON, so non-Julia tools
# can write it directly instead — dashboard/README.md documents the layout.

# Iterate anything pair-shaped: Dict and Vector{Pair} iterate pairs already,
# NamedTuples need pairs().
_pairs(x) = x isa NamedTuple ? pairs(x) : x

"""
    make_record(benchmarks; commit, date, coverage = :snapshot,
                removed_benchmarks = (), message = "", version = nothing,
                julia_version = string(VERSION),
                fingerprint = default_fingerprint()) -> Dict

Build one history record from measurements produced by any benchmarking
framework, validated against what the dashboard expects. Merge it into a
published history with [`add_record!`](@ref).

- `benchmarks`: `name => stats` pairs (a `Dict`, `NamedTuple`, or vector of
  pairs). Each `stats` maps a subset of `time` (nanoseconds), `memory` (bytes),
  `allocs`, and `instructions` (counts) to finite numbers; the dashboard shows
  a tab for each statistic that appears in the history.
- `commit`: hex sha (7–40 chars) of the commit the measurements belong to.
- `date`: the *commit* date, as a UTC `DateTime` or unix seconds — records are
  ordered and sharded by it, so keep it the commit date rather than "now".
- `coverage`: `:snapshot` means `benchmarks` is the complete suite and omitted
  benchmarks become inactive. `:partial` means it contains only measurements
  made in this upload; omitted benchmarks remain active.
- `removed_benchmarks`: names to deactivate in a partial upload. A partial
  upload may contain only removals. Snapshot records do not use this keyword.
- `message`, `version`, `julia_version`: display metadata (commit subject,
  project version at that commit, Julia version); all optional.
- `fingerprint`: the measurement regime, defaulting to the current machine
  (see [`default_fingerprint`](@ref)).
"""
function make_record(benchmarks;
        commit::AbstractString,
        date::Union{Dates.DateTime, Integer},
        coverage::Symbol = :snapshot,
        removed_benchmarks = (),
        message::AbstractString = "",
        version::Union{AbstractString, Nothing} = nothing,
        julia_version::Union{AbstractString, Nothing} = string(VERSION),
        fingerprint::AbstractDict = default_fingerprint(),
    )
    sha = lowercase(String(commit))
    occursin(_COMMIT_RE, sha) || error("commit must be a 7–40 char hex sha, got $(repr(commit))")
    date isa Bool && error("date must be a UTC DateTime or integer unix seconds, got $(repr(date))")
    coverage in (:snapshot, :partial) ||
        error("coverage must be :snapshot or :partial, got $(repr(coverage))")
    du = date isa Integer ? Int(date) : floor(Int, Dates.datetime2unix(date))

    benches = Dict{String, Any}()
    for (name, stats) in _pairs(benchmarks)
        name isa Union{AbstractString, Symbol} && !isempty(string(name)) ||
            error("benchmark names must be non-empty strings, got $(repr(name))")
        entry = Dict{String, Any}()
        for (k, v) in _pairs(stats)
            k = string(k)
            k in _STAT_KEYS ||
                error("unknown statistic $(repr(k)) for benchmark $(repr(string(name))); expected one of: $(join(_STAT_KEYS, ", "))")
            v isa Real && !(v isa Bool) && isfinite(v) && v >= 0 ||
                error("statistic \"$k\" of benchmark $(repr(string(name))) must be a non-negative finite number, got $(repr(v))")
            entry[k] = v
        end
        isempty(entry) && error("benchmark $(repr(string(name))) has no statistics")
        benches[string(name)] = entry
    end
    removed = String[]
    for name in removed_benchmarks
        name isa Union{AbstractString, Symbol} && !isempty(string(name)) ||
            error("removed benchmark names must be non-empty strings, got $(repr(name))")
        key = string(name)
        key in removed && error("removed benchmark name $(repr(key)) is duplicated")
        haskey(benches, key) &&
            error("benchmark $(repr(key)) cannot be both measured and removed in one record")
        push!(removed, key)
    end
    coverage == :snapshot && !isempty(removed) &&
        error("removed_benchmarks is only valid with coverage = :partial")
    isempty(benches) && isempty(removed) &&
        error("record must measure or remove at least one benchmark")

    fp = Dict{String, Any}()
    for (key, value) in _pairs(fingerprint)
        value isa Union{AbstractString, Real, Nothing} ||
            error("fingerprint values must be strings, numbers, or nothing; got $(repr(value)) for $(repr(key))")
        value isa Real && !isfinite(value) &&
            error("fingerprint value $(repr(key)) must be finite, got $(repr(value))")
        fp[string(key)] = value
    end

    return Dict{String, Any}(
        "commit" => sha,
        "date" => Dates.format(Dates.unix2datetime(du), "yyyy-mm-ddTHH:MM:SS\\Z"),
        "date_unix" => du,
        "recorded_at" => _now_iso(),
        "message" => String(message),
        "version" => version === nothing ? nothing : String(version),
        "julia_version" => julia_version === nothing ? nothing : String(julia_version),
        "fingerprint" => fp,
        "benchmarks" => benches,
        "coverage" => String(coverage),
        "removed_benchmarks" => removed,
    )
end

"""
    add_record!(data_dir, record; package, repo_url, releases) -> data_dir

Merge one `record` (see [`make_record`](@ref)) into the benchmark history under
`data_dir`, creating the history if the directory is empty. Snapshot records
replace the same commit; partial records merge their measurements and explicit
removals into it. Partial merges require matching measurement fingerprints.

The optional keyword arguments update the manifest and are left untouched when
omitted. `package` is the display name in the dashboard header. `repo_url` is
the HTTPS base URL for commit links (e.g. `"https://github.com/me/MyPkg.jl"`);
pass `nothing` to disable repository links. `releases` is a vector of
`(tag = "v1.2.0", commit = sha, date_unix = seconds)`-shaped entries drawn as
release markers; the whole list is replaced, so pass `[]` to clear it.

Publish `data_dir` next to the assets from [`write_dashboard`](@ref):

```julia
rec = Tachometer.make_record(...)
Tachometer.add_record!("site/data", rec; package = "MyPkg.jl")
Tachometer.write_dashboard("site")
```
"""
function add_record!(data_dir, record::AbstractDict;
        package = missing, repo_url = missing, releases = missing)
    _validate_history_record(record)
    ismissing(package) || package === nothing || package isa AbstractString ||
        error("package must be a string or nothing")
    ismissing(repo_url) || repo_url === nothing ||
        (repo_url isa AbstractString && occursin(r"""^https://[^\s"'<>]+$""", repo_url)) ||
        error("repo_url must be an https:// URL or nothing")
    try
        JSON.json(record)
    catch e
        error("record is not valid JSON; refusing to modify the history ($(sprint(showerror, e)))")
    end

    initial_package = ismissing(package) ? nothing : package
    initial_repo_url = ismissing(repo_url) ? nothing : repo_url
    idx = _open_index(data_dir, initial_package, initial_repo_url)
    ismissing(package) || (idx["package"] = package)
    ismissing(repo_url) || (idx["repo_url"] = repo_url)
    ismissing(releases) || (idx["releases"] = _release_dicts(releases))
    _upsert_record!(data_dir, idx, record)
    _write_index(data_dir, idx)
    return data_dir
end

function _release_dicts(releases)
    out = Any[]
    for r in releases
        d = Dict{String, Any}(string(k) => v for (k, v) in _pairs(r))
        get(d, "tag", nothing) isa AbstractString ||
            error("each release needs a string tag, got $(repr(r))")
        commit = get(d, "commit", nothing)
        commit isa AbstractString && occursin(_COMMIT_RE, commit) ||
            error("each release needs a lowercase 7–40 char hex commit, got $(repr(r))")
        date_unix = get(d, "date_unix", nothing)
        valid_date = date_unix isa Real && !(date_unix isa Bool) && isfinite(date_unix) &&
            isinteger(date_unix) && typemin(Int) <= date_unix <= typemax(Int)
        valid_date ||
            error("each release needs integer date_unix seconds, got $(repr(r))")
        push!(out, Dict(
            "tag" => String(d["tag"]),
            "commit" => String(commit),
            "date_unix" => Int(date_unix),
        ))
    end
    return out
end
