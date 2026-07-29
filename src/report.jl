# Rendering a `Report` to a GitHub-flavoured markdown comment.
#
# With no regressions the output is a status line and a collapsed full-results
# table. With regressions, the changed benchmarks are shown first (slowest on
# top) with before -> after values and a signed percentage; unchanged, added,
# removed and suppressed benchmarks go into collapsed sections.

using Printf: @sprintf

const MARKER_PREFIX = "tachometer"

"""
    render(report; max_rows=8, byte_limit=60000) -> String

Render a [`Report`](@ref) to a markdown string suitable for a PR comment. The
first line is a hidden marker used to keep the comment sticky (updated in place).
Every change is shown when it fits; only if the body would exceed `byte_limit`
bytes are the collapsed sections dropped in favour of a pointer to the run —
and the changes table capped at `max_rows` if even that isn't enough.
"""
function render(r::Report; max_rows::Int = 8, byte_limit::Int = 60000)
    function base(cap, overflow_where)
        io = IOBuffer()
        println(io, "<!-- $(MARKER_PREFIX):$(_safemarker(r.meta.marker)) -->")
        _header(io, r)
        println(io)
        _subtitle(io, r)
        if r.status === :regressed || !isempty(improvements(r)) || !isempty(tradeoffs(r))
            println(io)
            _changes_table(io, r, cap, overflow_where)
        end
        return String(take!(io))
    end

    body_extras = IOBuffer()
    _suppressed_section(body_extras, r)
    _full_details(body_extras, r)
    _uncompared(body_extras, r)
    extras = String(take!(body_extras))

    footer = _footer(r)
    full = base(typemax(Int), "")

    # Measure bytes (not characters): GitHub's comment limit is in bytes, and the
    # reporter rejects oversized bodies by byte count too.
    sizeof(full) + sizeof(extras) + sizeof(footer) <= byte_limit && return full * extras * footer

    # Too long for a comment: drop the collapsed sections and point at the run
    # for detail.
    note = "\n<sub>Full results omitted (comment size limit) — see the " *
        (let u = _safeurl(r.meta.run_url); isempty(u) ? "workflow run" : "[workflow run]($(u))" end) *
        " artifact.</sub>\n"
    sizeof(full) + sizeof(note) + sizeof(footer) <= byte_limit && return full * note * footer
    # Still too long: the changes table itself is what's oversized — cap it. Its
    # overflow note points at the run artifact, since the full results it would
    # normally refer to are the very thing being dropped.
    return base(max_rows, "in the run artifact") * note * footer
end

# --- pieces ----------------------------------------------------------------

function _header(io, r::Report)
    ntrade = length(tradeoffs(r))
    trade = ntrade == 0 ? "" : "$(ntrade) memory trade-off$(_s(ntrade))"
    if r.status === :ok
        nimp = length(improvements(r))
        bits = filter(!isempty, [nimp == 0 ? "" : "$(nimp) improvement$(_s(nimp)) 🟢", trade])
        extra = isempty(bits) ? "" : " (" * join(bits, ", ") * ")"
        println(io, "### 🟢 Tachometer — no performance regressions detected", extra)
    elseif r.status === :regressed
        nreg = length(regressions(r))
        nimp = length(improvements(r))
        bits = filter(!isempty, [nimp == 0 ? "" : "$(nimp) improvement$(_s(nimp))", trade])
        extra = isempty(bits) ? "" : ", " * join(bits, ", ")
        println(io, "### 🔴 Tachometer — $(nreg) regression$(_s(nreg))$(extra)")
    elseif r.status === :not_comparable
        println(io, "### 🟡 Tachometer — nothing to compare")
    else # :errored
        println(io, "### 🟡 Tachometer — benchmarks did not complete")
    end
    if r.status in (:not_comparable, :errored) && !isempty(r.message)
        println(io)
        if r.status === :errored
            println(io, "```\n", _safemsg(r.message), "\n```")
        else
            println(io, _safetext(r.message))
        end
    end
    return
end

