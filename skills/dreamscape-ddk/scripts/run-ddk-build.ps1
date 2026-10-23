# Run one DDK batchmode build step against a project, append a JSONL result record, and exit with Unity's exit code.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File run-ddk-build.ps1 -Project <dir>
#          -Step <Compile|WindowsClient|WindowsServer|WindowsSinglePlayer|Android|Profile>
#          [-Out <root dir, or .apk path for Android/.exe or .apk path for Profile>] [-BuildProfile "Assets/Settings/Build Profiles/<name>.asset"]
#          [-Tag name] [-ExtraArgs -ddkAgentHooks] [-Unity <path to Unity.exe>]
#   -ExtraArgs is appended to the Unity command line. Under -File it receives ONE token; pass several as a comma
#   list, e.g. -ExtraArgs "-ddkAgentHooks,-ddkDefines,A;B". -ddkAgentHooks has no effect on -Step Profile.
# Logs: <project parent>\logs\<Tag>-<Step>.log (Unity) and <project parent>\logs\builds.jsonl (one record per start/end).
# Exit codes: from DDKAgentBuild 0 ok, 1 build failed, 2 bad args / wrong active target, 3 Addressables failed,
#   4 output missing; this script also exits 2 when the project or Unity.exe is missing, and -1 when Unity's exit code is unknown.
param(
    [Parameter(Mandatory)] [string] $Project,
    [Parameter(Mandatory)] [ValidateSet('Compile','WindowsClient','WindowsServer','WindowsSinglePlayer','Android','Profile')] [string] $Step,
    [string] $Out = '',
    [string] $BuildProfile = '',
    [string] $Tag = 'build',
    [string[]] $ExtraArgs = @(),
    [string] $Unity = 'C:\Program Files\Unity\Hub\Editor\6000.3.2f1\Editor\Unity.exe'
)
$ErrorActionPreference = 'Stop'
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$utf8 = New-Object System.Text.UTF8Encoding $false
function Resolve-Full([string]$p) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p).TrimEnd('\') }
# A trailing backslash before the closing quote would escape it for the native argument parser.
function Quote([string]$s) { '"' + $s.TrimEnd('\') + '"' }
# A value ending in \" (e.g. -Out "C:\dir\") makes the shell swallow every later parameter into it, and the
# default Unity.exe then runs with the wrong arguments. A real path never contains a quote, so refuse it.
foreach ($pair in @(@('Project', $Project), @('Out', $Out), @('BuildProfile', $BuildProfile), @('Unity', $Unity), @('Tag', $Tag))) {
    if ($pair[1] -match '"') { Write-Output "STEP_DONE step=$Step exit=2 reason=-$($pair[0]) contains a quote; drop the trailing backslash before the closing quote"; exit 2 }
}
$Project = Resolve-Full $Project
$logDir = Join-Path (Split-Path $Project -Parent) 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$unityLog = Join-Path $logDir "$Tag-$Step.log"
$jsonl = Join-Path $logDir 'builds.jsonl'
function Write-Event($level, $evt, $ctx) {
    $rec = [ordered]@{ ts = (Get-Date).ToString('o'); run_id = $runId; level = $level; event = $evt; loc = 'run-ddk-build.ps1'; ctx = $ctx }
    [IO.File]::AppendAllText($jsonl, (($rec | ConvertTo-Json -Compress -Depth 5) + "`n"), $utf8)
}
function Stop-BadArgs([string]$reason) { Write-Event 'error' 'bad_args' @{ step = $Step; reason = $reason }; Write-Output "STEP_DONE step=$Step exit=2 reason=$reason"; exit 2 }
if (-not (Test-Path -LiteralPath (Join-Path $Project 'ProjectSettings\ProjectSettings.asset'))) { Stop-BadArgs "not a Unity project: $Project" }
if (-not (Test-Path -LiteralPath $Unity)) { Stop-BadArgs "Unity.exe not found: $Unity" }
if ($Out) { $Out = Resolve-Full $Out }
$ExtraArgs = @($ExtraArgs | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

$unityArgs = @('-batchmode', '-nographics', '-projectPath', (Quote $Project))
if ($Step -eq 'Profile') {
    if (-not $BuildProfile -or -not $Out) { Stop-BadArgs 'Profile builds need -BuildProfile <asset path> and -Out <exe/apk path>' }
    if ($ExtraArgs -contains '-ddkAgentHooks') { Write-Event 'warn' 'hooks_ignored' @{ reason = 'BuildPlayerWithProfileOptions has no extra defines; use a non-Profile step' } }
    # The editor opens directly in the profile, so no mid-run target switch happens.
    $unityArgs += @('-activeBuildProfile', (Quote $BuildProfile), '-ddkProfile', (Quote $BuildProfile))
    $target = "profile:$BuildProfile"
} else {
    $target = if ($Step -eq 'Android') { 'Android' } else { 'Win64' }
    $unityArgs += @('-buildTarget', $target)
}
$unityArgs += @('-executeMethod', "DDK.AgentBuild.DDKAgentBuild.$Step", '-logFile', (Quote $unityLog))
if ($Out) { $unityArgs += @('-ddkOut', (Quote $Out)) }
$unityArgs += $ExtraArgs
Write-Event 'info' 'step_start' @{ project = $Project; step = $Step; target = $target; out = $Out; log = $unityLog; extra = ($ExtraArgs -join ' ') }
$t0 = Get-Date
# Wait for Unity itself only. Start-Process -Wait also waits for descendants, and Unity leaves daemons behind
# (VBCSCompiler, a first-time adb server), which hangs the script after the build has finished.
$p = Start-Process -FilePath $Unity -ArgumentList $unityArgs -PassThru -WindowStyle Hidden
$null = $p.Handle  # cache the handle so ExitCode stays readable after exit (PS 5.1)
$p.WaitForExit()
$code = if ($null -eq $p.ExitCode) { -1 } else { $p.ExitCode }
$secs = [int]((Get-Date) - $t0).TotalSeconds
$errCs = @(Select-String -LiteralPath $unityLog -Pattern 'error CS\d+' -ErrorAction SilentlyContinue).Count
$ci = Select-String -LiteralPath $unityLog -Pattern '\[DDK-CI\] ' -ErrorAction SilentlyContinue | Select-Object -Last 1
Write-Event ($(if ($code -eq 0) { 'info' } else { 'error' })) 'step_end' @{ step = $Step; exit = $code; seconds = $secs; error_cs = $errCs; last_ci = $(if ($ci) { $ci.Line.Substring($ci.Line.IndexOf('[DDK-CI]')) } else { '' }) }
"STEP_DONE step=$Step exit=$code seconds=$secs error_cs=$errCs log=$unityLog"
exit $code
