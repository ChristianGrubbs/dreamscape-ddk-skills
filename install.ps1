# Install the skills in this repo for Codex and/or Claude Code (Windows PowerShell 5.1+).
#   Codex reads   %USERPROFILE%\.agents\skills\<name>   (also scanned: $CODEX_HOME\skills; do not install into both)
#   Claude Code   %USERPROFILE%\.claude\skills\<name>
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 [-Agent both|codex|claude] [-Mode link|copy] [-Force] [-Uninstall] [-HomeDir <dir>]
# -Mode link (default) creates directory junctions into this clone, so `git pull` updates the skills in place; no admin needed.
# -Mode copy copies the folders (re-run after `git pull`); copies carry a marker file so they can be replaced or removed safely.
# Existing folders that this script did not create are left alone unless -Force, which renames them to <name>.bak-<timestamp>.
# Exit 0 = every skill installed (or already installed / removed); 1 = at least one skill was skipped or failed.
param(
    [ValidateSet('both', 'codex', 'claude')] [string] $Agent = 'both',
    [ValidateSet('link', 'copy')] [string] $Mode = 'link',
    [switch] $Force,
    [switch] $Uninstall,
    [string] $HomeDir = $env:USERPROFILE
)
$ErrorActionPreference = 'Stop'
$runId  = [guid]::NewGuid().ToString('N').Substring(0, 8)
$repo   = $PSScriptRoot
$marker = '.dreamscape-ddk-skills-install'
$logPath = Join-Path $env:TEMP 'dreamscape-ddk-skills-install.jsonl'
function Log($level, $evt, $ctx) {
    $line = ([ordered]@{ ts = (Get-Date).ToString('o'); run_id = $runId; level = $level; event = $evt; loc = 'install.ps1'; ctx = $ctx } | ConvertTo-Json -Compress -Depth 4)
    [IO.File]::AppendAllText($logPath, $line + "`n", (New-Object Text.UTF8Encoding $false))
    $tag = if ($level -eq 'error') { 'FAIL' } elseif ($level -eq 'warn') { 'WARN' } else { 'OK  ' }
    Write-Host ("{0} {1} {2}" -f $tag, $evt, (($ctx.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))
}
function IsLink($p) { $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; return ($i -and ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) }
function FinalTarget($p) {
    # Follow junction/symlink chains (max 8 hops) to compare where a link really points.
    $cur = $p
    for ($i = 0; $i -lt 8 -and (IsLink $cur); $i++) {
        $t = @((Get-Item -LiteralPath $cur -Force).Target)[0]
        if (-not $t) { break }
        if (-not [IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path $cur -Parent) $t }
        $cur = $t
    }
    return [IO.Path]::GetFullPath($cur).TrimEnd('\')
}
function RemoveLinkOnly($p) { [IO.Directory]::Delete($p, $false) }   # deletes the junction itself, never the target's files

$skills = @(Get-ChildItem -LiteralPath (Join-Path $repo 'skills') -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })
if (-not $skills) { Log 'error' 'no_skills_found' @{ repo = $repo }; exit 1 }
$roots = @()
if ($Agent -in 'both', 'codex')  { $roots += [pscustomobject]@{ agent = 'codex';  dir = Join-Path $HomeDir '.agents\skills' } }
if ($Agent -in 'both', 'claude') { $roots += [pscustomobject]@{ agent = 'claude'; dir = Join-Path $HomeDir '.claude\skills' } }
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HomeDir '.codex' }
$failed = 0
foreach ($root in $roots) {
    New-Item -ItemType Directory -Force -Path $root.dir | Out-Null
    foreach ($s in $skills) {
        $src = [IO.Path]::GetFullPath($s.FullName).TrimEnd('\')
        $dst = Join-Path $root.dir $s.Name
        $ctx = [ordered]@{ agent = $root.agent; skill = $s.Name; dst = $dst }
        $exists = Test-Path -LiteralPath $dst
        $isLink = $exists -and (IsLink $dst)
        $ours   = $exists -and ($isLink -and ((FinalTarget $dst) -eq $src) -or (Test-Path -LiteralPath (Join-Path $dst $marker)))
        if ($Uninstall) {
            if (-not $exists) { Log 'info' 'not_installed' $ctx; continue }
            if ($isLink -and (FinalTarget $dst) -eq $src) { RemoveLinkOnly $dst; Log 'info' 'removed_link' $ctx; continue }
            if (-not $isLink -and (Test-Path -LiteralPath (Join-Path $dst $marker))) { Remove-Item -LiteralPath $dst -Recurse -Force; Log 'info' 'removed_copy' $ctx; continue }
            Log 'warn' 'left_foreign_folder' $ctx; $failed++; continue
        }
        if ($root.agent -eq 'codex' -and (Test-Path -LiteralPath (Join-Path $codexHome "skills\$($s.Name)"))) {
            Log 'warn' 'duplicate_in_codex_home' ([ordered]@{ skill = $s.Name; other = (Join-Path $codexHome "skills\$($s.Name)"); note = 'Codex will list both; remove one' })
        }
        if ($exists -and $isLink -and (FinalTarget $dst) -eq $src -and $Mode -eq 'link') { Log 'info' 'already_installed' $ctx; continue }
        if ($exists) {
            if ($ours) {
                if ($isLink) { RemoveLinkOnly $dst } else { Remove-Item -LiteralPath $dst -Recurse -Force }
                Log 'info' 'replacing_previous_install' $ctx
            } elseif ($Force) {
                $bak = "$dst.bak-$(Get-Date -Format yyyyMMddHHmmss)"
                if ($isLink) { RemoveLinkOnly $dst; Log 'warn' 'removed_foreign_link' $ctx } else { Rename-Item -LiteralPath $dst -NewName (Split-Path $bak -Leaf); Log 'warn' 'backed_up_foreign_folder' ([ordered]@{ skill = $s.Name; backup = $bak }) }
            } else {
                Log 'error' 'skipped_existing' ([ordered]@{ agent = $root.agent; skill = $s.Name; dst = $dst; fix = 're-run with -Force (renames it to .bak-<ts>)' }); $failed++; continue
            }
        }
        try {
            if ($Mode -eq 'link') {
                New-Item -ItemType Junction -Path $dst -Target $src | Out-Null
            } else {
                Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
                Get-ChildItem -LiteralPath $dst -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force
                $commit = try { (git -C $repo rev-parse --short HEAD 2>$null) } catch { '' }
                [IO.File]::WriteAllText((Join-Path $dst $marker), "source=$src`ncommit=$commit`n", (New-Object Text.UTF8Encoding $false))
            }
            if (-not (Test-Path -LiteralPath (Join-Path $dst 'SKILL.md'))) { throw "SKILL.md not visible at $dst" }
            Log 'info' "installed_$Mode" $ctx
        } catch {
            Log 'error' 'install_failed' ([ordered]@{ agent = $root.agent; skill = $s.Name; error = $_.Exception.Message }); $failed++
        }
    }
}
$hint = if ($Uninstall) { 'Restart Codex / Claude Code sessions to drop the skills.' } else { 'Restart open Codex / Claude Code sessions, then check /skills (Codex: invoke $dreamscape-ddk-re explicitly; Claude: /dreamscape-ddk-re).' }
Write-Host $hint
Log ($(if ($failed) { 'error' } else { 'info' })) 'done' ([ordered]@{ failed = $failed; log = $logPath })
exit $(if ($failed) { 1 } else { 0 })
