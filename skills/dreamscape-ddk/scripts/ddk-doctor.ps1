# DDK environment doctor: checks every prerequisite for building Dreamscape Developer Kit projects headless.
# Exit 0 = every REQUIRED check passed; 1 = at least one REQUIRED check failed. Optional checks only warn.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File ddk-doctor.ps1 [-UnityVersion 6000.3.2f1] [-Changeset a9779f353c9b]
#          [-TarballDir <dir>] [-TemplateDir <dir>] [-Json] [-LogFile <path.jsonl>]
# Log: one JSONL record per check plus a result record, appended to -LogFile (default %TEMP%\ddk-doctor.jsonl).
param(
    [string] $UnityVersion = '6000.3.2f1',
    [string] $Changeset = 'a9779f353c9b',
    [string] $TarballDir = "$env:ProgramData\Dreamscape Developer Kit\Package Cache",
    [string] $TemplateDir = "$env:ProgramData\Dreamscape Developer Kit\Unity Templates",
    [switch] $Json,
    [string] $LogFile = (Join-Path $env:TEMP 'ddk-doctor.jsonl')
)
$ErrorActionPreference = 'Continue'
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$utf8 = New-Object System.Text.UTF8Encoding $false
function Write-Event([string]$level, [string]$evt, $ctx) {
    $rec = [ordered]@{ ts = (Get-Date).ToString('o'); run_id = $runId; level = $level; event = $evt; loc = 'ddk-doctor.ps1'; ctx = $ctx }
    try { [IO.File]::AppendAllText($LogFile, (($rec | ConvertTo-Json -Compress -Depth 5) + "`n"), $utf8) } catch { }
}
$results = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$name, [bool]$ok, [bool]$required, [string]$detail, [string]$fix) {
    $results.Add([pscustomobject]@{ check = $name; ok = $ok; required = $required; detail = $detail; fix = $fix })
    Write-Event ($(if ($ok) { 'info' } elseif ($required) { 'error' } else { 'warn' })) 'check' @{ check = $name; ok = $ok; required = $required; detail = $detail }
}

# 1. Unity CLI (standalone first, then the copy bundled in Unity Hub >= 3.22)
$cliCandidates = @("$env:LOCALAPPDATA\Unity\bin\unity.exe", "$env:ProgramFiles\Unity Hub\resources\cli\unity.exe", "$env:ProgramFiles\Unity Hub\resources\unity.exe")
$cli = $cliCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
Add-Check 'unity-cli' ([bool]$cli) $false ($(if ($cli) { $cli } else { 'not found' })) 'irm https://unity.com/install.ps1 | iex   (then a new shell)'

# 2. Editor + modules
$editorRoot = "$env:ProgramFiles\Unity\Hub\Editor\$UnityVersion"
$editorExe = Join-Path $editorRoot 'Editor\Unity.exe'
Add-Check 'unity-editor' (Test-Path -LiteralPath $editorExe) $true $editorExe "unity install $UnityVersion --changeset $Changeset --architecture x86_64 --accept-eula --yes (+ one --module per missing module below); never --resume on a first install"
$needMods = 'windows-il2cpp', 'windows-server', 'android', 'android-sdk-ndk-tools', 'android-open-jdk-17.0.9+9'
$have = @()
if (Test-Path -LiteralPath "$editorRoot\modules.json") {
    # Parentheses force PS 5.1 to enumerate the top-level JSON array before filtering.
    try { $have = (Get-Content -LiteralPath "$editorRoot\modules.json" -Raw | ConvertFrom-Json) | Where-Object { $_.selected -or $_.isInstalled } | ForEach-Object { $_.id } } catch { }
}
foreach ($m in $needMods) {
    $req = $m -in 'windows-il2cpp', 'windows-server'
    Add-Check "module:$m" ($m -in $have) $req ($(if ($m -in $have) { 'installed' } else { 'missing' })) "unity install-modules --editor-version $UnityVersion --module $m --accept-eula"
}

# 3. License (needs the CLI)
if ($cli) {
    $env:UNITY_NO_BANNER = '1'; $env:UNITY_NON_INTERACTIVE = '1'
    $lic = $null
    try { $lic = (& $cli license list --json 2>$null | Out-String | ConvertFrom-Json).data } catch { }
    $names = @($lic | ForEach-Object { $_.product }) -join ', '
    Add-Check 'unity-license' ([bool]($names -match 'Unity (Personal|Pro|Plus|Industry|Enterprise)')) $true $names 'unity auth login  (the human signs in; then unity license list --json)'
} else {
    Add-Check 'unity-license' $false $true 'cannot check without the Unity CLI' 'install the Unity CLI'
}

