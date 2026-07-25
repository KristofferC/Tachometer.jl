using Tachometer
using Test
using Dates

using Tachometer: Estimate, Measurement, Meta, Report, RevisionRun, NoiseModel,
    _judge, _classify_time, _classify_memory, _combine, _as_ns, build_noise_from_history,
    effective_time_tolerance, prettytime, prettymemory, _signed_pct,
    regressions, improvements, invariants, added, removed, suppressed,
    project_version, last_release_tag, _release_baseline, WORKINGTREE,
    load_index, load_shard, load_all_records, _releases, _shard_name, write_dashboard,
    report_to_dict, report_from_dict

# Build a RevisionRun from a plain key => (time, memory[, allocs]) mapping.
function mkrun(pairs...; sha = "0123456789", hash = "h", ok = true)
    est = Dict{String, Estimate}()
    for (k, v) in pairs
        t, m = v[1], v[2]
        a = length(v) >= 3 ? v[3] : 0.0
        est[k] = Estimate(Float64(t), Float64(m), Float64(a))
    end
    return RevisionRun(sha, false, est, hash, ok, "")
end

judge(base, targ; kw...) = _judge([base], [targ], NoiseModel();
    time_tolerance = 0.05, memory_tolerance = 0.01, time_floor = 1000.0,
    memory_floor = 0.0, nruns = 1, kw...)

meta() = Meta(; package = "Demo", baseline_ref = "master",
    baseline_sha = "aaaaaaa000", target_ref = "working tree",
    target_sha = "bbbbbbb111", julia_version = "1.11.0", timestamp = "now")

