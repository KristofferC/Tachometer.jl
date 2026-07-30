# Using the dashboard with your own benchmark runner

The dashboard does not care where the numbers come from. It is three static
files (this directory) plus a `data/` directory of plain JSON, fetched at page
load — no build step, CDN, account, or server application. You can keep it
entirely on your machine or publish the same directory to any static host.

Tachometer's own [`track.yml`](../examples/track.yml) workflow is one producer
of this format; this document specifies the format so you can be another.

## Preview the dashboard

The [live example](https://kristofferc.github.io/Tachometer.jl/demo/) contains
synthetic regressions, releases, and runner changes.

To build that same demo locally from a Tachometer checkout:

```sh
demo_dir="$(mktemp -d)"
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. scripts/generate-demo-data.jl "$demo_dir"
python3 -m http.server --directory "$demo_dir" 8000
```

Then open <http://localhost:8000/>. The last command is only a static file
server; it does not upload anything. Browsers do not allow the dashboard to
fetch its JSON when `index.html` is opened directly as a `file://` URL.

## Site layout

Everything lives in one directory:

```
benchmarks/                  any name; the page URL ends up at .../benchmarks/
├── index.html               the dashboard (this directory)
├── uPlot.iife.min.js        vendored chart library (this directory)
├── uPlot.min.css            vendored chart styles (this directory)
└── data/
    ├── index.json           manifest: shard list, releases, metadata
    ├── shard-2025.json      records for commits dated in 2025 (UTC)
    └── shard-2026.json      … one file per calendar year
```

For GitHub Pages, also put a `.nojekyll` file at the root of the Pages branch.

To get the three assets, either copy them from this directory (pin a
commit/tag so you can update deliberately), or from Julia:

```julia
using Tachometer
Tachometer.write_dashboard("site")   # writes the three files into site/
```

The assets are stateless and safe to overwrite; all history is
under `data/`.

## The data format

### `data/index.json` — the manifest

Fetched with `cache: no-store` on every page load, so keep it small.

```json
{
  "schema": "tachometer-timeseries",
  "version": 3,
  "package": "MyPkg.jl",
  "repo_url": "https://github.com/me/MyPkg.jl",
  "shards": ["shard-2025", "shard-2026"],
  "releases": [
    { "tag": "v1.2.0", "commit": "0123456789abcdef0123456789abcdef01234567",
      "date_unix": 1735689600 }
  ],
  "latest_fingerprint": { "os": "Linux", "arch": "aarch64", "julia": "1.11.3",
                          "threads": 1, "cpu": "Neoverse-N2" },
  "generated_at": "2026-07-30T12:00:00Z"
}
```

| Field | Meaning |
|---|---|
| `schema` / `version` | Must be `"tachometer-timeseries"` / `3`. Version 2 histories are read as snapshots and upgraded on their next write. |
| `package` | Display name in the page header. Optional. |
| `repo_url` | `https://` base URL for commit links (`<repo_url>/commit/<sha>`). `null` disables links. |
| `shards` | Names (without `.json`) of the shard files to fetch, `shard-YYYY` only. |
| `releases` | Release markers: `tag`, `commit` (hex sha), `date_unix`. Drawn as dashed lines and used by the compare page. Maintain this list yourself — e.g. regenerate it from your `vX.Y.Z` git tags on every publish, which is what Tachometer does so that tags created after the fact (TagBot) still show up. |
| `latest_fingerprint` | Fingerprint of the newest record; shown in the header gauge. |
| `generated_at` | ISO timestamp of the last publish. Used as a cache-buster for the current shard. |

### `data/shard-YYYY.json` — the records

```json
{ "records": [ { …record… }, { …record… } ] }
```

A record belongs to the shard of the **UTC calendar year of its commit date**
(`date_unix`). This rule matters: it makes shard assignment deterministic, so
past-year shards do not change during normal forward-moving measurements
(browsers cache them and git does not re-store them). Correcting a commit date
or backfilling an older result can rewrite an older shard. A browser may keep
that older response until the static host's cache expires (allow about ten
minutes on GitHub Pages); use a hard refresh if you need to inspect the change
immediately. Keep records within a shard sorted by `date_unix`.

### A record

One benchmarked commit:

```json
{
  "commit": "60ab91e0123456789abcdef0123456789abcdef0",
  "date": "2026-07-30T09:41:00Z",
  "date_unix": 1785490860,
  "recorded_at": "2026-07-30T10:02:11Z",
  "message": "Hoist sparsity lookup out of the assembly inner loop",
  "version": "1.2.1-DEV",
  "julia_version": "1.11.3",
  "fingerprint": { "os": "Linux", "arch": "aarch64", "julia": "1.11.3",
                   "threads": 1, "cpu": "Neoverse-N2" },
  "coverage": "partial",
  "removed_benchmarks": [],
  "benchmarks": {
    "assembly/global": { "time": 11800000.0, "memory": 6900000, "allocs": 15240 },
    "solve/cg":        { "time": 148000000.0 }
  }
}
```

| Field | Required | Meaning |
|---|---|---|
| `commit` | yes | Lowercase hex sha, 7–40 chars (full shas make commit links work). Snapshot records replace this commit; partial records merge into it. |
| `date_unix` | yes | Commit date as unix seconds. Orders the timeline and picks the shard. Use the *commit* date, not the benchmark time, so re-runs land in the same place. |
| `benchmarks` | yes | Map of benchmark name → statistics. It may be empty only when a partial record contains explicit removals. |
| `coverage` | no | `"snapshot"` (default when absent) means `benchmarks` is the complete suite. `"partial"` means only selected benchmarks were measured. |
| `removed_benchmarks` | no | Names explicitly retired by a partial record. Default: `[]`. |
| `date` | recommended | Commit date as an ISO string; shown in commit lists and tooltips. |
| `message` | no | Commit subject line. |
| `version` | no | The project's version at that commit. |
| `recorded_at`, `julia_version` | no | Bookkeeping; not currently rendered. |
| `fingerprint` | recommended | The measurement regime, see below. |

