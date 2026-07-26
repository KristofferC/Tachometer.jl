#!/usr/bin/env bash
# Flag an existing sticky comment as superseded while a new run is in flight, so
# the numbers already on the PR aren't read as results for the latest commit.
#
# Usage: mark-running.sh <repo> <pr-number> <marker> <head-sha> [run-url]
#
# Inserts a banner immediately after the hidden marker line (the first line of a
# rendered report), leaving the rest of the body untouched. The next completed
# report replaces the whole body, which clears the banner again.
#
# No-ops when there is no marker comment yet (nothing stale to warn about, and
# posting one would just be noise) and when the banner is already present, so it
# is safe to run on every push.
#
# The body is rebuilt with jq from the fetched comment (never with sed on
# untrusted text), and the marker/sha/url are validated before they reach it.
#
# Requires `gh` and `jq` (both preinstalled on GitHub-hosted runners) and a token
# with pull-requests: write in $GH_TOKEN.
set -euo pipefail

repo="$1"; pr="$2"; marker="$3"; sha="$4"; run_url="${5:-}"

[[ "$marker" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid marker: '$marker'"; exit 1; }
[[ "$sha" =~ ^[0-9a-fA-F]{7,40}$ ]] || { echo "invalid sha: '$sha'"; exit 1; }
case "$run_url" in
  ""|https://*) ;;
  *) echo "ignoring non-https run url"; run_url="";;
esac

needle="<!-- tachometer:${marker} -->"
# Hidden id of the banner itself, so re-runs detect it without matching prose.
banner_id="<!-- tachometer:${marker}:running -->"
# Which comment author to match for stickiness. Same contract as comment.sh.
author="${COMMENT_AUTHOR:-github-actions[bot]}"

# One listing, reused for both the id and the body. No `|| true`: a listing
# failure must abort rather than look like "no comment yet".
comments="$(gh api --paginate "repos/${repo}/issues/${pr}/comments")"

existing="$(printf '%s' "$comments" | jq -rs --arg needle "$needle" --arg author "$author" '
    [ .[][] ]
    | map(select(.user.login == $author and (.body | contains($needle))))
    | (.[0].id // empty)')"

if [ -z "$existing" ]; then
  echo "no existing ${marker} comment; nothing to mark"
  exit 0
fi

body="$(printf '%s' "$comments" | jq -rs --argjson id "$existing" '
    [ .[][] ] | map(select(.id == $id)) | .[0].body')"

case "$body" in
  *"$banner_id"*) echo "comment ${existing} already marked as re-running"; exit 0;;
esac

short="${sha:0:7}"
if [ -n "$run_url" ]; then link="[the run in progress](${run_url})"; else link="the run in progress"; fi
# Trailing newline so the splice leaves a blank line before the report heading.
banner="${banner_id}
> [!NOTE]
> ⏳ **Benchmarks are re-running for \`${short}\`.** The results below are from an
> earlier commit — check ${link} before reading them as current.
"

# Splice the banner in after the marker line; join back with the original body.
payload="$(jq -n --arg body "$body" --arg banner "$banner" '
    {body: (($body | split("\n")) as $l | ([$l[0], $banner] + $l[1:]) | join("\n"))}')"

printf '%s' "$payload" | gh api --method PATCH "repos/${repo}/issues/comments/${existing}" --input - >/dev/null
echo "marked comment ${existing} as re-running for ${short}"
