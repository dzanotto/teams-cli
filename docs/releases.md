# Releasing Teams CLI

## One-time setup

Commit and push `.github/workflows/ci.yml`, `.github/workflows/release.yml`, and
`scripts/package-release.sh` together with the documentation. GitHub Actions must
be enabled for the repository. No personal access token or custom secret is
required: the publishing job uses the built-in `GITHUB_TOKEN` with
`contents: write`; build and test jobs have read-only repository access.

CI runs on pull requests and pushes to `main`. The release workflow reuses the
same CI workflow from the tagged commit. Both select Xcode 16.4 on `macos-15`
(Apple Silicon) and `macos-15-intel`; update these selections together when the
hosted runner images retire the selected tools. Actions are pinned to commit IDs.

## Publish a version

Start with a clean checkout of the commit you want to release, normally the latest
`main` with passing CI. The commit must contain the workflow and packaging files.
Choose a new version and push that tag explicitly; for example:

```sh
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

That tag push is the publication decision. No additional manual approval is
required. Ordinary branch pushes never publish releases. Tags must have the form
`vMAJOR.MINOR.PATCH`, with no leading zeroes; prerelease and build suffixes are not
supported by this workflow. The tag is the version source, so there is no separate
version file to update.

Watch the **Release** run in the repository's **Actions** tab. It:

1. Validates the tag format.
2. Runs `swift test`, `swift build -c release`, and `teams-cli --help` on both
   native architectures.
3. Packages and extracts each archive, then runs the extracted executable's help
   command to check that it is runnable and retains its executable permission.
4. Downloads both archives and creates and verifies `SHA256SUMS`.
5. Checks that the remote tag still points to the tested commit, creates a draft
   GitHub Release with generated notes and all three assets, then publishes it.

For `v0.1.0`, the uploaded assets are:

```text
teams-cli-v0.1.0-macos-arm64.tar.gz
teams-cli-v0.1.0-macos-x86_64.tar.gz
SHA256SUMS
```

Each archive has one directory containing `teams-cli`, `README.md`, `LICENSE`,
`AGENTS.md`, `docs/`, and `BUILD-INFO.txt`. Build information records the version,
tag, source commit, architecture, working-tree status, and compiler version.
Archives are not Developer ID signed or notarized. Automated checks do not
establish live Teams compatibility; any live action checks remain a separate,
explicitly authorized activity.

## Verify downloads

Download the archive for your Mac and `SHA256SUMS` from the same release. From
that directory:

```sh
shasum -a 256 --check --ignore-missing SHA256SUMS
```

Confirm that the downloaded archive is reported as `OK`. `--ignore-missing`
allows you to download just one architecture. SHA-256 checksums detect corrupted
downloads; they are not Apple signing or notarization.

## Recover from a failed run

A failed test, build, package, or checksum step prevents publication. Fix source
or workflow errors on `main`, then release a new version tag. Do not move tags
that have already been published.

For a transient failure before draft creation, rerun the failed workflow from
GitHub Actions. A failure during asset upload or publication can leave an
unpublished draft. Inspect it in GitHub Releases; to retry from scratch, delete
only that unpublished draft, keep its Git tag, and rerun the workflow. Creation
refuses an existing release, including a draft, rather than replacing its assets.
If the release is already public, the publication succeeded and should not be
rerun to replace it.

## Check packaging locally

After a release build, this packages the native architecture without creating a
Git tag or contacting GitHub:

```sh
swift build -c release
bash scripts/package-release.sh v0.0.0 "$(uname -m)"
```

The archive is written under ignored `.build/release-assets/`. CI uses `v0.0.0`
for this smoke check on ordinary branch and pull-request runs; only release runs
upload their versioned archives for publication. Local packaging records a dirty
working tree in `BUILD-INFO.txt` when applicable.
