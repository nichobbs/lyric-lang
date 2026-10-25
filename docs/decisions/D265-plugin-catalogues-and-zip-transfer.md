# D265 - Plugin catalogues and zip transfer: the shipped surface (refines D248 Decisions 8-11)

**Status:** shipped. Refines D248 Decisions 8-11 (docs/69 §12); plugins P8.

## Context

D248 specified per-application catalogues (`catalogue.json` and
`catalogue.sig`), following with serial, expiry and rotation rules, zip
transfer with safe extraction, and the `lyric plugin catalogue` and `install`
commands. Implementing `Std.Zip`, `Std.PluginCatalogue` and the CLI on
dotnet, the JVM and native settled the details below.

## Decision

1. **Location.** A catalogue is followed by its base location, a directory
   or an `http(s)` URL, holding `catalogue.json` and `catalogue.sig`. Entry
   URLs resolve against that base. `fetchBytes` reads either form.
2. **`catalogue.sig` is a JSON array** of `{type, keyId, signature}`; one
   signature by the current key is enough, and a catalogue that names a new
   `catalogueKey` must also carry that key's signature (K0120 otherwise).
3. **Times.** `expires` is exactly `YYYY-MM-DDTHH:MM:SSZ`, parsed and formatted
   in Lyric, so every target compares it the same way.
4. **Host state** lives in a directory the host names, one subdirectory per
   followed location (named from its SHA-256), holding the last verified
   `catalogue.json`, `catalogue.sig` and the current catalogue key.
   `updateCatalogue` refuses a lower serial or an equal serial with other
   bytes (K0122) and an expired catalogue (K0121) without touching the state;
   `loadFollowedCatalogue` returns the stored copy with `stale` set once it
   has expired, and `installPlugin` refuses a stale one.
5. **Trust from catalogues.** `TrustPolicy` (D264) gains no catalogue field:
   `catalogueTrust(pinned, followed, allowUnsigned)` builds one from pinned keys
   and followed catalogues' publishers and revocations, so `Std.Plugin` does
   not import HTTP or zip code.
6. **Install.** `installPlugin` takes the entry for an id (a given version,
   or the highest version not yanked, by semantic-version precedence), checks
   the zip's SHA-256, extracts it into `<into>/.lyric-install-<id>-<version>`,
   verifies it against the catalogue's keys and revocations (K0105-K0110),
   checks `plugin.sig`'s SHA-256 and the manifest's id, version and publisher
   against the entry (K0123), renames it to `<into>/<id>-<version>`, and then
   removes other installed versions of the same plugin, which would otherwise
   load as duplicates. Because `<id>-<version>` names a directory, an entry's
   id must be a plugin id and its version a plugin version (the manifest
   rules, so no `/`, `\` or `..`): `parseCatalogue` refuses any other entry,
   and `installPlugin` checks again for a catalogue built in code.
7. **Extraction.** Entries must sit under the single top-level directory
   `<id>-<version>/`, each path must be a listing path (D263), no symbolic
   link and no two names differing only in case; the zip reader's own limits
   apply (10,000 entries, 512 MiB per entry, 1 GiB in all, a 1000:1 ratio).
   Nothing is written before every entry has been checked. Executable entries
   get mode 0755 (`Std.File.setExecutable`).
8. **Zip.** `Std.Zip` reads and writes stored and deflate entries without
   ZIP64 or encryption, which it refuses. The writer is deterministic (fixed
   timestamps, Unix modes, no extra fields). The compiler's private
   `Jvm.Deflate`/`Jvm.ZipReader` stay until their users move (#8582).
9. **Authoring.** `lyric plugin catalogue publisher`, `remove-key`,
   `revoke-key`, `add` and `yank` edit `catalogue.json` and remove
   `catalogue.sig`; only `init` and `sign` sign, and `sign` increments the
   serial and sets the expiry (default 90 days). `add` verifies the zip
   against the catalogue's publishers before listing it, and copies it to
   `<dir>/artifacts/` unless `--url` is given.
10. **`pack --zip`** writes `<id>-<version>.zip` beside the artifact, marking
    the native payload executable. `verify` accepts a zip (named
    `<id>-<version>.zip`) and `--catalogue`/`--catalogue-key` in place of
    `--key`.
