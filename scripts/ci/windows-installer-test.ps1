# Tests scripts/install.ps1 against a freshly built win-x64 archive, using
# Windows PowerShell 5.1 (the interpreter `lyric upgrade` runs it with).
#
#   windows-installer-test.ps1 -Zip lyric-X.Y.Z-win-x64.zip
#
# Covers: a clean install; an in-place upgrade while the installed lyric.exe
# is running (the case `lyric upgrade` is always in); stale .old cleanup on
# the next install; rollback leaving the install usable when the archive is
# bad; and the `lyric upgrade --github --dry-run` plan on Windows.
param([Parameter(Mandatory = $true)][string]$Zip)

$ErrorActionPreference = "Stop"
$installer = Join-Path $PSScriptRoot "..\install.ps1"
$dir = Join-Path $env:RUNNER_TEMP "lyric-installer-test"
if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }

function Install([string]$Archive) {
  # Out-Host keeps the installer's output out of this function's return value.
  & powershell -NoProfile -ExecutionPolicy Bypass -File $installer -Archive $Archive -Dir $dir -NoPath | Out-Host
  return $LASTEXITCODE
}

Write-Host "== clean install"
if ((Install $Zip) -ne 0) { throw "clean install failed" }
& "$dir\lyric.exe" --version
if ($LASTEXITCODE -ne 0) { throw "installed lyric.exe does not run" }

Write-Host "== upgrade while lyric.exe is running"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "$dir\lyric.exe"
$psi.Arguments = "lsp"
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.UseShellExecute = $false
$holder = [System.Diagnostics.Process]::Start($psi)
try {
  Start-Sleep -Seconds 3
  if ($holder.HasExited) { throw "the process holding lyric.exe open exited early (code $($holder.ExitCode))" }
  if ((Install $Zip) -ne 0) { throw "in-place upgrade over a running lyric.exe failed" }
  $stale = @(Get-ChildItem -Recurse -Filter *.old $dir)
  if ($stale.Count -eq 0) { throw "expected the running image to be renamed aside to .old" }
} finally {
  if (-not $holder.HasExited) { $holder.Kill() }
  $holder.WaitForExit()
}
& "$dir\lyric.exe" --version
if ($LASTEXITCODE -ne 0) { throw "lyric.exe does not run after the in-place upgrade" }

Write-Host "== next install removes the leftovers"
if ((Install $Zip) -ne 0) { throw "reinstall failed" }
# The holder exited, so no rename needed a unique fallback name (name.<8 hex>.old).
$collided = @(Get-ChildItem -Recurse -Filter *.old $dir | Where-Object { $_.Name -match '\.[0-9a-f]{8}\.old$' })
if ($collided.Count -ne 0) { throw "stale .old files were not cleared before the reinstall: $($collided.Name -join ', ')" }

Write-Host "== a bad archive fails and leaves the install working"
$bad = Join-Path $env:RUNNER_TEMP "not-a-zip.zip"
Set-Content -Path $bad -Value "not a zip"
if ((Install $bad) -eq 0) { throw "a corrupt archive must fail the install" }
& "$dir\lyric.exe" --version
if ($LASTEXITCODE -ne 0) { throw "install was damaged by a failed install" }

Write-Host "== lyric upgrade --github --dry-run plans install.ps1"
$out = (& "$dir\lyric.exe" upgrade --github --dry-run --version 9.9.9 2>&1 | Out-String)
Write-Host $out
if ($LASTEXITCODE -ne 0) { throw "dry-run upgrade failed" }
if ($out -notmatch 'install\.ps1') { throw "dry-run did not plan install.ps1" }
if ($out -notmatch 'powershell') { throw "dry-run did not plan a PowerShell run" }
if ($out -match 'install\.sh') { throw "dry-run still mentions install.sh" }
Write-Host "installer tests passed"
