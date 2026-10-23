# Environment: doctor, provisioning, official installer

What a machine needs before a DDK project opens and builds, the two ways to get there, and the vendor
installer's traps. Tags: **V** verified by running on the evidence machine, **O** observed in vendor code, **I**
inferred. IDs index the evidence notes: F- in `05-lead-findings.md`, IR- in `20-installer-and-registry.md`, TB- in
`10-templates-and-build.md`. On the evidence machine the notes live in `<re>\notes\`
and `<re>` is the output folder of the `dreamscape-ddk-re` skill (SKILL.md, Evidence base); rebuild it with that skill when it is missing.

## 1. Doctor (run first)

1. Run `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ddk-doctor.ps1 [-TarballDir <dir>] [-TemplateDir <dir>] [-UnityVersion 6000.3.2f1] [-Changeset a9779f353c9b] [-Json] [-LogFile <path.jsonl>]` (JSONL default `%TEMP%\ddk-doctor.jsonl`).
   `-TarballDir` defaults to the installer's `%ProgramData%\Dreamscape Developer Kit\Package Cache`; on a
   route-A machine pass the extracted tarball folder (step 3 of route A).
   Done = `RESULT: ready` and exit 0 (V: `-TarballDir <re>\extract\...\Package Cache` -> ready; the default
   fails `ddk-tarballs` here because nothing is installed under ProgramData). Exit 1 = a required check failed;
   each FAIL or WARN prints a `fix:` line.

   | Check | Gate | What it tests |
   |---|---|---|
   | `unity-cli` | warn | `%LOCALAPPDATA%\Unity\bin\unity.exe`, else `<ProgramFiles>\Unity Hub\resources[\cli]\unity.exe` |
   | `unity-editor` | required | `%ProgramFiles%\Unity\Hub\Editor\<ver>\Editor\Unity.exe` exists. An editor elsewhere fails here; build with `run-ddk-build.ps1 -Unity <exe>` |
   | `module:<id>` | required: `windows-il2cpp`, `windows-server`; warn: `android`, `android-sdk-ndk-tools`, `android-open-jdk-17.0.9+9` | `selected` entries of `<editor root>\modules.json`. The warn-only Android modules are required for `-Step Android` |
   | `unity-license` | required | `unity license list --json` lists Unity Personal, Pro, Plus, Industry or Enterprise (V: `Unity Personal`) |
   | `msvc-toolchain` | required | `vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64` finds an instance |
   | `windows-sdk-22621` | warn | `Windows Kits\10\Lib\10.0.22621.0` |
   | `ddk-tarballs` | required | at least 55 `com.dreamscape-learn.*.tgz` in `-TarballDir` |
   | `ddk-templates` | warn | `template.*.tgz` in `-TemplateDir` (default `%ProgramData%\Dreamscape Developer Kit\Unity Templates`); on route A pass the extracted `Unity Templates` folder |
   | `python` | warn | `python` on PATH; the Store stub also passes (step 2.3 catches it) |
   | `verdaccio-4873` | warn | a listener on 4873: a WARN is correct for route A |
   | `long-paths` | warn | `LongPathsEnabled=1` (V: 1 here) |
   | `empty-env-vars` | warn | empty-valued variables in the doctor's own environment (F-29) |
   | `disk-free` | warn | 30 GB free on the drive of the current directory |

2. Run the checks the doctor skips. Set `$u = "$env:LOCALAPPDATA\Unity\bin\unity.exe"` (the standalone Unity CLI;
   V: `1.0.0-beta.13`).
   1. **Sign-in** `& $u auth status --json`. Pass: `success: true`, `data.loggedIn: true` (V). On fail, hand the
      user `unity auth login` and `unity license activate`: the user signs in and the agent enters no
      credentials. CLI exit 3 = authentication failure, 4 = precondition not met, e.g. no active license.
   2. **Editor as the CLI sees it** `& $u editors --installed --json`. Pass: an item with `version: 6000.3.2f1`
      whose `modules` reads `Android, Android SDK & NDK Tools, OpenJDK, Windows, Windows Server` (V). Set
      `$UnityExe` to its `location` (V: `C:\Program Files\Unity\Hub\Editor\6000.3.2f1\Editor\Unity.exe`). This
      also catches a module the installer skipped silently (IR-18).
   3. **Real Python** `(Get-Command python).Source; python --version`. Pass: Python 3 at a path outside
      `WindowsApps`; the Store alias stub breaks Dev Deploy and the CMS content server (TB-23). V: 3.13.13.
   4. **Registry route** (once a project exists) Route A project: `Select-String -Path <proj>\Packages\manifest.json -Pattern scopedRegistries`
      prints nothing, so Node and Verdaccio are irrelevant. Route B project: the section 4 health check prints
      `ping OK` and no `MISSING` line. V here: no `VerdaccioStartup` task and 4873 free, so route A only.
   5. **Unity registry** `Test-NetConnection packages.unity.com -Port 443`. Pass: `TcpTestSucceeded True` (V), or a
      warm `Library\PackageCache` from an earlier open: every `com.unity.*` package, including the experimental
      `com.unity.graphtoolkit 0.4.0-exp.2`, comes from there on a cold open (TB-26).
   6. **Paths** Project at `C:\p\<short>`, builds at `C:\b\<short>`: the 260-char limit bites in deep
      `SDK\bin\Hostess\...` paths (TB-44).
   7. **Disk** per project (V, multiplayer template after client, server and Android builds): `Library` 23.5 GiB,
      `DDK-Tarballs` 893 MiB, about 2.4 GiB per Windows player (2096 MiB of it the IL2CPP backup folder), `SDK\`
      442 MiB, APK 154 MiB: the doctor's 30 GB `disk-free` bar is roughly one project.

Done = doctor `RESULT: ready` and all seven checks pass. Then build.md.

## 2. Route A: Unity CLI + `file:` tarballs (default)

No admin rights for the project, no Node, no Verdaccio, no installer. Verified end to end (F-23, F-27, F-28, F-30).

1. **Editor.** When doctor `unity-editor` fails, run detached (multi-GB download):
   ```powershell
   & $u install 6000.3.2f1 --changeset a9779f353c9b --architecture x86_64 --module windows-il2cpp `
     --module windows-server --module android --module android-sdk-ndk-tools `
     --module android-open-jdk-17.0.9+9 --accept-eula --yes --json
   ```
   V: it pulls NDK r27c, CMake 3.22.1, SDK build-tools and platform-tools 36.0.0, platforms 34-36 and
   cmdline-tools 16.0 in as dependencies of `android-sdk-ndk-tools`. Done = JSON `success: true`, every item
   `status: installed`, and the section 1 check 2.2 passes. When only a `module:` check fails, add it with
   `& $u install-modules --editor-version 6000.3.2f1 --module <id> --accept-eula` (the doctor's fix line; flag V from `install-modules --help`, install I).
   - The JDK module id is `android-open-jdk-17.0.9+9`; the bare `android-open-jdk` does not exist (V, F-02).
   - `--resume` only resumes a paused download: on a fresh machine it returns success with
     `no_paused_downloads` and installs nothing (V, F-03). Run the plain `install` line.
2. **Build Tools.** When doctor `msvc-toolchain` fails, install VS 2022 Build Tools with the C++ workload (admin, I):
   ```powershell
   winget install --id Microsoft.VisualStudio.2022.BuildTools --accept-package-agreements --accept-source-agreements `
     --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended"
   ```
   Done = `& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationVersion`
   prints a `17.*` line. Without `-products *` vswhere hides Build Tools and prints nothing (V, F-25). V: Build
   Tools 17.14 (MSVC 14.44.35207, Win SDK 10.0.22621) builds IL2CPP client, server and Android. The VS IDE and the
   ManagedGame workload that the vendor script insists on are unnecessary.
