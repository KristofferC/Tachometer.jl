# Emitting results for the GitHub Actions layer to consume.
#
# The Julia side does not talk to the GitHub API; it only writes files and step
# outputs. Crucially, the untrusted benchmark job writes `report.json` (a full,
# re-renderable serialization) and the *trusted* reporter re-renders the comment
# from it — it never trusts a `report.md` produced next to untrusted fork code.
# `report_from_dict` validates the shape and coerces numbers, so a hostile
# artifact can only supply structured data, not arbitrary comment markup.

"""
    write_report(dir, report) -> NamedTuple

Write `report.md` (a convenience rendering) and `report.json` (the full,
re-renderable serialization) into `dir`.
"""
function write_report(dir::AbstractString, r::Report; kwargs...)
    mkpath(dir)
    md = joinpath(dir, "report.md")
    json = joinpath(dir, "report.json")
    write(md, render(r; kwargs...))
    open(json, "w") do io
        JSON.print(io, report_to_dict(r), 2)
    end
    return (; md, json, status = r.status)
end

# JSON cannot carry NaN/Inf; map non-finite numbers to null.
_jsonnum(x) = (x isa Real && isfinite(x)) ? Float64(x) : nothing
_est_to_dict(e) = e === nothing ? nothing :
    Dict("time" => _jsonnum(e.time), "memory" => _jsonnum(e.memory), "allocs" => _jsonnum(e.allocs))

function report_to_dict(r::Report)
    m = r.meta
    return Dict(
        "schema" => "tachometer-report", "version" => 1,
        "status" => String(r.status), "message" => r.message,
        "meta" => Dict(
            "package" => m.package, "baseline_ref" => m.baseline_ref, "baseline_sha" => m.baseline_sha,
            "target_ref" => m.target_ref, "target_sha" => m.target_sha, "julia_version" => m.julia_version,
            "estimator" => m.estimator, "time_tolerance" => m.time_tolerance, "memory_tolerance" => m.memory_tolerance,
            "time_floor_ns" => m.time_floor_ns, "memory_floor_bytes" => m.memory_floor_bytes, "nruns" => m.nruns,
            "suite_changed" => m.suite_changed, "run_url" => m.run_url, "marker" => m.marker,
            "timestamp" => m.timestamp, "note" => m.note,
        ),
        "measurements" => [
            Dict(
                "key" => x.key, "baseline" => _est_to_dict(x.baseline), "target" => _est_to_dict(x.target),
                "time_ratio" => _jsonnum(x.time_ratio), "mem_ratio" => _jsonnum(x.mem_ratio),
                "verdict" => String(x.verdict), "reason" => String(x.reason),
                "confirmations" => x.confirmations, "nruns" => x.nruns,
                "eff_time_tol" => _jsonnum(x.eff_time_tol), "suppressed" => x.suppressed,
            ) for x in r.measurements
        ],
    )
end

# --- deserialization (trusted side): validate shape, coerce numbers -----------

const _VERDICTS = (:regression, :improvement, :invariant, :added, :removed, :uncompared)
const _REASONS = (:time, :memory, :both, :none)

_num_or(x, default) = (x isa Real && isfinite(x)) ? Float64(x) : default
_optnum(x) = (x isa Real && isfinite(x)) ? Float64(x) : nothing
_str(x) = x isa AbstractString ? String(x) : ""
_sym_in(x, allowed, default) = (x isa AbstractString && Symbol(x) in allowed) ? Symbol(x) : default

function _est_from_dict(d)
    d isa AbstractDict || return nothing
    return Estimate(_num_or(get(d, "time", nothing), 0.0), _num_or(get(d, "memory", nothing), 0.0),
        _num_or(get(d, "allocs", nothing), 0.0))
end

