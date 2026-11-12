[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$manifest = Join-Path $root 'runtime-files.sha256'
if (-not (Test-Path -LiteralPath $manifest)) { throw 'Missing runtime-files.sha256. Restore the complete repository or Release ZIP.' }
$checked = @{}
foreach ($line in Get-Content -LiteralPath $manifest) {
    if ($line -notmatch '^([a-f0-9]{64})  (.+)$') { throw "Invalid runtime manifest line: $line" }
    $hash = $Matches[1]; $name = $Matches[2]
    if ($name -match '(^|/)\.\.(/|$)|\\|:' -or
        ($name -notmatch '^(8\.10\.8\.0|Stable)/' -and
         $name -notin @('YoudaoDict.exe','YodaoDict.exe','InstallHelper.exe','uninst.exe'))) {
        throw "Unsafe runtime manifest path: $name"
    }
    if ($checked.ContainsKey($name)) { throw "Duplicate runtime file: $name" }
    $path = Join-Path $root $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing runtime file: $name" }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) {
        throw "Runtime hash mismatch: $name. Restore this file from a trusted release; for libcef.dll run git lfs pull."
    }
    $checked[$name] = $true
}
if ($checked.Count -ne 612) { throw "Expected 612 runtime files for version 8.10.8.0; found $($checked.Count)." }
$exe = Join-Path $root 'YoudaoDict.exe'
if ((Get-Item -LiteralPath $exe).VersionInfo.FileVersion -ne '8.10.8.0') { throw 'Application version is not 8.10.8.0.' }
foreach ($required in @('start-youdao.cmd','scripts/start-youdao.ps1','scripts/protect-youdao.ps1','scripts/install-shortcuts.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $required) -PathType Leaf)) { throw "Missing launcher file: $required" }
}
foreach ($script in Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File) {
    $tokens = $null; $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) { throw "PowerShell syntax errors: $($script.Name): $parseErrors" }
}
Write-Host "PASS: $($checked.Count) runtime hashes, version 8.10.8.0, launch files and PowerShell syntax."
if (-not $SmokeTest) {
    Write-Host 'Read-only check: no application launched; no user settings or registry changed.'
    return
}

# Launch tests are restricted to disposable hosted CI, never the user's profile.
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'SmokeTest is allowed only on a disposable GitHub-hosted Windows runner.'
}
if (Get-Process YoudaoDict -ErrorAction SilentlyContinue) { throw 'Another Youdao process exists; refusing launch test.' }
$desk = Join-Path $env:LOCALAPPDATA 'Yodao\DeskDict'
if ((Test-Path -LiteralPath $desk) -or (Test-Path 'HKCU:\Software\Youdao\Dict')) {
    throw 'SmokeTest requires a fresh user profile with no Youdao configuration.'
}
$started = @{}
try {
    $launcher = Join-Path $root 'start-youdao.cmd'
    $log = Join-Path $env:RUNNER_TEMP ('youdao-launch-' + [Guid]::NewGuid().ToString('N'))
    $cmd = Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /c ""' + $launcher + '""') `
        -WorkingDirectory $env:RUNNER_TEMP -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput ($log + '.out') -RedirectStandardError ($log + '.err')
    $started[$cmd.Id] = $true
    if (-not $cmd.WaitForExit(60000)) { throw 'Launcher did not exit within 60 seconds.' }
    Get-Content -LiteralPath ($log + '.out'),($log + '.err')
    if ($cmd.ExitCode -ne 0) { throw "Launcher exit code: $($cmd.ExitCode)" }
    $deadline = (Get-Date).AddSeconds(90)
    $stableSince = $null
    do {
        Start-Sleep -Seconds 3
        $process = @(Get-Process YoudaoDict -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
        if ($process.Count -eq 0) { throw 'Restored application did not remain running.' }
        foreach ($p in $process) { $started[$p.Id] = $true }
        $loaded = @($process | ForEach-Object { $_.Modules } | Where-Object {
            $_.ModuleName -eq 'libcef.dll' -and $_.FileName -eq (Join-Path $root '8.10.8.0\libcef.dll')
        })
        if ($loaded.Count -gt 0 -and -not $stableSince) { $stableSince = Get-Date }
    } until (($stableSince -and ((Get-Date) - $stableSince).TotalSeconds -ge 30) -or (Get-Date) -ge $deadline)
    if (-not $stableSince -or ((Get-Date) - $stableSince).TotalSeconds -lt 30) {
        throw 'Restored application did not load its own libcef.dll and stay alive for 30 seconds.'
    }
    if ((Get-Content -LiteralPath (Join-Path $desk 'config.ini') -Raw) -notmatch '(?m)^AUTOUPDATE=0\s*$') {
        throw 'Auto-update protection was not retained after launch.'
    }
    $updater = Get-Item -LiteralPath (Join-Path $desk 'updaters') -Force
    if ($updater.PSIsContainer -or -not $updater.IsReadOnly) { throw 'Updater blocker missing or not read-only.' }
    if ((Get-ItemProperty 'HKCU:\Software\Youdao\Dict').Install -ne $root) { throw 'Install path did not follow restored folder.' }
    if (Get-ChildItem -LiteralPath $root -Filter '*.new' -File) { throw 'Upgrade package appeared during launch.' }
    Write-Host 'PASS: clean-profile launch from restored folder; own CEF loaded; survived 30 seconds; update protection present.'
    Write-Host 'This is a startup smoke test, not an online-service or permanent-update-block guarantee.'
}
finally {
    foreach ($p in Get-Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.Path -and $_.Path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) -or $started.ContainsKey($_.Id)
    }) { Stop-Process -Id $p.Id -ErrorAction SilentlyContinue }
}
