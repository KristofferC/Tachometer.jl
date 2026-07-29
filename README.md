# Tachometer

Tachometer runs a package's benchmark suite at two git revisions and reports the
difference as a pull request comment: benchmark the base branch and the PR, and
point out the benchmarks that changed.

It expects a `benchmark/benchmarks.jl` that defines `const SUITE = BenchmarkGroup()`
— the same layout PkgBenchmark and AirspeedVelocity use, so an existing suite
works unchanged. For each revision it checks the source out into a temporary
`git worktree`, runs the suite in a separate Julia process, and takes the minimum
time per benchmark with BenchmarkTools.

## The comment

There is a single comment per PR, updated in place on each push. When nothing
regressed it is a status line and a collapsed table of the full results:

```
### 🟢 Tachometer — no performance regressions detected
42 benchmarks compared · `d2de5a1` → `60ab91e` · Julia 1.11 · 5% tolerance
<details><summary>Full results (42 benchmarks)</summary> … </details>
```

When something regressed, the changed benchmarks come first, largest change first,
with the before/after times and the percentage change:

```
### 🔴 Tachometer — 2 regressions, 1 improvement
42 benchmarks compared · `d2de5a1` → `60ab91e` · Julia 1.11 · 5% tolerance · 3× runs

|    | Benchmark          | Time                    | Memory              |
|:--:|:-------------------|:------------------------|:--------------------|
| 🔴 | `assembly/global`  | 10.2 ms → 14.5 ms (+42%)| —                   |
| 🔴 | `dofs/close!`      | 9.1 µs → 10.1 µs (+10%) | 1 KiB → 4 KiB (+300%)|
| 🟢 | `mesh/generate`    | 2.4 ms → 1.87 ms (−22%) | —                   |
```

Benchmarks that did not change stay in the collapsed "Full results" section.
Benchmarks that exist in only one of the revisions, or that could not be compared,
are listed separately and do not affect the verdict.

If there is no baseline, the suite fails to run, or there is nothing to compare,
the comment says so (yellow) rather than reporting success.

## Setup

Tachometer is a composite GitHub Action. Copy the workflows you need from
[`examples/`](examples). The two PR setups are alternatives — pick one, then add
[`track.yml`](examples/track.yml) if you also want the history dashboard:

| | PR comments | + history |
|---|---|---|
| Fork PRs supported | `benchmark.yml` + `report.yml` | `+ track.yml` |
| Same-repo PRs only | `simple.yml` | `+ track.yml` |

- [`benchmark.yml`](examples/benchmark.yml) + [`report.yml`](examples/report.yml):
  use this if PRs can come from forks. The action itself only measures and uploads
  the report as an artifact; a separate workflow posts the comment. That split is
  what makes fork PRs safe: the `pull_request` job runs the PR's (untrusted)
  benchmark code with a read-only token and no secrets, and the `workflow_run` job
  — which has write access but never runs PR code — posts the comment. The trusted
  job re-renders the comment from the structured `report.json` rather than posting
  fork-produced markdown, so a fork can influence the numbers in the comment but
  not inject arbitrary markup or redirect the comment to another PR.
- [`simple.yml`](examples/simple.yml): a single job that benchmarks and comments.
  Only works for PRs from the same repository. Do not change it to
  `pull_request_target` to get around that — that runs untrusted code with a
  write token.

```yaml
- uses: KristofferC/Tachometer.jl@<commit-sha>
  with:
    nruns: "3"
    time-tolerance: "0.05"
    time-floor: "1us"
```

Because the comment is updated in place, a push leaves the previous commit's
numbers on the PR while the new run is in progress. Both setups mark this: as soon
as a new run starts, the existing comment gets a note saying the results below are
from an earlier commit, and the finished report replaces the whole comment. If you
run a benchmark matrix with several `marker` values, call
[`mark-running.sh`](scripts/mark-running.sh) once per marker.

## What counts as a regression

A benchmark is reported as a regression only if the change is both relatively and
absolutely large enough, and holds up across repeated runs:

- **Tolerance and floor.** The time ratio has to exceed `1 + time-tolerance`
  (default 5%) *and* the absolute change has to exceed `time-floor` (default
  1 µs). The floor is on the change, not on the benchmark's size, so a +40% wiggle
  on a 200 ns benchmark (an 80 ns change) is ignored while a 200 ns → 2 µs change
  is not. Memory has its own tolerance (default 5%) and byte floor. A benchmark
  that allocated nothing and now allocates is always reported, whatever the
  tolerance.

- **Trade-offs.** A benchmark that got *faster* while allocating more is reported
  as 🟡 "memory trade-off": it is shown in the table for a human to weigh, but it
  does not make the comment red and does not fail the job. The reverse — slower
  but allocating less — is still a regression.

- **Repeated runs.** With `nruns > 1` the baseline and target are run
  interleaved, alternating which goes first, and a benchmark is only reported if
  every run agrees. This costs time but removes most one-off blips.