3. **Tarballs and template.**
   - Installed machine: `%ProgramData%\Dreamscape Developer Kit\Package Cache\` (55 tgz, 893 MiB) and
     `%ProgramData%\Dreamscape Developer Kit\Unity Templates\template.4e8dc889093d8ee2.tgz` (multiplayer 1.5.5)
     or `template.5c79b07d09de3c1b.tgz` (single player 1.4.5).
   - Otherwise extract the bundle with the `dreamscape-ddk-re` skill. Tarballs land in
     `<re>\extract\msi\Dreamscape Developer Kit Unity Packages\SourceDir\CommApp\Dreamscape Developer Kit\Package Cache\`,
     templates in `<re>\extract\msi\com_dreamscape_learn_template_dreamscape_<multiplayer_1_5_5|single_player_1_4_5>\SourceDir\CommApp\Dreamscape Developer Kit\Unity Templates\` (V: all 55 and both templates here).
   - Done = `(Get-ChildItem <dir> -Filter 'com.dreamscape-learn.*.tgz').Count` prints 55.
4. **Generate the project.**
   `python -I scripts/make_filedeps_project.py --template <template .tgz or unpacked dir> --cache <tarball dir> --project C:\p\<name>`
   - Exit 0 ok; 1 project folder already exists (`project_exists`), no tarballs, or no `ProjectData~` in the
     template; 2 missing tarballs. JSONL log: `<project parent>\make_filedeps_project.jsonl`.
   - Done = event `closure` with `size: 55` (48 direct + 7 transitive: level-management-system, naming,
     subtitle-support, dream-api and the dream-station, hostess and vicon-routing-server artifacts) and
     `manifest_rewritten` with `file_deps: 55`, `removed_scoped_registries: 5`, `lock_removed: true`.
     V: multiplayer from the unpacked template (F-23); single player straight from its `.tgz` (exit 0 in 11 s).
   - Result: every DDK dependency is `file:../DDK-Tarballs/<tgz>`, so the folder is portable. Keep
     `DDK-Tarballs\` with the project in private storage (git LFS on a private remote, or a shared absolute
     `file:` path). It is vendor content, and 29 of its `package.json` files embed a vendor CI job token in
     `repository.url` (TB-41): it belongs in no public repository.
   - Version drift (F-21, O): 107 sibling `com.dreamscape-learn.*` pins are older than the shipped tarballs, and UPM
     lifts them to the shipped version, so packages run against siblings newer than they were built for. Unity-registry
     pins also conflict: addressables 2.7.2/2.7.6, burst 1.8.27/1.8.28, inputsystem 1.17.0/1.19.0, URP 17.1.0/17.3.0,
     timeline 1.8.11/1.8.12 and XRI 3.1.2/3.3.1/3.3.2, and UPM takes the highest. The verified builds use exactly that
     resolution (V: 0 `error CS`). Keep the resolved `packages-lock.json` and diff it after any package change.
5. **First open** (import + compile), detached:
   `& $UnityExe -batchmode -nographics -quit -projectPath C:\p\<name> -logFile C:\p\logs\<name>-first-open.log`
   - V timings: UPM resolve 131 s, script compile 101 s, initial refresh 694 s (about 12 min, 9607 imports).
   - Done = `Done resolving packages`, zero `error CS`, and the log ends with `Exiting batchmode successfully now!`
     and `return code 0` (V, F-23).
   - Expected changes (V): UPM writes a new `Packages\packages-lock.json` and adds `com.unity.purchasing@4.14.0`
     (deprecated IAP 4) to the manifest. Commit both, or strip the package for headset builds (build.md section 2).
   - Expected noise, non-blocking (V, F-24): `26 packages have invalid signatures`; `immutable packages were
     unexpectedly altered` (Input System regenerates `DreamConsoleActions.cs` inside dream-console); Rig Errors
     on `SK_Basemesh_Male_rig 1.fbx`, `SK_Basemesh_Female_rig_1.fbx` and `SK_Basemesh_M_Body_001@Sitting_Idle.fbx`
     (in avatar-assets and in the XR Avatar Calibration sample).
   - Interactive opens start on an untitled scene: open `Assets/Application/Application.unity` (TB-47).
6. Continue with build.md (personalise, compile gate, players).

A per-user Verdaccio seeded straight into storage keeps registry manifests without the installer: recipe R-B
in `20-installer-and-registry.md` (I).

## 3. Route B: official installer (`dreamscape-developer-kit-1.1.9788.20016.exe`)

Use it when the user wants the vendor's machine state. The installer was never run here: its behaviour is O or
I; the machine-state facts marked V were read on the evidence machine.

1. **Pre-flight**, each a known rollback or hang:
   - npmjs reachable: `npm view verdaccio@6 version` prints a version (IR-01).
   - 4873 free and outside `netsh int ipv4 show excludedportrange protocol=tcp` (IR-07).
   - Unity, Hub, VS and every adb client closed (IR-17; VS in use = exit 8006).
   - Hub >= 3.22.2 with `<Hub>\resources\unity.exe` or `<Hub>\resources\cli\unity.exe`: the orchestrator looks
     for the CLI only there, never at the standalone CLI (F-01). Burn's Hub gate reads only
     `%ProgramFiles%\Unity Hub\Unity Hub.exe`, so a Hub elsewhere re-runs the Hub step, which the orchestrator then
     skips on version (O). V here: Hub 3.22.4 at a non-default path, with `resources\unity.exe`.
   - Editor at a default Hub path (IR-15). A same-version editor that `<Hub CLI> editors --installed` does not
     list is a hard `UserActionRequired` failure (F-05); a listed one is logged "already installed" and skipped
     (O). V here: the Hub's bundled CLI (1.0.0-beta.13) lists the 6000.3.2f1 that the standalone CLI installed.
   - WebView2 present (IR-24); 52 GiB free on the install drive and 5 GiB on TEMP (IR-31).
2. **Run** from the developer's own elevated shell (IR-22):
   `& <bundle.exe> /quiet /log "$env:TEMP\DreamscapeDeveloperKit\Installer_$(Get-Date -f yyyyMMddHHmmss).log"`.
   `/quiet` skips EULA, disk and preflight UI. Keep the `Installer_<yyyyMMddHHmmss>.log` name so orchestrator
   logs group into `Installer_<ver>_<ts>\` (F-07).
3. **Verify.** Exit 0 proves nothing: every Verdaccio stage exits 0 on failure (IR-02). Done = the section 4
   health check and the doctor both pass. On any fail, read `Installer_<ver>_<ts>\orchestrator_install_*.log` for
   the package that broke.

### What the bundle does (O)

- `WorkspaceOrchestrator.exe` (`C:\Program Files\Dreamscape Developer Kit\Orchestrator\`) does the real work. Burn
  runs it directly for the Hub and VS steps; every MSI runs it from an immediate custom action after
  `InstallFinalize`, as the elevating user, so MSI rollback never undoes a step's side effects.
- Chain: VC++ 2010 x64; Unity Hub `/S` when below 3.22.2; editor 6000.3.2f1 + 6 modules (the 5 above plus
  documentation) via `Unity Hub.exe -- --headless install[-modules]` (F-04); VS 2022 Community with ManagedGame +
  NativeDesktop + VC tools + SDK 22621 on every install and repair (IR-12); Experience Launcher; Node 24.12.0
  (hidden from Apps & Features; upgrades Node <= 24.12.0, skips newer, IR-33); 55 tgz into the Package Cache;
  Verdaccio; both templates; the docs app.
- Logs: `%LOCALAPPDATA%\Temp\DreamscapeDeveloperKit\Installer_<ver>_<ts>\` holds `orchestrator_install_*.log`,
  `orchestrator-1.1.9788.20018-<date>.log`, `StateSnapshots\`, `UnityHubLogs\`, `VisualStudioLogs\` (F-07).

## 4. Verdaccio (O)

- `http://127.0.0.1:4873`, IPv4 loopback only: write `127.0.0.1` in every URL. Templates hardcode it in 5
  scopedRegistries; the port never drifts, it only conflicts (F-20).
