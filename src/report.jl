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

# A Report should be useful when returned directly at the REPL. Keep this plain
# text (rather than printing the GitHub-only marker/details markup from `render`)
# and focus on changes; the full Markdown remains available explicitly.
function Base.show(io::IO, ::MIME"text/plain", r::Report)
    nreg = length(regressions(r))
    headline = r.status === :ok ? "no performance regressions" :
        r.status === :regressed ? "$(nreg) regression$(_s(nreg))" :
        r.status === :not_comparable ? "nothing to compare" :
        "benchmarks did not complete"
    println(io, "Tachometer: ", headline)

    if !isempty(r.meta.baseline_ref) || !isempty(r.meta.target_ref)
        baseline = isempty(r.meta.baseline_ref) ? "baseline" : r.meta.baseline_ref
        target = isempty(r.meta.target_ref) ? "target" : r.meta.target_ref
        println(io, "  ", baseline, " → ", target)
    end
    if r.status in (:not_comparable, :errored) && !isempty(r.message)
        print(io, "  ", replace(_tail(r.message; n = 8, chars = 1000), '\n' => "\n  "))
        return
    end

    changed = vcat(regressions(r), tradeoffs(r), improvements(r))
    max_rows = get(io, :limit, true) ? 20 : length(changed)
    for m in Iterators.take(changed, max_rows)
        icon = m.verdict === :regression ? "🔴" :
            m.verdict === :tradeoff ? "🟡" : "🟢"
        print(io, "  ", icon, " ", m.key, ": ", _time_cell(m))
        memory = _mem_cell(m)
        memory == "—" || print(io, "; ", memory)
        println(io)
    end
    length(changed) > max_rows &&
        println(io, "  … and ", length(changed) - max_rows, " more changes")

    extras = String[]
    ninvariant = length(invariants(r))
    ninvariant > 0 && push!(extras, "$(ninvariant) unchanged")
    nadded, nremoved = length(added(r)), length(removed(r))
    nadded > 0 && push!(extras, "$(nadded) added")
    nremoved > 0 && push!(extras, "$(nremoved) removed")
    isempty(extras) || print(io, "  ", join(extras, ", "))
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
    push!(parts, "$(_pct0(m.time_tolerance)) tolerance")
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
    println(io, "| | Benchmark | Time | Memory |")
    println(io, "|:--:|:--|:--|:--|")
    for m in shown
        println(io, "| $(_icon(m)) | `$(_safekey(m.key))` | $(_time_cell(m)) | $(_mem_cell(m)) |")
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
    println(io, "| | Benchmark | Time | Memory |")
    println(io, "|:--:|:--|:--|:--|")
    for m in sort(rows; by = x -> x.key)
        println(io, "| $(_icon(m)) | `$(_safekey(m.key))` | $(_time_cell(m)) | $(_mem_cell(m)) |")
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
        println(io, "- 🆕 `$(_safekey(m.key))` — added in target ($(prettytime(m.target.time)))")
    end
    for m in sort(d; by = x -> x.key)
        println(io, "- 🗑️ `$(_safekey(m.key))` — removed from target (was $(prettytime(m.baseline.time)))")
    end
    for m in sort(u; by = x -> x.key)
        println(io, "- ⚠️ `$(_safekey(m.key))` — ran in non-overlapping passes, not compared")
    end
    println(io, "\n</details>")
    return
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
    push!(parts, "min estimator")
    push!(parts, "tol $(_pct0(m.time_tolerance))/$(_pct0(m.memory_tolerance))")
    push!(parts, "floor $(prettytime(m.time_floor_ns))")
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
    t = (m.time_ratio === nothing || !isfinite(m.time_ratio)) ? 1.0 : m.time_ratio
    mem = (m.mem_ratio === nothing || !isfinite(m.mem_ratio)) ? 1.0 : m.mem_ratio
    return m.reason === :memory ? abs(mem - 1) : abs(t - 1)
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

_pct0(x) = @sprintf("%.0f%%", x * 100)
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
