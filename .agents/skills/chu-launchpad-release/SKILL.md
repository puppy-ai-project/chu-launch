---
name: chu-launchpad-release
description: Publish a Chu Launchpad release by incrementing its patch version, committing all current changes, pushing the branch, packaging the app, and publishing through the repository's GitHub Actions release workflow.
---

# Chu Launchpad Release

Use only in `/Users/ipuppy/dev/codex/NovaLaunch` when asked to prepare or publish a Chu Launchpad release.

## Release sequence

1. Confirm the repository root and `origin` is `https://github.com/puppy-ai-project/chu-launch.git`. Verify Git push authentication with a non-mutating remote check. `gh` is optional and must not be a prerequisite when Git authentication works. Use `gh auth status` only when `gh` is installed, and use `gh` for workflow monitoring when available.
2. Fetch remote branches and tags. Find the highest stable `vMAJOR.MINOR.PATCH` tag across local and remote tags; ignore non-semver and prerelease tags. If no version tag exists, use `1.0.0` as the first release. Otherwise increment the patch component by one. Stop if the proposed tag already exists locally or remotely.
3. Inspect `git status` and the current branch. Review the current diff so the commit contents are visible. Stage all current, non-ignored changes with `git add -A`; commit them as `release: vX.Y.Z`. If there are no changes, do not create an empty commit. Never amend or rewrite an existing commit.
4. Push the current branch to `origin` and verify it succeeded. Do not force push. Build both local release packages with `CHU_VERSION=X.Y.Z CHU_ARCH=arm64 sh scripts/package-release.sh build/release` and `CHU_VERSION=X.Y.Z CHU_ARCH=x86_64 sh scripts/package-release.sh build/release`; stop if either package fails.
5. Create an annotated tag `vX.Y.Z` at the release commit and push that tag to `origin`. This triggers `.github/workflows/release.yml`, which builds arm64 and Intel x64 ZIP/DMG installers and checksums, then creates the GitHub Release. Do not run `gh release create` as well; it would race the workflow and duplicate release creation.
6. Monitor the workflow with `gh run list --workflow release.yml` and `gh run watch RUN_ID` when `gh` is installed and authenticated. Otherwise inspect the GitHub Actions and Release pages through an available browser or query the public GitHub API. Confirm the run succeeded and the Release contains both architectures' ZIP, DMG, and checksum assets. Report the version, commit, tag, asset links, and any failure plainly.

## Safety and recovery

- The user invoking this skill to publish a release authorizes staging all current non-ignored changes, committing them, pushing the branch and tag, and creating the GitHub Release. Do not ask for another confirmation for those requested actions.
- If the worktree is on a detached HEAD, has unresolved conflicts, the remote differs, Git authentication fails, or a push/package/workflow step fails, stop before continuing downstream. Do not force push, delete tags, overwrite a Release, or repeatedly retry a rejected remote mutation. Report what succeeded and what remains.
- Keep generated `build/` artifacts out of the commit; the repository ignores them. GitHub Actions cross-compiles both arm64 and Intel x86_64 assets from the pushed tag.
- Version comes from the pushed tag and is written into the app by `scripts/package-release.sh`; do not edit a separate version constant.
- The current app build is unsigned and unnotarized. State this limitation in the completion report; do not claim Gatekeeper-ready distribution.
