# 39 — Lyric Package Registry

**Status:** Specced in D074. Open questions Q-R-001–Q-R-004.

---

## 1. Problem

`docs/34-distribution-strategy.md` covers distributing the `lyric` compiler and
`Lyric.Stdlib.dll`. It says nothing about how third-party Lyric libraries (e.g.
`lyric-cache`, `lyric-web`, `lyric-grpc`) are published and consumed.

Lyric needs a package registry — a place where `lyric publish` deposits compiled
packages and `lyric restore` fetches them. The constraint is that this must not
require standing up bespoke infrastructure equivalent to NuGet Gallery or Maven
Central.

This document specifies:

- Which existing infrastructure serves as the Lyric package registry.
- The `lyric publish` flow for library authors.
- The `lyric restore` and dependency-resolution flow for consumers.
- Discovery (`lyric search`).
- Private and organisation-scoped registries.
- The lock-file checksum model.

The workspace and git-dep mechanisms for in-repo and pre-release dependencies
are specified in `docs/38-workspace.md`.

---

## 2. Registry channels

Lyric packages are compiled assemblies — DLLs on .NET, JARs on JVM. Rather than
a bespoke file store, the package registry piggybacks on existing, well-operated
package feeds for each target:

| Target | Primary registry | Notes |
|---|---|---|
| `.NET` | **NuGet.org** | Free, CDN-backed, globally available, supports package signing. |
| `JVM` | **GitHub Packages Maven** | Free for public packages; requires a GitHub token for reads (Q-R-001). Maven Central is the long-term target but requires GPG signing and Sonatype OSSRH (Q-R-002). |

The `lyric` toolchain wraps all push and pull operations — authors and consumers
never call `dotnet nuget push` or `mvn deploy` directly.

**Default feed URLs** (baked into the toolchain; overridable per project, see §6):

```
dotnet: https://api.nuget.org/v3/index.json
jvm:    https://maven.pkg.github.com/nichobbs/lyric-lang
```

---

## 3. Package identity

### 3.1 .NET packages (NuGet)

The Lyric package name (from `[package].name` in `lyric.toml`) maps 1:1 to the
NuGet package ID:

| Lyric package name | NuGet package ID |
|---|---|
| `Lyric.Cache` | `Lyric.Cache` |
| `Lyric.Web` | `Lyric.Web` |
| `MyOrg.Analytics` | `MyOrg.Analytics` |

Package version matches `[package].version`. Lyric uses semver (`MAJOR.MINOR.PATCH`
with optional pre-release suffix: `0.2.0-beta.1`).

Every published Lyric package carries the NuGet tag `lyric-package`. This tag is
the discriminator used by `lyric search` and by the NuGet.org search API to
distinguish Lyric packages from ordinary C# packages.

### 3.2 JVM packages (Maven)

Maven uses a `groupId:artifactId:version` triple. The mapping:

| Lyric package name | Maven coordinates |
|---|---|
| `Lyric.Cache` | `io.lyric-lang:lyric-cache:0.1.0` |
| `Lyric.Web` | `io.lyric-lang:lyric-web:0.1.0` |
| `MyOrg.Analytics` | `io.lyric-lang:myorg-analytics:0.1.0` |

Rules:
- `groupId` is always `io.lyric-lang` for first-party packages. Third-party
  packages may use their own group ID; see §6 for custom registry configuration.
- `artifactId` is the lowercased, dot-to-hyphen-converted package name.
- `version` matches `[package].version`.

---

## 4. `lyric publish`

`lyric publish` turns a built package into a feed artifact and uploads it.

### 4.1 .NET publish flow

```
lyric publish [--manifest <lyric.toml>] [--no-build] [--registry <url>] [--api-key <key>]
```

Steps performed by the CLI:

1. **Build** — runs `lyric build --manifest lyric.toml --target dotnet` (skipped
   if `--no-build` is passed and `.lyric/out/<name>.dll` already exists).

2. **Generate `.nuspec`** — synthesises a NuGet spec from `lyric.toml`:
   - `id` = `[package].name`
   - `version` = `[package].version`
   - `authors`, `description`, `license` from `[package]`
   - `tags` = `lyric-package` plus any `[package].tags` entries
   - `<dependencies>` = `[nuget]` entries from `lyric.toml` (raw native deps
     declared by the library; consumers get these transitively — see
     `docs/38-workspace.md` §4)
   - `<files>` = the compiled DLL(s)

3. **Pack** — calls `dotnet pack` on a generated `.csproj` wrapping the
   `.nuspec`. The `.nupkg` contains:
   ```
   lib/net10.0/<PackageName>.dll   # compiled Lyric assembly
   lyric.toml                      # source manifest, embedded as content
   ```

4. **Sign** (optional) — `dotnet nuget sign` if `LYRIC_NUGET_SIGNING_CERT` env
   var points at a PFX file (or GitHub Actions secret). Signing is optional for
   pre-v1.0 packages; required for packages published to the official
   first-party feed once `v1.0` ships.

