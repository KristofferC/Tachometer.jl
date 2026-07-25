# Tachometer

Tachometer runs a package's benchmark suite at two git revisions and reports the
difference as a pull request comment. The intended use is a PR performance check:
benchmark the base branch and the PR, and point out the benchmarks that changed.

It expects a `benchmark/benchmarks.jl` that defines `const SUITE = BenchmarkGroup()`
— the same layout PkgBenchmark and AirspeedVelocity use, so an existing suite
works unchanged. For each revision it checks the source out into a temporary `git
worktree`, runs the suite in a separate Julia process, and takes the minimum time
per benchmark with BenchmarkTools. The benchmarking itself uses only BenchmarkTools
(plus JSON, TOML, and standard libraries) rather than PkgBenchmark, which is what
lets it interleave the two revisions across repeated runs (see below).

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

Benchmarks that did not change are kept in the collapsed "Full results" section.
Benchmarks that exist in only one of the revisions, or that could not be compared,
are listed separately and do not affect the verdict.

## What counts as a regression

A benchmark is reported as a regression only if the change is both relatively and
absolutely large enough, and holds up across repeated runs:

- **Tolerance and floor.** The time ratio has to exceed `1 + time-tolerance`
  (default 5%) *and* the absolute change has to exceed `time-floor` (default
  1 µs). The floor is on the change, not on the benchmark's size, so a +40% wiggle
  on a 200 ns benchmark (an 80 ns change) is ignored while a 200 ns → 2 µs change
  is not. Memory has its own tolerance and byte floor; a benchmark that allocated
  nothing and now allocates is always reported.

- **Repeated runs.** With `nruns > 1` the baseline and target are run
  interleaved, alternating which goes first, and a benchmark is only reported if
  every run agrees. This costs time but removes most one-off blips.

- **Learned noise.** Some benchmarks are just noisy on shared CI runners. If you
  point Tachometer at the published default-branch history (`noise-history`), it
  estimates how much each benchmark naturally moves run-to-run on the main branch
  (the median of consecutive relative changes, over records from the same
  OS/arch/Julia regime) and widens that benchmark's tolerance toward the learned
  spread, up to a cap (default 50%) so a large real regression is never hidden.
  The model is read **only** from master history — a pull request never writes to
  it, so a noisy or adversarial PR cannot train the tool to accept regressions. A
  change that would have been reported at the plain tolerance but sits inside the
  learned spread is listed in a "suppressed as noise" section rather than dropped.

If there is no baseline, the suite fails to run, or there is nothing to compare,
the comment says so (yellow), rather than reporting success.

## Release gate

When a PR bumps the `version` in `Project.toml`, the interesting comparison is
usually not against the merge-base but against the last release: a version bump is
about to become a tag, and this is the moment to catch any regression that slipped
in over the whole release cycle, from whatever PR. So with `release-baseline` on
(the default), if the target's version is higher than the baseline's, Tachometer
replaces the baseline with the previous `vX.Y.Z` release tag and notes this in the
comment. It has no effect on PRs that don't raise the version.

This needs the tags to be present — check out with `fetch-depth: 0`.

## Tracking the default branch over time

Separately from PR comparisons, Tachometer can record the absolute results of each
push to the default branch and publish an interactive time-series dashboard to
GitHub Pages. [`examples/track.yml`](examples/track.yml) runs on push (and on
release-tag pushes), benchmarks the commit, appends a record to a history file,
and publishes a dashboard showing each benchmark over time — filterable by name,
with a time/memory toggle, release markers, and points that link to the commit.