function _subtitle(io, r::Report)
    m = r.meta
    n = length(compared(r))
    parts = String[]
    push!(parts, "$(n) benchmark$(_s(n)) compared")
    # Nothing ran (no baseline, or the suite never started): skip the arrow rather
    # than printing a pair of empty backticks.
    if !isempty(m.baseline_sha) || !isempty(m.target_sha)
        repo = _repo_url(m.run_url)
        push!(parts, "$(_sha_or_ref(m.baseline_sha, m.baseline_ref, repo)) → $(_sha_or_ref(m.target_sha, m.target_ref, repo))")
    end
    push!(parts, "Julia $(_safetext(m.julia_version))")
    if m.backend in ("perf", "callgrind")
        push!(parts, "$(m.backend == "perf" ? "hardware" : "simulated") instruction counts")
        push!(parts, "$(_pct1(m.instr_tolerance)) instr tolerance")
        time_judged(m) && push!(parts, "$(_pct0(max(m.time_tolerance, m.time_guard_tolerance))) time guard")
    else
        push!(parts, "$(_pct0(m.time_tolerance)) tolerance")
    end
    m.nruns > 1 && push!(parts, "$(m.nruns)× runs")
    nsup = length(suppressed(r))
    nsup > 0 && push!(parts, "$(nsup) suppressed as noise")
    println(io, join(parts, " · "))
    if !isempty(m.note)
        println(io)
        println(io, "> ", _safetext(m.note))
    end
    if m.suite_changed
        println(io)
        println(io, "> ⚠️ The benchmark suite differs between the two revisions — ",
            "results may not be directly comparable.")
    end
    return
end

# Which columns a report's tables carry: Instructions only when any measurement
# has counts; Time unless the backend makes it meaningless (callgrind) — except
# that a report with neither counts nor judged time still shows Time rather
# than an empty table.
function _columns(r::Report)
    has_instr = any(m -> m.instr_ratio !== nothing, r.measurements)
    show_time = time_judged(r.meta) || !has_instr
    return has_instr, show_time
end

function _table_header(io, r::Report)
    has_instr, show_time = _columns(r)
    header = "| | Benchmark |" * (has_instr ? " Instructions |" : "") *
        (show_time ? " Time |" : "") * " Memory |"
    println(io, header)
    ncols = 1 + has_instr + show_time   # metric columns incl. Memory
    println(io, "|:--:|:--|", ":--|"^ncols)
    return
end

function _table_row(io, r::Report, m::Measurement)
    has_instr, show_time = _columns(r)
    cells = String[]
    has_instr && push!(cells, _instr_cell(m))
    show_time && push!(cells, _time_cell(m))
    push!(cells, _mem_cell(m))
    println(io, "| $(_icon(m)) | `$(_safekey(m.key))` | ", join(cells, " | "), " |")
    return
end

# Single table of everything that moved: regressions (worst first), then memory
# trade-offs, then improvements. One icon per row. Only capped as a last resort
# against the comment size limit, in which case `overflow_where` says where the
# cut rows can still be found.
function _changes_table(io, r::Report, max_rows::Int, overflow_where::String)
    regs = sort(regressions(r); by = m -> -_sortkey(m))   # biggest regression first
    trds = sort(tradeoffs(r); by = m -> -_sortkey(m))
    imps = sort(improvements(r); by = m -> -_sortkey(m))  # biggest improvement first
    rows = vcat(regs, trds, imps)

    shown = rows[1:min(max_rows, length(rows))]
    _table_header(io, r)
    for m in shown
        _table_row(io, r, m)
    end
    hidden = length(rows) - length(shown)
    hidden > 0 && println(io, "\n<sub>… and $(hidden) more change$(_s(hidden)) $(overflow_where).</sub>")
    return
end

_icon(m::Measurement) = m.verdict === :regression ? "🔴" :
    m.verdict === :improvement ? "🟢" : m.verdict === :tradeoff ? "🟡" : "⚪️"

function _full_details(io, r::Report)
    rows = compared(r)
    isempty(rows) && return
    n = length(rows)
    println(io, "\n<details><summary>Full results ($(n) benchmark$(_s(n)))</summary>\n")
    _table_header(io, r)
    for m in sort(rows; by = x -> x.key)
        _table_row(io, r, m)
    end
    println(io, "\n</details>")
    return
end