@testset "Tachometer" begin

    @testset "time-floor parsing" begin
        @test _as_ns(1234) == 1234.0
        @test _as_ns("500ns") == 500.0
        @test _as_ns("1us") == 1000.0
        @test _as_ns("2µs") == 2000.0
        @test _as_ns("3ms") == 3.0e6
        @test _as_ns("1s") == 1.0e9
        @test _as_ns("100") == 100.0
    end

    @testset "classification" begin
        # Clear regression: +40%, well above the 1 µs floor.
        ms = judge(mkrun("g/a" => (10_000, 0)), mkrun("g/a" => (14_000, 0)))
        @test only(ms).verdict === :regression
        @test only(ms).reason === :time
        @test only(ms).time_ratio ≈ 1.4

        # Clear improvement.
        ms = judge(mkrun("g/a" => (14_000, 0)), mkrun("g/a" => (10_000, 0)))
        @test only(ms).verdict === :improvement

        # Within tolerance -> invariant.
        ms = judge(mkrun("g/a" => (10_000, 0)), mkrun("g/a" => (10_200, 0)))
        @test only(ms).verdict === :invariant

        # Big *ratio* but tiny absolute change below the floor -> invariant.
        ms = judge(mkrun("g/fast" => (100, 0)), mkrun("g/fast" => (150, 0)))
        @test only(ms).verdict === :invariant  # 50% but only 50 ns < 1 µs floor

        # Same jump above a lowered floor -> regression.
        ms = _judge([mkrun("g/fast" => (100, 0))], [mkrun("g/fast" => (150, 0))],
            NoiseModel(); time_tolerance = 0.05, memory_tolerance = 0.01,
            time_floor = 10.0, memory_floor = 0.0, nruns = 1)
        @test only(ms).verdict === :regression
    end

    @testset "memory rules" begin
        # Zero-allocation baseline turning non-zero is always a regression.
        ms = judge(mkrun("g/a" => (10_000, 0)), mkrun("g/a" => (10_000, 64)))
        @test only(ms).verdict === :regression
        @test only(ms).reason === :memory

        # Memory shrinks -> improvement (time unchanged).
        ms = judge(mkrun("g/a" => (10_000, 1024)), mkrun("g/a" => (10_000, 512)))
        @test only(ms).verdict === :improvement
    end

    @testset "added / removed" begin
        ms = judge(mkrun("g/a" => (10_000, 0)),
            mkrun("g/a" => (10_000, 0), "g/new" => (5_000, 0)))
        @test any(m -> m.key == "g/new" && m.verdict === :added, ms)

        ms = judge(mkrun("g/a" => (10_000, 0), "g/old" => (5_000, 0)),
            mkrun("g/a" => (10_000, 0)))
        @test any(m -> m.key == "g/old" && m.verdict === :removed, ms)
    end

    @testset "paired reruns require agreement" begin
        # One run regresses, the other does not -> not confirmed -> invariant.
        base = [mkrun("g/a" => (10_000, 0)), mkrun("g/a" => (10_000, 0))]
        targ = [mkrun("g/a" => (14_000, 0)), mkrun("g/a" => (10_100, 0))]
        ms = _judge(base, targ, NoiseModel(); time_tolerance = 0.05,
            memory_tolerance = 0.01, time_floor = 1000.0, memory_floor = 0.0, nruns = 2)
        @test only(ms).verdict === :invariant

        # Both runs regress -> confirmed regression, 2/2.
        targ2 = [mkrun("g/a" => (14_000, 0)), mkrun("g/a" => (13_500, 0))]
        ms = _judge(base, targ2, NoiseModel(); time_tolerance = 0.05,
            memory_tolerance = 0.01, time_floor = 1000.0, memory_floor = 0.0, nruns = 2)
        @test only(ms).verdict === :regression
        @test only(ms).confirmations == 2
    end

    # Build master time-series records (as stored in shards) for the noise model.
    tsrec(times...) = Dict("benchmarks" => Dict(k => Dict("time" => float(t)) for (k, t) in times))

    @testset "noise model (from master history)" begin
        # A benchmark that swings run-to-run on master learns a wide band; a stable
        # one keeps the global tolerance.
        recs = [tsrec("g/jittery" => t, "g/stable" => 1000.0)
                for t in (1000.0, 1300.0, 950.0, 1250.0, 1050.0, 800.0)]
        model = build_noise_from_history(recs; min_samples = 5, factor = 3.0, cap = 0.5)
        @test effective_time_tolerance(model, "g/jittery", 0.05) > 0.3
        @test effective_time_tolerance(model, "g/stable", 0.05) == 0.05

        # Too few samples -> global tolerance.
        model2 = build_noise_from_history([tsrec("g/x" => 1.0), tsrec("g/x" => 1.3)]; min_samples = 5)
        @test effective_time_tolerance(model2, "g/x", 0.05) == 0.05

        # The learned band is CAPPED so a large real regression always fires.
        wild = build_noise_from_history([tsrec("g/w" => t) for t in (1.0, 5.0, 1.0, 6.0, 1.0, 7.0)];
            min_samples = 5, factor = 3.0, cap = 0.5)
        @test effective_time_tolerance(wild, "g/w", 0.05) <= 0.5

        # A 15% PR "regression" on the jittery benchmark is suppressed, not reported.
        ms = _judge([mkrun("g/jittery" => (10_000, 0))], [mkrun("g/jittery" => (11_500, 0))], model;
            time_tolerance = 0.05, memory_tolerance = 0.01, time_floor = 1000.0, memory_floor = 0.0, nruns = 1)
        @test only(ms).verdict === :invariant && only(ms).suppressed

        # A regression larger than the cap still fires despite the noise band.
        ms2 = _judge([mkrun("g/jittery" => (10_000, 0))], [mkrun("g/jittery" => (18_000, 0))], model;
            time_tolerance = 0.05, memory_tolerance = 0.01, time_floor = 1000.0, memory_floor = 0.0, nruns = 1)
        @test only(ms2).verdict === :regression

        # Regime filter: the band is learned only from records of the matching
        # regime. Here 1.10 is stable and 1.11 is jittery.
        fp(j) = Dict("os" => "Linux", "arch" => "x86_64", "julia" => j, "threads" => 1)
        mixed = [Dict("fingerprint" => fp(j), "benchmarks" => Dict("g/a" => Dict("time" => t)))
                 for (j, t) in (("1.10", 100.0), ("1.10", 100.0), ("1.10", 100.0), ("1.10", 100.0),
                                ("1.11", 100.0), ("1.11", 150.0), ("1.11", 90.0), ("1.11", 140.0), ("1.11", 100.0))]
        stable = build_noise_from_history(mixed; regime = ("Linux", "x86_64", "1.10", "1"), min_samples = 3)
        jittery = build_noise_from_history(mixed; regime = ("Linux", "x86_64", "1.11", "1"), min_samples = 3)
        @test effective_time_tolerance(stable, "g/a", 0.05) == 0.05    # stable regime keeps global tol
        @test effective_time_tolerance(jittery, "g/a", 0.05) > 0.3     # jittery regime widens
    end

    @testset "paired alignment and display consistency" begin
        # g/a present in both baseline passes but only target pass 1: only one of
        # the two requested passes is comparable, so a change CANNOT be confirmed
        # across all nruns -> invariant (no false "confirmed" regression).
        base = [mkrun("g/a" => (10_000, 0)), mkrun("g/a" => (10_000, 0))]
        targ = [mkrun("g/a" => (14_000, 0)), mkrun("other" => (1, 0))]
        ms = _judge(base, targ, NoiseModel(); time_tolerance = 0.05,
            memory_tolerance = 0.01, time_floor = 1000.0, memory_floor = 0.0, nruns = 2)
        ga = only(filter(m -> m.key == "g/a", ms))
        @test ga.verdict === :invariant

        # When both requested passes are present and regress, it is confirmed 2/2.
        targ_full = [mkrun("g/a" => (14_000, 0)), mkrun("g/a" => (13_800, 0))]
        ms_full = _judge(base, targ_full, NoiseModel(); time_tolerance = 0.05,
            memory_tolerance = 0.01, time_floor = 1000.0, memory_floor = 0.0, nruns = 2)
        gaf = only(filter(m -> m.key == "g/a", ms_full))
        @test gaf.verdict === :regression && gaf.confirmations == 2 && gaf.nruns == 2

        # No aligned pair at all -> :uncompared, and NOT counted as a comparison.
        base2 = [mkrun("g/a" => (10_000, 0)), mkrun("x" => (1, 0))]
        targ2 = [mkrun("y" => (1, 0)), mkrun("g/a" => (11_000, 0))]  # g/a never in same pass
        ms2 = _judge(base2, targ2, NoiseModel(); time_tolerance = 0.05,
            memory_tolerance = 0.01, time_floor = 1000.0, memory_floor = 0.0, nruns = 2)
        @test only(filter(m -> m.key == "g/a", ms2)).verdict === :uncompared

        # Displayed ratio equals target/baseline of the shown absolutes.
        m = only(judge(mkrun("g/a" => (10_000, 0)), mkrun("g/a" => (14_000, 0))))
        @test m.time_ratio ≈ m.target.time / m.baseline.time
    end

    @testset "memory needs unanimous passes" begin
        # A mixed history (0→0 in one pass, 100→200 in the other) is NOT a
        # regression — the invariant pass blocks unanimity.
        base = [mkrun("g/a" => (10_000, 0)), mkrun("g/a" => (10_000, 100))]
        targ = [mkrun("g/a" => (10_000, 0)), mkrun("g/a" => (10_000, 200))]
        ms = _judge(base, targ, NoiseModel(); time_tolerance = 0.05,
            memory_tolerance = 0.01, time_floor = 1000.0, memory_floor = 0.0, nruns = 2)
        @test only(ms).verdict === :invariant

        # Zero-allocation baseline turning non-zero is ALWAYS a regression, even
        # with a large memory floor (the floor applies only to nonzero baselines).
        ms2 = _judge([mkrun("g/a" => (10_000, 0))], [mkrun("g/a" => (10_000, 64))],
            NoiseModel(); time_tolerance = 0.05, memory_tolerance = 0.01,
            time_floor = 1000.0, memory_floor = 128.0, nruns = 1)
        @test only(ms2).verdict === :regression && only(ms2).reason === :memory
    end

    @testset "key sanitisation" begin
        E(t) = Estimate(float(t), 0.0, 0.0)
        bad = "grp/a|b`c<!-- tachometer:x -->"
        ms = [Measurement(bad, E(10_000), E(14_000), 1.4, 1.0, :regression, :time, 1, 1, 0.05, false)]
        out = render(Report(:regressed, ms, meta(), ""))
        @test !occursin("<!-- tachometer:x -->", replace(out, "<!-- tachometer:tachometer -->" => ""))
        @test !occursin("a|b", out)   # raw pipe would break the table
    end

    @testset "release baseline" begin
        dir = mktempdir()
        gitc(args...) = run(`git -C $dir -c user.email=t@t.co -c user.name=t $(collect(args))`)
        gitc("init", "-q")
        write(joinpath(dir, "Project.toml"), "name = \"P\"\nuuid = \"x\"\nversion = \"0.1.0\"\n")
        gitc("add", "-A"); gitc("commit", "-q", "-m", "v0.1.0")
        gitc("tag", "v0.1.0")
        # Bump the version in the working tree.
        write(joinpath(dir, "Project.toml"), "name = \"P\"\nuuid = \"x\"\nversion = \"0.2.0\"\n")

        @test project_version(dir, WORKINGTREE) == v"0.2.0"
        @test project_version(dir, "HEAD") == v"0.1.0"
        @test last_release_tag(dir, WORKINGTREE) == "v0.1.0"

        # Version bumped -> baseline swapped to the last release tag, with a note.
        nb, note = _release_baseline(dir, "HEAD", WORKINGTREE)
        @test nb == "v0.1.0"
        @test occursin("0.1.0", note) && occursin("0.2.0", note)

        # No bump -> baseline untouched, no note.
        nb2, note2 = _release_baseline(dir, "HEAD", "HEAD")
        @test nb2 == "HEAD" && isempty(note2)

        # A version *downgrade* does not trigger the gate.
        write(joinpath(dir, "Project.toml"), "name = \"P\"\nuuid = \"x\"\nversion = \"0.0.9\"\n")
        nb3, note3 = _release_baseline(dir, "HEAD", WORKINGTREE)
        @test nb3 == "HEAD" && isempty(note3)

        # If the target commit is itself tagged, it is not compared against its
        # own tag: below=target-version excludes it, leaving the previous release.
        write(joinpath(dir, "Project.toml"), "name = \"P\"\nuuid = \"x\"\nversion = \"0.2.0\"\n")
        gitc("commit", "-q", "-am", "v0.2.0")
        gitc("tag", "v0.2.0")
        @test last_release_tag(dir, "HEAD") == "v0.2.0"                 # highest reachable
        @test last_release_tag(dir, "HEAD"; below = v"0.2.0") == "v0.1.0"  # previous release

        # A stray non-semver tag is ignored.
        gitc("tag", "v-nightly")
        @test last_release_tag(dir, "HEAD") == "v0.2.0"

        # No Project.toml on one side -> no gate, no error.
        bare = mktempdir()
        run(`git -C $bare -c user.email=t@t.co -c user.name=t init -q`)
        write(joinpath(bare, "x.txt"), "hi")
        run(`git -C $bare -c user.email=t@t.co -c user.name=t add -A`)
        run(`git -C $bare -c user.email=t@t.co -c user.name=t commit -q -m init`)
        nb4, note4 = _release_baseline(bare, "HEAD", WORKINGTREE)
        @test nb4 == "HEAD" && isempty(note4)
    end

    @testset "timeseries sharding" begin
        # A missing index starts fresh; a present-but-incompatible one fails closed.
        d1 = mktempdir()
        @test isempty(load_index(d1, "P", "url")["shards"])
        d2 = mktempdir(); write(joinpath(d2, "index.json"), "{\"foo\": 1}")
        @test_throws ErrorException load_index(d2, "P", "url")
        d3 = mktempdir(); write(joinpath(d3, "index.json"), "not json{")
        @test_throws ErrorException load_index(d3, "P", "url")

        # Records land in the shard for their calendar year.
        @test _shard_name(round(Int, Dates.datetime2unix(DateTime(2026, 3, 1)))) == "shard-2026"
        @test _shard_name(round(Int, Dates.datetime2unix(DateTime(2024, 12, 31)))) == "shard-2024"

        # write_dashboard copies the (overwriteable) assets.
        dd = mktempdir()
        write_dashboard(dd)
        @test isfile(joinpath(dd, "index.html")) && isfile(joinpath(dd, "uPlot.iife.min.js"))

        # load_shard on a malformed shard fails closed.
        d4 = mktempdir(); write(joinpath(d4, "shard-2026.json"), "{\"records\": 3}")
        @test_throws ErrorException load_shard(d4, "shard-2026")

        # load_all_records is read-only and lenient: missing/foreign dir -> empty.
        @test isempty(load_all_records(mktempdir()))
        d5 = mktempdir()
        write(joinpath(d5, "index.json"), "{\"schema\":\"tachometer-timeseries\",\"version\":2,\"shards\":[\"shard-2025\",\"shard-2026\"]}")
        write(joinpath(d5, "shard-2025.json"), "{\"records\":[{\"commit\":\"a\",\"date_unix\":10,\"benchmarks\":{}}]}")
        write(joinpath(d5, "shard-2026.json"), "{\"records\":[{\"commit\":\"b\",\"date_unix\":20,\"benchmarks\":{}}]}")
        recs = load_all_records(d5)
        @test [r["commit"] for r in recs] == ["a", "b"]   # concatenated, chronological
    end

    @testset "release list from tags" begin
        r = mktempdir()
        g(a...) = run(`git -C $r -c user.email=t@t.co -c user.name=t $(collect(a))`)
        g("init", "-q")
        write(joinpath(r, "f"), "x"); g("add", "-A"); g("commit", "-q", "-m", "c1")
        g("tag", "v1.0.0"); g("tag", "not-a-release")
        write(joinpath(r, "f"), "y"); g("commit", "-q", "-am", "c2")
        g("tag", "v1.1.0")
        rels = _releases(r)
        @test [x["tag"] for x in rels] == ["v1.0.0", "v1.1.0"]   # strict vX.Y.Z, sorted by version
        @test all(x -> occursin(r"^[0-9a-f]{40}$", x["commit"]), rels)
        @test rels[2]["commit"] == readchomp(`git -C $r rev-parse HEAD`)
    end

    @testset "report json round-trip (trusted re-render)" begin
        ms = judge(mkrun("g/hot" => (10_000, 0)), mkrun("g/hot" => (14_500, 512)))
        r = Report(:regressed, ms, meta(), "")
        r2 = report_from_dict(report_to_dict(r))
        @test render(r2) == render(r)               # survives a round-trip
        # A hostile report.json cannot inject markup/mentions/links via ANY string
        # field — marker, julia_version, note, refs, message.
        d = report_to_dict(r)
        d["meta"]["marker"] = "x --></summary>## Fake ping @everyone [click](https://evil)<!--"
        d["meta"]["julia_version"] = "1.11 <a href=\"https://evil\">x</a>"
        d["meta"]["note"] = "ping @maintainer <!-- tachometer:evil --> `x`|y [l](https://evil) <img src=\"https://track\"> <https://auto.evil>"
        d["meta"]["baseline_ref"] = "[r](https://evil)"
        d["meta"]["run_url"] = "javascript:alert(1)"
        d["measurements"][1]["key"] = "grp/a|b`c"
        out = render(report_from_dict(d))
        @test !occursin("@maintainer", out) && !occursin("@everyone", out)   # mentions defanged
        @test !occursin("<!-- tachometer:evil -->", out)
        @test !occursin("](https://evil)", out) && !occursin("](https://track)", out)  # no markdown links/images
        @test !occursin("<a href", out) && !occursin("<img", out)            # no raw HTML
        @test !occursin("<https://auto.evil>", out)                          # no autolink
        @test !occursin("javascript:", out)                                  # bad run_url dropped
        @test occursin("<!-- tachometer:tachometer -->", out)  # bad marker fell back to the safe token
        # A forced (validated) marker overrides the embedded one for the re-render.
        d["meta"]["marker"] = "evil"
        r3 = report_from_dict(d)
        # Unknown verdicts/reasons coerce to safe defaults rather than erroring.
        d["measurements"][1]["verdict"] = "lol"
        @test report_from_dict(d).measurements[1].verdict === :invariant
        @test_throws ErrorException report_from_dict(Dict("schema" => "nope"))
        @test_throws ErrorException report_from_dict(Dict("schema" => "tachometer-report", "version" => 999))
    end

    @testset "formatting" begin
        @test prettytime(500) == "500 ns"
        @test occursin("µs", prettytime(5_000))
        @test occursin("ms", prettytime(5_000_000))
        @test occursin("KiB", prettymemory(2048))
        @test _signed_pct(1.42) == "+42%"
        @test _signed_pct(0.78) == "−22%"
    end

    # --- rendering ---------------------------------------------------------

    @testset "render: clean is calm" begin
        ms = judge(mkrun("g/a" => (10_000, 0)), mkrun("g/a" => (10_100, 0)))
        r = Report(:ok, ms, meta(), "")
        out = render(r)
        @test occursin("no performance regressions detected", out)
        @test occursin("<!-- tachometer:tachometer -->", out)
        @test occursin("🟢", out)
        # No big changes table when everything is invariant.
        @test !occursin("| 🔴 |", out)
        # Full results are tucked away in a collapsed block.
        @test occursin("<details><summary>Full results", out)
    end

    @testset "render: regression is actionable" begin
        ms = judge(mkrun("g/hot" => (10_000, 0)), mkrun("g/hot" => (14_500, 512)))
        r = Report(:regressed, ms, meta(), "")
        out = render(r)
        @test occursin("🔴 Tachometer — 1 regression", out)
        @test occursin("`g/hot`", out)
        @test occursin("→", out)           # before -> after absolute values
        @test occursin("+45%", out)        # signed percentage, not a bare ratio
        @test occursin("Tachometer.jl</sub>", out)
    end

    @testset "render: yellow states never read as success" begin
        r = Report(:not_comparable, Measurement[], meta(), "No common ancestor.")
        out = render(r)
        @test occursin("🟡", out)
        @test !occursin("🟢", out)

        r2 = Report(:errored, Measurement[], meta(), "boom")
        out2 = render(r2)
        @test occursin("🟡", out2)
        @test occursin("did not complete", out2)

        # Untrusted messages on the re-render path can't inject an active link,
        # image, or a second sticky marker.
        evil = "see <a href=\"https://evil\">x</a> <img src=\"https://track\"> [l](https://evil) <!-- tachometer:evil -->"
        # not_comparable: emitted as inline text -> HTML/markdown/​marker neutralized.
        onc = render(Report(:not_comparable, Measurement[], meta(), evil))
        @test !occursin("<a href", onc) && !occursin("<img", onc)
        @test !occursin("](https://evil)", onc)
        @test !occursin("<!-- tachometer:evil -->", onc)
        # errored: wrapped in a code fence (so raw text is inert) and the marker is
        # still defanged so it can't be matched as a sticky comment.
        oer = render(Report(:errored, Measurement[], meta(), evil))
        @test occursin("```", oer)
        @test !occursin("<!-- tachometer:evil -->", oer)
    end
end
