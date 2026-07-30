using Tachometer
using Test
using Dates

using Tachometer: Estimate, Measurement, Meta, Report, RevisionRun, NoiseModel,
    _judge, _classify_time, _classify_memory, _combine, _as_ns, _as_fraction, _as_bytes,
    build_noise_from_history,
    effective_time_tolerance, prettytime, prettymemory, _signed_pct,
    regressions, improvements, invariants, tradeoffs, added, removed, suppressed, compared,
    project_version, last_release_tag, _release_baseline, WORKINGTREE, _write_driver, _run_julia,
    load_index, load_shard, load_all_records, _releases, _shard_name, write_dashboard,
    make_record, add_record!, default_fingerprint, JSON,
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
        @test _as_fraction(0.05) == 0.05
        @test _as_fraction("0.05") == 0.05
        @test _as_fraction("5%") == 0.05
        @test _as_fraction(" 2.5 % ") == 0.025
        @test_throws ErrorException _as_fraction("five percent")
        @test_throws ErrorException _as_fraction("5")
        @test_throws ErrorException _as_fraction(1)
        @test_throws ErrorException _as_fraction(-0.1)
        @test_throws ErrorException _as_fraction(NaN)
        @test _as_bytes(1024) == 1024.0
        @test _as_bytes("1 KiB") == 1024.0
        @test _as_bytes("1.5 MB") == 1.5e6
        @test_throws ErrorException _as_bytes("a lot")
        @test_throws ErrorException _as_bytes("1.2.3")
        @test_throws ErrorException _as_bytes(-1)
        withenv("TACHOMETER_TIME_TOLERANCE" => "") do
            @test Tachometer._env_nonempty("TACHOMETER_TIME_TOLERANCE", "5%") == "5%"
        end

        # The common local form needs neither a repository path nor awkward
        # numeric notation. An empty baseline returns before running benchmarks.
        local_report = compare(; baseline = "", time_tolerance = "5%",
            memory_floor = "1 KiB", verbose = false)
        @test local_report.status === :not_comparable
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

        # Memory tolerance: a change inside the band is invariant, one past it is a
        # regression. At the 5% default, +3% is noise-level bookkeeping and +10% is not.
        memjudge(b, t; tol) = _judge([mkrun("g/a" => (10_000, b))], [mkrun("g/a" => (10_000, t))],
            NoiseModel(); time_tolerance = 0.05, memory_tolerance = tol,
            time_floor = 1000.0, memory_floor = 0.0, nruns = 1)
        @test only(memjudge(1000, 1030; tol = 0.05)).verdict === :invariant
        @test only(memjudge(1000, 1100; tol = 0.05)).verdict === :regression
        @test only(memjudge(1000, 970; tol = 0.05)).verdict === :invariant
        @test only(memjudge(1000, 900; tol = 0.05)).verdict === :improvement
        # The same +3% is a regression at the tighter tolerance, so the knob still bites.
        @test only(memjudge(1000, 1030; tol = 0.01)).verdict === :regression
    end

    @testset "faster but hungrier is a trade-off" begin
        # Time improved, memory regressed: a trade-off for a human to weigh, not a
        # regression, and it does not turn the report red.
        ms = judge(mkrun("g/a" => (14_000, 1000)), mkrun("g/a" => (10_000, 2000)))
        @test only(ms).verdict === :tradeoff
        @test only(ms).reason === :memory
        r = Report(:ok, ms, meta(), "")
        @test isempty(regressions(r)) && length(tradeoffs(r)) == 1
        @test length(compared(r)) == 1          # still a compared benchmark
        out = render(r)
        @test occursin("🟡", out)
        @test occursin("no performance regressions detected", out)
        @test occursin("memory trade-off", out)

        # The reverse — slower but leaner — stays a regression: a byte saved does
        # not buy the right to be slower.
        ms = judge(mkrun("g/a" => (10_000, 2000)), mkrun("g/a" => (14_000, 1000)))
        @test only(ms).verdict === :regression && only(ms).reason === :time

        # Memory alone regressing (time flat) is still a regression, as before.
        ms = judge(mkrun("g/a" => (10_000, 1000)), mkrun("g/a" => (10_000, 2000)))
        @test only(ms).verdict === :regression && only(ms).reason === :memory

        # Faster *and* leaner is an unambiguous improvement, not a trade-off.
        ms = judge(mkrun("g/a" => (14_000, 2000)), mkrun("g/a" => (10_000, 1000)))
        @test only(ms).verdict === :improvement

        # A trade-off never gates: `compare`'s status logic keys off regressions.
        @test Report(:ok, ms, meta(), "").status === :ok
    end

    @testset "benchmark driver" begin
        # `verbose` reaches the subprocess's `run(suite; verbose = ...)` call, so a
        # failing run's log names the benchmark it died on.
        dir = mktempdir()
        mkpath(joinpath(dir, "benchmark"))
        write(joinpath(dir, "benchmark", "benchmarks.jl"), "const SUITE = nothing\n")
        for v in (true, false)
            path = _write_driver(dir, "benchmark/benchmarks.jl", joinpath(dir, "out.json"), false, v)
            code = read(path, String)
            @test occursin("const _VERBOSE = $(v)", code)
            @test occursin("run(suite; verbose = _VERBOSE)", code)
            rm(path; force = true)
        end
    end

    @testset "streamed subprocess output" begin
        drv = tempname() * ".jl"
        write(drv, """
        println("first")
        println(stderr, "on stderr")
        println("last")
        exit(3)
        """)
        try
            # Streamed to `io` line by line, prefixed with the revision tag...
            sink = IOBuffer()
            r = _run_julia(drv, copy(ENV); stream = true, io = sink, prefix = "[abc1234] ")
            streamed = String(take!(sink))
            @test occursin("[abc1234] first", streamed)
            @test occursin("[abc1234] last", streamed)
            # ...and still captured, stderr included, with the exit status intact.
            @test occursin("first", r.log) && occursin("on stderr", r.log)
            @test r.code.exitcode == 3

            # Off: nothing on `io`, but the log is unaffected.
            quiet = IOBuffer()
            r2 = _run_julia(drv, copy(ENV); stream = false, io = quiet)
            @test isempty(String(take!(quiet)))
            @test occursin("first", r2.log) && occursin("last", r2.log)
        finally
            rm(drv; force = true)
        end
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

    @testset "footer revisions" begin
        foot(; kw...) = render(Report(:ok, Measurement[], Meta(; package = "P", timestamp = "now", kw...), ""))

        # A ref that is just the commit written out adds nothing next to the SHA.
        out = foot(baseline_sha = "389ecb7bd0", baseline_ref = "389ecb7bd0",
            target_sha = "7f5fcb3aa1", target_ref = "7f5fcb3")
        @test occursin("baseline `389ecb7` · target `7f5fcb3` ·", out)
        @test !occursin("(389ecb7", out) && !occursin("(7f5fcb3", out)

        # A name the SHA does not carry is still shown, and still sanitised.
        out = foot(baseline_sha = "389ecb7bd0", baseline_ref = "master",
            target_sha = "7f5fcb3aa1", target_ref = "v1.2.0")
        @test occursin("baseline `389ecb7` (master)", out)
        @test occursin("target `7f5fcb3` (v1.2.0)", out)
        @test occursin("target `7f5fcb3` (working tree)",
            foot(target_sha = "7f5fcb3aa1", target_ref = "working tree"))
        @test !occursin("<!-- x -->",
            foot(baseline_sha = "389ecb7bd0", baseline_ref = "ma<!-- x -->ster"))

        # Uncommitted changes are the one thing that makes a run unreproducible, so
        # the marker survives abbreviation — in the subtitle and in the footer.
        out = foot(baseline_sha = "389ecb7bd0", baseline_ref = "master",
            target_sha = "7f5fcb3aa1+dirty", target_ref = "working tree")
        @test occursin("`389ecb7` → `7f5fcb3+dirty`", out)          # subtitle
        @test occursin("target `7f5fcb3+dirty` (working tree)", out) # footer
        # A `+dirty` target whose ref is the same commit still drops the ref, but
        # keeps the marker.
        out = foot(target_sha = "7f5fcb3aa1+dirty", target_ref = "7f5fcb3aa1")
        @test occursin("target `7f5fcb3+dirty` ·", out)
        @test !occursin("(7f5fcb3", out)

        # No SHA at all (nothing was run): the ref alone, no empty backticks in the
        # footer or in the subtitle's `sha → sha` span.
        out = foot(baseline_ref = "master", target_ref = "working tree")
        @test occursin("baseline `master` · target `working tree` ·", out)
        @test !occursin("``", out)
        @test !occursin("→", out)   # nothing ran, so no arrow between revisions

        # A GitHub run URL names the repository, so the SHAs link to their
        # commits — GitHub autolinks bare full SHAs but never code spans, so the
        # link has to be explicit. A dirty working tree links to the commit it
        # sits on, keeping the marker in the visible text.
        out = foot(baseline_sha = "389ecb7bd0", baseline_ref = "master",
            target_sha = "7f5fcb3aa1+dirty", target_ref = "working tree",
            run_url = "https://github.com/K/P.jl/actions/runs/123")
        @test occursin("baseline [`389ecb7`](https://github.com/K/P.jl/commit/389ecb7bd0) (master)", out)
        @test occursin("target [`7f5fcb3+dirty`](https://github.com/K/P.jl/commit/7f5fcb3aa1) (working tree)", out)
        @test occursin("[`389ecb7`](https://github.com/K/P.jl/commit/389ecb7bd0) → [`7f5fcb3+dirty`]", out) # subtitle

        # No link without a repository to point at: a non-GitHub run URL, or a
        # SHA that isn't hex.
        out = foot(target_sha = "7f5fcb3aa1", run_url = "https://example.com/run/1")
        @test occursin("target `7f5fcb3` ·", out) && !occursin("[`7f5fcb3`]", out)
        out = foot(target_sha = "not-a-sha!",
            run_url = "https://github.com/K/P.jl/actions/runs/123")
        @test !occursin("](https://github.com/K/P.jl/commit/", out)

        # The CPU the numbers came from sits next to the Julia version; unknown
        # (empty) leaves no gap in the separator chain.
        @test occursin("Julia 1.11.0 · Apple M2 · min estimator",
            foot(julia_version = "1.11.0", cpu = "Apple M2"))
        @test occursin("Julia 1.11.0 · min estimator", foot(julia_version = "1.11.0", cpu = ""))

        # Vendor boilerplate is trimmed from the detected model.
        @test Tachometer._cpu_model("Intel(R) Xeon(R) Platinum 8370C CPU @ 2.80GHz") ==
            "Intel Xeon Platinum 8370C"
        @test Tachometer._cpu_model("AMD EPYC 7763 64-Core Processor") == "AMD EPYC 7763"
        @test Tachometer._cpu_model("Apple M2") == "Apple M2"

        # On aarch64 Linux Sys.cpu_info() reports "unknown" (no "model name" line in
        # /proc/cpuinfo); the ARM CPUID implementer/part fields are decoded instead.
        cobalt = """
        processor\t: 0
        BogoMIPS\t: 50.00
        CPU implementer\t: 0x41
        CPU architecture: 8
        CPU variant\t: 0x0
        CPU part\t: 0xd49
        CPU revision\t: 1
        """
        @test Tachometer._proc_cpuinfo_model(cobalt) == "ARM Neoverse-N2"
        # A "model name" line wins when present (x86, and some arm kernels).
        @test Tachometer._proc_cpuinfo_model("model name\t: Neoverse-N1\n" * cobalt) == "Neoverse-N1"
        # Unmapped ids stay identifiable instead of pretending to know the name.
        @test Tachometer._proc_cpuinfo_model(replace(cobalt, "0xd49" => "0x123")) == "ARM part 0x123"
        @test Tachometer._proc_cpuinfo_model(replace(cobalt, "0x41" => "0x99")) ==
            "implementer 0x99 part 0xd49"
        # No usable fields at all -> empty, which the footer omits.
        @test Tachometer._proc_cpuinfo_model("flags\t: fp asimd\n") == ""
        # _raw_cpu_model never *returns* "unknown": either a real model or empty.
        @test Tachometer._raw_cpu_model() != "unknown"
    end

    @testset "changes table capping" begin
        E(t) = Estimate(float(t), 0.0, 0.0)
        key(i) = "g/b$(lpad(i, 3, '0'))"
        mk(i) = Measurement(key(i), E(10_000), E(14_000), 1.4, 1.0, :regression, :time, 1, 1, 0.05, false)
        r = Report(:regressed, [mk(i) for i in 1:30], meta(), "")

        # Nothing is cut by default: every changed benchmark is in the top table.
        full = render(r)
        @test all(i -> occursin("`$(key(i))`", split(full, "<details>")[1]), 1:30)
        @test !occursin("… and", full)

        # Over the size limit: the collapsed sections go first, the table stays full.
        out = render(r; byte_limit = sizeof(full) - 1)
        @test occursin("Full results omitted", out) && !occursin("<details>", out)
        @test all(i -> occursin("`$(key(i))`", out), 1:30)
        @test !occursin("… and", out)

        # Still over: the changes table itself is capped as a last resort, and its
        # overflow note points at the run artifact instead of the dropped full
        # results.
        out = render(r; max_rows = 8, byte_limit = 300)
        @test occursin("… and 22 more changes in the run artifact.", out)
        @test occursin("Full results omitted", out)
        @test occursin("`$(key(8))`", out) && !occursin("`$(key(9))`", out)
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

    @testset "bring-your-own-runner record API" begin
        sha = "60ab91e0123456789abcdef0123456789abcdef0"
        rec = make_record(
            Dict("g/hot" => (time = 1.5e6, memory = 1024, allocs = 3),
                 "cold" => Dict("time" => 9.0e3));
            commit = uppercase(sha),                       # normalized to lowercase
            date = DateTime(2026, 3, 1, 12),
            message = "speed up hot loop", version = "1.2.0")
        @test rec["commit"] == sha
        @test rec["date_unix"] == round(Int, Dates.datetime2unix(DateTime(2026, 3, 1, 12)))
        @test rec["date"] == "2026-03-01T12:00:00Z"
        @test rec["benchmarks"]["g/hot"] == Dict("time" => 1.5e6, "memory" => 1024, "allocs" => 3)
        @test rec["benchmarks"]["cold"] == Dict("time" => 9.0e3)
        @test rec["coverage"] == "snapshot" && isempty(rec["removed_benchmarks"])
        @test rec["fingerprint"]["os"] == string(Sys.KERNEL)   # defaulted
        # Unix seconds and DateTime describe the same instant.
        @test make_record(Dict("x" => (time = 1,)); commit = sha,
            date = rec["date_unix"])["date"] == rec["date"]

        # Validation: bad sha/date, empty input, unknown stats, and bad values.
        @test_throws ErrorException make_record(Dict{String, Any}(); commit = "xyz", date = 0)
        @test_throws ErrorException make_record(Dict{String, Any}(); commit = sha, date = 0)
        @test_throws ErrorException make_record(Dict("a" => (time = 1,)); commit = sha, date = true)
        @test_throws ErrorException make_record(Dict("a" => (mem = 1,)); commit = sha, date = 0)
        @test_throws ErrorException make_record(Dict("a" => (time = NaN,)); commit = sha, date = 0)
        @test_throws ErrorException make_record(Dict("a" => (time = -1,)); commit = sha, date = 0)
        @test_throws ErrorException make_record(Dict("a" => (time = true,)); commit = sha, date = 0)
        @test_throws ErrorException make_record(Dict("a" => Dict{String, Any}()); commit = sha, date = 0)
        @test_throws ErrorException make_record(Dict("a" => (time = 1,)); commit = sha,
            date = 0, fingerprint = Dict("backend" => NaN))
        @test_throws ErrorException make_record(Dict("a" => (time = 1,)); commit = sha,
            date = 0, fingerprint = Dict("backend" => Dict()))
        @test_throws ErrorException make_record(Dict("a" => (time = 1,)); commit = sha,
            date = 0, coverage = :unknown)
        @test_throws ErrorException make_record(Dict("a" => (time = 1,)); commit = sha,
            date = 0, removed_benchmarks = ["b"])
        @test_throws ErrorException make_record(Dict("a" => (time = 1,)); commit = sha,
            date = 0, coverage = :partial, removed_benchmarks = ["a"])

        # Partial uploads merge at the same commit and preserve snapshot
        # completeness. Explicit removals delete a benchmark without treating
        # every unmeasured benchmark as deleted.
        partial_data = joinpath(mktempdir(), "data")
        regime = Dict("cpu" => "local", "julia" => "1.12")
        base = make_record(Dict("a" => (time = 1,), "b" => (time = 2,), "c" => (time = 3,));
            commit = sha, date = DateTime(2026, 1, 1), message = "base", fingerprint = regime)
        update = make_record(Dict("a" => (time = 4,));
            commit = sha, date = DateTime(2026, 1, 1), coverage = :partial,
            removed_benchmarks = ["b"], fingerprint = regime)
        add_record!(partial_data, base)
        add_record!(partial_data, update)
        merged = only(load_all_records(partial_data))
        @test merged["coverage"] == "snapshot"
        @test merged["message"] == "base"                  # empty partial default did not erase it
        @test merged["benchmarks"] == Dict(
            "a" => Dict("time" => 4), "c" => Dict("time" => 3))
        @test isempty(merged["removed_benchmarks"])

        # Several partial uploads for a new commit accumulate measurements and
        # tombstones while remaining explicitly partial.
        partial_sha = "c"^40
        p1 = make_record(Dict("a" => (time = 5,), "c" => (time = 6,)); commit = partial_sha,
            date = DateTime(2026, 2, 1), coverage = :partial, fingerprint = regime)
        p2 = make_record(Dict{String, Any}(); commit = partial_sha,
            date = DateTime(2026, 2, 1), coverage = :partial,
            removed_benchmarks = ["a"], fingerprint = regime)
        add_record!(partial_data, p1)
        add_record!(partial_data, p2)
        partial_merged = load_all_records(partial_data)[end]
        @test partial_merged["coverage"] == "partial"
        @test partial_merged["benchmarks"] == Dict("c" => Dict("time" => 6))
        @test partial_merged["removed_benchmarks"] == ["a"]

        # Never combine measurements from different regimes under one commit.
        mismatch = make_record(Dict("d" => (time = 7,)); commit = partial_sha,
            date = DateTime(2026, 2, 1), coverage = :partial,
            fingerprint = Dict("cpu" => "other"))
        @test_throws ErrorException add_record!(partial_data, mismatch)
        @test !haskey(load_all_records(partial_data)[end]["benchmarks"], "d")

        # add_record! creates the history, upserts by sha, and shards by year.
        dd = mktempdir()
        data = joinpath(dd, "data")
        add_record!(data, rec; package = "MyPkg.jl", repo_url = "https://x.y/z",
            releases = [(tag = "v1.0.0", commit = "a"^40, date_unix = 100)])
        idx = JSON.parsefile(joinpath(data, "index.json"))
        @test idx["schema"] == "tachometer-timeseries" && idx["version"] == 3
        @test idx["shards"] == ["shard-2026"]
        @test idx["package"] == "MyPkg.jl" && idx["repo_url"] == "https://x.y/z"
        @test idx["releases"] == [Dict("tag" => "v1.0.0", "commit" => "a"^40, "date_unix" => 100)]
        @test idx["latest_fingerprint"]["os"] == string(Sys.KERNEL)

        # Same commit again -> replaced, not duplicated; omitted kwargs untouched.
        rec2 = make_record(Dict("g/hot" => (time = 2.0e6,)); commit = sha, date = rec["date_unix"])
        add_record!(data, rec2)
        recs2 = load_all_records(data)
        @test length(recs2) == 1 && recs2[1]["benchmarks"]["g/hot"]["time"] == 2.0e6
        @test JSON.parsefile(joinpath(data, "index.json"))["package"] == "MyPkg.jl"

        # A commit from another year lands in its own shard, chronologically.
        old = make_record(Dict("g/hot" => (time = 3.0e6,)); commit = "b"^40,
            date = DateTime(2025, 6, 1), fingerprint = Dict("cpu" => "old runner"))
        add_record!(data, old)
        @test JSON.parsefile(joinpath(data, "index.json"))["shards"] == ["shard-2025", "shard-2026"]
        @test [r["commit"] for r in load_all_records(data)] == ["b"^40, sha]
        # Backfilling an old commit must not make its fingerprint appear latest.
        @test JSON.parsefile(joinpath(data, "index.json"))["latest_fingerprint"] == rec2["fingerprint"]

        # Correcting a commit date moves it instead of duplicating it across shards.
        moved = make_record(Dict("g/hot" => (time = 4.0e6,)); commit = "b"^40,
            date = DateTime(2024, 6, 1), fingerprint = Dict("cpu" => "old runner"))
        add_record!(data, moved)
        all = load_all_records(data)
        @test count(r -> r["commit"] == "b"^40, all) == 1
        @test all[1]["date_unix"] == moved["date_unix"]
        @test isempty(JSON.parsefile(joinpath(data, "shard-2025.json"))["records"])

        # Explicit nothing disables repository links; omitting the keyword preserves it.
        add_record!(data, rec2; repo_url = nothing)
        @test JSON.parsefile(joinpath(data, "index.json"))["repo_url"] === nothing

        # Structural validation and fail-closed behavior.
        @test_throws ErrorException add_record!(data, Dict{String, Any}("commit" => sha))
        bad_coverage = copy(rec); bad_coverage["coverage"] = "unknown"
        @test_throws ErrorException add_record!(data, bad_coverage)
        bad_removed = copy(rec); bad_removed["coverage"] = "partial"
        bad_removed["removed_benchmarks"] = ["cold"]
        @test_throws ErrorException add_record!(data, bad_removed) # measured and removed
        @test_throws ErrorException add_record!(data, rec;
            releases = [(tag = "v1.0.0",)])                # release without commit
        @test_throws ErrorException add_record!(data, rec; repo_url = "http://example.com")
        d6 = mktempdir(); write(joinpath(d6, "index.json"), "not json{")
        @test_throws ErrorException add_record!(d6, rec)   # corrupt index -> refuse
        d7 = mktempdir()
        write(joinpath(d7, "index.json"),
            "{\"schema\":\"tachometer-timeseries\",\"version\":2,\"shards\":[\"shard-2020\"]}")
        @test_throws ErrorException add_record!(d7, rec)   # listed shard is missing

        # Existing v2 histories upgrade without rewriting their old records;
        # missing coverage retains the old snapshot meaning.
        d8 = mktempdir()
        write(joinpath(d8, "index.json"),
            "{\"schema\":\"tachometer-timeseries\",\"version\":2,\"shards\":[]}")
        add_record!(d8, rec)
        @test JSON.parsefile(joinpath(d8, "index.json"))["version"] == 3
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
        d["meta"]["cpu"] = "CPU [l](https://evil) @cpuguy"
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

        # Returning the report directly at the REPL gives a compact plain-text
        # result instead of dumping every struct field or GitHub-only markup.
        plain = sprint(show, MIME"text/plain"(), r)
        @test occursin("Tachometer: 1 regression", plain)
        @test occursin("🔴 g/hot:", plain)
        @test !occursin("<!--", plain)
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