function _suppressed_section(io, r::Report)
    sup = suppressed(r)
    isempty(sup) && return
    n = length(sup)
    println(io, "\n<details><summary>Suppressed as noise ($(n)) — crossed the tolerance but within the learned noise band</summary>\n")
    println(io, "| Benchmark | Time | Learned band |")
    println(io, "|:--|:--|:--|")
    for m in sort(sup; by = x -> x.key)
        band = @sprintf("±%.0f%%", m.eff_time_tol * 100)
        println(io, "| `$(_safekey(m.key))` | $(prettytime(m.baseline.time)) → $(prettytime(m.target.time)) ($(_signed_pct(m.time_ratio))) | $(band) |")
    end
    println(io, "\n</details>")
    return
end

function _uncompared(io, r::Report)
    a = added(r)
    d = removed(r)
    u = filter(m -> m.verdict === :uncompared, r.measurements)
    (isempty(a) && isempty(d) && isempty(u)) && return
    tot = length(a) + length(d) + length(u)
    println(io, "\n<details><summary>Uncompared benchmarks ($(tot))</summary>\n")
    for m in sort(a; by = x -> x.key)
        println(io, "- 🆕 `$(_safekey(m.key))` — added in target ($(_solo_value(r, m.target)))")
    end
    for m in sort(d; by = x -> x.key)
        println(io, "- 🗑️ `$(_safekey(m.key))` — removed from target (was $(_solo_value(r, m.baseline)))")
    end
    for m in sort(u; by = x -> x.key)
        println(io, "- ⚠️ `$(_safekey(m.key))` — ran in non-overlapping passes, not compared")
    end
    println(io, "\n</details>")
    return
end

# The one-number description of a benchmark that exists on only one side:
# instructions when time is not meaningful (callgrind), wall time otherwise.
function _solo_value(r::Report, e::Estimate)
    (!time_judged(r.meta) && hasinstr(e)) && return prettycount(e.instructions) * " insns"
    return prettytime(e.time)
end

# "baseline `389ecb7` (master)" — the ref in parentheses only earns its place when
# it names something the SHA doesn't. The action resolves refs to SHAs before
# calling, so the common case would otherwise read "`389ecb7` (389ecb7…)".
function _revision_part(label, sha, ref, repo = "")
    part = "$(label) $(_sha_or_ref(sha, ref, repo))"
    (isempty(sha) || isempty(strip(ref)) || _same_commit(strip(ref), sha)) && return part
    return part * " ($(_safetext(strip(ref))))"
end

# The SHA when there is one — linked to its commit when the repository is known —
# else whatever name we have for the revision.
function _sha_or_ref(sha, ref, repo = "")
    isempty(sha) && return isempty(strip(ref)) ? "unknown" : "`$(_safetext(strip(ref)))`"
    code = "`$(_safetext(_short_sha(sha)))`"
    base = first(split(sha, '+'))   # a "+dirty" working tree still sits on this commit
    (isempty(repo) || !occursin(r"^[0-9a-fA-F]{7,40}$", base)) && return code
    return "[$(code)]($(repo)/commit/$(base))"
end

# The repository the comparison ran in, recovered from the workflow-run URL.
# Only a URL that passed `_safeurl` is consulted, so the capture is safe to
# embed as a link target.
function _repo_url(run_url)
    m = match(r"^(https://github\.com/[^/]+/[^/]+)/actions/", _safeurl(run_url))
    return m === nothing ? "" : String(m.captures[1])
end

# Abbreviate the SHA but keep the "+dirty" marker a working-tree target carries:
# plain `_short` would cut it off, hiding that the measured source had
# uncommitted changes — the one thing that makes the run unreproducible.
function _short_sha(sha::AbstractString)
    parts = split(sha, '+'; limit = 2)
    return length(parts) == 2 ? _short(parts[1]) * "+" * parts[2] : _short(sha)
end

# Whether `ref` is just the commit written out: a hex string that is a prefix of
# the SHA, or of which the SHA is a prefix (either side may be abbreviated).
function _same_commit(ref::AbstractString, sha::AbstractString)
    sha = first(split(sha, '+'))   # drop the "+dirty" marker on a working-tree target
    (isempty(ref) || isempty(sha)) && return false
    occursin(r"^[0-9a-fA-F]{4,40}$", ref) || return false
    a, b = lowercase(ref), lowercase(sha)
    return startswith(a, b) || startswith(b, a)
