---
name: dreamscape-ddk
description: Dreamscape Developer Kit (DDK) work - Unity 6000.3.2f1 VR projects built on com.dreamscape-learn.* packages. Use to set up a DDK machine, create a project from the Multiplayer or Single Player template, build Windows client/server or Android (Quest) players headless, run and verify a local session, or write experience code against DDK systems (ACS modules, DreamFish/FishNet, seats/avatars, Experience Logic, Aether Canvas, XR platform, pod services).
---

# Dreamscape Developer Kit

The DDK ships as a WiX installer that sets up Unity, a local Verdaccio npm registry, 55 UPM packages with full
C# source, two project templates, an Experience Launcher and pod services. Much of it is broken. This
skill is the reverse-engineered **working path**: every pipeline step below has been run end to end on Unity
6000.3.2f1. Tags: **V** verified by running, **O** observed in vendor code, **I** inferred.

Pinned facts: Unity **6000.3.2f1**, changeset **a9779f353c9b**; modules windows-il2cpp, windows-server,
android, android-sdk-ndk-tools, android-open-jdk-17.0.9+9. Templates: `com.dreamscape-learn.template.dreamscape-multiplayer@1.5.5`
and `...dreamscape-single-player@1.4.5`. `productName` is always `experience`.

## Pipeline

Scripts live in `scripts/` next to this file; each logs JSONL. Run each step to its completion criterion before the next.

1. **Doctor.** `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ddk-doctor.ps1 [-TarballDir <dir>] [-TemplateDir <dir>]`.
   Without the official installer pass `-TarballDir <extracted Package Cache>` (and `-TemplateDir <extracted Unity Templates>`):
   the default ProgramData path fails `ddk-tarballs` (V).
   The guided setup (`setup-wizard.sh` in the skills repo) saves `DDK_TARBALL_DIR`, `DDK_TEMPLATE_DIR` and `DDK_UNITY_EXE` to
   `%USERPROFILE%\.dreamscape-ddk\config.env`; the doctor uses them when no folders are passed (V), and later steps can read them there.
   Done: `RESULT: ready`, exit 0, plus the manual checks in [references/environment.md](references/environment.md)
   section 1 step 2. Fix each FAIL with its printed `fix:` line; that reference also covers installer-free
   provisioning, the official installer and repair.
2. **Project.** `python -I scripts/make_filedeps_project.py --template <template.tgz|dir> --cache <tarball dir> --project <short path, e.g. C:\p\name>`.
   It resolves all 55 DDK packages from local tarballs through `file:` references (no Verdaccio).
   Done: exit 0 and the log line `manifest_rewritten {'file_deps': 55 ...}` (V).
3. **Personalise** before the first build ([references/build.md](references/build.md) section 2). Keep
   `productName = experience`. Set a unique Android `applicationIdentifier` (`com.dreamscapelearn.<experience>`), the
   Standalone id, `bundleVersion`, `AndroidBundleVersionCode`, and `ExperienceName` in
   `Assets/StreamingAssets/specialFiles/experience_config.xml`. For headset builds remove `com.unity.ads`,
   `com.unity.purchasing` (UPM adds it on first open), `Assets/MobileDependencyResolver/` and
   `Assets/Resources/BillingMode.json`; the stock APK carries AD_ID/BILLING permissions (V; removal I).
   Done: none of the template ids are left (`dev.dreamscapelearn.icstarterpack01`, `com.dreamscapelearn.hum_seti_r01`,
   `com.Dreamscape-Learn.Acumen-Beta`, `dsl-multiplayer-project-template`, `rtp-single-player-template`).
4. **Agent scripts and vendor patches.** `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-agent-scripts.ps1 -Project <p>` installs
   `DDK.AgentBuild` (editor) and `DDK.AgentHooks` (a test hook, compiled only into builds that request it).
   `python -I scripts/apply_ddk_patches.py --project <p>` embeds and patches the vendor packages listed in `patches/`.
   Done: `Packages/<package>/DDK-PATCHED.json` exists for each patch, and the patch run exits 0.
5. **Compile gate.** `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-ddk-build.ps1 -Project <p> -Step Compile`.
   Done: `STEP_DONE ... exit=0 ... error_cs=0` and a `[DDK-CI]` line with `"reason":"compiled"` (V, F-34: 57 s on an
   imported project). The first open takes about 12 minutes (package resolve plus a 9.6k-asset import, V).
