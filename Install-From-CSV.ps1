#requires -Version 5.1
<#
.SYNOPSIS
  Install Windows applications listed in Install-Plan.csv with WinGet or MSI downloads.
.DESCRIPTION
  Eligible rows:
    - InstallMethod=WinGet with WingetId: installed with winget.exe.
    - InstallMethod=MSI with an https DownloadUrl: downloaded, verified against Sha256
      (when present), then installed with msiexec.exe.
      A GitHub URL of the form .../releases/latest/download/<asset> is resolved through the
      GitHub API at install time: the newest release is downloaded and verified against the
      asset digest published by GitHub. Set GITHUB_TOKEN to avoid API rate limits.
  All other rows are treated as Manual and only listed.
  Defaults to Install-Plan.csv located in the same folder as this script.
  Default mode is PREVIEW. Use -Install for actual installations.
  SourceVersion is informational: WinGet installs or upgrades to the newest available version;
  MSI installs exactly the file referenced by DownloadUrl.
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-From-CSV.ps1
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-From-CSV.ps1 -Install -Group Development
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-From-CSV.ps1 -CsvPath '.\Install-Plan-WinGet-Reviewed(1).csv' -Install -Silent
#>
[CmdletBinding()]
param(
    [string]$CsvPath,
    [ValidateSet('All', 'Basic', 'Development', 'Optional', 'Manual')]
    [string]$Group = 'All',
    [switch]$Install,
    [switch]$Silent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve the script directory after param() has completed.
# $PSScriptRoot may be empty while parameter default values are evaluated
# (including in Windows PowerShell 5.1).
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
    $scriptDirectory = (Get-Location).ProviderPath
}
if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $CsvPath = Join-Path -Path $scriptDirectory -ChildPath 'Install-Plan.csv'
}

if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
    throw "CSV file not found: $CsvPath`nPut Install-Plan.csv next to Install-From-CSV.ps1, or pass its actual path with -CsvPath."
}
$csvFullPath = (Resolve-Path -LiteralPath $CsvPath).ProviderPath
$rows = @(Import-Csv -LiteralPath $csvFullPath -Encoding UTF8)
if ($rows.Count -eq 0) {
    throw "CSV is empty: $csvFullPath"
}

$requiredColumns = @('Group', 'Name', 'WingetId', 'InstallMethod')
$actualColumns = @($rows[0].PSObject.Properties.Name)
foreach ($column in $requiredColumns) {
    if ($actualColumns -notcontains $column) {
        throw "Required CSV column missing: $column"
    }
}

# Optional columns (DownloadUrl, Sha256) may be absent in older CSV files.
function Get-CsvField {
    param($Row, [string]$Name)
    $property = $Row.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return ([string]$property.Value).Trim()
}

# DownloadUrl of the form https://github.com/<owner>/<repo>/releases/latest/download/<asset>
# is resolved through the GitHub API at install time, so the newest release is always used
# and the asset's SHA256 digest published by GitHub replaces the CSV Sha256.
$gitHubLatestPattern = '^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/latest/download/([^/?#]+)$'

function Resolve-GitHubLatestAsset {
    param([string]$Owner, [string]$Repo, [string]$AssetName)
    $apiUrl = "https://api.github.com/repos/$Owner/$Repo/releases/latest"
    $headers = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'Install-From-CSV' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing
    $asset = @($release.assets | Where-Object { $_.name -eq $AssetName }) | Select-Object -First 1
    if (-not $asset) {
        throw "Asset '$AssetName' not found in latest release $($release.tag_name) of $Owner/$Repo."
    }
    $digest = ''
    if ($asset.PSObject.Properties['digest'] -and [string]$asset.digest -match '^sha256:([0-9A-Fa-f]{64})$') {
        $digest = $Matches[1].ToUpperInvariant()
    }
    return [pscustomobject]@{
        Tag         = [string]$release.tag_name
        DownloadUrl = [string]$asset.browser_download_url
        Sha256      = $digest
    }
}

