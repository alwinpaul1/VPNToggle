$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true") {
    Write-Error "integration-windows.ps1 installs a SYSTEM scheduled task; it runs on the CI runner only"
    exit 1
}
Set-Location (Join-Path $PSScriptRoot "..")
$exe = (Resolve-Path "windows/publish/VPNToggle.exe").Path
$taskName = "VPNToggle NVM Pause"
$installed = Join-Path $env:ProgramFiles "VPNToggle\VPNToggle.exe"
$pauseLog = Join-Path $env:ProgramData "VPNToggle\nvm-pause.log"
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("vpntoggle-it-" + [guid]::NewGuid().ToString("N"))
$started = New-Object System.Collections.Generic.List[System.Diagnostics.Process]

function Fail([string]$message) {
    Write-Host "FAIL integration: $message"
    if (Test-Path $pauseLog) { Get-Content $pauseLog | Write-Host }
    Get-Process | Where-Object { $_.ProcessName -match "acnvmagent|csc_vpnagent|VPNToggle" } |
        ForEach-Object { Write-Host "$($_.Id) $($_.ProcessName) session $($_.SessionId)" }
    Cleanup
    exit 1
}

function Cleanup {
    try { Start-Process $exe -ArgumentList "--nvm-uninstall" -Wait | Out-Null } catch { }
    foreach ($p in $started) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
}

function Suspended([int]$id) {
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $false }
    $threads = @($p.Threads)
    if ($threads.Count -eq 0) { return $false }
    foreach ($t in $threads) {
        if ($t.ThreadState -ne [System.Diagnostics.ThreadState]::Wait) { return $false }
        if ($t.WaitReason -ne [System.Diagnostics.ThreadWaitReason]::Suspended) { return $false }
    }
    return $true
}

function WaitSuspended([int]$id, [bool]$wanted, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Suspended $id) -eq $wanted) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Spawn([string]$folder, [string]$name) {
    $dir = Join-Path $work $folder
    Copy-Item -Recurse (Join-Path $work "dummy") $dir
    Rename-Item (Join-Path $dir "Dummy.exe") "$name.exe"
    $p = Start-Process (Join-Path $dir "$name.exe") -PassThru -WindowStyle Hidden
    $started.Add($p)
    return $p
}

function TaskPresent {
    schtasks.exe /Query /TN $taskName 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

New-Item -ItemType Directory -Path $work | Out-Null
dotnet build tests/windows-dummy/Dummy.csproj -c Release -o (Join-Path $work "dummy") --nologo -v quiet
if ($LASTEXITCODE -ne 0) { Fail "the dummy process did not build" }

$agent = Spawn "a" "acnvmagent"
$decoy1 = Spawn "b" "csc_vpnagent"
$decoy2 = Spawn "c" "acnvmagent2"
Start-Sleep -Seconds 2
if ($agent.HasExited -or $decoy1.HasExited -or $decoy2.HasExited) { Fail "a dummy process exited" }
if ((Get-Process -Id $agent.Id).ProcessName -ne "acnvmagent") { Fail "the dummy is not named acnvmagent" }
if (Suspended $agent.Id) { Fail "the dummy counts as suspended before the install" }

$install = Start-Process $exe -ArgumentList "--nvm-install" -Wait -PassThru
if ($install.ExitCode -ne 0) { Fail "install exited with $($install.ExitCode)" }
if (-not (TaskPresent)) { Fail "the scheduled task is missing" }
if (-not (Test-Path $installed)) { Fail "the pauser was not copied to Program Files" }
$xml = [xml](schtasks.exe /Query /TN $taskName /XML | Out-String)
if ($xml.Task.Principals.Principal.UserId -ne "S-1-5-18") { Fail "the task does not run as SYSTEM" }
if ($xml.Task.Settings.DisallowStartIfOnBatteries -ne "false") { Fail "the task would not start on battery" }
if ($xml.Task.Settings.ExecutionTimeLimit -ne "PT0S") { Fail "the task has a time limit" }
if (-not (WaitSuspended $agent.Id $true 10)) { Fail "agent not suspended within 10 s" }
Start-Sleep -Seconds 2
if (-not (Suspended $agent.Id)) { Fail "agent did not stay suspended" }
if ((Suspended $decoy1.Id) -or $decoy1.HasExited) { Fail "decoy csc_vpnagent was suspended" }
if ((Suspended $decoy2.Id) -or $decoy2.HasExited) { Fail "decoy acnvmagent2 was suspended" }
Write-Host "ok: agent suspended, decoys untouched"

$agent.Kill()
$agent.WaitForExit(5000) | Out-Null
$agent = Spawn "d" "acnvmagent"
if (-not (WaitSuspended $agent.Id $true 4)) { Fail "respawned agent not suspended within 4 s" }
if (Suspended $decoy1.Id) { Fail "decoy suspended after the respawn" }
Write-Host "ok: respawned agent suspended"

$again = Start-Process $exe -ArgumentList "--nvm-install" -Wait -PassThru
if ($again.ExitCode -ne 0) { Fail "second install exited with $($again.ExitCode)" }
if (-not (WaitSuspended $agent.Id $true 10)) { Fail "agent not suspended after a second install" }
Write-Host "ok: installing twice works"

$uninstall = Start-Process $exe -ArgumentList "--nvm-uninstall" -Wait -PassThru
if ($uninstall.ExitCode -ne 0) { Fail "uninstall exited with $($uninstall.ExitCode)" }
if (-not (WaitSuspended $agent.Id $false 3)) { Fail "agent not resumed after uninstall" }
if (TaskPresent) { Fail "the scheduled task is still there" }
if (Test-Path $installed) { Fail "the pauser file is still in Program Files" }
Start-Sleep -Seconds 2
if (Suspended $agent.Id) { Fail "agent suspended again after uninstall" }
if ($agent.HasExited) { Fail "agent died during uninstall" }
Write-Host "ok: uninstall resumed the agent and removed the task"

$app = Start-Process $exe -PassThru
$started.Add($app)
Start-Sleep -Seconds 12
if ($app.HasExited) { Fail "the app exited within 12 s with code $($app.ExitCode)" }
$appLog = Join-Path $env:LOCALAPPDATA "VPNToggle\VPNToggle.log"
if (-not (Test-Path $appLog)) { Fail "the app wrote no log" }
$tag = (git describe --tags --abbrev=0 --match "v*").TrimStart("v")
$stamped = (Get-Item $exe).VersionInfo.FileVersion
Write-Host "tag $tag, exe $stamped"
if ([version]$stamped -ne [version]$tag) { Fail "the published exe is version $stamped, the tag says $tag" }
$tagVersion = [version]$tag
$shown = if ($tagVersion.Build -gt 0) { "$($tagVersion.Major).$($tagVersion.Minor).$($tagVersion.Build)" } else { "$($tagVersion.Major).$($tagVersion.Minor)" }
if (-not (Select-String -Path $appLog -SimpleMatch "app started $shown" -Quiet)) { Fail "the app did not start as version $shown" }
Get-Content $appLog | Write-Host
Write-Host "ok: app published, started and stayed up"

foreach ($p in $started) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host "integration: passed"
exit 0
