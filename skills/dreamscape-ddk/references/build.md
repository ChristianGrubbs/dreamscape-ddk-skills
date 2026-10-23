# Builds: personalise, compile gate, players, Dev Deploy

How to turn a DDK project into a Windows client, Windows server and Android player that pass every vendor
validator, and how to ship them to a pod. Tags: **V** verified by running on the evidence machine, **O** observed
in vendor code, **I** inferred. IDs index the evidence notes: TB- in `10-templates-and-build.md`, F- in
`05-lead-findings.md`, CA- in `40-core-architecture.md` (on the evidence machine under
`<re>\notes\`; its build runs are in `..\runtime\logs\builds.jsonl`). Machine
prerequisites: environment.md. User code asmdefs: architecture.md, "Set up author code".

## 1. Install the entry points (once per project)

1. `powershell -File scripts/install-agent-scripts.ps1 -Project <dir> [-NoHooks]` copies
   `scripts/unity/DDKAgentBuild/` to `<project>\Assets\Editor\DDKAgentBuild\` (editor-only asmdef `DDK.AgentBuild`,
   references `Unity.Addressables` + `Unity.Addressables.Editor`) and, unless `-NoHooks`,
   `scripts/unity/DDKAgentHooks/` to `<project>\Assets\DDKAgentHooks\`. It throws when
   `ProjectSettings\ProjectSettings.asset` is missing. Done = its JSON line lists the installed folders.
2. The hook's asmdef carries defineConstraint `DDK_AGENT_HOOKS`, so it compiles only into builds made with
   `-ExtraArgs -ddkAgentHooks` (V: `build_start` logs `"defines":"DDK_AGENT_HOOKS"`). Ship builds without it.

## 2. Personalise (editor closed, before the first build)

Edit `ProjectSettings/ProjectSettings.asset` as YAML. Template leftovers belong to shipped vendor products (O;
V: both templates read here):

| Key | Set to | Template MP / SP | Why |
|---|---|---|---|
| `productName` | keep `experience` | `experience` | Dev Deploy validates `experience.exe` and `experience_Data`; `DDKAgentBuild` hardcodes that file name, editor and profile builds default it from `productName` (I) |
| `companyName` | yours | `Dreamscape Learn` / `dreamscapelearn` | TB-24 |
| `bundleVersion` | `x.y.z` | `0.3.16` / `1.2.2` | names `SDK\version-<bundleVersion>.json` (V: `version-0.3.16.json`) and the Addressables player version |
| `applicationIdentifier` -> `Android` | `com.dreamscapelearn.<experience-id>` | `dev.dreamscapelearn.icstarterpack01` / `com.dreamscapelearn.hum_seti_r01` | it is the cart ExperienceId (prefix stripped); the template id collides on headsets (TB-06) |
| `applicationIdentifier` -> `Standalone` | same id | `com.Dreamscape-Learn.Acumen-Beta` (both) | TB-24 |
| `AndroidBundleVersionCode` | fresh integer, raised per upload | `46` / `3` | TB-06 |

Then:
1. `Assets/StreamingAssets/specialFiles/experience_config.xml`: set `ExperienceName` to a unique Dev Deploy id
   (templates `dsl-multiplayer-project-template` / `rtp-single-player-template`, TB-07). Single player: decide
   `ExperienceMode` (the SP template says `MultiPlayer`). Keep the file: no build recreates it (TB-20).
2. Delete `Assets/Editor/DevDeploy/` (MP only); clear the server in
   `Assets/Settings/Dreamscape Learn/DevDeploy/DevDeployData.foo` (TB-24).
3. Multiplayer Android: in `Assets/XR/XRGeneralSettingsPerBuildTarget.asset` set the `Android Settings` block's
   `m_InitManagerOnStart: 1` to `0` (TB-32; SP already ships 0).
4. Headset builds: remove `com.unity.ads` and `com.unity.purchasing` from `Packages/manifest.json`, plus
   `Assets/MobileDependencyResolver/` and (MP) the IAP leftover `Assets/Resources/BillingMode.json`. V: the stock APK
   carries `AD_ID`, `ACCESS_ADSERVICES_*` and `com.android.vending.BILLING` (F-30), and UPM adds
   `com.unity.purchasing@4.14.0` on first open (environment.md route A step 5; trigger unknown). O: no template
   script or asmdef and no DDK `package.json` references either package. The removal itself is I: re-run the
   compile gate afterwards (TB-46).
5. Play Mode config: project-root `EnvironmentVariables.json` (runtime-config.md).

Done = `Select-String -Path ProjectSettings\ProjectSettings.asset,Assets\StreamingAssets\specialFiles\experience_config.xml -Pattern 'icstarterpack01|hum_seti_r01|Acumen-Beta|project-template|single-player-template'`
prints nothing, `productName` still reads `experience`, and for headset builds
`Select-String Packages\manifest.json -Pattern 'com\.unity\.(ads|purchasing)'` prints nothing after the next open.

## 3. Run any step through the wrapper

`scripts/run-ddk-build.ps1 -Project <dir> -Step <Compile|WindowsClient|WindowsServer|WindowsSinglePlayer|Android|Profile> [-Out <root or .apk>] [-BuildProfile <asset path>] [-Tag <name>] [-ExtraArgs <unity args>] [-Unity <Unity.exe>]`

- `-Unity` defaults to `C:\Program Files\Unity\Hub\Editor\6000.3.2f1\Editor\Unity.exe`; pass the CLI's `location`
  when the editor lives elsewhere (environment.md section 1). `-Tag` defaults to `build`.
- It starts Unity hidden with `-batchmode -nographics -projectPath <p> -buildTarget <Win64|Android> -executeMethod
  DDK.AgentBuild.DDKAgentBuild.<Step> -logFile <log> [-ddkOut <Out>]`, waits for the Unity process only (Unity's
  leftover VBCSCompiler or adb server no longer block it, V), and appends `step_start` /
  `step_end` to `<project parent>\logs\builds.jsonl`; the Unity log is `<project parent>\logs\<Tag>-<Step>.log`
  (V). It passes no `-quit`: `DDKAgentBuild` exits Unity itself.
- It exits 2 before starting Unity when the project or `Unity.exe` is missing, or when a path value contains `"`. A
  trailing `\` before a closing quote (`-Out "C:\b\x\"`) swallows every later parameter, so the default Unity
  would run with the wrong arguments (V).
- It blocks for the whole build (6 to 20 min, V). Launch it detached and wait for its `step_end` record:
  ```powershell
  $s = '<skill>\scripts\run-ddk-build.ps1'   # Start-Process joins arguments unquoted: quote paths with spaces
  Start-Process powershell -WindowStyle Hidden -RedirectStandardOutput C:\p\logs\exp-client.out -ArgumentList `
    "-NoProfile -ExecutionPolicy Bypass -File `"$s`" -Project C:\p\exp -Step WindowsClient -Out C:\b\exp -Tag exp"
  ```
- The wrapper exits with Unity's exit code. The same code is in the last stdout line
  `STEP_DONE step=<s> exit=<n> seconds=<n> error_cs=<n> log=<path>` and in `step_end.ctx.exit`; `ctx.last_ci`
  holds the last `[DDK-CI]` line.
- `DDKAgentBuild` exit codes: 0 ok, 1 build failed, 2 bad arguments or wrong active target, 3 Addressables
  failed, 4 output missing (O). It logs JSON lines prefixed `[DDK-CI] `: `addressables_ok`, `build_start`,
  `build_result`, `exit`, `compile_ok` (V, F-34), plus `addressables_skipped` and, on `Profile`, `defines_ignored`
  (O). Grep them; the Unity log runs to
  20k+ lines.
- Extra Unity args (V, PS 5.1 binding test):
  - one value binds through `-File`: `-ExtraArgs -ddkAgentHooks`;
  - several values through `-File`: one comma list, `-ExtraArgs "-ddkAgentHooks,-ddkDefines,A;B"`; the wrapper
    splits it on commas (V).
- One Unity per project at a time; a second instance fails on the project lock (I).

**Every build step is done when** `step_end` shows `exit: 0` and `error_cs: 0`, the log has a `[DDK-CI]`
`build_result` line with `"result":"Succeeded"`, and that target's output checks in section 5 pass.

## 4. Compile gate

`-Step Compile` (no `-Out`). It compiles for Win64 only, so Android-only code first compiles in the Android build.
Done = `exit=0`, `error_cs=0`, and a `[DDK-CI]` `compile_ok` line with the active target and scene count. V (F-34):
57 s on an already-imported project, `"reason":"compiled"`. A compile failure leaves `DDKAgentBuild` unresolved, so
Unity exits 1 with `error CS` lines and `Scripts have compiler errors.` in the log (V). On a fresh project the first batchmode open is the
import gate (environment.md route A step 5, F-23).

## 5. Players

| Step | `-Out` | Output | V result |
|---|---|---|---|
| `WindowsClient` | `C:\b\<name>` | `Experience\Client\experience.exe` | 1180 s wall incl. Addressables 83 s, 0 errors, 11 warnings (F-27); hooked rebuilds into fresh roots 637 s and 358 s |
| `WindowsServer` | same root | `Experience\Server\experience.exe` | 351 s, 0 errors, 10 warnings (F-28) |
| `WindowsSinglePlayer` | `C:\b\<name>` | `Experience\experience.exe` (single-player layout) | not run (I) |
| `Android` | `C:\b\<name>-android\experience.apk` | that apk (a folder gets `\experience.apk` appended) | 866 s wall incl. platform switch (initial refresh 181 s) and Addressables 88 s, Gradle 8.13 / AGP 8.10.0, 0 errors, 12 warnings, apk 161.2 MB = 153.7 MiB (F-30) |

Build client and server into the same root: that is the multiplayer Dev Deploy layout, and it triggers SDK
assembly (V, F-27). Each switch between Win64 and Android re-imports for the new target (V: 181 s before the
Android build), so group builds by target. The single-player template has no server: its Server target is
unset, so it would build Mono (TB-35).

**Output checks** (V: run on the multiplayer builds here):

```powershell
$root = 'C:\b\<name>'
foreach ($side in 'Client','Server') { $e = "$root\Experience\$side\experience.exe"
  $b = [IO.File]::ReadAllBytes($e); $pe = [BitConverter]::ToInt32($b, 0x3C)
  "$side subsystem=$([BitConverter]::ToUInt16($b, $pe + 0x5C))" }   # Client 2 (GUI), Server 3 (console)
Test-Path "$root\Experience\Client\FishNet.SDK.Id","$root\SDK\bin\DreamStation.exe",
  "$root\Experience\experience_Data\StreamingAssets\specialFiles\experience_config.xml"
Get-ChildItem "$root\SDK\version-*.json" | % Name                     # version-<bundleVersion>.json
Select-String -Path C:\p\logs\<tag>-*.log -Pattern '"event":"build_result"' | % Line
```

- Client: `experience.exe`, `GameAssembly.dll` (about 91 MB), `UnityPlayer.dll`, an empty `FishNet.SDK.Id`,
  `experience_Data\StreamingAssets\aa\`, PE subsystem 2.
- Server: the same files, PE subsystem **3** (console). A 2 means the server subtarget was lost (TB-10).
- `SDK\` (442 MiB): `start.bat`, `rv_start.bat`, `version-<bundleVersion>.json`, `feature-flags.json`,
  `sdk-metadata.json`, `bin\DreamStation.exe`, `bin\{Hostess,Vicon,Universe,turnserver}` (V). Missing `SDK\` = the
  exe was not under `Experience\{Client,Server}\`.
- Android: the apk exists, and the log has `ManifestInjector: AndroidManifest.xml updated successfully.` (V).
  `FishNet.SDK.Id` and `experience_BurstDebugInformation_DoNotShip\` land beside it (V); ship only the apk.

Then smoke-run server + clients: runtime-config.md.

## 6. Build Profile route (Unity 6 profile assets)

`run-ddk-build.ps1 -Step Profile -BuildProfile "Assets/Settings/Build Profiles/Windows_Server.asset" -Out C:\b\<name>\Experience\Server\experience.exe`.
V (F-34): 360 s, exit 0, PE subsystem 3, `SDK\` assembled. The wrapper opens the editor with
`-activeBuildProfile <asset>` instead of `-buildTarget`, so there is no mid-run target switch, then calls
`DDKAgentBuild.Profile`. The Windows_Client and Android_Client profiles take the same form (I: not run).

- `-Out` is the full output file (`.exe` or `.apk`); both `-BuildProfile` and `-Out` are mandatory.
- A profile carries its own Graphics and Quality overrides (Windows_Client, Android_Client). MP ships
  `Windows_Client` (Win64/Player), `Windows_Server` (Win64/Server), `Android_Client` and `Linux Server`; SP ships
  only `Windows_Client` and `Android_Client` (O; V file listing). All use the global scene list. Linux Server
  needs the `linux-server` module, which nobody installs (TB-25).
- `-ddkDefines` and `-ddkAgentHooks` are ignored on this route (O, `DDKAgentBuild.Profile`).

## 7. Dev Deploy

Layout the Dev Deploy panel validates (O):
- Multiplayer: `<root>\Experience\Client\experience.exe`, `<root>\Experience\Server\experience.exe`,
  `<root>\Experience\experience_Data\StreamingAssets\specialFiles\experience_config.xml`, `<root>\SDK\version-x.y.z.json`,
  `<root>\SDK\start.bat`, `<root>\SDK\rv_start.bat`.
- Single player: `<root>\Experience\experience.exe`, its `experience_Data\...\experience_config.xml`, same SDK files.
- The post-build fires when the exe's parent is `Experience` (single player) or `Client`/`Server` under
  `Experience` (multiplayer), case-insensitive, never for Android or iOS. `SDK\bin` is unpacked from the
  `Artifacts\*.tar.gz` of the dream-station, hostess, vicon-routing-server and haptic-universe artifact packages,
  plus dev-deploy's `SdkContent\turnserver.tar` (V `sdk-metadata.json`: DreamStation 1.1.9, Hostess 1.0.10,
  Vicon 1.0.6, Universe 1.0.5, turnserver 1.5.13). `rv_start.bat` writes HKLM OpenXR layers and
  `turnserver\setup-coturn.bat` runs docker: they are pod-side scripts, so leave them unrun on dev machines (TB-22).

Upload (O, not run here):
1. The pod is in Dev Deploy mode (Backstage Manager).
2. Move `Experience\*\experience_BackUpThisFolder_ButDontShipItWithYourGame` and `*_BurstDebugInformation_DoNotShip`
   out of the root. The uploader zips all of `Experience\` except `monitoring` dirs into `<root>\Experience.zip` and
   `<root>\SDK.zip` (deleted after the upload), and the backup folder is 2096 MiB of the 2476 MiB client (V size).
3. Python venv (TB-18): `python -m venv C:\b\ddvenv`, then `C:\b\ddvenv\Scripts\python -m pip install -r
   <pkg>\upload_build\requirements.txt` (2021 pins: requests 2.26.0, urllib3 1.26.6). `<pkg>` =
   `<project>\Library\PackageCache\com.dreamscape-learn.editor-tools.dev-deploy@<hash>` (V: `file:` packages
   unpack there).
4. `C:\b\ddvenv\Scripts\python <pkg>\upload_build\upload_build.py C:\b\<name> --server http://<host>:<port>
   --deployment_stream <stream> --deploy_to <pod> --force`. Options also include `--commit_id`, `--comment` and
   `--compress_level` (default 0); `--server` defaults to `http://localhost:5000`.
   - Always `--force`: a re-upload otherwise blocks on `input()`. Check HTTP status yourself: the script crashes
     on its own error path, and `--from_zip` / `copy_build.py` are broken (TB-19).
   - Protocol: plain HTTP, no auth. `GET /upload_script/version` (a major other than the script's 1 exits 1),
     `POST /api/upload` (metadata.json + Experience.zip + SDK.zip), then `update_deployment_stream_tag`,
     `start_deployment`, polling `GET /api/poll_job/<id>`.
   - `--deploy_to` acts only together with `--deployment_stream`. The script exits 0 whatever happens, so
     Done = stdout shows `Uploaded build with id <id>` and `<job finished successfully>`.
- Editor panel: Dreamscape DevKit > Project Configurator (Ctrl+Shift+D) > Developer Tools > Deployment. EditorPrefs
  `DevDeploy_TargetServer` overwrites its server field every time the panel opens (O).

## 8. DDK Build System CLI (fallback only)

Reach for it only when a user requires it; its output is not Dev Deploy ready (TB-03). O, not run.
1. Create a BuildConfiguration (Create > Dreamscape DevKit > Build System > Build Configuration); none ships
   (TB-01). Client and server go in separate configs: one path for both overwrites (TB-02). Save, reload, and
   confirm `BuildWindowsServer` / `LoadVersionFromGitTag` tasks survived (TB-11).
2. Run with `-quit` (it never exits on success, TB-08):
   ```powershell
   $env:UNITY_BUILD_CONFIGURATION_NAME = '<asset name>'
   & $UnityExe -batchmode -nographics -quit -projectPath <p> -buildTarget Win64 `
     -executeMethod DreamscapeLearn.BuildSystem.Editor.Cli.CliEntrypoint.RunBuildProcess -logFile <log>
   ```
   Exit 2 = failure. Unset `UNITY_BUILD_RELEASE_TYPE` = Development build; an unknown release type throws
   `NullReferenceException` (TB-09). `UNITY_PIPELINE_NAME` empty = all stages; an unknown name succeeds doing
   nothing; stage names `Default` and `all` re-run everything (TB-08, TB-40).
3. Output: `Builds/Executables/<App>/<ver>/<release>/Windows/<App>/<App>.exe`, `Builds/build-manifest-*.json`,
   `Builds/Logs/build_log.log`. No zip. Defines, app id and version from `ReleaseType` are never applied (TB-09);
   a git tag beats `UNITY_BUILD_VERSION_OVERRIDE` and missing git crashes it (TB-12, TB-13). Done = the exe exists:
   an unknown stage name exits 0 having built nothing (TB-08).

## 9. Addressables and CMS content packs

- Player content: `m_BuildAddressablesWithPlayerBuild: 0` follows a per-user preference (TB-49). `DDKAgentBuild`
  runs `AddressableAssetSettings.BuildPlayerContent` before every build and exits 3 on error (V: `addressables_ok`
  83 s client, 11 s server, 88 s Android). The player gets `experience_Data\StreamingAssets\aa\catalog.json` (V:
  a JSON catalog, as CMS expects).
- Keep `Assets/Samples/*`: Localization settings and the Localization Addressables groups point into the XR
  Avatar Calibration sample (TB-30).
- Content packs (O, not run): a Prefab Pack or Texture Pack whose `Identifier` equals an Addressables group
  name, built per target through its inspector or `BuildContentPacksTask`.
  - The runtime always loads `{DSL_CMS_ROOT_LOAD_PATH}/<id>/<StandaloneWindows64|Android|StandaloneLinux64>/catalog.json`:
    the public `LoadContentCatalog` drops its `version` argument (CA-16). Build packs with `Versioned=false`: a
    version would also move the bundle load path to `<id>/<ver>/<Target>` (`ContentEditorUtility.GetSerializableLoadDirectory`).
  - Interactive build: output `Builds/Addressables/<id>/<target>/catalog.json` + `catalog.hash`.
  - Batch build: the rename step looks in a git-versioned folder, so the catalog keeps its build name (TB-05).
    Rename `*.json` / `*.hash` in `Builds/Addressables/<id>/<target>/` to `catalog.json` / `catalog.hash`. Batch
    pack builds also call `git describe --tags`: git on PATH, tags fetched (TB-13).
  - Done = `catalog.json` exists for every target: the task reports success on failure (TB-04).
  - Revert `Assets/AddressableAssetsData/AddressableAssetSettings.asset` afterwards: remote catalog and git player
    version stick to later player builds (TB-50).
  - Serving: runtime-config.md "Content server".

## 10. Validators and hooks (run on every player build, whatever started it; O)

| Hook | Fails the build when | Keep it green by |
|---|---|---|
| `SceneValidator`, `AddressableSceneValidator` (seat management) | a seat number repeats per seat type in any enabled or Addressable scene. Also opens and **saves** every scene and regenerates duplicate seat GUIDs (TB-16) | saving scenes before building, unique seat numbers, Addressable scene address = asset path, committing the re-serialized scenes |
| `RelayValidationPrebuildStep` | `[RelayTypeIdRange]` ranges overlap or payload ids repeat (TB-17) | a range outside relay-system 10-99, LMS client 2000-2199, LMS server 2200-2399, avatar-management 6000-6199, Chat sample 61000-61199 |
| XR Core Utils `BuildValidator` rules (XR Platform Service) | flags Error when Android is not ARM64 + IL2CPP or minSdk < 32 (whether that blocks a batch build is unknown); the rest are warnings | template settings (V: all builds green). Keep MetaQuestFeature off; skip the "Create URP" fix, it nulls the RP (TB-37) |
| `ManifestInjector` (Android) | does not gate; injects permissions, `wave.feature.handtracking` required, `com.oculus.supportedDevices`, VR category unless `UseCustomManifest` | nothing (V: ran, build green) |
| `MixerGroupBuildChecker` | inert while `RequiredMixerGroups` is empty (TB-52) | leaving it empty |
| `MessagePackBuildProcessor` | interactive builds only; batch skips codegen (TB-48) | committing generated resolvers |
| `DevDeployPostBuildScript`, FishNet `BuildIdentifier`, `LogicLinkXmlGenerator` | do not gate | nothing: they write the SDK folder, `FishNet.SDK.Id` (V) and the linker `link.generated.xml` |

## 11. Scripting defines

- ProjectSettings `scriptingDefineSymbols` (O):
  - `Standalone` and `Android`: `ENABLE_JSON_CATALOG;FISHNET;FISHNET_V4;USE_INPUT_SYSTEM_POSE_CONTROL;USE_STICK_CONTROL_THUMBSTICKS;UPPipeline;FISHNET_DISABLE_V3TOV4_HELPERS`.
  - `Server`: `ENABLE_JSON_CATALOG;FISHNET;FISHNET_V4;FISHNET_DISABLE_V3TOV4_HELPERS`. Align it when server code
    needs the others (TB-35).
  - CMS re-adds `ENABLE_JSON_CATALOG` on every domain reload; FishNet manages its own. Only FishNet reads
    `UNITY_SERVER`.
- Per build, ProjectSettings untouched: `-ddkAgentHooks` adds `DDK_AGENT_HOOKS` (V: `build_start` `defines`) and
  `-ddkDefines "A;B"` adds arbitrary symbols (I: not yet built), both through
  `BuildPlayerOptions.extraScriptingDefines`.

## 12. Android specifics

- Template settings already pass (O; V from the built APK, F-30): ARM64 only (arm64-v8a), IL2CPP, minSdk 32,
  targetSdk = highest installed (36 here), Vulkan only in multiplayer (add GLES3 for devices that need it, TB-34),
  debug keystore, Activity entry. Set a release keystore in PlayerSettings before store uploads (I).
- OpenXR features, hand tracking, controllers, manifest required features, `adb install` and the on-device check:
  xr-pod.md "Recipe: Quest (Android) build".
- Manifest source: multiplayer generates it through `ManifestInjector`; single player ships
  `Assets/Plugins/Android/AndroidManifest.xml` (`useCustomMainManifest: 1`).
- `com.unity.ads` drags in EDM4U, which can stall an offline build at dependency resolution (TB-46, I): section 2
  step 4 removes it. Headset runtime config: runtime-config.md "Android headset".

## 13. Vendor patches (embed, then patch)

DDK packages resolved from `file:` tarballs are immutable. To fix a vendor bug, embed that one package, with the
editor closed:
`python -I scripts/apply_ddk_patches.py --project <dir> [--only <package>] [--tarballs <dir>] [--patches <dir>] [--force]`.

- For each `patches/<package>@<version>/patch.json` it extracts `<package>-<version>.tgz` from `--tarballs`
  (default `<project>\DDK-Tarballs`) into `Packages\<package>\` (embedded packages win over manifest entries),
  applies the find/replace hunks and writes `DDK-PATCHED.json`. JSONL log: `<project parent>\apply_ddk_patches.jsonl`.
- Each `find` must match exactly once (overlapping matches count), or nothing is written and the run exits 1, so a
  different vendor version fails loudly instead of being patched blindly. Exit 0 = applied, or `already_patched` on
  a re-run with the same spec (V).
- `DDK-PATCHED.json` records the spec's sha256. A changed spec (`spec_changed`), or a `Packages\<package>\` folder
  without the marker (`embedded_unmanaged`), exits 1 and stays untouched until you pass `--force` (V).
- Hunks match in the file's own line endings (LF or CRLF), and BOMs are preserved. V: a fresh apply is
  byte-identical (86 files) to the embedded package of
  the build that passed F-32.
- Done = `Packages\<package>\DDK-PATCHED.json` exists for every spec.

Shipped patches:

| Package | Fixes | Status |
|---|---|---|
| `environment-management@1.2.10` | F-29 (empty env var -> config system dead) and RC-01 (duplicate CLI key -> config system dead): null-safe values and indexer writes in `EnvironmentVariableResolver` and `ExecutableArgumentsResolver`; a repeated CLI key then resolves to its last value | V (F-32): rebuilt client launched with an injected empty var and a duplicated `-DSL_DREAMFISH_SERVER_PORT` -> `Module EnvironmentManagement initialized`, no missing variables; the unpatched build Fatals on the same launch |

Add a patch:
1. Edit a copy of the vendor file and mark each change with a `// DDK patch (<ID>)` comment.
2. Run `python -I scripts/make_patch_spec.py --spec <skill>/patches/<package>@<version>/patch.json --package <name> --version <ver> --file <path in package> --original <vendor file> --patched <your copy> --id <ID>`.
   It stores only the changed hunks plus enough context to make each `find` unique (overlapping regions merge into
   one hunk). It then replays them the way the applier does, and exits 1 unless the replay reproduces your copy.
   No vendor file ships with the skill; re-running replaces that file's entry.
3. Delete your copy, apply the patch, and rerun the A/B launch that reproduced the bug. Done = the A/B launch
   flips from failing to passing.

## 14. Build defects, ranked by impact

| # | ID | Symptom | Workaround |
|---|---|---|---|
| 1 | TB-03, TB-01, TB-02 | Build-system CLI: no config ships, client and server overwrite, output not Dev Deploy ready | `DDKAgentBuild` into `Experience\{Client,Server}\` |
| 2 | TB-16 | Seat validators fail on duplicates, save every scene, discard unsaved edits | Save first, unique seats, commit re-serialized scenes |
| 3 | TB-17 | `BuildFailedException` "[Relay] ... overlapping ranges" | Unused id range (section 10) |
| 4 | TB-06 | Every project shares an Android id and cart ExperienceId with a vendor product | Section 2 |
| 5 | TB-05, TB-04, CA-16 | Content-pack catalog not renamed (runtime 404), versioned packs never load, failure reported as success | Section 9: `Versioned=false`, rename in batch, assert `catalog.json` |
| 6 | TB-10 | Client becomes server or the reverse | Explicit subtarget (`DDKAgentBuild` sets it); check PE subsystem |
| 7 | TB-44 | Path-too-long during import or build (deep `SDK\bin\Hostess\...`) | `C:\p\<short>`, `C:\b\<short>` |
| 8 | TB-29 | `CS0246` for DDK types in user scripts | Own asmdef (architecture.md) |
| 9 | TB-36 | Player ignores template ports and URLs | `EnvironmentVariables.json` next to the exe (runtime-config.md) |
| 10 | TB-49, TB-50 | Addressables stale or remote catalog after pack builds | `DDKAgentBuild` builds content; revert settings after packs |
| 11 | F-30, TB-46 | Store-hostile ads/billing permissions; offline Android build stalls (I) | Section 2 step 4 |
| 12 | TB-32 | Double XR init on multiplayer Android | `m_InitManagerOnStart: 0` |
| 13 | TB-07, TB-20 | Every project uploads under the template experience; config never recreated | Section 2 step 1 |
| 14 | TB-18, TB-19, TB-23 | Dev Deploy upload fails or hangs | venv, `--force`, real Python on PATH |
| 15 | TB-24 | Vendor identity, cache-server IP and deploy servers ship in the build | Section 2 |
| 16 | TB-26, TB-27, TB-28 | First open fails offline or with Verdaccio down; lock rewritten | environment.md route A; commit the new lock |
| 17 | TB-30 | Re-imported or deleted samples break localization and Addressables | Keep `Assets/Samples/*` |
| 18 | TB-43 | Removing `com.unity.test-framework` breaks dev-deploy compile (I) | Keep the package |
| 19 | TB-25 | Linux Server profile: module not installed | Ignore the profile |
| 20 | TB-48 | MessagePack codegen skipped in batch | Commit generated resolvers |
| 21 | TB-08, TB-09, TB-11..TB-15 | Build-system CLI hangs, NREs, drops tasks, false success | Section 8 rules, or stay on `DDKAgentBuild` |

Build-time noise that is harmless (V): the F-24 import errors on first open, and 10-13 warnings per player.