$selectedRows = @($rows | Where-Object {
    $Group -eq 'All' -or $_.Group.Trim() -eq $Group
})
$manualRows = @($selectedRows | Where-Object { @('WinGet', 'MSI') -notcontains $_.InstallMethod.Trim() })
$invalidRows = @($selectedRows | Where-Object {
    ($_.InstallMethod.Trim() -eq 'WinGet' -and [string]::IsNullOrWhiteSpace($_.WingetId)) -or
    ($_.InstallMethod.Trim() -eq 'MSI' -and [string]::IsNullOrWhiteSpace((Get-CsvField $_ 'DownloadUrl')))
})
$eligibleRows = @($selectedRows | Where-Object {
    ($_.InstallMethod.Trim() -eq 'WinGet' -and -not [string]::IsNullOrWhiteSpace($_.WingetId)) -or
    ($_.InstallMethod.Trim() -eq 'MSI' -and -not [string]::IsNullOrWhiteSpace((Get-CsvField $_ 'DownloadUrl')))
})

# Validate and de-duplicate targets without changing the order in the CSV.
$seen = @{}
$installRows = @()
foreach ($row in $eligibleRows) {
    $method = $row.InstallMethod.Trim()
    if ($method -eq 'WinGet') {
        $id = $row.WingetId.Trim()
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            Write-Warning "Invalid WinGet ID; skipping: $id"
            continue
        }
        $sha256 = ''
    } else {
        $id = Get-CsvField $row 'DownloadUrl'
        $uri = $null
        if (-not [Uri]::TryCreate($id, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
            Write-Warning "DownloadUrl must be an absolute https URL; skipping $($row.Name): $id"
            continue
        }
        $sha256 = (Get-CsvField $row 'Sha256').ToUpperInvariant()
        if ($sha256 -and $sha256 -notmatch '^[0-9A-F]{64}$') {
            Write-Warning "Invalid Sha256; skipping $($row.Name): $sha256"
            continue
        }
    }
    if ($seen.ContainsKey($id)) {
        Write-Warning "Duplicate install target; skipping later entry: $id"
        continue
    }
    $seen[$id] = $true
    $installRows += [pscustomobject]@{
        Group         = $row.Group
        Name          = [string]$row.Name
        Method        = $method
        Target        = $id
        Sha256        = $sha256
        SourceVersion = $row.SourceVersion
    }
}
$msiRows = @($installRows | Where-Object { $_.Method -eq 'MSI' })
$wingetRows = @($installRows | Where-Object { $_.Method -eq 'WinGet' })

Write-Host ''
Write-Host '==== CSV Installer (WinGet / MSI) ====' -ForegroundColor Cyan
Write-Host "CSV   : $csvFullPath"
Write-Host "Group : $Group"
Write-Host "Mode  : $(if ($Install) { 'INSTALL' } else { 'PREVIEW (no changes)' })"
Write-Host "WinGet targets : $($wingetRows.Count)"
Write-Host "MSI targets    : $($msiRows.Count)"
Write-Host "Manual skipped : $($manualRows.Count)"
Write-Host "Missing IDs/URL: $($invalidRows.Count)"
Write-Host ''

if ($installRows.Count -gt 0) {
    $installRows |
        Select-Object Group, Name, Method, Target, SourceVersion |
        Format-Table -AutoSize -Wrap | Out-Host
}
if ($manualRows.Count -gt 0) {
    Write-Host 'Manual entries (not installed):' -ForegroundColor Yellow
    foreach ($row in $manualRows) {
        Write-Host "  - $($row.Name)"
    }
}
if ($invalidRows.Count -gt 0) {
    Write-Warning 'Rows marked WinGet without WingetId, or MSI without DownloadUrl, were skipped.'
}
foreach ($row in $msiRows) {
    if ($row.Target -match $gitHubLatestPattern) {
        if ($row.Sha256) {
            Write-Warning "$($row.Name): Sha256 in CSV is ignored for a releases/latest URL; the GitHub API digest is used instead."
        }
    } elseif (-not $row.Sha256) {
        Write-Warning "$($row.Name): no Sha256 in CSV; the downloaded MSI will not be integrity-checked."
    }
}