end

function _footer(r::Report)
    m = r.meta
    io = IOBuffer()
    parts = String[]
    repo = _repo_url(m.run_url)
    push!(parts, _revision_part("baseline", m.baseline_sha, m.baseline_ref, repo))
    push!(parts, _revision_part("target", m.target_sha, m.target_ref, repo))
    push!(parts, "Julia $(_safetext(m.julia_version))")
    isempty(m.cpu) || push!(parts, _safetext(m.cpu))
    isempty(m.backend) || push!(parts, "$(m.backend) backend")
    push!(parts, "min estimator")
    if m.backend in ("perf", "callgrind")
        tguard = time_judged(m) ? " / $(_pct0(max(m.time_tolerance, m.time_guard_tolerance))) time guard" : ""
        push!(parts, "tol $(_pct1(m.instr_tolerance)) instr$(tguard) / $(_pct0(m.memory_tolerance)) mem")
        push!(parts, "floor $(prettycount(m.instr_floor)) insns")
    else
        push!(parts, "tol $(_pct0(m.time_tolerance))/$(_pct0(m.memory_tolerance))")
        push!(parts, "floor $(prettytime(m.time_floor_ns))")
    end
    time_judged(m) || push!(parts, "wall time not judged (simulated run)")
    m.nruns > 1 && push!(parts, "$(m.nruns)× runs")
    let u = _safeurl(m.run_url)
        isempty(u) || push!(parts, "[run]($(u))")
    end
    println(io, "\n<sub>", join(parts, " · "), " · Tachometer.jl</sub>")
    return String(take!(io))
end

# --- cells -----------------------------------------------------------------

function _time_cell(m::Measurement)
    (m.baseline === nothing || m.target === nothing) && return "—"
    b, t = m.baseline.time, m.target.time
    return "$(prettytime(b)) → $(prettytime(t)) ($(_signed_pct(m.time_ratio)))"
end

function _instr_cell(m::Measurement)
    (m.baseline === nothing || m.target === nothing || m.instr_ratio === nothing) && return "—"
    b, t = m.baseline.instructions, m.target.instructions
    return "$(prettycount(b)) → $(prettycount(t)) ($(_signed_pct1(m.instr_ratio)))"
end

function _mem_cell(m::Measurement)
    (m.baseline === nothing || m.target === nothing) && return "—"
    b, t = m.baseline.memory, m.target.memory
    if b == 0 && t == 0
        return "—"
    elseif b == 0 && t > 0
        return "0 B → $(prettymemory(t)) 🆕"
    end
    # Only surface memory when it actually moved beyond tolerance.
    moved = m.reason in (:memory, :both) || abs(m.mem_ratio - 1) > 0.01
    moved || return "—"
    return "$(prettymemory(b)) → $(prettymemory(t)) ($(_signed_pct(m.mem_ratio)))"
end

# Sort key: how far the change is from no-change, biased toward the metric that
# triggered the verdict.
function _sortkey(m::Measurement)
    dist(r) = (r === nothing || !isfinite(r)) ? 0.0 : abs(r - 1)
    return m.reason === :memory ? dist(m.mem_ratio) :
        m.reason === :instructions ? dist(m.instr_ratio) :
        m.reason === :multiple ? max(dist(m.instr_ratio), dist(m.time_ratio), dist(m.mem_ratio)) :
        m.instr_ratio !== nothing && m.reason !== :time ? dist(m.instr_ratio) : dist(m.time_ratio)
end

# --- formatting ------------------------------------------------------------

function prettytime(ns::Real)
    ns < 0 && return "-" * prettytime(-ns)
    if ns < 1e3
        return @sprintf("%.0f ns", ns)
    elseif ns < 1e6
        return @sprintf("%.3g µs", ns / 1e3)
    elseif ns < 1e9
        return @sprintf("%.3g ms", ns / 1e6)
    else
        return @sprintf("%.3g s", ns / 1e9)
    end
end

