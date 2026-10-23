# Start a DDK player (client or server exe) with a controlled environment block, without waiting for it.
# Empty-valued environment variables are removed by default because they crash the DDK
# EnvironmentVariableResolver in IL2CPP players (F-29). -InjectEmptyVar re-adds one for A/B tests.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File start-ddk-player.ps1 -Exe <experience.exe> -LogFile <player.log>
#          [-PlayerArgs <arg>,<arg>,...] [-InjectEmptyVar NAME]
#   Prefer calling it in-process (& start-ddk-player.ps1 -PlayerArgs @(...)): under -File, -PlayerArgs gets one token.
#   Pass each -KEY once (RC-01). -LogFile is made absolute and its folder created.
# Output: one JSON line {pid, removed_empty_vars, injected_empty, args}; the same record is appended to
#   <LogFile folder>\players.jsonl. Exit: 0 started, 2 bad arguments, 1 start failed.
param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $LogFile,
    [string[]] $PlayerArgs = @(),
    [string] $InjectEmptyVar = ''
)
$ErrorActionPreference = 'Stop'
function Resolve-Full([string]$p) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p) }
# Windows argv quoting (CommandLineToArgvW rules): empty -> "", backslashes doubled only before a quote.
function ConvertTo-Arg([string]$s) {
    if ($s -eq '') { return '""' }
    if ($s -notmatch '[\s"]') { return $s }
    $sb = New-Object System.Text.StringBuilder; [void]$sb.Append('"'); $bs = 0
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') { [void]$sb.Append('\' * (2 * $bs + 1)); [void]$sb.Append('"') } else { [void]$sb.Append('\' * $bs); [void]$sb.Append($ch) }
        $bs = 0
    }
    [void]$sb.Append('\' * (2 * $bs)); [void]$sb.Append('"'); $sb.ToString()
}
foreach ($pair in @(@('Exe', $Exe), @('LogFile', $LogFile))) {
    if ($pair[1] -match '"') { Write-Error "-$($pair[0]) contains a quote: drop the trailing backslash before the closing quote" -ErrorAction Continue; exit 2 }
}
$Exe = Resolve-Full $Exe
if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { Write-Error "player exe not found: $Exe" -ErrorAction Continue; exit 2 }
$LogFile = Resolve-Full $LogFile
$logDir = Split-Path $LogFile -Parent
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Exe
$psi.WorkingDirectory = Split-Path $Exe
$psi.UseShellExecute = $false
$psi.Arguments = (@($PlayerArgs + @('-logFile', $LogFile)) | ForEach-Object { ConvertTo-Arg $_ }) -join ' '
$removed = @()
foreach ($k in @($psi.EnvironmentVariables.Keys)) {
    if ([string]::IsNullOrEmpty($psi.EnvironmentVariables[$k])) { $psi.EnvironmentVariables.Remove($k); $removed += $k }
}
if ($InjectEmptyVar) { $psi.EnvironmentVariables[$InjectEmptyVar] = '' }
try { $p = [System.Diagnostics.Process]::Start($psi) } catch { Write-Error "start failed: $($_.Exception.Message)" -ErrorAction Continue; exit 1 }
$rec = [ordered]@{ pid = $p.Id; removed_empty_vars = ($removed -join ','); injected_empty = $InjectEmptyVar; args = $psi.Arguments }
$line = [ordered]@{ ts = (Get-Date).ToString('o'); run_id = [guid]::NewGuid().ToString('N').Substring(0, 8); level = 'info'; event = 'player_started'; loc = 'start-ddk-player.ps1'; ctx = ([ordered]@{ exe = $Exe; log = $LogFile } + $rec) }
[IO.File]::AppendAllText((Join-Path $logDir 'players.jsonl'), (($line | ConvertTo-Json -Compress -Depth 4) + "`n"), (New-Object System.Text.UTF8Encoding $false))
[pscustomobject]$rec | ConvertTo-Json -Compress