5. **Push** — `dotnet nuget push <pkg>.nupkg --source <registry-url>
   --api-key <key>`. The API key comes from (in precedence order):
   `--api-key`, `LYRIC_NUGET_API_KEY` env var, `~/.lyric/credentials.toml`.

6. **Record** — appends a `[[published]]` entry to `lyric.lock` with the package
   name, version, and SHA-512 of the `.nupkg`.

**Workspace `{ workspace = true }` deps are substituted** for registry-version
deps before the `.nuspec` is generated (see `docs/38-workspace.md` §5). If a
sibling dep has not been published at the declared version, the publish fails
with a list of unpublished dependencies.

### 4.2 JVM publish flow

```
lyric publish --target jvm [--registry <maven-url>] [--token <github-token>]
```

Steps:

1. **Build** — `lyric build --target jvm`.
2. **Generate POM** — synthesises a `pom.xml` from `lyric.toml`.
3. **Package** — produces a JAR containing the compiled `.class` files and the
   `lyric.toml` as a META-INF resource.
4. **Deploy** — calls the bundled Maven wrapper: `mvnw deploy -DaltDeploymentRepository=...`.
   Authentication uses a GitHub token for GitHub Packages, or `settings.xml`
   credentials for Maven Central.

JVM publish is deferred until Phase 6 ships; the `.NET` publish path is the
v1.0 deliverable.

---

## 5. `lyric restore`

`lyric restore` fetches all resolved dependencies and places them in the local
cache (`~/.lyric/pkg-cache/`).

### 5.1 Resolution algorithm

1. **Read** `[dependencies]` from `lyric.toml`.
2. **Resolve** each dep according to its source form:
   - `{ workspace = true }` → local path from workspace index (no network).
   - `{ git, tag/rev/branch }` → `~/.lyric/git-cache/` (fetch if absent).
   - `"1.0.0"` (registry form) → query the NuGet feed for the package.
3. **Read** each resolved package's `lyric.toml` (embedded in the `.nupkg` or
   from the local source) and add its `[nuget]` entries to the NuGet restore
   graph. This is how native deps propagate transitively.
4. **Run** `dotnet restore` with the accumulated NuGet dep set to place
   NuGet assemblies in the NuGet cache.
5. **Write / verify** `lyric.lock` — pins every package to a version + SHA-512
   of its `.nupkg`. On subsequent restores the checksum is verified before
   unpacking.

### 5.2 Lock file checksums

The lock file produced by `lyric restore` pins all resolved packages.  After a
`lyric publish` run, the lock file also records the uploaded artifact:

```toml
# lyric.lock (excerpt — combines restore and publish entries)

[[package]]
name     = "Lyric.Cache"
version  = "0.1.0"
source   = "nuget:https://api.nuget.org/v3/index.json"
sha512   = "sha512-abc123..."

[[package]]
name     = "Lyric.Web"
version  = "0.1.0"
source   = "nuget:https://api.nuget.org/v3/index.json"
sha512   = "sha512-def456..."

# [[published]] entries are appended by `lyric publish`.
# They record the package name, version, and SHA-512 of the uploaded .nupkg
# so the publish is reproducible and auditable.
[[published]]
name     = "MyLib"
version  = "0.2.0"
registry = "https://api.nuget.org/v3/index.json"
sha512   = "sha512-ghi789..."
```

`lyric restore` in CI (`--locked` flag) refuses to update the lock file and
fails if any package hash does not match. This provides supply-chain integrity
equivalent to `cargo --locked`.

---

## 6. Registry configuration

### 6.1 Per-project registry override

```toml
# lyric.toml

[registry]
dotnet = "https://pkgs.dev.azure.com/my-org/_packaging/my-feed/nuget/v3/index.json"
jvm    = "https://maven.pkg.github.com/my-org/my-repo"
```

### 6.2 Per-dependency registry

A dependency can pin to a specific feed:

```toml
[dependencies]
"MyPrivateLib" = { version = "1.0.0", registry = "https://pkgs.dev.azure.com/..." }
```

### 6.3 Credentials

Registry credentials are never stored in `lyric.toml` (which is committed to
version control). They come from:

1. `~/.lyric/credentials.toml` — per-registry auth tokens:
   ```toml
   ["https://pkgs.dev.azure.com/my-org/..."]
   token = "..."
   ```
   Set restrictive file permissions so other users on the machine cannot read
   the file:
   ```sh
   chmod 600 ~/.lyric/credentials.toml
   ```
   The toolchain emits a warning on startup if the file exists with permissions
   broader than `600`.
2. Environment variables: `LYRIC_NUGET_API_KEY`, `LYRIC_GITHUB_TOKEN`.
3. Standard NuGet credential providers (for Azure Artifacts, the
   `CredentialProvider.Microsoft` plugin is detected automatically).

### 6.4 Multiple feeds (feed priority)

When the default NuGet.org feed and a private feed are both configured, the
private feed is queried first. If the package is not found in the private feed,
resolution falls through to NuGet.org. This mirrors NuGet's `packageSources`
priority model.

