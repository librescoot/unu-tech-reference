# Releasing the Tech Reference

The docs are versioned with [mike](https://github.com/jimporter/mike) (squidfunk's
Zensical-compatible fork). The Material header carries a version dropdown; each entry
is one deployed snapshot on the `gh-pages` branch. The site is served from `gh-pages`
at https://reference.librescoot.org/.

## The model: one trunk, frozen tags

- **`main` is the dev line.** It describes the current code across all services, and
  auto-deploys as the `dev` version on every push. All ongoing documentation work
  happens here.
- **`docs/vX.Y.Z` branches are frozen release snapshots.** Each one describes the code
  as it shipped in that LibreScoot release (e.g. `docs/v1.0.5` predates the
  motion-service refactor, so it still documents the `bmx` hash and alarm-service
  owning the IMU). They are deliberately behind `main`.

The single rule that keeps this sane:

> Build forward on `main`. Never base new work on a `docs/vX.Y.Z` branch. A frozen
> snapshot is two architectures behind the trunk; branching off it throws away
> everything documented since that release.

Touch a `docs/vX.Y.Z` branch only to correct an error specific to that shipped release.

## How a branch becomes a version

`.github/workflows/deploy.yml` derives the mike version from the branch name:

| Pushed branch  | Deploys as | Aliases               |
|----------------|------------|-----------------------|
| `main`         | `dev`      | none                  |
| `docs/vX.Y.Z`  | `vX.Y.Z`   | `stable` + `latest` if it equals `LATEST_STABLE`, else none |

The branch whose version equals the workflow's `LATEST_STABLE` also becomes the
default served at `/`. `LATEST_STABLE` is read from the deploy workflow *on the pushed
branch*, so it has to be correct on the release branch itself.

## Cutting a new stable release (say v1.0.6)

Do this once the v1.0.6 image is released and `main` already documents what it ships.

1. Branch from `main`:
   ```bash
   git fetch origin
   git switch -c docs/v1.0.6 origin/main
   ```
2. Make the snapshot match v1.0.6 exactly. If anything on `main` postdates the release
   (a feature merged after the v1.0.6 cutoff), trim it here so the snapshot describes
   only what shipped. Verify against the service revisions pinned in
   `librescoot/librescoot:stable.env` at the release tag.
3. Set `LATEST_STABLE` to `"v1.0.6"` in this branch's `.github/workflows/deploy.yml`.
   Also bump it on `main` (in a normal `main` commit) so the next release branch
   inherits the right value.
4. Push the release branch:
   ```bash
   git push -u origin docs/v1.0.6
   ```
   CI deploys `v1.0.6`, moves `stable`/`latest` onto it, and makes it the default.
   v1.0.5 stays selectable as an older version.

## Correcting an already-shipped version

```bash
git switch docs/v1.0.5
# fix the error, commit
git push
```
The push redeploys only that version. If the fix also applies to newer versions, make
it on `main` too (and on the other affected `docs/vX.Y.Z` branches).

## Caveat: push release branches one at a time

The deploy uses a single `mike-deploy` concurrency group. GitHub keeps only one
*pending* run per group, so pushing several `docs/v*` branches at once leaves the
last one pending and cancels the earlier ones. When bootstrapping or back-filling
multiple versions, push them one at a time (or re-run the cancelled deploys
sequentially from the Actions tab). Cutting one release at a time never hits this.

## Local preview

```bash
mkdir -p docs && cp README.md docs/index.md
for d in battery battery-charger bluetooth dashboard electronic mechanical nrf redis services states tools wiring; do cp -r "$d" "docs/$d"; done
cp -r stylesheets docs/stylesheets
python -m zensical serve   # or: zensical build
```
The version dropdown only appears on the mike-deployed site, not in a local single-version build.
