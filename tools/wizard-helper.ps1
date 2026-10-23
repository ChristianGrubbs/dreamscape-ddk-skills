# Windows-side helper for setup-wizard.sh (Windows PowerShell 5.1+). One subcommand per call.
# Value subcommands print exactly one line on stdout (empty line = not found); action subcommands stream output.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File wizard-helper.ps1 <command> [args...]
# Log: %TEMP%\dreamscape-ddk-wizard.jsonl
param([Parameter(Position = 0, Mandatory)] [string] $Command, [Parameter(ValueFromRemainingArguments)] [string[]] $Rest)
$ErrorActionPreference = 'Continue'
$env:UNITY_NO_BANNER = '1'; $env:UNITY_NO_PAGER = '1'
$repo = Split-Path $PSScriptRoot -Parent
$log = Join-Path $env:TEMP 'dreamscape-ddk-wizard.jsonl'
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)
function Log($level, $evt, $ctx) {
    $line = ([ordered]@{ ts = (Get-Date).ToString('o'); run_id = $runId; level = $level; event = $evt; loc = 'wizard-helper.ps1'; ctx = $ctx } | ConvertTo-Json -Compress -Depth 4)
    try { [IO.File]::AppendAllText($log, $line + "`n", (New-Object Text.UTF8Encoding $false)) } catch { }
}
# Tools installed earlier in this wizard run (winget, dotnet tool) are on the registry PATH, not yet on this process's.
function Update-ToolPath { $env:Path = (@([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User'), "$env:USERPROFILE\.dotnet\tools", $env:Path) | Where-Object { $_ }) -join ';' }
Update-ToolPath
function Arg($i) { if ($Rest -and $Rest.Count -gt $i) { $Rest[$i] } else { '' } }
function CliJson($cli, [string[]] $cliArgs) { $env:UNITY_NON_INTERACTIVE = '1'; try { (& $cli @cliArgs --json 2>$null | Out-String | ConvertFrom-Json) } catch { $null } finally { $env:UNITY_NON_INTERACTIVE = $null } }
$requiredModules = 'windows-il2cpp', 'windows-server', 'android', 'android-sdk-ndk-tools', 'android-open-jdk-17.0.9+9'
$out = ''
switch ($Command) {
    'unity-cli' {
        $c = @("$env:LOCALAPPDATA\Unity\bin\unity.exe", "$env:ProgramFiles\Unity Hub\resources\cli\unity.exe", "$env:ProgramFiles\Unity Hub\resources\unity.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        $out = "$c"
    }
    'install-unity-cli' {
        # Unity's documented installer for the standalone Unity CLI (lands in %LOCALAPPDATA%\Unity\bin).
        Invoke-RestMethod https://unity.com/install.ps1 | Invoke-Expression
        Log 'info' 'install_unity_cli' @{ exists = (Test-Path -LiteralPath "$env:LOCALAPPDATA\Unity\bin\unity.exe") }
        return
    }
    'auth-ok' { $j = CliJson (Arg 0) @('auth', 'status'); $out = $(if ($j -and $j.data.loggedIn) { 'yes' } else { 'no' }) }
    'auth-login' {
        # Opens the browser; the human signs in with their Unity ID. Credentials stay in the Unity CLI's keyring.
        & (Arg 0) auth login
        $code = $LASTEXITCODE; Log 'info' 'auth_login' @{ exit = $code }; exit $code
    }
    'license-activate' {
        # personal: the human accepted the Unity Personal terms in the wizard. serial: read from DDK_UNITY_SERIAL, never logged.
        # The Unity CLI only takes a serial as an argument, so it is briefly visible to local process listings.
        if ((Arg 1) -eq 'serial') {
            $serial = $env:DDK_UNITY_SERIAL; $env:DDK_UNITY_SERIAL = $null
            if (-not $serial) { [Console]::Error.WriteLine('DDK_UNITY_SERIAL is empty'); exit 2 }
            & (Arg 0) license activate --serial $serial
        } else {
            & (Arg 0) license activate --personal --accept-eula
        }
        $code = $LASTEXITCODE; Log 'info' 'license_activate' @{ kind = (Arg 1); exit = $code }; exit $code
    }
    'install-editor' {
        # The verified route-A line (environment.md section 2): version, changeset, then one --module per module.
        $cli = Arg 0; $ver = Arg 1; $cs = Arg 2
        $modArgs = @($Rest | Select-Object -Skip 3 | ForEach-Object { '--module', $_ })
        & $cli install $ver --changeset $cs --architecture x86_64 @modArgs --accept-eula --yes
        $code = $LASTEXITCODE; Log 'info' 'install_editor' @{ version = $ver; modules = ($Rest | Select-Object -Skip 3) -join ' '; exit = $code }; exit $code
    }
    'install-modules' {
        $cli = Arg 0; $ver = Arg 1
        $modArgs = @($Rest | Select-Object -Skip 2 | ForEach-Object { '--module', $_ })
        & $cli install-modules --editor-version $ver @modArgs --accept-eula --yes
        $code = $LASTEXITCODE; Log 'info' 'install_modules' @{ version = $ver; modules = ($Rest | Select-Object -Skip 2) -join ' '; exit = $code }; exit $code
    }
    'license-ok' {
        $j = CliJson (Arg 0) @('license', 'list')
        $names = @($j.data | ForEach-Object { $_.product }) -join ', '
        $out = $(if ($names -match 'Unity (Personal|Pro|Plus|Industry|Enterprise)') { 'yes' } else { 'no' })
    }
    'editor-exe' {
        $j = CliJson (Arg 0) @('editors', '--installed')
        $out = "$(@($j.data | Where-Object { $_.version -eq (Arg 1) } | Select-Object -First 1).location)"
    }
    'missing-modules' {
        $root = Split-Path (Split-Path (Arg 0) -Parent) -Parent
        $have = @()
        if (Test-Path -LiteralPath "$root\modules.json") {
            try { $have = (Get-Content -LiteralPath "$root\modules.json" -Raw | ConvertFrom-Json) | Where-Object { $_.selected -or $_.isInstalled } | ForEach-Object { $_.id } } catch { }
        }
        $out = (@($requiredModules | Where-Object { $_ -notin $have }) -join ' ')
    }
    'vc-path' {
        $vw = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        if (Test-Path -LiteralPath $vw) { $out = "$(& $vw -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1)" }
    }
    'buildtools-path' {
        # Any VS 2022 Build Tools instance, even one missing the C++ workload (winget then reports "already installed").
        $vw = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        if (Test-Path -LiteralPath $vw) { $out = "$(& $vw -latest -products Microsoft.VisualStudio.Product.BuildTools -property installationPath 2>$null | Select-Object -First 1)" }
    }
    'install-buildtools' {
        winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended"
        $code = $LASTEXITCODE; Log 'info' 'install_buildtools' @{ exit = $code }; exit $code
    }
    'modify-buildtools' {
        # Adds the C++ workload to an existing Build Tools instance through the VS Installer CLI (UAC prompt).
        $setup = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe"
        & $setup modify --installPath (Arg 0) --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended --passive --norestart
        $code = $LASTEXITCODE; Log 'info' 'modify_buildtools' @{ exit = $code; path = (Arg 0) }; exit $code
    }
    'python-ok' {
        $p = Get-Command python -ErrorAction SilentlyContinue
        $ok = $p -and ($p.Source -notlike '*\WindowsApps\*') -and ((& python --version 2>&1 | Out-String) -match 'Python 3\.(1[2-9]|[2-9]\d)')
        $out = $(if ($ok) { 'yes' } else { 'no' })
    }
    'install-python' {
        winget install --id Python.Python.3.12 --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements
        $code = $LASTEXITCODE; Log 'info' 'install_python' @{ exit = $code }; exit $code
    }
    'count-tgz' { $out = "$(@(Get-ChildItem -LiteralPath (Arg 0) -Filter 'com.dreamscape-learn.*.tgz' -ErrorAction SilentlyContinue).Count)" }
    'count-templates' { $out = "$(@(Get-ChildItem -LiteralPath (Arg 0) -Filter 'template.*.tgz' -ErrorAction SilentlyContinue).Count)" }
    'ddk-default' {
        $t = "$env:ProgramData\Dreamscape Developer Kit\Package Cache"; $m = "$env:ProgramData\Dreamscape Developer Kit\Unity Templates"
        $n = @(Get-ChildItem -LiteralPath $t -Filter 'com.dreamscape-learn.*.tgz' -ErrorAction SilentlyContinue).Count
        $out = $(if ($n -ge 55) { "$t|$m" } else { '' })
    }
    'extract-tools-missing' {
        $miss = @()
        if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { $miss += 'dotnet' }
        if (-not ((Test-Path -LiteralPath "$env:USERPROFILE\.dotnet\tools\wix.exe") -or (Get-Command wix -ErrorAction SilentlyContinue))) { $miss += 'wix' }
        if (-not ((Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter lessmsi.exe -ErrorAction SilentlyContinue | Select-Object -First 1) -or (Get-Command lessmsi -ErrorAction SilentlyContinue))) { $miss += 'lessmsi' }
        $out = ($miss -join ' ')
    }
    'install-extract-tools' {
        foreach ($t in $Rest) {
            switch ($t) {
                'dotnet'  { winget install --id Microsoft.DotNet.SDK.8 --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements }
                'wix'     { & dotnet tool install --global wix --version 6.0.2 --add-source https://api.nuget.org/v3/index.json }
                'lessmsi' { winget install --id activescott.lessmsi --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements }
            }
            Log 'info' 'install_tool' @{ tool = $t; exit = $LASTEXITCODE }
            Update-ToolPath
        }
        return
    }
    'extract-installer' {
        $exe = Arg 0; $dest = Arg 1
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'skills\dreamscape-ddk-re\scripts\ddk-extract.ps1') -Bundle $exe -Out $dest -Stages 'bundle,msi'
        $tar = Join-Path $dest 'extract\msi\Dreamscape Developer Kit Unity Packages\SourceDir\CommApp\Dreamscape Developer Kit\Package Cache'
        $tpl = Join-Path $dest 'templates'
        New-Item -ItemType Directory -Force -Path $tpl | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $dest 'extract\msi') -Recurse -Filter 'template.*.tgz' -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $tpl -Force }
        Log 'info' 'extract_installer' @{ tarballs = $tar; templates = $tpl }
        Write-Output "RESULT|$tar|$tpl"
        return
    }
    'install-skills' { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') @Rest; exit $LASTEXITCODE }
    'doctor' { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'skills\dreamscape-ddk\scripts\ddk-doctor.ps1') @Rest; exit $LASTEXITCODE }
    'profile-dir' { $out = "$env:USERPROFILE" }
    'local-dir' { $out = "$env:LOCALAPPDATA" }
    'temp-dir' { $out = "$env:TEMP" }
    'path-exists' { $out = $(if (Test-Path -LiteralPath (Arg 0)) { 'yes' } else { 'no' }) }
    default { [Console]::Error.WriteLine("unknown command: $Command"); exit 2 }
}
Log 'info' $Command @{ args = ($Rest -join ' '); out = $out }
Write-Output $out
