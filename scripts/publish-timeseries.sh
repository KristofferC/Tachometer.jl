#!/usr/bin/env bash
# Publish the benchmark history + dashboard to a subdirectory of a Pages branch,
# additively, so it coexists with Documenter (which owns the rest of the branch).
#
# Env in:
#   REPO           path to the main checkout (used for git tag lookups)
#   PAGES_BRANCH   branch to publish to (default gh-pages)
#   SUBDIR         subdirectory to own (default benchmarks)
#   RECORD         path to record.json to merge (empty/absent -> refresh only)
#   JULIA_PROJECT  project with Tachometer installed
#   REPO_URL       https URL of the repo (for commit links)
#   PACKAGE_NAME   display name
#
# Runs a fetch -> merge -> commit -> push loop, re-merging on push rejection so a
# concurrent Documenter deploy (or another run) never clobbers or is clobbered.
set -euo pipefail

REPO="${REPO:?}"; PAGES_BRANCH="${PAGES_BRANCH:-gh-pages}"; SUBDIR="${SUBDIR:-benchmarks}"
RECORD="${RECORD:-}"; JULIA_PROJECT="${JULIA_PROJECT:?}"; REPO_URL="${REPO_URL:-}"; PACKAGE_NAME="${PACKAGE_NAME:-}"

# Reject anything that could escape the intended subdirectory. Restrict to a
# conservative charset so it can't act as a pathspec option or regex.
case "$SUBDIR" in ""|.|/*|*..*) echo "invalid SUBDIR: '$SUBDIR'"; exit 1;; esac
printf '%s' "$SUBDIR" | grep -qE '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' \
  || { echo "invalid SUBDIR chars: '$SUBDIR'"; exit 1; }

cd "$REPO"
wt="$(mktemp -d)"

cleanup(){ git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"; }
trap cleanup EXIT

for attempt in 1 2 3 4 5; do
  cleanup; wt="$(mktemp -d)"
  git fetch --quiet origin "$PAGES_BRANCH" 2>/dev/null && exists=1 || exists=0
  if [ "$exists" = 1 ]; then
    git worktree add --quiet --detach "$wt" "origin/$PAGES_BRANCH"
  else
    git worktree add --quiet --detach "$wt"
    git -C "$wt" checkout --quiet --orphan "$PAGES_BRANCH"
    git -C "$wt" rm -rq --cached -r . 2>/dev/null || true
    find "$wt" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  fi

  # Reject planted symlinks BEFORE creating or writing anything, so mkdir/writes
  # cannot follow a symlink out of the worktree. Check each path component first.
  [ -L "$wt/.nojekyll" ] && { echo "refusing: .nojekyll is a symlink"; exit 1; }
  p="$wt"
  IFS='/' read -ra _parts <<< "$SUBDIR/data"
  for part in "${_parts[@]}"; do
    p="$p/$part"
    [ -L "$p" ] && { echo "refusing: symlink at $p"; exit 1; }
  done

  mkdir -p "$wt/$SUBDIR/data"
  touch "$wt/.nojekyll"   # ensure present; never removed

  # Also reject any symlink already present deeper under the subdir (e.g. a
  # symlinked history.json) before writing through it. No pipe (pipefail-safe).
  sym="$(find "$wt/$SUBDIR" -type l -print -quit)"
  [ -n "$sym" ] && { echo "refusing: symlink under $SUBDIR ($sym)"; exit 1; }
  # Belt and suspenders: the resolved subdir must live inside the worktree.
  case "$(cd "$wt/$SUBDIR" && pwd -P)/" in
    "$(cd "$wt" && pwd -P)"/*) ;;
    *) echo "refusing: $SUBDIR escapes the worktree"; exit 1;;
  esac

  TACHOMETER_MODE=publish \
  TACHOMETER_DATA_DIR="$wt/$SUBDIR/data" \
  TACHOMETER_DASHBOARD_DIR="$wt/$SUBDIR" \
  TACHOMETER_RECORD_IN="$RECORD" \
  TACHOMETER_PACKAGE="$REPO" \
  TACHOMETER_REPO_URL="$REPO_URL" \
  TACHOMETER_PACKAGE_NAME="$PACKAGE_NAME" \
    julia --project="$JULIA_PROJECT" --startup-file=no -e 'using Tachometer; Tachometer.main()'

  # Stage only our subdir and .nojekyll, so nothing outside can ever be committed
  # (Documenter's dirs are never added). Then verify the staged set — NUL-parsed
  # with a literal prefix check, no regex/word-splitting.
  git -C "$wt" add -A -- "$SUBDIR" .nojekyll
  while IFS= read -r -d '' path; do
    case "$path" in
      "$SUBDIR"/* | .nojekyll) ;;
      *) echo "refusing to publish; unexpected staged path: $path"; exit 1;;
    esac
  done < <(git -C "$wt" diff --cached --name-only -z)
  if git -C "$wt" diff --cached --quiet; then echo "no changes to publish"; exit 0; fi
  git -C "$wt" -c user.name="github-actions[bot]" \
                -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
                commit --quiet -m "Update benchmark history [skip ci]"

  if git -C "$wt" push --quiet origin "HEAD:$PAGES_BRANCH"; then
    echo "published to $PAGES_BRANCH/$SUBDIR"; exit 0
  fi
  echo "push rejected (attempt $attempt); refetching and retrying"
  sleep $((attempt * 3))
done

echo "failed to publish after retries"; exit 1