- **Learned noise.** Some benchmarks are just noisy on shared CI runners. If you
  point `noise-history` at the published default-branch history (the `data/`
  directory that `track.yml` produces — the example workflows fetch it from
  `gh-pages`), Tachometer estimates how much each benchmark naturally moves
  run-to-run on the default branch and widens that benchmark's tolerance
  accordingly, up to a cap (default 50%) so a large real regression is never
  hidden. Only history from the same OS, architecture, and Julia version is used.
  The history is read-only for PRs — a PR never writes to it, so a PR cannot
  influence what counts as noise. A change that sits inside the learned spread is
  listed in a "suppressed as noise" section rather than dropped.

## Version bumps

When a PR bumps the `version` in `Project.toml`, the interesting comparison is
usually not the merge-base but the last release: the bump is about to become a
tag, and this is the moment to catch regressions that accumulated over the whole
release cycle. So with `release-baseline` on (the default), if the target's
version is higher than the baseline's, Tachometer compares against the previous
`vX.Y.Z` release tag instead and notes this in the comment. It has no effect on
PRs that don't raise the version.

This needs the tags to be present — check out with `fetch-depth: 0`.

## Tracking the default branch over time

Separately from PR comparisons, [`track.yml`](examples/track.yml) records the
absolute results of each push to the default branch and publishes an interactive
time-series dashboard to GitHub Pages: each benchmark over time, filterable by
name, with a time/memory toggle, release markers, and points that link to the
commit. Each record also carries the OS, architecture, Julia version, and CPU,
and the dashboard marks where those changed so a runner change isn't mistaken
for a performance change.

The dashboard is a static page (vendored [uPlot](https://github.com/leeoniya/uPlot),
no build step, no CDN). History is stored as one JSON file per calendar year plus
a small manifest, so neither the download nor the `gh-pages` git history grows
unboundedly. Release markers are recomputed from `vX.Y.Z` tags on every publish,
so a tag created after the commit (e.g. by TagBot) still shows up.

Everything is published under a subdirectory (default `benchmarks/`) of the Pages
branch, and only that subdirectory is ever touched, so it coexists with
Documenter on the same `gh-pages` branch — the publish step fetches, merges, and
pushes with a retry loop, so a concurrent `deploydocs` neither clobbers it nor is
clobbered. The site ends up at `https://OWNER.github.io/REPO/benchmarks/`.

Setup: GitHub Pages must be set to "Deploy from a branch: `gh-pages` / root", and
the workflow needs `contents: write`.

## Choosing a runner

The examples use `ubuntu-24.04-arm`: in a null experiment (identical code
benchmarked against itself) it had roughly half the run-to-run noise of
`ubuntu-latest` and a quarter of `macos-latest`, whose spread was wide enough
that only very large regressions could be caught without false positives.

Two caveats: arm runners are free for **public repos only**, and **it's
aarch64** — a regression confined to x86-specific code paths won't show. If
either forces you onto `ubuntu-latest`, expect to loosen `time-tolerance` and
lean harder on `nruns` and the noise history.

Use the **same runner** for the PR workflow and `track.yml`: the noise model
only learns from history on the same OS, architecture, and Julia version, so
switching runners resets it.

## Local use

```julia
using Tachometer

# Working tree against master:
report = compare("."; baseline = "master")
print(render(report))

# Two explicit revisions, three interleaved runs. `noise_history` (optional) is
# a path to a published time-series `data/` directory (read-only):
report = compare("path/to/Pkg";
    baseline = "v1.2.0",
    target   = "my-branch",
    nruns    = 3,
    noise_history = nothing,
)

# By default each benchmark is named as it runs and the output is streamed, so a
# long comparison can be watched. Pass `verbose = false` for a quiet run:
report = compare("."; baseline = "master", verbose = false)
```

`baseline`/`target` are git refs; `target` may also be `Tachometer.WORKINGTREE`
(the default) to benchmark the current working tree, uncommitted changes included.

## Options

| Option | Default | Meaning |
|---|---|---|
| `julia-version` | `1` | Julia version to benchmark with |
| `package` | `.` | Path to the package to benchmark |
| `script` | `benchmark/benchmarks.jl` | Suite entrypoint, defines `SUITE` |
| `baseline` | merge-base of the PR | Revision to compare against |
| `target` | PR head / working tree | Revision under test |
| `time-tolerance` | `0.05` | Relative time change to report |
| `memory-tolerance` | `0.05` | Relative memory change to report |
| `time-floor` | `1us` | Absolute time change also required |
| `memory-floor` | `0` | Absolute byte change also required |
| `nruns` | `1` | Interleaved runs; all must agree |
| `threads` | `1` | `JULIA_NUM_THREADS` for the benchmark processes |
| `verbose` | `true` | Name each benchmark in the job log as it runs |
| `fail-on-regression` | `false` | Fail the job on a regression |
| `release-baseline` | `true` | On a version bump, compare against the last release tag |
| `marker` | `tachometer` | Comment namespace; give matrix jobs distinct markers |
| `noise-history` | — | Path to the default-branch time-series `data/` directory |

The measurement options are also keyword arguments to `compare` (with
underscores instead of dashes).

`fail-on-regression` fails the job in a final step, after the report artifact has
been uploaded, so the comment is still posted. It is skipped when the benchmark
suite itself changed between the two revisions, since the comparison is then not
apples-to-apples.

## License

MIT.
