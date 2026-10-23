# Copy the DDK agent build script and the optional test hook into a Unity project (idempotent: files are overwritten).
#   Assets/Editor/DDKAgentBuild/   editor-only build entry points (DDK.AgentBuild.DDKAgentBuild.*)
#   Assets/DDKAgentHooks/          runtime hook, compiled only when DDK_AGENT_HOOKS is defined for a build
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File install-agent-scripts.ps1 -Project <project dir> [-NoHooks]
# Exit: 0 installed (prints one JSON line), 1 not a Unity project or copy failed.
param(
    [Parameter(Mandatory)] [string] $Project,
    [switch] $NoHooks
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath (Join-Path $Project 'ProjectSettings\ProjectSettings.asset'))) { throw "Not a Unity project (no ProjectSettings\ProjectSettings.asset): $Project" }
$src = Join-Path $PSScriptRoot 'unity'
$sets = @(@{ from = 'DDKAgentBuild'; to = 'Assets\Editor\DDKAgentBuild' })
if (-not $NoHooks) { $sets += @{ from = 'DDKAgentHooks'; to = 'Assets\DDKAgentHooks' } }
$installed = @()
foreach ($s in $sets) {
    $dst = Join-Path $Project $s.to
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    # Pipeline input binds as LiteralPath, so brackets or parentheses in either path are safe.
    Get-ChildItem -LiteralPath (Join-Path $src $s.from) -File | Copy-Item -Destination $dst -Force
    $installed += @(Get-ChildItem -LiteralPath $dst -File | ForEach-Object { Join-Path $s.to $_.Name })
}
[pscustomobject]@{ project = $Project; installed = $installed; note = 'Unity compiles them on next open/batch run' } | ConvertTo-Json -Compress