# 4. C++ toolchain for IL2CPP Windows (Build Tools are enough; -products * is mandatory)
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vc = $null
if (Test-Path -LiteralPath $vswhere) { $vc = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1 }
Add-Check 'msvc-toolchain' ([bool]$vc) $true ($(if ($vc) { $vc } else { 'no instance with VC.Tools.x86.x64' })) 'winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended"'
$sdk = Test-Path -LiteralPath "${env:ProgramFiles(x86)}\Windows Kits\10\Lib\10.0.22621.0"
Add-Check 'windows-sdk-22621' $sdk $false ($(if ($sdk) { 'present' } else { 'missing' })) 'add Microsoft.VisualStudio.Component.Windows11SDK.22621'

# 5. DDK package tarballs and templates (inputs of make_filedeps_project.py)
$tgz = @(Get-ChildItem -LiteralPath $TarballDir -Filter 'com.dreamscape-learn.*.tgz' -ErrorAction SilentlyContinue)
Add-Check 'ddk-tarballs' ($tgz.Count -ge 55) $true "$($tgz.Count) tarballs in $TarballDir" 'install the DDK, or extract the bundle with the dreamscape-ddk-re skill and pass -TarballDir'
$tmpl = @(Get-ChildItem -LiteralPath $TemplateDir -Filter 'template.*.tgz' -ErrorAction SilentlyContinue)
Add-Check 'ddk-templates' ($tmpl.Count -ge 1) $false "$($tmpl.Count) template tgz in $TemplateDir" 'extract templates from the bundle (dreamscape-ddk-re) and pass -TemplateDir'

# 6. Optional services
$py = Get-Command python -ErrorAction SilentlyContinue
Add-Check 'python' ([bool]$py) $false ($(if ($py) { $py.Source } else { 'not on PATH' })) 'winget install Python.Python.3.12 (the skill scripts, Dev Deploy upload and the content server need it; the DDK installs none)'
$verd = Get-NetTCPConnection -LocalPort 4873 -State Listen -ErrorAction SilentlyContinue
Add-Check 'verdaccio-4873' ([bool]$verd) $false ($(if ($verd) { 'listening' } else { 'not listening (fine for the file: route)' })) 'Start-ScheduledTask VerdaccioStartup, or use make_filedeps_project.py'

# 7. Host hygiene
$lp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
Add-Check 'long-paths' ($lp -eq 1) $false "LongPathsEnabled=$lp" 'keep project paths short (e.g. C:\p\<name>) or enable long paths (admin)'
$empty = @([Environment]::GetEnvironmentVariables().GetEnumerator() | Where-Object { [string]::IsNullOrEmpty([string]$_.Value) } | ForEach-Object { $_.Key })
Add-Check 'empty-env-vars' ($empty.Count -eq 0) $false ($(if ($empty.Count) { 'present: ' + ($empty -join ',') } else { 'none' })) 'launch players only via start-ddk-player.ps1 (F-29: empty vars crash the DDK config system in IL2CPP players)'
$drive = Get-PSDrive -Name (Split-Path -Qualifier (Get-Location).Path).TrimEnd(':') -ErrorAction SilentlyContinue
$freeGb = if ($drive) { [math]::Round($drive.Free / 1GB, 1) } else { -1 }
Add-Check 'disk-free' ($freeGb -ge 30) $false "$freeGb GB free on current drive" 'a project + Library + 3 builds needs about 30 GB'

$failedRequired = @($results | Where-Object { $_.required -and -not $_.ok })
Write-Event ($(if ($failedRequired.Count -eq 0) { 'info' } else { 'error' })) 'result' @{ ready = ($failedRequired.Count -eq 0); failed_required = @($failedRequired | ForEach-Object { $_.check }) }
if ($Json) {
    [pscustomobject]@{ ok = ($failedRequired.Count -eq 0); checks = $results } | ConvertTo-Json -Depth 4
} else {
    foreach ($r in $results) {
        $tag = if ($r.ok) { 'PASS' } elseif ($r.required) { 'FAIL' } else { 'WARN' }
        "{0}  {1,-28} {2}" -f $tag, $r.check, $r.detail
        if (-not $r.ok) { "      fix: $($r.fix)" }
    }
    "RESULT: " + $(if ($failedRequired.Count -eq 0) { 'ready' } else { "$($failedRequired.Count) required check(s) failed" })
}
exit $(if ($failedRequired.Count -eq 0) { 0 } else { 1 })