"""
    report_from_dict(d) -> Report

Reconstruct a [`Report`](@ref) from `report_to_dict` output, validating the shape
and coercing numeric fields. Used by the trusted reporter to re-render a comment
from an untrusted artifact without trusting its markdown.
"""
function report_from_dict(d)
    (d isa AbstractDict && get(d, "schema", nothing) == "tachometer-report") ||
        error("not a Tachometer report JSON")
    get(d, "version", nothing) == 1 || error("unsupported Tachometer report version")
    get(d, "measurements", []) isa AbstractVector || error("report measurements are malformed")
    md = get(d, "meta", Dict{String, Any}())
    md isa AbstractDict || error("report meta is malformed")
    meta = Meta(;
        package = _str(get(md, "package", "")), baseline_ref = _str(get(md, "baseline_ref", "")),
        baseline_sha = _str(get(md, "baseline_sha", "")), target_ref = _str(get(md, "target_ref", "")),
        target_sha = _str(get(md, "target_sha", "")), julia_version = _str(get(md, "julia_version", "")),
        estimator = _str(get(md, "estimator", "minimum")),
        time_tolerance = _num_or(get(md, "time_tolerance", nothing), 0.05),
        memory_tolerance = _num_or(get(md, "memory_tolerance", nothing), 0.01),
        time_floor_ns = _num_or(get(md, "time_floor_ns", nothing), 1000.0),
        memory_floor_bytes = _num_or(get(md, "memory_floor_bytes", nothing), 0.0),
        nruns = round(Int, _num_or(get(md, "nruns", nothing), 1)),
        suite_changed = get(md, "suite_changed", false) === true,
        run_url = _str(get(md, "run_url", "")), marker = _str(get(md, "marker", "tachometer")),
        timestamp = _str(get(md, "timestamp", "")), note = _str(get(md, "note", "")),
    )
    ms = Measurement[]
    for x in get(d, "measurements", [])
        x isa AbstractDict || continue
        push!(ms, Measurement(
            _str(get(x, "key", "")), _est_from_dict(get(x, "baseline", nothing)), _est_from_dict(get(x, "target", nothing)),
            _optnum(get(x, "time_ratio", nothing)), _optnum(get(x, "mem_ratio", nothing)),
            _sym_in(get(x, "verdict", nothing), _VERDICTS, :invariant),
            _sym_in(get(x, "reason", nothing), _REASONS, :none),
            round(Int, _num_or(get(x, "confirmations", nothing), 0)), round(Int, _num_or(get(x, "nruns", nothing), 1)),
            _num_or(get(x, "eff_time_tol", nothing), meta.time_tolerance), get(x, "suppressed", false) === true,
        ))
    end
    return Report(_sym_in(get(d, "status", nothing), (:ok, :regressed, :not_comparable, :errored), :errored), ms, meta, _str(get(d, "message", "")))
end

"""
    render_report_file(in_json, out_md; kwargs...)

Load a `report.json`, validate/reconstruct it, and write the rendered markdown to
`out_md`. This is what the trusted reporter runs.
"""
function render_report_file(in_json, out_md; marker = nothing, run_url = nothing, kwargs...)
    r = report_from_dict(JSON.parsefile(in_json))
    # Override untrusted, security-relevant meta with the reporter's trusted values:
    # the marker (must match the sticky search needle) and the run URL (a link).
    if (marker !== nothing && !isempty(marker)) || (run_url !== nothing && !isempty(run_url))
        m = r.meta
        r = Report(r.status, r.measurements,
            Meta(; package = m.package, baseline_ref = m.baseline_ref, baseline_sha = m.baseline_sha,
                target_ref = m.target_ref, target_sha = m.target_sha, julia_version = m.julia_version,
                estimator = m.estimator, time_tolerance = m.time_tolerance, memory_tolerance = m.memory_tolerance,
                time_floor_ns = m.time_floor_ns, memory_floor_bytes = m.memory_floor_bytes, nruns = m.nruns,
                suite_changed = m.suite_changed,
                run_url = (run_url === nothing || isempty(run_url)) ? m.run_url : String(run_url),
                marker = (marker === nothing || isempty(marker)) ? m.marker : String(marker),
                timestamp = m.timestamp, note = m.note),
            r.message)
    end
    write(out_md, render(r; kwargs...))
    return out_md
end

# Append `name=value` to the file named by $GITHUB_OUTPUT (a no-op off CI).
function set_output(name::AbstractString, value)
    path = get(ENV, "GITHUB_OUTPUT", "")
    isempty(path) && return
    open(path, "a") do io
        println(io, "$(name)=$(value)")
    end
    return
end

# A one-line status suitable for logs and the Actions step summary.
function oneline(r::Report)
    c = (length(regressions(r)), length(improvements(r)), length(suppressed(r)))
    return "status=$(r.status) regressions=$(c[1]) improvements=$(c[2]) suppressed=$(c[3])"
end