6. **Build** with the same driver: `-Step WindowsClient|WindowsServer|Android -Out <root or .apk>` (`-Out` for Android is the full `.apk` path).
   Done, per target (V):
   - client: `<root>\Experience\Client\experience.exe`, a GUI-subsystem PE;
   - server: `<root>\Experience\Server\experience.exe`, a **CONSOLE**-subsystem PE;
   - both: `<root>\SDK\bin\DreamStation.exe` (Dev Deploy bundle);
   - Android: an arm64-v8a APK;
   - all: the log line `[DDK-CI] ... "event":"exit" ... "code":0`.
   Build times here: client 20 min, server 6 min, Android 14 min.
7. **Run and verify.** Start every player with `scripts/start-ddk-player.ps1`, then triage each log.
   Done: `python -I scripts/ddk_log_triage.py <log> --strict` prints `VERDICT: clean` for every log, and each client
   reaches the lines in [references/runtime-config.md](references/runtime-config.md) (Verify a session). A healthy
   server also announces ports `9000` (game) and `9045` (RTC).

## Traps that break working builds (all verified unless tagged)

- **Empty-valued environment variables** in the launching process crash the DDK config system in IL2CPP
  players. The result is a server on the wrong port, voice down and `Failed to Initialize System`. The step 4
  patch fixes it; `start-ddk-player.ps1` strips them as a second line of defence (F-29).
- **A repeated `-KEY` CLI argument** kills the same system on unpatched builds (O, RC-01). Pass each key once and
  keep `-DSL_*` out of launcher custom args.
- **`unity install ... --resume` installs nothing** on a fresh machine. The bare `android-open-jdk` module
  id doesn't exist; use `android-open-jdk-17.0.9+9`.
- **IL2CPP needs MSVC.** VS 2022 Build Tools are enough. Query them with `vswhere -products *`, because without it Build Tools stay hidden.
- **Building into `<root>\Experience\{Client,Server}\`** triggers Dev Deploy's post-build step, which copies
  about 440 MiB of pod services into `<root>\SDK` (V: `SDK\` is 442 MiB). That's expected. Any other output path skips it.
- **Headless clients never log in on stock templates.** In batchmode the calibration step returns early, so the
  login canvas never appears. After it, auto-login still waits at a Confirm popup. Build with
  `-ExtraArgs -ddkAgentHooks` and start the client with `-ddkAutoConfirm`. Verified end to end for a teacher and a
  student together: auth, roles, groups, seats and avatar spawn (runtime-config.md, Login; F-31..F-33).
- **The DDK runtime asmdefs are not auto-referenced** (O). Experience code needs its own asmdef that references
  the DDK assemblies it calls ([references/architecture.md](references/architecture.md), Set up author code).
- **The installed packages are immutable.** To fix a vendor bug, embed that one package with
  `scripts/apply_ddk_patches.py` and a `patches/<package>@<version>/patch.json` spec built by `scripts/make_patch_spec.py`
  (build.md, Vendor patches); the embedded copy takes precedence over the `file:` entry.

## Reference map

| Task branch | Read |
|---|---|
| Machine setup, installer failures, Verdaccio, uninstall | [references/environment.md](references/environment.md) |
| Project settings, build targets, Dev Deploy, CMS content packs, build validators, vendor patches | [references/build.md](references/build.md) |
| Launching players, `DSL_*` config keys, ports, login, session checks, launcher, Android config | [references/runtime-config.md](references/runtime-config.md) |
| Boot order, ACS modules, levels, config variables, CMS runtime, services, logging, console, debug panel, emergency broadcast | [references/architecture.md](references/architecture.md) |
| DreamFish/FishNet, relay messages, RTC voice, DreamConnect, session backends | [references/networking.md](references/networking.md) |
| Seats, groups, roles, avatars, calibration, lip-sync | [references/avatars-seats.md](references/avatars-seats.md) |
| Experience Logic graphs, checkpoints, Aether Canvas, XR interaction, subtitles | [references/experience-authoring.md](references/experience-authoring.md) |
| OpenXR/hand tracking, Quest vs PC VR, Vicon/haptics, DreamStation and pod services | [references/xr-pod.md](references/xr-pod.md) |

Evidence base: `<re>\notes\` (one file per subsystem, plus the `05-lead-findings.md` ledger) and the vendor source
under `<re>\extract\packages\`, where `<re>` is the output folder of the `dreamscape-ddk-re` skill; run that skill
when no such folder exists. Treat vendor docs as a hint only: they describe a Free Roam template and an
experience-coordination package that do not ship, and their login codes and ports disagree with the code.