Benchmark statistics — any non-empty subset per benchmark:

| Key | Unit |
|---|---|
| `time` | nanoseconds |
| `memory` | bytes |
| `allocs` | count |
| `instructions` | count |

The dashboard shows a tab for each statistic that appears anywhere in the
history, so a runner that measures e.g. instruction counts but not
allocations just writes the keys it has. Values must be non-negative finite
numbers.
Grouping is by name prefix: `"assembly/global"` files under an **assembly**
group; names without a `/` are shown first, outside any group.

### Snapshots and partial uploads

The dashboard must know whether an absent benchmark was deleted or merely not
measured:

- A `"snapshot"` record contains the complete suite. Benchmarks absent from it
  become inactive. Tachometer's normal tracking workflow writes snapshots.
- A `"partial"` record updates only the benchmarks it contains. Other active
  benchmarks stay visible, with a gap at that commit.
- `removed_benchmarks` explicitly deactivates names during a partial upload.

Records without `coverage` are snapshots, so existing histories keep their
current behavior. Several partial uploads for the same commit are merged.
Their fingerprints must match; Tachometer refuses to combine measurements from
different machines or runtimes into one commit record.

The benchmark graphs show every partial measurement and mark stale latest
values in their tooltip. Aggregate Overview and commit-delta points omit partial
records because changing coverage would produce a misleading geomean. The
Compare page labels partial selections and uses only values actually measured
at the selected commits.

### The fingerprint

`fingerprint` records *what machine and toolchain measured this*, so that a
CI runner swap is not mistaken for a performance change. Recognised keys:
`os`, `arch`, `cpu`, `threads`, `julia` (compared as major.minor), and
`backend` — all optional, all free-form strings/numbers. When any of them
changes between consecutive records the dashboard draws an environment-change
marker at that commit and re-baselines the percent views there. Extra keys
(like Tachometer's `suite` script hash) are stored but ignored for this
comparison. Use whichever keys fit your stack — `julia` can just as well
carry a compiler or runtime version.

## Adding an entry

### From Julia

```julia
using Dates
using Tachometer

rec = Tachometer.make_record(
    Dict(
        "assembly/global" => (time = 11.8e6, memory = 6.9e6, allocs = 15_240),
        "solve/cg"        => (time = 148.0e6,),
    );
    commit  = "60ab91e0123456789abcdef0123456789abcdef0",
    date    = DateTime(2026, 7, 30, 9, 41),   # the commit date (UTC), or unix seconds
    coverage = :partial,                       # selected results, not the complete suite
    message = "Hoist sparsity lookup out of the assembly inner loop",
    version = "1.2.1-DEV",
)

Tachometer.add_record!("site/data", rec;
    package  = "MyPkg.jl",
    repo_url = nothing,  # no repository links in a local-only dashboard
)
Tachometer.write_dashboard("site")
```

Serve `site` with the command in [Preview the dashboard](#preview-the-dashboard)
and keep adding records as measurements arrive. No GitHub setup is required.

`make_record` validates names, recognized statistics, and values;
`add_record!` upserts by commit sha into the right year shard, updates the
manifest, and refuses to clobber history it cannot parse. `package`, `repo_url`,
and `releases` are left alone when omitted. Pass `repo_url = nothing` to remove
repository links and `releases = []` to remove release markers. The fingerprint
defaults to the current machine (`Tachometer.default_fingerprint()`); pass your
own to override. Omit `coverage` for a complete snapshot. To retire a benchmark
during an incremental run, pass `removed_benchmarks = ["old/name"]`; the
measurement dictionary may be empty when the record only removes names.

### From any other language

The storage is plain JSON, so "the API" is the upsert algorithm:

1. Read `data/index.json`; if absent, start from the empty manifest
   (`schema`/`version` as above, empty `shards` and `releases`). If present
   but unparsable, **stop** rather than overwrite someone's history.
2. Compute the record's shard name: `"shard-" + year(date_unix, UTC)`.
3. Find any record with the same `commit` across the listed shards. A snapshot
   replaces it. A partial record merges its measured benchmarks, applies
   `removed_benchmarks`, and remains partial unless the existing record was a
   snapshot. Require identical fingerprints before merging. Then put the result
   in the target year shard and sort by `date_unix`; looking across shards
   matters if a corrected commit date moves it to another year.
4. Update the manifest: add the shard name to `shards` (sorted), set
   `latest_fingerprint` from the chronologically newest record, update
   `releases` as needed, set `generated_at`, and write it back.
5. Copy the three dashboard assets next to `data/` (they are safe to
   overwrite).

If you later publish with GitHub Actions,
[`scripts/publish-timeseries.sh`](../scripts/publish-timeseries.sh) shows the
robust way to push: commit only your subdirectory of the Pages branch inside a
fetch → merge → push retry loop, so concurrent deploys (e.g. Documenter)
neither clobber you nor get clobbered.

## Serving your own data locally

Run this from any directory:

```sh
python3 -m http.server --directory site 8000
```

Open <http://localhost:8000/> and reload after adding records. Stop the server
with Ctrl-C. Publishing is optional; the local directory is the complete
dashboard.
