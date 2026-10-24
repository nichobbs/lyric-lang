# install.ps1 - Lyric compiler installer for Windows
#
# Downloads the win-x64 archive from a GitHub Release, verifies it against the
# release's SHASUMS256.txt, and installs it to %USERPROFILE%\.lyric\bin.
# Runs on Windows PowerShell 5.1 and PowerShell 7+.
#
# Usage:
#   irm https://raw.githubusercontent.com/nichobbs/lyric-lang/main/scripts/install.ps1 -OutFile install.ps1
#   .\install.ps1
#   .\install.ps1 -Version 0.7.10
#   .\install.ps1 -Dir C:\Tools\lyric -NoPath
#
# Parameters:
#   -Version X.Y.Z   Install a specific version (default: latest release)
#   -Dir DIR         Installation directory (default: %USERPROFILE%\.lyric\bin)
#   -NoPath          Do not add the installation directory to the user PATH
#   -Archive FILE    Install from a local win-x64 zip instead of downloading
#                    (offline installs and tests; checksum verification is
#                    skipped because there is no published digest to compare)
#
# An existing installation is upgraded in place, including one whose lyric.exe
# is running (as during `lyric upgrade`): Windows refuses to overwrite or
# delete a running image but allows renaming it, so each file being replaced
# is first renamed to <name>.old, and the leftovers are removed on the next
# run once the old process has exited.

[CmdletBinding()]
param(
  [string]$Version = "",
  [string]$Dir = "",
  [switch]$NoPath,
  [string]$Archive = ""
)

$ErrorActionPreference = "Stop"
# Invoke-WebRequest is an order of magnitude slower in Windows PowerShell 5.1
# while it renders a progress bar.
$ProgressPreference = "SilentlyContinue"

$Repo = "nichobbs/lyric-lang"
$Rid = "win-x64"

function Say([string]$Message) { Write-Host $Message }

function Get-Url([string]$Url, [string]$Dest) {
  Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Dest -Headers @{ "User-Agent" = "lyric-install" }
}

function Get-LatestVersion {
  $release = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "lyric-install" }
  $tag = [string]$release.tag_name
  if (-not $tag) { throw "could not determine the latest version from the GitHub API" }
  return $tag -replace '^[vV]', ''
}

# Fails closed: a missing manifest, a missing entry for this archive, or a
# digest mismatch aborts before anything is extracted.
function Assert-Checksum([string]$File, [string]$ManifestFile, [string]$ArchiveName) {
  $expected = $null
  foreach ($line in Get-Content -LiteralPath $ManifestFile) {
    $parts = $line.Trim() -split '\s+', 2
    if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $ArchiveName) {
      $expected = $parts[0].ToLowerInvariant()
      break
    }
  }
  if (-not $expected) {
    throw "no SHASUMS256.txt entry for $ArchiveName; aborting rather than installing an unverified archive"
  }
  $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $expected) {
    throw "checksum mismatch for ${ArchiveName}: expected $expected, got $actual"
  }
}

function Remove-StaleFiles([string]$Root) {
  Get-ChildItem -LiteralPath $Root -Recurse -Force -File -Filter "*.old" -ErrorAction SilentlyContinue |
    ForEach-Object {
      try { Remove-Item -LiteralPath $_.FullName -Force } catch { }
    }
}