function prettymemory(bytes::Real)
    if bytes < 1024
        return @sprintf("%.0f B", bytes)
    elseif bytes < 1024^2
        return @sprintf("%.3g KiB", bytes / 1024)
    elseif bytes < 1024^3
        return @sprintf("%.3g MiB", bytes / 1024^2)
    else
        return @sprintf("%.3g GiB", bytes / 1024^3)
    end
end

function _signed_pct(ratio)
    ratio === nothing && return "—"
    pct = (ratio - 1) * 100
    s = pct >= 0 ? "+" : "−"
    return @sprintf("%s%.0f%%", s, abs(pct))
end

# Instruction changes are judged at ~1%, so one decimal keeps sub-percent
# changes visible instead of rounding to +0%.
function _signed_pct1(ratio)
    ratio === nothing && return "—"
    pct = (ratio - 1) * 100
    s = pct >= 0 ? "+" : "−"
    return abs(pct) < 10 ? @sprintf("%s%.1f%%", s, abs(pct)) : @sprintf("%s%.0f%%", s, abs(pct))
end

function prettycount(x::Real)
    isfinite(x) || return "—"
    if x >= 1e9
        return @sprintf("%.3g G", x / 1e9)
    elseif x >= 1e6
        return @sprintf("%.3g M", x / 1e6)
    elseif x >= 1e3
        return @sprintf("%.3g k", x / 1e3)
    else
        return @sprintf("%.0f", x)
    end
end

_pct0(x) = @sprintf("%.0f%%", x * 100)
_pct1(x) = x * 100 == round(x * 100) ? @sprintf("%.0f%%", x * 100) : @sprintf("%.1f%%", x * 100)
_s(n) = n == 1 ? "" : "s"

# Benchmark keys are author-controlled text embedded in inline code and tables.
# Neutralise what could break the table, the inline-code span, or the sticky
# marker: backticks, pipes, and HTML-comment delimiters.
function _safekey(s::AbstractString)
    s = replace(s, r"[\x00-\x1f\x7f]" => " ")   # control chars incl. CR/LF/TAB: would break the row
    s = replace(s, '`' => 'ˋ', '|' => '∣')
    s = replace(s, "<!--" => "<!‑‑", "-->" => "‑‑>")
    return s
end

# Inline meta text (refs, notes, shas, version) may originate from an untrusted
# report.json on the trusted re-render path. Neutralise markup, comment markers,
# @mentions, and markdown link/image syntax so nothing renders as a link, image,
# heading, or mention.
function _safetext(s)
    t = replace(String(s), r"[\x00-\x1f\x7f]" => " ")
    # Escape raw HTML/autolinks first — GitHub renders a whitelist of inline HTML
    # (<a>, <img>, <https://…>), so entity-escaping neutralises those too.
    t = replace(t, '&' => "&amp;", '<' => "&lt;", '>' => "&gt;")
    t = replace(t, '`' => 'ˋ', '|' => '∣')
    t = replace(t, '[' => '［', ']' => '］', '(' => '（', ')' => '）', '!' => '！')
    t = replace(t, "@" => "@​")
    return t
end

# The sticky marker is embedded raw in an HTML comment, so it must be a strict
# safe token; anything else falls back to the default (never breaks out).
_safemarker(s) = occursin(r"^[A-Za-z0-9._-]+$", String(s)) ? String(s) : "tachometer"

# Only emit a link for a plain https URL; otherwise "" (drop the link).
_safeurl(u) = occursin(r"^https://[^\s\"'<>)]+$", String(u)) ? String(u) : ""

# Show an untrusted message as a fenced code block that it cannot break out of.
function _safemsg(s)
    t = replace(String(s), r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]" => " ")
    # Defang code-fence breakout, mentions, and any embedded sticky marker (the
    # comment search matches marker text anywhere in the body).
    t = replace(t, "```" => "'''", "@" => "@​", "<!--" => "<!‑‑", "-->" => "‑‑>")
    length(t) > 4000 && (t = "…" * last(t, 4000))
    return t
end

"""
    marker(name="tachometer") -> String

The hidden HTML marker used to find and update the sticky comment. Namespace it
(e.g. per Julia version in a matrix build) to avoid distinct jobs clobbering each
other's comment.
"""
marker(name::AbstractString = "tachometer") = "<!-- $(MARKER_PREFIX):$(name) -->"
