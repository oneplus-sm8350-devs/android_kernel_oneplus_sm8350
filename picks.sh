#!/bin/bash
# picks.sh — run from repo root
# usage:
#   ./picks.sh gen   # prompt, fetch, and generate list
#   ./picks.sh       # process the list
#   ./picks.sh all   # generate then process

set -u  # handle errors explicitly; do not set -e

# resolve repo root and cd there
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  echo "error: run inside a git repo" >&2
  exit 1
fi
cd "$REPO_ROOT" || exit 1

# list file can be overridden via env LIST
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

# auto-resolve "deleted by us" conflicts if possible
auto_resolve_du() {
  # capture DU files from porcelain status (XY code "DU")
  local du
  du="$(git status --porcelain | awk 'substr($0,1,2)=="DU"{print substr($0,4)}')"
  if [ -n "$du" ]; then
    echo "auto-resolving deleted-by-us paths:"
    printf '%s\n' "$du"
    # shellcheck disable=SC2086
    git rm -- $du || return 1
    # if no more unmerged entries remain, we handled it
    if ! git status --porcelain | grep -Eq '^(UU|AA|DD|DU|UD) '; then
      return 0
    fi
  fi
  return 1
}

generate_list() {
  echo "generate commit list"

  read -r -p "Source URL or remote [https://android.googlesource.com/kernel/common]: " SRC
  SRC="${SRC:-https://android.googlesource.com/kernel/common}"

  read -r -p "Base ref (older, example android11-5.4): " BASE
  [ -n "$BASE" ] || die "base ref is required"

  read -r -p "Upstream ref (newer, example android13-5.10): " UP
  [ -n "$UP" ] || die "upstream ref is required"

  echo "Path filter is space separated. press enter for default"
  read -r -p "Paths [kernel/bpf]: " PATHS
  PATHS="${PATHS:-kernel/bpf}"

  echo "fetching $BASE and $UP from $SRC into local refs"
  git fetch --no-tags "$SRC" "$BASE:$BASE" "$UP:$UP" || die "fetch failed"

  echo "writing list to $LIST"
  # shellcheck disable=SC2086
  git log --no-merges --reverse --format="%H" "$BASE..$UP" -- $PATHS > "$LIST" || die "git log failed"
  echo "commit count: $(wc -l < "$LIST")"
}

process_list() {
  # handle an in-progress pick if we start mid-operation
  if [ -f "$(git rev-parse --git-dir)/CHERRY_PICK_HEAD" ]; then
    # empty paused pick -> auto skip
    if git diff --quiet && git diff --cached --quiet; then
      echo "startup: empty paused cherry-pick, skipping"
      git cherry-pick --skip
      drop_first
    else
      # try auto resolve "deleted by us" and continue
      if git status --porcelain | grep -Eq '^(UU|AA|DD|DU|UD) '; then
        if auto_resolve_du; then
          prefix_merge_msg_if_needed "BACKPORT:"
          if git cherry-pick --continue --no-edit; then
            drop_first
          else
            echo "startup: ready to continue but --continue failed"
            exit 2
          fi
        fi
      elif ! git status --porcelain | grep -q '^UU '; then
        # no unmerged paths, just continue
        prefix_merge_msg_if_needed "BACKPORT:"
        if git cherry-pick --continue --no-edit; then
          drop_first
        else
          echo "startup: ready to continue but --continue failed"
          exit 2
        fi
      fi
    fi
  fi

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

    # A) active conflicts or special states
    if git status --porcelain | grep -Eq '^(UU|AA|DD|DU|UD) '; then
      # first, try to auto-resolve deleted-by-us files
      if auto_resolve_du; then
        prefix_merge_msg_if_needed "BACKPORT:"
        if git cherry-pick --continue --no-edit; then
          drop_first
          continue
        else
          echo "auto-continue after DU resolution failed"
          exit 2
        fi
      fi

      # true unresolved conflict — let the user fix
      echo "conflict on $commit"
      prefix_merge_msg_if_needed "BACKPORT:"
      drop_first
      echo "resolve conflicts, stage with: git add -A"
      echo "continue with:              git cherry-pick --continue"
      echo "then run:                   ./picks.sh"
      exit 1
    fi

    # B) paused with no unmerged paths. try to continue automatically
    if [ -f "$(git rev-parse --git-dir)/CHERRY_PICK_HEAD" ]; then
      # B1) paused but empty. auto skip and continue
      if git diff --quiet && git diff --cached --quiet; then
        echo "empty change, auto skip"
        git cherry-pick --skip
        drop_first
        continue
      fi
      # B2) not empty. auto continue with BACKPORT prefix
      prefix_merge_msg_if_needed "BACKPORT:"
      if git cherry-pick --continue --no-edit; then
        drop_first
        continue
      else
        echo "ready to continue but --continue failed"
        exit 2
      fi
    fi

    # C) non paused and empty change. abort and drop
    if git diff --quiet && git diff --cached --quiet; then
      echo "empty change, skipping"
      git cherry-pick --abort || true
      drop_first
      continue
    fi

    echo "unexpected cherry-pick failure on $commit"
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