The dashboard is a static page (vendored [uPlot](https://github.com/leeoniya/uPlot),
no build step, no CDN). Data is stored sharded: a small `data/index.json` manifest
plus one `data/shard-YYYY.json` per calendar year. Each record carries the commit
metadata, the per-benchmark min time/memory/allocs, and an environment fingerprint
(OS, arch, Julia version, CPU); the dashboard marks where the fingerprint changes
so a runner/Julia change isn't mistaken for a performance change. Because past-year
shards are immutable, browsers cache them and each publish rewrites only the
current year's shard plus the tiny manifest — so neither the download nor the
`gh-pages` git history grows unboundedly. Release markers live in the manifest,
recomputed from `vX.Y.Z` tags on every publish, so a tag created after the commit
(e.g. by TagBot) still shows up without rewriting any shard.

Everything is published under a subdirectory (default `benchmarks/`) of the Pages
branch, and only that subdirectory is ever touched, so it **coexists with
Documenter** on the same `gh-pages` branch. The publish step fetches, merges, and
pushes with a retry loop, so a concurrent `deploydocs` neither clobbers it nor is
clobbered. The site ends up at `https://OWNER.github.io/REPO/benchmarks/`.

Setup: GitHub Pages must be set to "Deploy from a branch: `gh-pages` / root", and
the workflow needs `contents: write`.

## Local use

```julia
using Tachometer

# Working tree against master:
report = compare("."; baseline = "master")
print(render(report))

# Two explicit revisions, three interleaved runs. `noise_history` (optional) is a
# path to a published time-series `data/` dir; it is read-only, so the noise band
# is derived from that history but never written to.
report = compare("path/to/Pkg";
    baseline = "v1.2.0",
    target   = "my-branch",
    nruns    = 3,
    noise_history = nothing,
)
```

`baseline`/`target` are git refs; `target` may also be `Tachometer.WORKINGTREE`
(the default) to benchmark the current working tree, uncommitted changes included.

## Use on CI

Tachometer is a composite GitHub Action. Ready-to-copy workflows are in
[`examples/`](examples).

The action itself only measures and uploads the report as an artifact; it does
not post the comment. That split is deliberate: a `pull_request` job runs the PR's
(untrusted) benchmark code with a read-only token and no secrets, and a separate
`workflow_run` job — running from the default branch with write access, but never
executing PR code — downloads the artifact and posts the comment. This is the
setup GitHub recommends for commenting on pull requests from forks.

The trusted job does not post the fork-produced markdown; it re-renders the
comment from the structured `report.json` with its own Tachometer install, and
derives the PR number from the trusted event (not the artifact). So a malicious
fork can influence the numbers and benchmark names in the comment, but not inject
arbitrary markup, mentions, or links, and cannot redirect the comment to another
PR.

- [`benchmark.yml`](examples/benchmark.yml) + [`report.yml`](examples/report.yml):
  the two-workflow split above. Use this if PRs can come from forks.
- [`simple.yml`](examples/simple.yml): a single job that benchmarks and comments.
  Only works for PRs from the same repository. Do not change it to
  `pull_request_target` to get around that — that runs untrusted code with a
  write token.

```yaml
- uses: KristofferC/Tachometer.jl@<commit-sha>
  with:
    nruns: "2"
    time-tolerance: "0.05"
    time-floor: "1us"
    history: .tachometer/history.json
```

The `actions/cache` for the history file is scoped to the PR by GitHub, so
cross-PR learning is limited unless you also run the workflow on `push` to the
default branch, whose cache every PR can read.

## Options

| Option | Default | Meaning |
|---|---|---|
| `baseline` | merge-base of the PR | Revision to compare against |
| `target` | PR head / working tree | Revision under test |
| `script` | `benchmark/benchmarks.jl` | Suite entrypoint, defines `SUITE` |
| `time-tolerance` | `0.05` | Relative time change to report |
| `memory-tolerance` | `0.01` | Relative memory change to report |
| `time-floor` | `1us` | Absolute time change also required |
| `memory-floor` | `0` | Absolute byte change also required |
| `nruns` | `1` | Interleaved runs; all must agree |
| `fail-on-regression` | `false` | Fail the job on a regression |
| `release-baseline` | `true` | On a version bump, compare against the last release tag |
| `history` | — | Path to the noise-history file |

Gating (`fail-on-regression`) happens in a final step after the report artifact
is uploaded, so it is independent of whether the comment posted.

## License

MIT.
