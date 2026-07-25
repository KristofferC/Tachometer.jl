# A tiny suite so Tachometer can dogfood itself (its own CI can benchmark PRs).
using BenchmarkTools
using Tachometer

const SUITE = BenchmarkGroup()

SUITE["render"] = BenchmarkGroup()

let
    E(t, m) = Tachometer.Estimate(float(t), float(m), 0.0)
    ms = Tachometer.Measurement[
        Tachometer.Measurement("g/a", E(10_000, 0), E(14_000, 0), 1.4, 1.0, :regression, :time, 1, 1, 0.05, false),
        Tachometer.Measurement("g/b", E(10_000, 0), E(10_050, 0), 1.005, 1.0, :invariant, :none, 1, 1, 0.05, false),
    ]
    meta = Tachometer.Meta(; package = "Demo", baseline_sha = "aaaaaaa", target_sha = "bbbbbbb")
    report = Tachometer.Report(:regressed, ms, meta, "")
    SUITE["render"]["regressed"] = @benchmarkable render($report)
end
