# CI tool installs no longer depend on one Ubuntu archive mirror

On 2026-11-11 GitHub-hosted runners (Ubuntu 26.04, image 20261101.186.1) could not resolve
`azure.archive.ubuntu.com`, `archive.ubuntu.com` or `security.ubuntu.com`, so every `apt-get` step in
`ci.yml` failed before any test ran. `scripts/ci/install-tool.sh` now provisions the tools:

- `z3`: the pinned upstream release zip (4.13.3, the version the runner's Ubuntu release packages), verified
  by SHA-256 and installed under `/opt`; `apt` only if GitHub itself cannot be reached.
- `aot-prereqs`: uses the clang, binutils and zlib development files the runner image already ships (clang
  20, 21 and 22 are in the image README); anything missing comes from `apt`, and the zlib development files
  from a pinned, SHA-256-verified zlib 1.3.1 source tarball as the last resort.
- `apt PKG...`: installs only the packages that are missing, from the runner's own mirrors, then from
  alternate Ubuntu archive mirrors. apt still verifies every index against the Ubuntu archive keyring.

`ui-browser-e2e.sh` installs Chromium from Playwright's own download and adds system packages (through the
same helper) only if Chromium cannot launch, instead of `playwright install --with-deps`. The native e2e
scripts and `native-platforms.yml` call the helper. `ci.yml` shrank by 465 bytes. Tool versions are
unchanged; the .NET toolchain pins (#8989) are untouched.

The workflows that do not run on pull requests (`publish.yml`, `seed-candidacy.yml`, `stage2-self-test.yml`,
`manual-test.yml`) still call `apt-get` directly; tracked in a follow-up issue.