if (-not $Install) {
    Write-Host ''
    Write-Host 'Preview only. Add -Install to start installation.' -ForegroundColor Yellow
    Write-Host 'Use -Group Basic, Development or Optional to limit selection.'
    return
}

if ($env:OS -ne 'Windows_NT') {
    throw 'Installation is only supported on Windows.'
}
$winget = $null
if ($wingetRows.Count -gt 0) {
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'winget.exe not found. Install/update Windows App Installer first.'
    }
}
if ($installRows.Count -eq 0) {
    Write-Host 'No WinGet or MSI entries selected. Nothing to install.'
    return
}

$logDir = Join-Path -Path $scriptDirectory -ChildPath 'Install-Logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logPath = Join-Path $logDir "Install-$timestamp.log"
$reportPath = Join-Path $logDir "Install-Result-$timestamp.csv"
$results = @()

# msiexec /qn cannot show a UAC prompt, so per-machine MSIs fail silently without elevation.
# Fall back to /passive (progress bar only, UAC prompt allowed) in that case.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$msiUiLevel = '/passive'
if ($Silent) {
    if ($isAdmin) {
        $msiUiLevel = '/qn'
    } elseif ($msiRows.Count -gt 0) {
        Write-Warning 'Not running as administrator: MSI installs use /passive instead of /qn so UAC can prompt.'
    }
}
if ($msiRows.Count -gt 0) {
    $downloadDir = Join-Path -Path $logDir -ChildPath "Downloads-$timestamp"
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    # Windows PowerShell 5.1 may default to TLS 1.0, which GitHub rejects.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

Write-Host ''
Write-Host 'Beginning installations. Windows may ask for UAC approval.' -ForegroundColor Cyan
Write-Host 'Newest available WinGet versions will be installed (existing installations can be upgraded).'
Write-Host 'MSI entries install the exact file referenced by DownloadUrl.'
if ($Silent) {
    Write-Host 'Silent mode requested. Some installers may still require input.'
}

$number = 0
foreach ($row in $installRows) {
    $number++
    $name = $row.Name
    $id = $row.Target
    $start = Get-Date

    Write-Host ''
    Write-Host "[$number/$($installRows.Count)] $name [$($row.Method)] ($id)" -ForegroundColor Cyan
    "[$($start.ToString('s'))] START $name [$($row.Method)] [$id]" | Add-Content -LiteralPath $logPath -Encoding UTF8

    $exitCode = $null
    $status = 'Review'
    $details = ''
    try {
        if ($row.Method -eq 'WinGet') {
            $argsList = @(
                'install', '--id', $id, '--exact',
                '--source', 'winget',
                '--accept-source-agreements', '--accept-package-agreements'
            )
            if ($Silent) { $argsList += '--silent' }
            # An argument array prevents the CSV fields from being executed as PowerShell code.
            & $winget.Source @argsList
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) {
                $status = 'Success'
                $details = 'WinGet returned exit code 0.'
                Write-Host "Completed: $name" -ForegroundColor Green
            } else {
                $details = "WinGet returned exit code $exitCode; check console output and installed status."
                Write-Warning "$name : $details"
            }
        } else {
            $downloadUrl = $id
            $expectedHash = $row.Sha256
            $hashSource = 'CSV'
            $versionNote = ''
            if ($id -match $gitHubLatestPattern) {
                $owner = $Matches[1]; $repo = $Matches[2]
                $assetName = [Uri]::UnescapeDataString($Matches[3])
                Write-Host "Resolving latest release: $owner/$repo ($assetName)"
                $latest = Resolve-GitHubLatestAsset -Owner $owner -Repo $repo -AssetName $assetName
                $downloadUrl = $latest.DownloadUrl
                $expectedHash = $latest.Sha256
                $hashSource = 'GitHub API digest'
                $versionNote = " Release $($latest.Tag)."
                Write-Host "Latest release: $($latest.Tag)"
                if (-not $expectedHash) {
                    Write-Warning "$name : GitHub API returned no SHA256 digest; the download will not be integrity-checked."
                }
            }

            $fileName = [IO.Path]::GetFileName(([Uri]$downloadUrl).AbsolutePath)
            if ($fileName -notmatch '^[A-Za-z0-9._-]+\.msi$') {
                $fileName = "package-$number.msi"
            }
            $msiPath = Join-Path $downloadDir $fileName
            Write-Host "Downloading: $downloadUrl"
            # The progress bar slows Invoke-WebRequest drastically in Windows PowerShell 5.1.
            $previousProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest -Uri $downloadUrl -OutFile $msiPath -UseBasicParsing
            } finally {
                $ProgressPreference = $previousProgress
            }

            $actualHash = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash
            if ($expectedHash -and $actualHash -ne $expectedHash) {
                Remove-Item -LiteralPath $msiPath -Force
                throw "SHA256 mismatch ($hashSource). Expected $expectedHash, got $actualHash. Installer deleted, not executed.$versionNote"
            }
            Unblock-File -LiteralPath $msiPath

            $msiLogPath = Join-Path $logDir ("MSI-{0}-{1}.log" -f [IO.Path]::GetFileNameWithoutExtension($fileName), $timestamp)
            $msiArgs = @('/i', "`"$msiPath`"", $msiUiLevel, '/norestart', '/l*v', "`"$msiLogPath`"")
            $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
            $exitCode = $process.ExitCode
            $hashNote = if ($expectedHash) { "SHA256 verified ($hashSource).$versionNote" } else { "SHA256 not checked ($actualHash).$versionNote" }
            if ($exitCode -eq 0) {
                $status = 'Success'
                $details = "msiexec returned exit code 0. $hashNote."
                Write-Host "Completed: $name" -ForegroundColor Green
            } elseif ($exitCode -eq 3010 -or $exitCode -eq 1641) {
                $status = 'Success'
                $details = "msiexec returned exit code $exitCode (reboot required). $hashNote."
                Write-Host "Completed (reboot required): $name" -ForegroundColor Green
            } else {
                $details = "msiexec returned exit code $exitCode; see $msiLogPath. $hashNote."
                Write-Warning "$name : $details"
            }
        }
    } catch {
        $status = 'Error'
        $details = $_.Exception.Message
        Write-Warning "$name : $details"
    }

    $results += [pscustomobject]@{
        Group         = $row.Group
        Name          = $name
        Method        = $row.Method
        Target        = $id
        Status        = $status
        ExitCode      = $exitCode
        StartedAt     = $start.ToString('s')
        FinishedAt    = (Get-Date).ToString('s')
        Details       = $details
    }
    "[$((Get-Date).ToString('s'))] $status $name [$($row.Method)] [$id] ExitCode=$exitCode : $details" |
        Add-Content -LiteralPath $logPath -Encoding UTF8
    # Write a report after every application, to preserve progress if interrupted.
    $results | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
}

$successCount = @($results | Where-Object { $_.Status -eq 'Success' }).Count
$reviewCount = $results.Count - $successCount
Write-Host ''
Write-Host '==== Installation summary ====' -ForegroundColor Cyan
Write-Host "Success       : $successCount"
Write-Host "Needs review  : $reviewCount"
Write-Host "Report        : $reportPath"
Write-Host "Log           : $logPath"
if ($reviewCount -gt 0) {
    Write-Warning 'Some installs returned nonzero or raised errors. Check their results in the CSV report.'
}
Write-Host 'Application settings, accounts, licenses and Manual items must be migrated separately.'
