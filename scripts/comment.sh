#!/usr/bin/env bash
# Post or update a single sticky PR comment, identified by a hidden marker.
#
# Usage: comment.sh <repo> <pr-number> <marker> <body-file>
#
# Idempotent: finds an existing comment that (a) contains the marker and (b) was
# written by github-actions[bot], and edits it in place; otherwise creates one.
# The marker is passed to jq via --arg (never interpolated into the program) and
# the body via --rawfile, so untrusted marker/body text cannot alter the query
# or forge JSON. Only ever touches the bot's own marker comment, and paginates
# so it works on busy PRs.
#
# Requires `gh` and `jq` (both preinstalled on GitHub-hosted runners) and a token
# with pull-requests: write in $GH_TOKEN.
set -euo pipefail

repo="$1"; pr="$2"; marker="$3"; body_file="$4"
needle="<!-- tachometer:${marker} -->"
# Which comment author to match for stickiness. Defaults to the Actions bot; set
# COMMENT_AUTHOR when posting with a GitHub App / PAT whose login differs.
author="${COMMENT_AUTHOR:-github-actions[bot]}"

# Find the bot's marker comment. No `|| true`: a listing failure must abort
# rather than look like "no comment yet" and create a duplicate.
# `gh api --paginate` emits one JSON array per page, so slurp (-s) all pages and
# flatten before selecting; otherwise `.[][]` would index into comment fields.
existing="$(gh api --paginate "repos/${repo}/issues/${pr}/comments" \
  | jq -rs --arg needle "$needle" --arg author "$author" '
      [ .[][] ]
      | map(select(.user.login == $author and (.body | contains($needle))))
      | (.[0].id // empty)')"

payload="$(jq -n --rawfile body "$body_file" '{body: $body}')"

if [ -n "${existing}" ]; then
  echo "Updating existing comment ${existing}"
  printf '%s' "$payload" | gh api --method PATCH "repos/${repo}/issues/comments/${existing}" --input - >/dev/null
else
  echo "Creating new comment"
  printf '%s' "$payload" | gh api --method POST "repos/${repo}/issues/${pr}/comments" --input - >/dev/null
fi