# Copies every file under $Src into $Dst. A file that already exists is
# renamed aside first, and everything is rolled back if any step fails.
function Install-Tree([string]$Src, [string]$Dst) {
  New-Item -ItemType Directory -Force -Path $Dst | Out-Null
  Remove-StaleFiles $Dst

  $srcRoot = (Resolve-Path -LiteralPath $Src).Path.TrimEnd('\')
  $renamed = New-Object System.Collections.ArrayList
  $created = New-Object System.Collections.ArrayList
  try {
    foreach ($file in Get-ChildItem -LiteralPath $srcRoot -Recurse -Force -File) {
      $relative = $file.FullName.Substring($srcRoot.Length + 1)
      $target = Join-Path $Dst $relative
      $targetDir = Split-Path -Parent $target
      if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
      }
      if (Test-Path -LiteralPath $target) {
        $aside = $target + ".old"
        if (Test-Path -LiteralPath $aside) {
          # A leftover that is still locked by a running process.
          $aside = $target + "." + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".old"
        }
        Move-Item -LiteralPath $target -Destination $aside
        [void]$renamed.Add(@($target, $aside))
      } else {
        [void]$created.Add($target)
      }
      Copy-Item -LiteralPath $file.FullName -Destination $target
    }
  } catch {
    foreach ($path in $created) {
      Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    foreach ($pair in $renamed) {
      Remove-Item -LiteralPath $pair[0] -Force -ErrorAction SilentlyContinue
      Move-Item -LiteralPath $pair[1] -Destination $pair[0] -Force -ErrorAction SilentlyContinue
    }
    throw
  }
}

function Add-ToUserPath([string]$Directory) {
  $normalized = $Directory.TrimEnd('\')
  $current = [Environment]::GetEnvironmentVariable("Path", "User")
  $entries = @()
  if ($current) { $entries = @($current -split ';' | Where-Object { $_ }) }
  foreach ($entry in $entries) {
    if ($entry.TrimEnd('\') -ieq $normalized) { return }
  }
  [Environment]::SetEnvironmentVariable("Path", ((@($entries) + $normalized) -join ';'), "User")
  Say "Added $normalized to your user PATH."
  Say "(Open a new terminal for the change to take effect.)"
}

try {
  if (-not [Environment]::Is64BitOperatingSystem) {
    throw "Lyric requires 64-bit Windows"
  }
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  if (-not $Dir) {
    if (-not $env:USERPROFILE) { throw "USERPROFILE is not set; pass -Dir" }
    $Dir = Join-Path $env:USERPROFILE ".lyric\bin"
  }
  if ($Version -and $Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "-Version must be a semver string (e.g. 1.0.0)"
  }

  $work = Join-Path ([IO.Path]::GetTempPath()) ("lyric-install-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
    if ($Archive) {
      if (-not (Test-Path -LiteralPath $Archive)) { throw "archive not found: $Archive" }
      $zip = (Resolve-Path -LiteralPath $Archive).Path
      Say "Installing Lyric from local archive $zip (checksum verification skipped)"
    } else {
      if (-not $Version) {
        Say "Resolving latest Lyric release..."
        $Version = Get-LatestVersion
      }
      Say "Installing Lyric $Version ($Rid)"
      $archiveName = "lyric-$Version-$Rid.zip"
      $base = "https://github.com/$Repo/releases/download/v$Version"
      $zip = Join-Path $work $archiveName
      Say "Downloading $archiveName..."
      Get-Url "$base/$archiveName" $zip
      $manifest = Join-Path $work "SHASUMS256.txt"
      Say "Verifying checksum..."
      try {
        Get-Url "$base/SHASUMS256.txt" $manifest
      } catch {
        throw "failed to download SHASUMS256.txt from $base - releases published before checksum manifests existed cannot be verified; pass a newer -Version"
      }
      Assert-Checksum $zip $manifest $archiveName
      Say "Checksum OK."
    }

    Say "Extracting..."
    $staging = Join-Path $work "staging"
    Expand-Archive -LiteralPath $zip -DestinationPath $staging -Force
    if (-not (Test-Path -LiteralPath (Join-Path $staging "lyric.exe"))) {
      throw "the archive does not contain lyric.exe"
    }

    Install-Tree $staging $Dir
  } finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }

  $lyric = Join-Path $Dir "lyric.exe"
  Say "Installed: $lyric"
  if (-not $NoPath) { Add-ToUserPath $Dir }

  & $lyric --version | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "$lyric --version failed (exit code $LASTEXITCODE)"
  }
  Say ""
  Say "Lyric installed successfully. Run 'lyric --help' to get started."
} catch {
  [Console]::Error.WriteLine("error: " + $_.Exception.Message)
  exit 1
}
