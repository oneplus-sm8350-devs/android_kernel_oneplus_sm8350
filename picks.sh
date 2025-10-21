#!/bin/bash
# picks.sh
# place in your repo root, then: chmod +x picks.sh
# it can generate the commit list and then process it

set -u  # handle failures in code, do not -e

# default list file lives in the repo root
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  echo "error: run inside a git repo" >&2
  exit 1
fi
cd "$REPO_ROOT"

LIST="${LIST:-$REPO_ROOT/backport_commits.txt}"

die() { echo "error: $*" >&2; exit 1; }

drop_first() {
  [ -f "$LIST" ] || return 0
  local tmp="${LIST}.tmp.$$"
  tail -n +2 "$LIST" > "$tmp" && mv "$tmp" "$LIST"
}

amend_prefix() {
  local prefix="$1"
  local subj body
  subj="$(git log -1 --pretty=%s)"
  if [[ "$subj" != $prefix* ]]; then
    body="$(git log -1 --pretty=%b)"
    git commit --amend -m "$prefix $subj" -m "$body"
  fi
}

prefix_merge_msg_if_needed() {
  local prefix="$1"
  local mfile
  mfile="$(git rev-parse --git-dir)/MERGE_MSG"
  if [ -f "$mfile" ]; then
    local first
    first="$(head -n1 "$mfile")"
    if [[ "$first" != "$prefix "* ]]; then
      sed -i "1s|^|$prefix |" "$mfile"
    fi
  fi
}

generate_list() {
  echo "generate commit list"

  # prompt for source
  read -r -p "Source URL or remote for refs [https://android.googlesource.com/kernel/common]: " SRC
  SRC="${SRC:-https://android.googlesource.com/kernel/common}"

  # prompt for base and upstream refs to diff
  read -r -p "Base ref (older, example android11-5.4): " BASE
  [ -n "$BASE" ] || die "base ref is required"

  read -r -p "Upstream ref (newer, example android13-5.10): " UP
  [ -n "$UP" ] || die "upstream ref is required"

  # prompt for path filter
  read -r -p "Path filter space separated [kernel/bpf]: " PATHS
  PATHS="${PATHS:-kernel/bpf}"

  echo "fetching $BASE and $UP from $SRC into local refs"
  # fetch directly without adding a remote
  git fetch --no-tags "$SRC" "$BASE:$BASE" "$UP:$UP" || die "fetch failed"

  echo "writing list to $LIST"
  # shellcheck disable=SC2086
  git log --no-merges --reverse --format="%H" \
    "$BASE..$UP" -- $PATHS > "$LIST" || die "git log failed"

  echo "commit count: $(wc -l < "$LIST")"
}

process_list() {
  echo "processing commits from $LIST"
  while true; do
    if ! read -r commit < "$LIST"; then
      echo "done. no more commits in $LIST"
      exit 0
    fi
    commit="${commit%% *}"

    echo "cherry picking $commit"
    if git cherry-pick -x "$commit"; then
      amend_prefix "UPSTREAM:"
      drop_first
      continue
    fi

    # conflict
    if git status --porcelain | grep -q '^UU '; then
      echo "conflict on $commit"
      prefix_merge_msg_if_needed "BACKPORT:"
      drop_first
      echo "resolve conflicts, stage with: git add -A"
      echo "continue with:              git cherry-pick --continue"
      echo "then re run:                ./picks.sh"
      exit 1
    fi

    # empty change
    if git diff --quiet && git diff --cached --quiet; then
      echo "empty change, skipping"
      git cherry-pick --abort || true
      drop_first
      continue
    fi

    echo "unexpected cherry pick failure on $commit"
    exit 2
  done
}

case "${1:-}" in
  gen|generate)
    generate_list
    ;;
  run|"")
    [ -f "$LIST" ] || die "list file not found. run: ./picks.sh gen"
    process_list
    ;;
  all)
    generate_list
    process_list
    ;;
  *)
    echo "usage:"
    echo "  ./picks.sh gen        # prompt, fetch, and generate $LIST"
    echo "  ./picks.sh            # process commits in $LIST"
    echo "  ./picks.sh all        # generate then process"
    exit 1
    ;;
esac
