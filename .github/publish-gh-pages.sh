#!/usr/bin/env bash
# Publish to gh-pages exactly once per run, safely against concurrent publishers.
#
#   publish-gh-pages.sh deploy <version>    # mike deploy, no alias movement
#   publish-gh-pages.sh promote <version>   # move stable + latest onto <version>
#
# mike never calls `git fetch`, and it does not touch the working tree: it builds
# the commit with `git fast-import` and moves refs/heads/gh-pages with update-ref,
# trusting whatever `origin/gh-pages` already points at. So the base is ours to
# control. Each attempt:
#
#   1. fetch origin/gh-pages
#   2. reset the local gh-pages branch onto it (dropping any unpushed commit from
#      a previous rejected attempt, which would otherwise be duplicated)
#   3. let mike write the commit
#   4. fold CNAME and the pre-mike redirect stubs into that same commit
#   5. push once
#
# A push rejected because another run got there first is retried against the new
# head. That makes concurrent deploys and promotions safe, which is why the
# workflows no longer need a concurrency group (GitHub can only hold one pending
# run per group, so a group silently cancelled back-to-back deploys).
#
# Read from main at runtime (`git show origin/main:...`) so a frozen docs/vX.Y.Z
# branch never has to carry it.
set -uo pipefail

MODE="${1:?usage: publish-gh-pages.sh deploy|promote <version>}"
VERSION="${2:?usage: publish-gh-pages.sh deploy|promote <version>}"
REMOTE="${PUBLISH_REMOTE:-origin}"
BRANCH="${PUBLISH_BRANCH:-gh-pages}"
MAX_ATTEMPTS="${PUBLISH_ATTEMPTS:-8}"
WORKTREE="${PUBLISH_WORKTREE:-/tmp/ghpages}"

if [ "$MODE" != deploy ] && [ "$MODE" != promote ]; then
  echo "::error::unknown mode '$MODE'"
  exit 2
fi

run_mike() {
  if [ "$MODE" = deploy ]; then
    mike deploy "$VERSION"
  else
    mike alias --update-aliases "$VERSION" stable latest
    mike set-default latest
  fi
}

cleanup_worktree() {
  git worktree remove --force "$WORKTREE" 2>/dev/null || true
}

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  echo "::group::publish $MODE $VERSION (attempt $attempt/$MAX_ATTEMPTS)"

  git fetch --quiet "$REMOTE" "$BRANCH" main 2>/dev/null || git fetch --quiet "$REMOTE" main

  # Rebase the local branch on the current remote head. A branch that does not
  # exist yet is left absent so mike creates it.
  if git show-ref --verify --quiet "refs/remotes/$REMOTE/$BRANCH"; then
    git update-ref "refs/heads/$BRANCH" "refs/remotes/$REMOTE/$BRANCH"
  else
    git update-ref -d "refs/heads/$BRANCH" 2>/dev/null || true
  fi

  if ! run_mike; then
    echo "mike $MODE failed"
    echo "::endgroup::"
    attempt=$((attempt + 1))
    sleep $((attempt * 5))
    continue
  fi

  # Fold CNAME and the redirect stubs into mike's own commit so the run pushes
  # once instead of twice.
  cleanup_worktree
  if ! git worktree add -q "$WORKTREE" "$BRANCH"; then
    echo "failed to check out $BRANCH"
    echo "::endgroup::"
    attempt=$((attempt + 1))
    sleep $((attempt * 5))
    continue
  fi
  (
    set -e
    cd "$WORKTREE" || exit 1
    if [ "$(cat CNAME 2>/dev/null)" != "reference.librescoot.org" ]; then
      echo "reference.librescoot.org" > CNAME
    fi
    # The stub list comes from main, not from the pushed ref: a frozen
    # docs/vX.Y.Z branch will never carry this script, and the result has to be
    # identical whichever ref triggered the run.
    git show "$REMOTE/main:.github/restore-legacy-urls.py" | python3 - .
    if [ -n "$(git status --porcelain)" ]; then
      git add -A
      git commit --amend --no-edit --quiet
    fi
  )
  stamp_status=$?
  cleanup_worktree
  if [ "$stamp_status" -ne 0 ]; then
    echo "stamping CNAME/redirect stubs failed"
    echo "::endgroup::"
    attempt=$((attempt + 1))
    sleep $((attempt * 5))
    continue
  fi

  if git push --quiet "$REMOTE" "refs/heads/$BRANCH:refs/heads/$BRANCH"; then
    echo "::endgroup::"
    echo "published $MODE $VERSION on attempt $attempt"
    exit 0
  fi

  echo "push rejected; another publisher got there first, retrying against the new head"
  echo "::endgroup::"
  attempt=$((attempt + 1))
  sleep $((attempt * 5))
done

echo "::error::failed to publish $MODE $VERSION after $MAX_ATTEMPTS attempts"
exit 1