---

## 7. Discovery (`lyric search`)

```
lyric search cache            # search for packages matching "cache"
lyric search "Lyric.Cache"    # look up a specific package
lyric search --all            # list all published Lyric packages
```

Implementation: queries the NuGet.org search API with `q=<term>&packageType=lyric-package`.
(`packageType` is the NuGet search API's filter for a named package type, distinct from
the `tags` field which is a free-text keyword.)

```
GET https://azuresearch-usnc.nuget.org/query?q=cache&packageType=lyric-package
```

Output example:

```
Lyric.Cache    0.1.0    Typed key-value cache with TTL and a pluggable store interface.
Lyric.Search   0.1.0    Search engine integration (Elasticsearch, Meilisearch).
```

A companion GitHub Pages site (`lyric-lang.io/packages` — Q-R-003) may be added
later for richer browsing, but `lyric search` is the primary discovery UX and
requires no additional infrastructure.

---

## 8. Publishing the first-party ecosystem

The `lyric-*` directories in this repository form the first-party ecosystem.
Publishing them follows the standard `lyric publish` flow but with two
additional conventions:

**Publishing order.** Libraries are published in dependency order (a topological
sort of the workspace dep graph). `lyric publish --workspace` (Q-R-004) will
automate this; until it ships, publish manually in this order:

1. `lyric-stdlib` (no Lyric deps)
2. `lyric-resilience`, `lyric-validation`, `lyric-logging`, `lyric-cache`
3. `lyric-auth`, `lyric-otel`, `lyric-proto`
4. `lyric-grpc`, `lyric-web`, `lyric-db`, `lyric-health`, `lyric-mq`,
   `lyric-jobs`, `lyric-mail`, `lyric-storage`, `lyric-ws`, `lyric-session`,
   `lyric-search`, `lyric-feature-flags`, `lyric-i18n`, `lyric-testing`
5. `lyric-lambda` (depends on `lyric-web`)

**Version alignment.** All first-party packages are versioned together (same
`MAJOR.MINOR.PATCH`). A version bump requires updating every `[package].version`
in the workspace. A future `lyric version --workspace 0.2.0` command will
automate this (Q-R-004).

**CI publish gate.** The `.github/workflows/publish.yml` workflow runs
`lyric publish` for each workspace member in dependency order when a version
tag is pushed.  The `publish-ecosystem` job drives this: it bootstraps the
`lyric` CLI, then calls `lyric build` + `lyric publish --skip-duplicate` for
each library in the tier ordering above.  Authentication uses NuGet Trusted
Publishing (OIDC) — see `docs/34-distribution-strategy.md` §7 for setup.

---

## 9. Relationship to `[nuget]` and `[maven]` tables

The `[nuget]` and `[maven]` tables in a library's `lyric.toml` declare the
native platform boundaries: the NuGet or Maven packages that the library's
kernel code wraps. These entries are:

- **Embedded** in the published `.nupkg` (as NuGet `<dependencies>`) so that
  `lyric restore` can propagate them transitively to consumers.
- **Invisible** to application developers. An app that depends on `Lyric.Grpc`
  does not need `"Grpc.Net.Client"` in its own `lyric.toml`; `lyric restore`
  adds it to the NuGet restore graph automatically.
- **Not Lyric packages.** They are raw platform deps and do not go through the
  `lyric-package`-tagged NuGet flow described in this document.

Application developers who need an arbitrary NuGet package that has no Lyric
wrapper should add it to their own `[nuget]` table. This is the explicit escape
hatch; see `docs/38-workspace.md` §8 (Q-W-001) for the long-term question of
whether this should be constrained.

---

## 10. Open questions

**Q-R-001** — GitHub Packages Maven requires authentication even for public
package reads. This is a friction point: consumers need a `GITHUB_TOKEN` or
personal access token just to run `lyric restore` against the JVM feed. Options:
(a) accept the friction until Maven Central is set up; (b) host a public Maven
mirror via a GitHub Actions cron job that re-publishes to a CDN or static S3
bucket; (c) use JitPack (automatically builds from GitHub releases — no upload
step needed). Decision deferred to Phase 6.

**Q-R-002** — Maven Central (Sonatype OSSRH) requires GPG-signed artifacts and
a namespace claim (`io.lyric-lang`). This is achievable but involves one-time
registration and changes to the publish workflow. Defer until Phase 6 JVM target
ships and the friction of GitHub Packages Maven becomes measurable.

**Q-R-003** — A GitHub Pages discovery site (`lyric-lang.io/packages`) for
richer browsing than `lyric search`. Low priority: NuGet.org's search with the
`lyric-package` tag filter is adequate for the scale of v1.0.

**Q-R-004** — `lyric publish --workspace` (bulk topological publish) and
`lyric version --workspace <semver>` (bulk version bump). These reduce the
manual steps in §8 to a single command. Implement once the individual publish
path is stable and the workspace dep graph is fully integrated into the CLI.
