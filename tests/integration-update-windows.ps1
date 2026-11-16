$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true") {
    Write-Error "integration-update-windows.ps1 starts the app; it runs on the CI runner only"
    exit 1
}
Set-Location (Join-Path $PSScriptRoot "..")
$oldBuild = (Resolve-Path "windows/publish/VPNToggle.exe").Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("vpntoggle-up-" + [guid]::NewGuid().ToString("N"))
$served = Join-Path $work "served"
$appFolder = Join-Path $work "app"
$inst = Join-Path $appFolder "VPNToggle.exe"
$appLog = Join-Path $env:LOCALAPPDATA "VPNToggle\VPNToggle.log"
$script:server = $null
$began = Get-Date

function Cleanup {
    Get-Process VPNToggle -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $inst } | ForEach-Object { try { $_.Kill() } catch { } }
    if ($null -ne $script:server) { try { if (-not $script:server.HasExited) { $script:server.Kill() } } catch { } }
}

function Fail([string]$message) {
    Write-Host "FAIL update: $message"
    if (Test-Path $appLog) { Get-Content $appLog | Write-Host }
    try {
        Get-WinEvent -FilterHashtable @{ LogName = "Application"; StartTime = $began } -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -in ".NET Runtime", "Application Error", "Windows Error Reporting" } |
            Select-Object -First 6 | ForEach-Object { Write-Host "--- $($_.ProviderName) $($_.TimeCreated)"; Write-Host $_.Message }
    } catch { Write-Host "no event log entries: $_" }
    Cleanup
    exit 1
}

function Digest([string]$path) { return (Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant() }

function Release([string]$tag, [string]$url, [string]$digest, [long]$size) {
    $field = ""
    if ($digest -ne "") { $field = "`"digest`": `"sha256:$digest`"," }
    $json = "{`"tag_name`": `"$tag`", `"html_url`": `"https://github.com/alwinpaul1/VPNToggle/releases/tag/$tag`", " +
        "`"assets`": [{`"name`": `"VPNToggle.exe`", $field `"size`": $size, `"browser_download_url`": `"$url`"}]}"
    [System.IO.File]::WriteAllText((Join-Path $served "latest.json"), $json)
}

function Attempt {
    $p = Start-Process $inst -ArgumentList "--self-update-test" -Wait -PassThru
    return $p.ExitCode
}

function Refused([string]$name, [string]$kind) {
    $code = Attempt
    if ($code -ne 3) { Fail "${name}: exit code $code, expected a refusal" }
    if (-not (Select-String -Path $appLog -Pattern "update test: not installed: $kind" -Quiet)) { Fail "${name}: expected refusal $kind in the log" }
    if ((Digest $inst) -ne $oldDigest) { Fail "${name}: the installed program changed" }
    $left = @(Get-ChildItem $appFolder | ForEach-Object Name)
    if ($left.Count -ne 1) { Fail "${name}: files left next to the program: $($left -join ', ')" }
    Write-Host "ok: $name refused ($kind), old program intact"
}

New-Item -ItemType Directory -Path $served, $appFolder | Out-Null
dotnet publish windows/VPNToggle.csproj -c Release -o (Join-Path $work "new") -p:Version=99.0 -p:AssemblyVersion=99.0.0.0 -p:FileVersion=99.0.0.0 --nologo -v quiet
if ($LASTEXITCODE -ne 0) { Fail "publishing the new version failed" }
Copy-Item (Join-Path $work "new\VPNToggle.exe") (Join-Path $served "VPNToggle.exe")
Copy-Item $oldBuild (Join-Path $served "old.exe")
Copy-Item $oldBuild $inst
$oldVersion = (Get-Item $inst).VersionInfo.FileVersion
$newVersion = (Get-Item (Join-Path $served "VPNToggle.exe")).VersionInfo.FileVersion
Write-Host "old $oldVersion, new $newVersion"
if (-not ([version]$newVersion -gt [version]$oldVersion)) { Fail "the new build is not newer than the old one" }
if ([version]$newVersion -ne [version]"99.0.0.0") { Fail "the new build is not version 99.0" }
$oldDigest = Digest $inst
$good = Digest (Join-Path $served "VPNToggle.exe")
$bytes = (Get-Item (Join-Path $served "VPNToggle.exe")).Length
$oldBytes = (Get-Item (Join-Path $served "old.exe")).Length

$port = Get-Random -Minimum 20000 -Maximum 40000
$script:server = Start-Process python -ArgumentList "-m", "http.server", "$port", "--bind", "127.0.0.1", "--directory", "`"$served`"" -PassThru -WindowStyle Hidden
$origin = "http://127.0.0.1:$port"
$env:VPNTOGGLE_UPDATE_TEST_API = "$origin/latest.json"
$up = $false
for ($i = 0; $i -lt 50 -and -not $up; $i++) {
    try { Invoke-WebRequest "$origin/old.exe" -Method Head -UseBasicParsing | Out-Null; $up = $true } catch { Start-Sleep -Milliseconds 200 }
}
if (-not $up) { Fail "the local server did not start" }
if (Test-Path $appLog) { Remove-Item $appLog }

Release "v99.0" "$origin/VPNToggle.exe" $oldDigest $bytes
Refused "bad digest" "DigestMismatch"
Release "v99.0" "$origin/VPNToggle.exe" "" $bytes
Refused "missing digest" "MissingDigest"
Release "v99.0" "https://example.org/VPNToggle.exe" $good $bytes
Refused "disallowed host" "UrlNotAllowed"
Release "v99.0" "http://127.0.0.1:$($port + 1)/VPNToggle.exe" $good $bytes
Refused "another local port" "UrlNotAllowed"
Release "v99.0" "$origin/old.exe" $oldDigest $oldBytes
Refused "download older than the release says" "WrongApp"
Release "v0.1" "$origin/VPNToggle.exe" $good $bytes
Refused "release not newer" "NotNewer"

Release "v99.0" "$origin/VPNToggle.exe" $good $bytes
$code = Attempt
if ($code -ne 0) { Fail "update: exit code $code" }
if ((Digest $inst) -ne $good) { Fail "update: the program in place is not the new one" }
if ([version](Get-Item $inst).VersionInfo.FileVersion -ne [version]"99.0.0.0") { Fail "update: wrong version in place" }
$running = $null
for ($i = 0; $i -lt 75 -and $null -eq $running; $i++) {
    $running = Get-Process VPNToggle -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $inst } | Select-Object -First 1
    if ($null -eq $running) { Start-Sleep -Milliseconds 200 }
}
if ($null -eq $running) { Fail "update: the new version was not started" }
$gone = $false
for ($i = 0; $i -lt 120 -and -not $gone; $i++) {
    $gone = -not (Test-Path "$inst.old") -and -not (Test-Path "$inst.new")
    if (-not $gone) { Start-Sleep -Milliseconds 500 }
}
if (-not $gone) { Fail "update: the old program file was not cleaned up" }
Start-Sleep -Seconds 8
if ($running.HasExited) { Fail "update: the new version did not stay up" }
if (-not (Select-String -Path $appLog -Pattern "update: now running 99.0" -Quiet)) { Fail "update: the new version did not log its version" }
$copies = @(Get-Process VPNToggle -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $inst })
if ($copies.Count -ne 1) { Fail "update: $($copies.Count) copies are running" }
Get-Content $appLog | Write-Host
Write-Host "ok: $oldVersion replaced by 99.0, new version running as pid $($running.Id)"

Cleanup
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host "update integration: passed"
exit 0
