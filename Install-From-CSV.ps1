#requires -Version 5.1
<#
.SYNOPSIS
  Install Windows applications listed in Install-Plan.csv with WinGet.
.DESCRIPTION
  Only rows where InstallMethod=WinGet and WingetId is present are eligible.
  Defaults to Install-Plan.csv located in the same folder as this script.
  Default mode is PREVIEW. Use -Install for actual installations.
  SourceVersion is informational: installs or upgrades to the newest available WinGet version.
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

$selectedRows = @($rows | Where-Object {
    $Group -eq 'All' -or $_.Group.Trim() -eq $Group
})
$manualRows = @($selectedRows | Where-Object { $_.InstallMethod.Trim() -ne 'WinGet' })
$invalidRows = @($selectedRows | Where-Object {
    $_.InstallMethod.Trim() -eq 'WinGet' -and [string]::IsNullOrWhiteSpace($_.WingetId)
})
$eligibleRows = @($selectedRows | Where-Object {
    $_.InstallMethod.Trim() -eq 'WinGet' -and -not [string]::IsNullOrWhiteSpace($_.WingetId)
})

# De-duplicate IDs without changing the order in the CSV.
$seen = @{}
$installRows = @()
foreach ($row in $eligibleRows) {
    $id = $row.WingetId.Trim()
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        Write-Warning "Invalid WinGet ID; skipping: $id"
        continue
    }
    if ($seen.ContainsKey($id)) {
        Write-Warning "Duplicate WinGet ID; skipping later entry: $id"
        continue
    }
    $seen[$id] = $true
    $installRows += $row
}

Write-Host ''
Write-Host '==== CSV WinGet Installer ====' -ForegroundColor Cyan
Write-Host "CSV   : $csvFullPath"
Write-Host "Group : $Group"
Write-Host "Mode  : $(if ($Install) { 'INSTALL' } else { 'PREVIEW (no changes)' })"
Write-Host "WinGet targets : $($installRows.Count)"
Write-Host "Manual skipped : $($manualRows.Count)"
Write-Host "Missing IDs    : $($invalidRows.Count)"
Write-Host ''

if ($installRows.Count -gt 0) {
    $installRows |
        Select-Object Group, Name, WingetId, SourceVersion |
        Format-Table -AutoSize -Wrap | Out-Host
}
if ($manualRows.Count -gt 0) {
    Write-Host 'Manual entries (not installed):' -ForegroundColor Yellow
    foreach ($row in $manualRows) {
        Write-Host "  - $($row.Name)"
    }
}
if ($invalidRows.Count -gt 0) {
    Write-Warning 'Rows marked WinGet but missing WingetId were skipped.'
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
$winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue
if (-not $winget) {
    throw 'winget.exe not found. Install/update Windows App Installer first.'
}
if ($installRows.Count -eq 0) {
    Write-Host 'No WinGet entries selected. Nothing to install.'
    return
}

$logDir = Join-Path -Path $scriptDirectory -ChildPath 'Install-Logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logPath = Join-Path $logDir "Install-$timestamp.log"
$reportPath = Join-Path $logDir "Install-Result-$timestamp.csv"
$results = @()

Write-Host ''
Write-Host 'Beginning installations. Windows may ask for UAC approval.' -ForegroundColor Cyan
Write-Host 'Newest available WinGet versions will be installed (existing installations can be upgraded).' 
if ($Silent) {
    Write-Host 'Silent mode requested. Some installers may still require input.'
}

$number = 0
foreach ($row in $installRows) {
    $number++
    $name = [string]$row.Name
    $id = $row.WingetId.Trim()
    $start = Get-Date
    $argsList = @(
        'install', '--id', $id, '--exact',
        '--source', 'winget',
        '--accept-source-agreements', '--accept-package-agreements'
    )
    if ($Silent) { $argsList += '--silent' }

    Write-Host ''
    Write-Host "[$number/$($installRows.Count)] $name ($id)" -ForegroundColor Cyan
    "[$($start.ToString('s'))] START $name [$id]" | Add-Content -LiteralPath $logPath -Encoding UTF8

    $exitCode = $null
    $status = 'Review'
    $details = ''
    try {
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
    } catch {
        $status = 'Error'
        $details = $_.Exception.Message
        Write-Warning "$name : $details"
    }

    $results += [pscustomobject]@{
        Group         = $row.Group
        Name          = $name
        WingetId      = $id
        Status        = $status
        ExitCode      = $exitCode
        StartedAt     = $start.ToString('s')
        FinishedAt    = (Get-Date).ToString('s')
        Details       = $details
    }
    "[$((Get-Date).ToString('s'))] $status $name [$id] ExitCode=$exitCode : $details" |
        Add-Content -LiteralPath $logPath -Encoding UTF8
    # Write a report after every application, to preserve progress if interrupted.
    $results | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
}

$successCount = @($results | Where-Object { $_.Status -eq 'Success' }).Count
$reviewCount = $results.Count - $successCount
Write-Host ''
Write-Host '==== Installation summary ====' -ForegroundColor Cyan
Write-Host "WinGet exit 0 : $successCount"
Write-Host "Needs review  : $reviewCount"
Write-Host "Report        : $reportPath"
Write-Host "Log           : $logPath"
if ($reviewCount -gt 0) {
    Write-Warning 'Some WinGet calls returned nonzero or raised errors. Check their results in the CSV report.'
}
Write-Host 'Application settings, accounts, licenses and Manual items must be migrated separately.'