- Reads are anonymous (`access: $all`), so UPM needs no `.upmconfig.toml`. `uplinks: {}`: `com.unity.*` still
  comes from packages.unity.com.
- Started by the SYSTEM scheduled task `VerdaccioStartup`: AtStartup trigger only, restart 999 x 1 min, action
  `VerdaccioTaskRunner.ps1 -NodeExe <absolute node.exe> ... -Port 4873` -> `node verdaccio --listen 127.0.0.1:4873`.
- Seeding runs on every task start over every `*.tgz` under `%ProgramData%\Dreamscape Developer Kit\Package Cache`
  (recursive). Tarballs over 300 MB (only avatar-assets, 490.8 MiB) go straight into storage via
  `Add-StorageVersion.js`. The rest are extracted, get `publishConfig.registry` rewritten (saved with a UTF-8
  BOM) and are `npm publish`ed by bot user `registry-bot`, so served bytes differ from the shipped tgz (IR-19).
  Result: `C:\ProgramData\Verdaccio\seed-status.json`.
- Files: `C:\ProgramData\Verdaccio\{Scripts,config,app,storage,plugins,logs,Profile}`. `Profile\` holds the bot
  token and a plaintext bot password (IR-29): keep both out of logs and chat.
- Logs: `logs\verdaccio-task.log`, `verdaccio-lastrun.log`, `verdaccio-crash-*.log`; live output in SYSTEM TEMP
  `verdaccio_*_out.log` (IR-30). Task `LastTaskResult`: 2 node.exe missing, 3 verdaccio missing, 4 config
  missing, 5 Start-Process failed.

Health check (read-only). Pass = `ping OK`, `LastTaskResult` 0, a `127.0.0.1` listener, a seed status without
failures, and no `MISSING` line:

```powershell
$r='http://127.0.0.1:4873'
try { Invoke-RestMethod "$r/-/ping" -TimeoutSec 3 | Out-Null; 'ping OK' } catch { 'ping FAIL' }
Get-ScheduledTask VerdaccioStartup -EA SilentlyContinue | Get-ScheduledTaskInfo | Select LastRunTime,LastTaskResult
Get-NetTCPConnection -LocalPort 4873 -State Listen -EA SilentlyContinue | Select LocalAddress,OwningProcess
Get-Content "$env:ProgramData\Verdaccio\seed-status.json" -EA SilentlyContinue
Get-ChildItem "$env:ProgramData\Dreamscape Developer Kit\Package Cache\*.tgz" | % {
  if ($_.Name -match '^(.+)-(\d+\.\d+\.\d+.*)\.tgz$') { $n=$matches[1]; $v=$matches[2]
    try { $p = Invoke-RestMethod "$r/$n" -TimeoutSec 5; if (-not $p.versions.$v) { "MISSING $n@$v" } } catch { "MISSING $n" } } }
