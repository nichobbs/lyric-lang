# Windows installer and in-place `lyric upgrade --github`

`lyric upgrade --github` used to refuse on Windows (the installer was a POSIX
shell script and a running `lyric.exe` cannot be overwritten). Supersedes the
"fails with a message" note in the 2026-10-21 Windows release leg entry.

- New `scripts/install.ps1` (Windows PowerShell 5.1 and PowerShell 7+) with
  `-Version`, `-Dir`, `-NoPath` and `-Archive`. It verifies the download against
  `SHASUMS256.txt` (fail closed), installs to `%USERPROFILE%\.lyric\bin`, and
  upgrades in place by renaming each replaced file to `<name>.old` (a running
  image can be renamed but not overwritten), rolling everything back on error
  and clearing leftovers on the next run. `scripts/install.ps1.sha256` pins its
  digest; `windows-build.yml` fails when it is stale.
- `lyric upgrade --github` picks `install.ps1` under `powershell -NoProfile
  -ExecutionPolicy Bypass -File` on Windows and `install.sh` under `sh`
  elsewhere (`installerScriptName`/`installerInterpreter`/`installerArgs`,
  covered by `cli_upgrade_self_test.l`).
- `windows-build.yml` now runs `scripts/ci/windows-installer-test.ps1` (clean
  install, upgrade while `lyric.exe` is running, reinstall, a bad archive
  leaving the install usable, the dry-run plan) and
  `scripts/ci/windows-lyric-test.ps1` (`lyric test` on a CRLF checkout with
  `TMPDIR` unset, including the temp-directory recovery path) against the
  freshly built archive.
- Verified on a `windows-latest` runner: a real download install with the
  checksum check, and an in-place upgrade over a running `lyric.exe`.
- Found while testing: released binaries up to v0.7.10 fail `lyric test` on a
  CRLF source file (a Windows checkout); fixed on `main` in #8437.
