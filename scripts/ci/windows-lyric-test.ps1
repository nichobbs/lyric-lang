# Runs `lyric test` with a win-x64 lyric.exe on a checked-out (CRLF) source,
# with TMPDIR unset as on a normal Windows machine.
#
#   windows-lyric-test.ps1 -Lyric <dir containing lyric.exe and lib\>
#
# 1. Installed layout: the stdlib bundle sits in lib\ beside lyric.exe.
# 2. No compiled stdlib beside the binary: `lyric test` recovers the stdlib
#    DLLs the in-process bridge wrote to the temp directory, which it finds
#    through TMPDIR, then TEMP, then TMP (cli_test.l).
param([Parameter(Mandatory = $true)][string]$Lyric)

$ErrorActionPreference = "Stop"
$repo = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$work = Join-Path $env:RUNNER_TEMP "lyric-test-smoke"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Path $work | Out-Null
Copy-Item (Join-Path $repo "scripts\ci\windows-smoke\smoke_tests.l") $work
Remove-Item Env:TMPDIR -ErrorAction SilentlyContinue
Write-Host "TEMP=$env:TEMP TMP=$env:TMP"

function Run-Test([string]$Exe) {
  Push-Location $work
  try {
    $out = (& $Exe test smoke_tests.l 2>&1 | Out-String)
    $code = $LASTEXITCODE
  } finally { Pop-Location }
  Write-Host $out
  if ($code -ne 0) { throw "lyric test failed (exit $code)" }
  if ($out -notmatch 'ok 2 - strings') { throw "lyric test did not report both tests passing" }
}

Write-Host "== installed layout"
Run-Test (Join-Path $Lyric "lyric.exe")

Write-Host "== no compiled stdlib beside the binary (temp-directory recovery)"
$iso = Join-Path $env:RUNNER_TEMP "lyric-bare"
if (Test-Path $iso) { Remove-Item -Recurse -Force $iso }
New-Item -ItemType Directory -Path $iso | Out-Null
Copy-Item (Join-Path $Lyric "lyric.exe") $iso
$env:LYRIC_STD_PATH = Join-Path $repo "lyric-stdlib\std"
Run-Test (Join-Path $iso "lyric.exe")
Write-Host "lyric test checks passed"