```

## 5. Repair (admin; confirm each with the user)

Scripts live in `C:\ProgramData\Verdaccio\Scripts\`; run each as
`powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File <script>` (Windows PowerShell 5.1).
Each fix is done when the health check passes.

| Symptom | Fix |
|---|---|
| `ping FAIL` after boot, crash or Fast Startup (IR-06) | `Start-ScheduledTask VerdaccioStartup`, wait 60 s, re-check |
| `LastTaskResult` 2, Node upgraded or moved (IR-08) | `2-Create-VerdaccioScheduledTask.ps1 -ForceRecreate` |
| `LastTaskResult` 3 | `1-Install-Verdaccio.ps1` (needs npmjs), then `2-Create-VerdaccioScheduledTask.ps1` |
| `E401` / `ENEEDAUTH` / `E409` in task log or seed-status (IR-04) | Delete `Profile\.npmrc`, keep `details.md`, run `3-ConfigureProfile.ps1` |
| `MISSING` lines, corrupt storage | Stop the task; kill `node` whose command line contains `Verdaccio\app\node_modules`; rename `storage` to `storage.bad-<ts>`; per tgz run `node Add-StorageVersion.js <tgz> <extracted package.json> C:\ProgramData\Verdaccio\storage http://127.0.0.1:4873`, then `node Add-StorageVersion.js --list-only <storage>`; start the task |
| 4873 held by another process (IR-07) | Stop that process (with approval). Moving the port means the task's `-Port`, `-RegistryUrl` for scripts 3, 4 and Reseed, and all 5 scopedRegistries in every manifest |
| Anything else | Burn repair (I path): `& "C:\ProgramData\Package Cache\{5FDE33E2-275B-4321-B2F6-821C6669CEED}\dreamscape-developer-kit-1.1.9788.20016.exe" /repair /passive /log <Installer_ts.log>` |

