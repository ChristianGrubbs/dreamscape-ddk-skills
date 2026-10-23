# Unpack a Dreamscape Developer Kit installer bundle into an analysable tree. Every stage is idempotent and logs JSONL.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File ddk-extract.ps1 -Bundle <dreamscape-developer-kit-*.exe> -Out <empty dir> [-Stages all|<comma list>]
# Stages, in order: bundle, msi, cas, tgz (also writes package-inventory.json + dependency-check.json), launcher, docs, artifacts, decompile.
# Tools: wix (dotnet tool, 6.x), sfextract (dotnet tool), ilspycmd (dotnet tool), lessmsi (winget activescott.lessmsi),
#        7-Zip, tar.exe, python 3.12+ with brotli, pefile, html2text, beautifulsoup4.
# Log: <Out>\notes\extract.jsonl (BOM-free JSONL). Exit: 0 done, 2 bad -Stages / missing bundle / a tool a selected stage needs is missing.
param(
    [Parameter(Mandatory)] [string] $Bundle,
    [Parameter(Mandatory)] [string] $Out,
    [string] $Stages = 'all'
)
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$allStages = 'bundle', 'msi', 'cas', 'tgz', 'launcher', 'docs', 'artifacts', 'decompile'
$picked = if ($Stages -eq 'all') { $allStages } else { @($Stages -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$unknown = @($picked | Where-Object { $_ -notin $allStages })
if ($unknown) { Write-Host "unknown stage(s): $($unknown -join ','); valid: $($allStages -join ',')"; exit 2 }
New-Item -ItemType Directory -Force $Out, "$Out\notes", "$Out\extract", "$Out\decomp" | Out-Null
$jsonl = Join-Path $Out 'notes\extract.jsonl'
$utf8 = New-Object System.Text.UTF8Encoding $false
function Log($level, $evt, $ctx) { [IO.File]::AppendAllText($jsonl, (([ordered]@{ ts = (Get-Date).ToString('o'); run_id = $runId; level = $level; event = $evt; loc = 'ddk-extract.ps1'; ctx = $ctx } | ConvertTo-Json -Compress -Depth 5) + "`n"), $utf8); Write-Host "[$level] $evt $(($ctx | ConvertTo-Json -Compress -Depth 3))" }
function Want($s) { $picked -contains $s }
function Tool($name, $paths) { foreach ($p in $paths) { if ($p -and (Test-Path $p)) { return $p } }; $c = Get-Command $name -ErrorAction SilentlyContinue; if ($c) { return $c.Source }; return $null }

$wix   = Tool 'wix' @("$env:USERPROFILE\.dotnet\tools\wix.exe")
$sfx   = Tool 'sfextract' @("$env:USERPROFILE\.dotnet\tools\sfextract.exe")
$ilspy = Tool 'ilspycmd' @("$env:USERPROFILE\.dotnet\tools\ilspycmd.exe")
$lessmsi = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter lessmsi.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
$7z    = Tool '7z' @("$env:ProgramFiles\7-Zip\7z.exe")
$py    = Tool 'python' @()
Log 'info' 'tools' @{ wix = $wix; sfextract = $sfx; ilspycmd = $ilspy; lessmsi = $lessmsi; '7z' = $7z; python = $py }
$found = @{ wix = $wix; sfextract = $sfx; ilspycmd = $ilspy; lessmsi = $lessmsi; '7z' = $7z; python = $py }
$needs = @{ bundle = 'wix'; msi = 'lessmsi,wix,python'; cas = '7z,ilspycmd'; tgz = 'python'; launcher = 'python'; docs = 'python'; artifacts = 'sfextract,ilspycmd'; decompile = 'sfextract,ilspycmd' }
$missing = @($picked | ForEach-Object { $needs[$_] -split ',' } | Sort-Object -Unique | Where-Object { -not $found[$_] })
if ($missing) {
    Log 'error' 'missing_tools' @{ missing = ($missing -join ','); stages = ($picked -join ','); hint = 'dotnet tool install -g wix --version 6.0.2 --add-source https://api.nuget.org/v3/index.json; same for sfextract, ilspycmd; winget install activescott.lessmsi' }
    exit 2
}
if ((Want 'bundle') -and -not (Test-Path -LiteralPath $Bundle -PathType Leaf)) { Log 'error' 'bundle_missing' @{ bundle = $Bundle }; exit 2 }

$container = "$Out\extract\bundle\WixAttachedContainer"
if (Want 'bundle') {
    & $wix burn extract $Bundle -o "$Out\extract\bundle" -oba "$Out\extract\ba" 2>&1 | Out-Null
    Log 'info' 'bundle_extracted' @{ payloads = (Get-ChildItem $container -File -ErrorAction SilentlyContinue).Count; ba_files = (Get-ChildItem "$Out\extract\ba" -Recurse -File -ErrorAction SilentlyContinue).Count }
}
if (Want 'msi') {
    foreach ($m in Get-ChildItem $container -Filter *.msi) {
        $n = [IO.Path]::GetFileNameWithoutExtension($m.Name); $d = "$Out\extract\msi\$n"
        New-Item -ItemType Directory -Force $d, "$d\_binaries" | Out-Null
        & $lessmsi x $m.FullName "$d\" | Out-Null
        & $wix msi decompile $m.FullName -o "$d\_decompiled.wxs" 2>&1 | Out-Null
        & $wix msi decompile $m.FullName -x "$d\_binaries" -o "$d\_binaries\_with_binaries.wxs" 2>&1 | Out-Null
        if (Test-Path "$d\_binaries\File") { Remove-Item -LiteralPath "$d\_binaries\File" -Recurse -Force -Confirm:$false }
        Log 'info' 'msi_extracted' @{ msi = $n; files = (Get-ChildItem $d -Recurse -File).Count }
    }
    & $py -I "$here\decode_manifests.py" "$Out\extract\msi" "$Out\notes\orchestrator-manifests.json"
}
if (Want 'cas') {
    foreach ($b in Get-ChildItem "$Out\extract\msi" -Recurse -File -Filter *_File) {
        $name = $b.Name -replace '_File$', ''; $raw = "$Out\extract\ca\$name"; $dec = "$Out\decomp\ca\$name"
        if (Test-Path "$dec\*.csproj") { continue }
        New-Item -ItemType Directory -Force $raw, $dec | Out-Null
        & $7z x -y -o"$raw" $b.FullName | Out-Null
        $asm = Get-ChildItem $raw -File | Where-Object { $_.Extension -in '.exe', '.dll' -and $_.Name -notmatch '^(WixSharp|WixToolset)' } | Select-Object -First 1
        if ($asm) { & $ilspy -p -o $dec $asm.FullName 2>&1 | Out-Null }
        Log 'info' 'ca_decompiled' @{ ca = $name; assembly = $asm.Name }
    }
}
if (Want 'tgz') {
    New-Item -ItemType Directory -Force "$Out\extract\packages\_templates" | Out-Null
    foreach ($t in Get-ChildItem "$Out\extract\msi" -Recurse -Filter *.tgz) {
        $isTemplate = $t.FullName -match 'Unity Templates'
        $name = [IO.Path]::GetFileNameWithoutExtension($t.Name)
        $dst = if ($isTemplate) { "$Out\extract\packages\_templates\" + ($t.FullName -replace '.*\\msi\\([^\\]+)\\.*', '$1') + "__$name" } else { "$Out\extract\packages\$name" }
        New-Item -ItemType Directory -Force $dst | Out-Null
        & tar.exe -xzf $t.FullName -C $dst
    }
    & $py -I "$here\package_inventory.py" "$Out\extract\packages" "$Out\notes\package-inventory.json" | Out-Null
    & $py -I "$here\dep_check.py" "$Out\extract\packages" "$Out\notes\dependency-check.json"
    Log 'info' 'packages_unpacked' @{ packages = (Get-ChildItem "$Out\extract\packages" -Directory | Where-Object Name -notlike '_*').Count }
}
if (Want 'launcher') {
    $kb = Get-ChildItem "$Out\extract\msi" -Recurse -Filter kernel_blob.bin | Select-Object -First 1
    if ($kb) { & $py -I "$here\dill_sources.py" $kb.FullName "$Out\extract\launcher_src" 'dream-launcher' | Select-Object -Last 1; Log 'info' 'launcher_source' @{ kernel = $kb.FullName } }
    else { Log 'warn' 'launcher_source_skipped' @{ reason = 'no kernel_blob.bin (release build); only app.so AOT present' } }
}
if (Want 'docs') {
    $docExe = Get-ChildItem "$Out\extract\msi" -Recurse -Filter dreamscape-documentation.exe | Select-Object -First 1
    if ($docExe) {
        & $py -I "$here\tauri_assets.py" $docExe.FullName "$Out\extract\docs_site" | Select-Object -First 1
        & $py -I "$here\docs_to_md.py" "$Out\extract\docs_site" "$Out\extract\docs_md" | Select-Object -First 1
        Log 'info' 'docs_carved' @{ pages = @(Get-ChildItem "$Out\extract\docs_md" -Filter *.md | Where-Object Name -ne '_INDEX.md').Count }
    }
}
if (Want 'artifacts') {
    New-Item -ItemType Directory -Force "$Out\extract\artifacts" | Out-Null
    foreach ($t in Get-ChildItem "$Out\extract\packages" -Recurse -Filter *.tar.gz) {
        $d = "$Out\extract\artifacts\" + ($t.Name -replace '\.tar\.gz$', ''); New-Item -ItemType Directory -Force $d | Out-Null; & tar.exe -xzf $t.FullName -C $d
    }
    foreach ($exe in 'DreamStation.exe', 'HapticUniverseController.exe', 'ViconRoutingServer.exe') {
        $e = Get-ChildItem "$Out\extract\artifacts" -Recurse -Filter $exe | Select-Object -First 1; if (-not $e) { continue }
        $base = [IO.Path]::GetFileNameWithoutExtension($exe); $sfo = "$Out\extract\artifacts\_sf\$base"
        New-Item -ItemType Directory -Force $sfo, "$Out\decomp\artifacts\$base" | Out-Null
        & $sfx $e.FullName -o $sfo 2>&1 | Out-Null
        $dll = Get-ChildItem $sfo -Filter "$base.dll" | Select-Object -First 1
        if ($dll) { & $ilspy -p -o "$Out\decomp\artifacts\$base" $dll.FullName 2>&1 | Out-Null }
        Log 'info' 'artifact_decompiled' @{ service = $base; cs = (Get-ChildItem "$Out\decomp\artifacts\$base" -Recurse -Filter *.cs -ErrorAction SilentlyContinue).Count }
    }
}
if (Want 'decompile') {
    $orch = Get-ChildItem $container -Filter WorkspaceOrchestrator.exe | Select-Object -First 1
    if ($orch) {
        New-Item -ItemType Directory -Force "$Out\extract\orchestrator_sf", "$Out\decomp\WorkspaceOrchestrator" | Out-Null
        & $sfx $orch.FullName -o "$Out\extract\orchestrator_sf" 2>&1 | Out-Null
        & $ilspy -p -o "$Out\decomp\WorkspaceOrchestrator" "$Out\extract\orchestrator_sf\WorkspaceOrchestrator.dll" 2>&1 | Out-Null
    }
    $ui = Get-ChildItem "$Out\extract\ba" -Filter DreamscapeLearn.UI.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ui) { New-Item -ItemType Directory -Force "$Out\decomp\DreamscapeLearn.UI" | Out-Null; & $ilspy -p -o "$Out\decomp\DreamscapeLearn.UI" $ui.FullName 2>&1 | Out-Null }
    Log 'info' 'installer_decompiled' @{ orchestrator = [bool]$orch; ui = [bool]$ui }
}
Log 'info' 'done' @{ out = $Out; stages = ($picked -join ',') }
exit 0
