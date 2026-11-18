#!/usr/bin/env bash
#
# Check in the project containing this script to the TARGET_BRANCH branch.
# Keep this script in the Git repository root.
#
set -Eeuo pipefail

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" \
    || die "This script must be placed inside a Git repository."

cd "$REPO_ROOT"

TARGET_BRANCH="uat"
CURRENT_BRANCH="$(git branch --show-current)"

[[ "$CURRENT_BRANCH" == "$TARGET_BRANCH" ]] || die \
    "You are on branch '$CURRENT_BRANCH', but this is the $TARGET_BRANCH check-in script.
Switch first with: git switch $TARGET_BRANCH"

git remote get-url origin >/dev/null 2>&1 \
    || die "No 'origin' remote is configured."

printf '\n========================================\n'
printf ' uat branch check-in\n'
printf '========================================\n'
printf 'Project : %s\n' "$REPO_ROOT"
printf 'Branch  : %s\n' "$TARGET_BRANCH"
printf 'Remote  : %s\n\n' "$(git remote get-url origin)"

git add -A

if git diff --cached --quiet; then
    printf 'No changes to check in. Working tree is clean.\n'
    exit 0
fi

git diff --cached --check || die "Whitespace check failed. Fix the issues before committing."

printf 'Changes staged for %s:\n' "$TARGET_BRANCH"
git diff --cached --stat
printf '\n'
git status --short

read -r -p "Commit message: " COMMIT_MESSAGE
[[ -n "${COMMIT_MESSAGE//[[:space:]]/}" ]] || die "Commit message cannot be empty."

read -r -p "Commit and push to origin/$TARGET_BRANCH? [y/N] " CONFIRM
case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *)
        printf 'Cancelled. Changes remain staged locally; nothing was pushed.\n'
        exit 0
        ;;
esac

git commit -m "$COMMIT_MESSAGE"

if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    git push origin "$TARGET_BRANCH"
else
    git push --set-upstream origin "$TARGET_BRANCH"
fi

printf '\nSUCCESS: committed and pushed to origin/%s.\n' "$TARGET_BRANCH"