The fastest repair for a build is leaving the registry: convert the project to route A. Rewrite each
`com.dreamscape-learn.*` dependency to `file:<tgz>`, add the 7 transitive ones (route A step 4), drop
`scopedRegistries`, delete `packages-lock.json` (TB-28). `make_filedeps_project.py` does exactly this for a fresh
template.

## 6. Clean uninstall (destructive; confirm each step)

1. Back up `C:\ProgramData\Verdaccio\storage` when anything was published locally (IR-26); convert projects that
   must keep working to route A.
2. `<cached bundle> /uninstall /passive /log <Installer_ts.log>`. The Apps & Features entry is "Dreamscape
   Developer Kit Installer", not the docs' "Dreamscape Learn Setup" (IR-09).
3. Verify: `Get-ScheduledTask VerdaccioStartup` is gone, else `Unregister-ScheduledTask VerdaccioStartup
   -Confirm:$false` (IR-05); 4873 free; `C:\ProgramData\Verdaccio` gone or only empty dirs.
4. Hidden MSIs (`SystemComponent=1`) under `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*` whose
   DisplayName starts with "Dreamscape", "Verdaccio" or "Node.js": `msiexec /x {ProductCode} /qn` each, Workspace
   Orchestrator Setup `{3749C16A-56CF-F7C6-CDD8-E0F3132EEF6C}` last (the others' uninstall actions call it).
5. Leftovers to delete: `C:\ProgramData\Dreamscape Developer Kit\{Package Cache,Package Cache Backup,Unity
   Templates}` (old tgz there keep getting seeded, IR-27); `C:\Program Files\Dreamscape Developer Kit\`; both
   template tgz in the editor's `ProjectTemplates`; `HKCU\Software\dreamscapelearn`; Desktop and Start Menu
   `Dreamscape Learn` shortcuts; `%LOCALAPPDATA%\Temp\DreamscapeDeveloperKit\`; SYSTEM TEMP `verdaccio_*`.
6. Kept by the bundle, decide with the user: editor + modules, Unity Hub, VS 2022, VC++ 2010, WebView2. Node goes
   only when the bundle installed it (`node --version`). The uninstalling user's npm cache is wiped (IR-25).

Done = every step 3 check passes and no step 4 entry remains.

## 7. Templates in Unity Hub

- Copy `template.4e8dc889093d8ee2.tgz` (MP) and `template.5c79b07d09de3c1b.tgz` (SP) into
  `<Editor>\Data\Resources\PackageManager\ProjectTemplates\` (admin). This is all the installer does (F-06).
  V here: that folder holds only the 3 stock Unity templates.
- Hub-created projects keep the 5 scopedRegistries: they need Verdaccio, or conversion to route A.
- An editor reinstall or repair drops them (IR-16): copy again.
- Whether Hub lists templates for an editor it did not install, and whether `-cloneFromTemplate` accepts the
  DDK tgz, are unknown. Headless work uses route A step 4.

## 8. Installer defects, ranked by impact

| # | ID | Symptom | Workaround |
|---|---|---|---|
| 1 | IR-01 | Offline: `npm install verdaccio@6` fails and the WHOLE bundle rolls back | Reachable npm registry; or pre-stage `C:\ProgramData\Verdaccio\app\node_modules\verdaccio` (the script then skips npm); or route A |
| 2 | IR-02 | "Installed successfully" with a dead or empty registry | Health check after every install and repair |
| 3 | F-01, F-05, IR-15 | Editor step fails: CLI expected inside Hub, same-version editor unknown to Hub's CLI, custom editor folder | Hub >= 3.22.2, editor at the default Hub path; or route A |
| 4 | IR-07 | Installer kills whatever listens on 4873; any HTTP server there passes as "Verdaccio" | Free 4873 first |
| 5 | IR-03 | Non-English Windows: mutex ACL by account name throws, bundle rolls back (I) | Patch a copy of `3-ConfigureProfile.ps1` to `SecurityIdentifier 'S-1-5-11'`; or route A |
| 6 | IR-12 | Every install or repair updates, repairs and modifies VS 2022; VS 2026 users get 2022 beside it | Route A + Build Tools |
| 7 | IR-11 | Hang: scripts run without timeouts; the npm adduser driver can deadlock (I) | Kill the `npm`/`powershell` children, read `orchestrator_install_*.log`, replay scripts 0-4 by hand |
| 8 | IR-06, IR-08 | Registry down after Fast Startup, a crash, or a Node change | `Start-ScheduledTask VerdaccioStartup`; `-ForceRecreate` |
| 9 | IR-17 | adb killed mid-session; editor files in use | Close Unity and adb clients first |
| 10 | IR-22 | Over-the-shoulder elevation: Hub editor records, npm cache and docs HKCU keys land in the admin's account (I) | Run from the developer's own elevated shell |
| 11 | IR-04 | Re-running the profile script crashes on any npm stderr line (PS 5.1) | Delete `Profile\.npmrc`, keep `details.md`, re-run |
| 12 | IR-05 | Uninstall leaves the SYSTEM task pointing at deleted scripts | `Unregister-ScheduledTask VerdaccioStartup -Confirm:$false` |
| 13 | IR-10, IR-26, IR-25 | Uninstall (even a rolled-back one) wipes registry storage and the npm cache | Back up `storage` first |
| 14 | IR-33 | A machine Node <= 24.12.0 is upgraded in place; removal on uninstall is unknown | Route A on machines with their own Node |
| 15 | IR-09 | Uninstall leaves editor, Hub, VS, VC++; docs claim otherwise | Clean-uninstall checklist |
| 16 | IR-28 | Multi-user: Users can write where the SYSTEM task loads code (I) | Single-user machines, or route A |
| 17 | IR-19, IR-20 | Re-packed tarballs (BOM), vendor CI tokens republished, dist-tag `old` | Route A uses the original bytes |
