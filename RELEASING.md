# Releasing dhis2-tools

The rules are in `architecture.md` (Versions and releases). This is the order of the steps.

1. **Build** on `release/<x.y.z>`, with `VERSION` = `x.y.z-dev`. Every change adds its line under "Unreleased" in
   `CHANGELOG.md` (Added / Changed / Fixed / Security / Upgrade notes) in the same commit.
2. **Release candidate**, for the test server: `tools/release.sh x.y.z-rc.N` sets `VERSION`, commits and tags `vx.y.z-rc.N`.
   Push it and publish it as a pre-release with the commands it prints. Fixes found in testing go on the same branch,
   then the next `rc.N`.
3. **Release**, once tested and approved: `tools/release.sh --dry-run x.y.z`, then `tools/release.sh x.y.z`. It moves
   "Unreleased" to `[x.y.z] - <date>`, sets `VERSION` = `x.y.z`, commits and tags `vx.y.z`. Nothing is pushed.
4. **Publish** with the printed commands: push the branch and the tag, create the GitHub Release (notes from
   `tools/release.sh --notes x.y.z`), fast-forward `master` to the tag (only with the maintainer's yes), then delete the
   branch locally and on GitHub. The tag keeps the release.
5. **Next version**: `git checkout -b release/<next> vx.y.z`, set `VERSION` to `<next>-dev` and commit.
6. **Hotfix** (newest release only): `git checkout -b hotfix/x.y.(z+1) vx.y.z`, fix, add the change under "Unreleased", then
   steps 3–4 with `x.y.(z+1)`. Merge the hotfix into the current `release/` branch before deleting it.

Tags are never deleted or moved. `tools/release.sh` refuses to run on a dirty tree, on the wrong branch, for an existing tag,
for a version not newer than the newest release, for an empty "Unreleased", or when `bash -n` fails on any script.
