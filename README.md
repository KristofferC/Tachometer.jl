# Tachometer

**TL;DR:** Tachometer is benchmark CI for Julia packages. It benchmarks every
pull request against its merge-base and posts the comparison as a PR comment,
and it records default-branch results on a published dashboard
(**[live demo →](https://kristofferc.github.io/Tachometer.jl/demo/)**).
A representative comment:

> ### 🔴 Tachometer — 1 regression, 1 improvement
>
> 10 benchmarks compared · `60ab91e` → `f3c2d1a` · Julia 1.12 · 5% tolerance · 3× runs
>
> | | Benchmark | Time | Memory |
> |:--:|:--|:--|:--|
> | 🔴 | `assembly/global` | 11.8 ms → 16.3 ms (+38%) | 6.58 MiB → 8.23 MiB (+25%) |
> | 🟢 | `solve/cg` | 148 ms → 115 ms (−22%) | — |
>
> <sub>Full results, added/removed benchmarks, and run details follow in collapsed sections.</sub>

Comparisons use
[BenchmarkTools](https://github.com/JuliaCI/BenchmarkTools.jl), so benchmark
suites written for PkgBenchmark or AirspeedVelocity will usually work unchanged.
Each committed revision is checked out in a temporary git worktree and benchmarked
in a separate Julia process. Tachometer does not modify the package checkout.

## Set up a benchmark suite

The default entrypoint is `benchmark/benchmarks.jl`. It must assign a
`BenchmarkGroup` named `SUITE`:

```julia
using BenchmarkTools
using MyPackage

SUITE = BenchmarkGroup()
SUITE["scalar"] = @benchmarkable MyPackage.f(1)
SUITE["array"] = @benchmarkable MyPackage.f(x) setup=(x = rand(1_000))
```

Put dependencies used only by benchmarks in `benchmark/Project.toml`. Tachometer
copies this environment for each run, adds the package revision being tested,
and makes `BenchmarkTools` available. The source checkout and benchmark
environment are left unchanged.

If the entrypoint is elsewhere, set the action's `script` input to its path,
relative to the package root.

[What makes a good benchmark suite](#what-makes-a-good-benchmark-suite), at the
end of this README, has guidance on keeping the suite fast and its results
stable.

## Set up GitHub Actions

Choose one of the supplied PR setups:

| PRs to benchmark | Copy to `.github/workflows/` |
|---|---|
| Same-repository and fork PRs | [`benchmark.yml`](examples/benchmark.yml) and [`report.yml`](examples/report.yml) |
| Same-repository PRs only | [`simple.yml`](examples/simple.yml) |

These are alternatives. Do not install all three workflows. The simple action
posts directly; the fork-safe setup keeps measurement and commenting in separate
security contexts.

### Fork-safe setup

Use this setup for public repositories or any repository that accepts PRs from
forks.

1. Copy [`benchmark.yml`](examples/benchmark.yml) and
   [`report.yml`](examples/report.yml) to `.github/workflows/`.
2. Choose a reviewed Tachometer commit and use its full 40-character SHA in
   both files:

   - In `benchmark.yml`, replace
     `KristofferC/Tachometer.jl@v1` with
     `KristofferC/Tachometer.jl@<full-commit-sha>`.
   - In `report.yml`, replace the all-zero SHA in the reporter action with the
     same SHA.

3. Change the `branches` filters to match the package's default branch.
4. Check the Julia version and benchmark runner. `benchmark.yml` uses the
   action's Julia `1` default and `ubuntu-24.04-arm`.
5. Commit both workflows to the default branch. The reporting workflow becomes
   active only after it is present there.

If you rename the benchmark workflow, keep its top-level `name` in sync with
`workflows: [...]` in `report.yml`.

The two workflows form a security boundary. `benchmark.yml` runs code from the
PR with a read-only token and uploads structured results. `report.yml` has
permission to comment, but runs trusted code from the default branch and
re-renders the comment itself. Do not replace this setup with
`pull_request_target`.

### Same-repository setup

If all benchmarked PRs come from branches in the same repository:

1. Copy [`simple.yml`](examples/simple.yml) to `.github/workflows/`.
2. Replace `KristofferC/Tachometer.jl@v1` with a full Tachometer commit SHA.
3. Change the `branches` filters, Julia version, and runner as needed.
4. Commit the workflow.

This workflow benchmarks and comments in one job. It deliberately skips fork
PRs.

Both setups keep one Tachometer comment per PR and update it after each push.
While a new run is in progress, the existing comment is marked as stale.

> [!IMPORTANT]
> The examples ignore documentation-only changes. Remove `paths-ignore` if the
> benchmark workflow will be a required check. A workflow skipped by a path
> filter does not report a check result.

### Choosing a runner

The examples use `ubuntu-24.04-arm`, which has produced less benchmark noise
than the standard shared x64 and macOS runners in this project's testing. It is
free only for public repositories, and it exercises AArch64 rather than x86_64
code paths.

Use `ubuntu-latest` or a controlled self-hosted runner if AArch64 is not suitable.
Use the same runner, Julia version, and thread count for PR comparisons and
default-branch tracking.

## Configure the comparison

The supplied workflows start with three interleaved runs, a 5% time tolerance,
and a 1 µs time floor. These are reasonable initial settings for a shared runner;
adjust them after observing the suite.

```yaml
- id: bench
  uses: KristofferC/Tachometer.jl@<full-commit-sha>
  with:
    julia-version: "1.12"
    nruns: "3"
    time-tolerance: "5%"
    time-floor: "1us"
    fail-on-regression: "true"
```

Keep `fetch-depth: 0` on the package checkout. Tachometer needs the commit
history to find a merge-base and tags to find release baselines. The supplied
workflows already set it.

### Inputs

These are the action defaults. Values set in the example workflows override
them.

| Input | Default | Meaning |
|---|---:|---|
| `julia-version` | `1` | Julia version accepted by `julia-actions/setup-julia` |
| `package` | `.` | Path to the package's git checkout |
| `script` | `benchmark/benchmarks.jl` | Benchmark entrypoint relative to `package` |
| `baseline` | PR merge-base; otherwise `HEAD~1` | Revision used as the baseline |
| `target` | PR head; otherwise `HEAD` | Revision being tested |
| `time-tolerance` | `5%` | Relative time change required to report a change; `0.05` also works |
| `memory-tolerance` | `5%` | Relative memory change required to report a change; `0.05` also works |
| `time-floor` | `1us` | Absolute time change also required |
| `memory-floor` | `0` | Absolute memory change also required; accepts bytes or sizes such as `1 KiB` |
| `nruns` | `1` | Interleaved baseline/target passes; every pass must agree |
| `threads` | `1` | `JULIA_NUM_THREADS` used by benchmark processes |
| `verbose` | `true` | Print benchmark names and subprocess output to the job log |
| `fail-on-regression` | `false` | Fail the job when a regression is confirmed |
| `release-baseline` | `true` | On a version bump, compare with the previous release |
| `marker` | `tachometer` | Sticky-comment identifier |
| `noise-history` | `auto` | Fetch tracking data from `gh-pages`; use `none` to disable or provide a data-directory path |
| `comment` | `false` | Post the PR comment directly (same-repository PRs only) |

The action exposes three outputs:

| Output | Meaning |
|---|---|
| `status` | `ok`, `regressed`, `not_comparable`, or `errored` |
| `regressed` | `true` when at least one regression was confirmed |
| `report` | Path to the rendered Markdown report |

Set `fail-on-regression: "true"` to use Tachometer as a required performance
check. Gating happens after the report artifact is uploaded, so the PR still
gets a comment when the check fails. The action does not gate when Julia files
in the benchmark script's directory changed between the revisions, because the
suites may no longer be comparable.

For a benchmark matrix, give every job a distinct `marker` and list those
markers in the reporter action; `report.yml` contains an example.

## How results are judged

Tachometer records the minimum time reported by BenchmarkTools for each
benchmark pass.

A time or memory change must pass both its relative tolerance and its absolute
floor. With the defaults, a change from 200 ns to 280 ns is ignored: the 40%
difference is large enough, but the 80 ns absolute difference is below
`time-floor`. A change from 200 ns to 2 µs passes both thresholds. Going from no
memory allocation to any allocation is always a regression.

When `nruns` is greater than one, baseline and target runs are interleaved and
their order alternates. A change is reported only if every pass agrees.

A benchmark that becomes faster while using more memory is shown as a memory
trade-off and does not fail the check. A benchmark that becomes slower while
using less memory is still a regression.

Benchmarks present in only one revision are listed separately and do not affect
the verdict. An unavailable baseline or a result with nothing in common is
`not_comparable`; a revision, build, or benchmark failure is `errored`. Neither
is presented as a successful comparison.

If `noise-history` is set, Tachometer learns a separate time tolerance for each
benchmark from matching default-branch history. It uses only records with the
same OS, architecture, Julia version, and thread count, and caps the learned
tolerance at 50%. PR runs read this history but never write to it.

### Version bumps

When a PR raises the version in `Project.toml`, the action normally compares it
with the highest reachable `vX.Y.Z` tag below the new version instead of the PR
merge-base. This catches regressions accumulated since the previous release.

Set `release-baseline: "false"` to keep the normal merge-base. If no suitable
tag is available, Tachometer keeps the merge-base and notes this in the report.

## Track the default branch

[`track.yml`](examples/track.yml) records benchmark results on default-branch
pushes and publishes a static dashboard at:

```text
https://OWNER.github.io/REPOSITORY/benchmarks/
```

**[Live example →](https://kristofferc.github.io/Tachometer.jl/demo/)** — generated
from synthetic data by [`scripts/generate-demo-data.jl`](scripts/generate-demo-data.jl),
so regressions, releases, and environment changes all have something to show.

To enable it:

1. Copy `examples/track.yml` to `.github/workflows/`.
2. In both `Install Tachometer` steps, change the install call to:

   ```julia
   Pkg.add(
       url = "https://github.com/KristofferC/Tachometer.jl",
       rev = "<full-commit-sha>",
   )
   ```

   Use the same Tachometer commit as the PR workflows.

3. Match the Julia version and runner used by the PR workflow. Both templates
   use one thread. If the PR workflow sets `threads` to another value, set
   `TACHOMETER_THREADS` to the same value in the `Record` step.
4. In the repository's Pages settings, select **Deploy from a branch**,
   `gh-pages`, and `/ (root)`.

The first successful publish creates the `gh-pages` branch. The PR workflow
examples read the history from that branch automatically; before any history
exists, they use the fixed tolerances.

The dashboard is written only below `benchmarks/`, so it can share a Pages
branch with Documenter.

### Using only the dashboard (bring your own runner)

The dashboard doesn't care where the numbers come from: it is three static
files plus a `data/` directory of plain JSON. If you already have a
benchmarking framework and just want the dashboard, build records from your
own measurements:

```julia
using Dates
using Tachometer

rec = Tachometer.make_record(
    Dict("assembly/global" => (time = 11.8e6, memory = 6.9e6, allocs = 15_240));
    commit = "60ab91e0123456789abcdef0123456789abcdef0",
    date = DateTime(2026, 7, 30, 9, 41),
    coverage = :partial)  # unmeasured benchmarks remain visible
Tachometer.add_record!("site/data", rec;
    package = "MyPkg.jl", repo_url = nothing)
Tachometer.write_dashboard("site")   # the static page, next to data/
```

Use the default `coverage = :snapshot` when the dictionary is the complete
suite. Partial uploads for the same commit are merged; use
`removed_benchmarks = ["old/name"]` to explicitly retire a benchmark.

To use it only on your machine, run
`python3 -m http.server --directory site 8000` and open
<http://localhost:8000/>. Nothing is uploaded. Publishing `site/` is optional.
[`dashboard/README.md`](dashboard/README.md) has a local demo, the JSON schema,
and instructions for non-Julia runners.

## Compare locally

Install Tachometer from the repository if it is not already in the active
environment:

```julia
using Pkg
Pkg.add(
    url = "https://github.com/KristofferC/Tachometer.jl",
    rev = "<full-commit-sha>",
)
```

Then compare the current working tree, including uncommitted changes, with its
current `HEAD`:

```julia
using Tachometer

compare()
```

The returned report displays a compact summary at the REPL. Use
`print(render(report))` when you specifically want the GitHub-flavoured Markdown.

To compare the whole branch with `main`, or compare two explicit revisions:

```julia
compare(; baseline = "main")

compare("path/to/MyPackage";
    baseline = "v1.2.0",
    target = "feature-branch",
    nruns = 3,
    verbose = false,
)
```

`baseline` and `target` accept git revisions. The local defaults are `HEAD` and
`WORKINGTREE`, respectively; `release_baseline` defaults to `false`.
Action inputs that also exist as `compare` keywords use underscores instead of
dashes.

### Install as a shell command

On Julia 1.12+ the CLI can be installed as a
[Pkg app](https://pkgdocs.julialang.org/v1.12/apps/), which puts a
`tachometer` executable in `~/.julia/bin`:

```
pkg> app add https://github.com/KristofferC/Tachometer.jl
```

```sh
tachometer                        # compare HEAD vs the working tree
tachometer --baseline=v1.2.0 --nruns=3
tachometer record --record-out=record.json
```

The first argument selects the mode (`compare`, `record`, `publish`, `render`);
every `--option=value` sets the corresponding `TACHOMETER_<OPTION>` environment
variable, so the same knobs as the action's [inputs](#inputs) apply. `compare`
uses the local defaults above and exits non-zero on a regression.

## What makes a good benchmark suite

A suite is only useful if it is cheap enough to run often. Aim for one that
finishes in a couple of minutes — well under the package's test time. A CI job
runs it `nruns` times per revision (six passes with the example settings), and
a fast suite is one you will also run locally before pushing.

Spend that budget on a few benchmarks that each exercise a distinct code path.
Avoid the cartesian product of input types × sizes × options: most
combinations run the same code and just measure it again, and every extra row
makes the report longer and real regressions easier to overlook. Add a
benchmark when it covers a different algorithm or kernel, not another value of
a parameter.

Set `evals = 1` on every benchmark:

```julia
SUITE["array"] = @benchmarkable MyPackage.f(x) setup=(x = rand(1_000)) evals=1
```

Before a suite runs, BenchmarkTools tunes it: every benchmark without an
explicit `evals` is executed repeatedly to decide how many evaluations to fold
into one sample. Tachometer tunes in each benchmark process, so with
`nruns: "3"` an untuned suite pays that sweep six times — and because each
revision tunes independently, a borderline benchmark can land on a different
`evals` per side, which skews the comparison. An explicit `evals` avoids both,
and `evals = 1` is correct for anything taking a microsecond or more. (A
committed `benchmark/tune.json` also pins parameters, but goes stale;
`evals = 1` doesn't.)

Also worth doing:

- Measure a realistic chunk of work rather than one nanosecond-scale call.
  Per-call differences of a few nanoseconds are usually code-placement and
  alignment churn rather than the change under test — this is what
  `time-floor` discounts — and repeating one call in a loop amplifies that
  churn along with the signal. A loop over a *varied* batch of inputs
  diversifies layout and data effects and measures the throughput users
  actually see.
- Bound sampling time. BenchmarkTools spends up to 5 s per benchmark by
  default; `BenchmarkTools.DEFAULT_PARAMETERS.seconds = 1` at the top of the
  script is usually plenty, since minimum times converge quickly.
- Make the work identical on every run: build inputs in `setup`, seed any
  randomness that affects the timed code, and keep I/O and downloads out of
  the suite.
- Keep names stable. Learned noise tolerances and dashboard history are keyed
  by benchmark name, so a rename discards its history.

If a nanosecond-scale function is itself the product, it can still be tracked;
the defaults just assume otherwise. Give it a fixed `evals` large enough that
one sample measures a microsecond or more (`evals = 500` for a ~20 ns
function — an explicit value is never re-tuned, so both revisions measure
identically), lower `time-floor` to match, and expect to need a quiet runner:
on shared hardware a few nanoseconds per call is often code-layout churn
however it is measured. Often the more useful benchmark is throughput over a
spread of inputs — `sum(sin, xs)` per argument range — which exercises every
branch instead of one perfectly predicted path, and works with the defaults.

## License

MIT.
