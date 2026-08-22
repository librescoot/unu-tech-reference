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

## The shape of a snapshot branch

**A snapshot is `main` plus exactly one commit.** That commit only removes or adjusts
what postdates the release. Keep it that way: it is what makes a cross-cutting fix on
main propagate by rebase instead of being re-derived by hand on six branches.

Snapshots do **not** carry site chrome. `zensical.toml`, `stylesheets/` and the
workflows come from main at build time, and nav entries pointing at pages a version
does not have are pruned automatically. Editing any of those on a snapshot branch has
no effect on what gets published. Editing a snapshot means editing its content `.md`,
nothing else.

The branch tips from before this model was adopted are kept as
`archive/docs-vX.Y.Z-preflatten` tags.

## How a branch becomes a version

The pipeline lives in `.github/workflows/deploy-impl.yml` **on main**. Every branch
carries only a thin caller, `.github/workflows/deploy.yml`, which holds the triggers.
Actions always reads triggers from the pushed ref, so that stub cannot be
de-versioned, but everything it does can: fixing the pipeline is one commit on main.

The version is derived from the branch name:

| Pushed branch  | Deploys as | Aliases |
|----------------|------------|---------|
| `main`         | `dev`      | none    |
| `docs/vX.Y.Z`  | `vX.Y.Z`   | none    |

A push never touches `stable` or `latest`. Publishing a version and promoting it are
separate acts on separate triggers, so re-pushing an old snapshot to correct an error
cannot take the aliases off the current release.

## Promoting a release to stable

Actions -> Deploy versioned docs -> Run workflow, and put the version in the `promote`
input (e.g. `v1.2.1`). That moves `stable` and `latest` onto it and makes it the
default served at `/`. It refuses versions that are not deployed yet, and it only
rewrites alias entries, so it never rebuilds or overwrites the version's own content.

Running the workflow with `promote` empty just rebuilds and redeploys the ref you
launched it from.

## Cutting a new stable release (say v1.0.6)

Do this once the v1.0.6 image is released and `main` already documents what it ships.

1. Branch from `main`:
   ```bash
   git fetch origin
   git switch -c docs/v1.0.6 origin/main
   ```
2. Make the snapshot match v1.0.6 exactly, in **one commit**. If anything on `main`
   postdates the release (a feature merged after the v1.0.6 cutoff), trim it here so
   the snapshot describes only what shipped. Verify against the service revisions
   pinned in `librescoot/librescoot:stable.env` at the release tag.

   > `stable.env` is only authoritative from **v1.0.3** onward. Before that the
   > `SRCREV_*` overrides were written to `local.conf` and then destroyed by a
   > truncating rewrite, so builds silently used `AUTOREV` (each service's main HEAD
   > at build time). Fixed by `76e4a1a fix SRCREV pinning`, which is contained in
   > v1.0.3 and later. Treat pre-v1.0.3 pins as a hypothesis, not a record.

3. Push the release branch:
   ```bash
   git push -u origin docs/v1.0.6
   ```
   CI deploys `v1.0.6` as a selectable version. It does not become stable yet.
4. Promote it: Actions -> Deploy versioned docs -> Run workflow, `promote` = `v1.0.6`.
   `stable` and `latest` move onto it and it becomes the default served at `/`. The
   previous release stays selectable as an older version.

## Correcting one version only

For an error specific to a single shipped release, amend that branch's trim commit so
the branch stays at one commit ahead of main:

```bash
git switch docs/v1.0.5
# fix the error
git commit --amend --no-edit
git push --force-with-lease
```
The push redeploys only that version and leaves the aliases alone, so correcting an
old snapshot cannot disturb which release is current.

## Propagating a fix to every version

Fix it once on `main`, then replay each snapshot's trim commit on top:

```bash
git switch main && git pull
for v in v1.0.3 v1.0.4 v1.0.5 v1.1.0 v1.2.0 v1.2.1; do
  git rebase main "docs/$v" && git push --force-with-lease origin "docs/$v"
done
```

A conflict means main changed text the trim also touches, which is exactly the case
worth a human's attention: that passage reads differently in that release. Resolve it
in favour of what the release actually shipped.

Rebasing rewrites the snapshot branches, so anyone holding a local copy needs
`git fetch && git reset --hard origin/docs/vX.Y.Z`. Tell them before you force-push.

Do not apply the same fix by hand on each branch. That is how the branches drift, and
a correction verified against one release is not automatically true for another whose
services are pinned to different commits.

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
The version dropdown only appears on the mike-deployed site, not in a local
single-version build. On a snapshot branch a local build uses that branch's own
`zensical.toml`, while CI uses main's, so local nav can differ from what ships.
