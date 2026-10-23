# Dreamscape Developer Kit agent skills

Agent skills (Claude Code / Agent Skills `SKILL.md` format) for building and shipping **Dreamscape Learn VR
experiences on the Dreamscape Developer Kit (DDK) 1.1.9788.20016**: Unity 6000.3.2f1 projects built from the
`com.dreamscape-learn.*` packages.

The vendor installer, templates and tooling have many defects. These skills document a tested **working path**
around them. Every step is tagged **V** (verified by running a real build or player), **O** (observed in vendor code) or
**I** (inferred), and every defect has an ID and a workaround.

> Unofficial. Not affiliated with, endorsed by, or supported by Dreamscape Learn. "Dreamscape", "Dreamscape Learn"
> and related names are trademarks of their owners. This repository contains no vendor code, binaries or assets.
> You need your own licensed copy of the DDK installer.

## The skills

| Skill | Invocation | What it does |
|---|---|---|
| [`dreamscape-ddk`](skills/dreamscape-ddk/SKILL.md) | model-invoked | 7-step pipeline: doctor -> project -> personalise -> agent scripts + vendor patches -> compile gate -> builds -> run and verify. Eight references cover environment, build, runtime config, architecture, networking, avatars/seats, experience authoring, XR/pod services. |
| [`dreamscape-ddk-re`](skills/dreamscape-ddk-re/SKILL.md) | user-invoked (`/dreamscape-ddk-re`) | Unpacks and indexes a new DDK installer release, diffs it against the previous version, and refreshes `dreamscape-ddk`. |

## Verified on Windows 11 with Unity 6000.3.2f1

- **Project without the vendor registry:** a project generated from the Multiplayer template, with all 55 DDK packages
  resolved from local tarballs (no Verdaccio). It imports and compiles with 0 errors.
- **Headless IL2CPP builds:**
  - Windows client;
  - Windows dedicated server, a console PE built both from the subtarget and from the Build Profile route;
  - Android arm64 APK.
  - Building into the Dev Deploy layout auto-assembles the pod `SDK\` bundle.
- **Headless multiplayer:** a server plus a teacher client and a student client on one PC. Each client authenticates,
  is assigned a role, group and seat, and has its avatar spawned.
- **Critical runtime defects found, each with a fix:**
  - an empty-valued environment variable, or a repeated CLI key, disables the whole DDK config system in IL2CPP
    players (fixed by a shipped vendor patch);
  - batchmode clients can never reach login (handled by a build-time-only test hook).

## Requirements

- Windows 10/11, the Unity CLI, Unity 6000.3.2f1 with the windows-il2cpp, windows-server, android,
  android-sdk-ndk-tools and android-open-jdk-17.0.9+9 modules, and a Unity license.
- VS 2022 Build Tools (C++ workload, Windows SDK 22621) for IL2CPP.
- Python 3.12+. `dreamscape-ddk-re` also needs the WiX 6 CLI, sfextract, ilspycmd, lessmsi and 7-Zip.
- Your own DDK installer, or a machine where it is installed (for the package tarballs and templates).

## Install

Copy or link each skill folder into your agent's skills directory, for example:

```powershell
New-Item -ItemType Junction -Path "$HOME\.claude\skills\dreamscape-ddk"    -Target "<clone>\skills\dreamscape-ddk"
New-Item -ItemType Junction -Path "$HOME\.claude\skills\dreamscape-ddk-re" -Target "<clone>\skills\dreamscape-ddk-re"
```

Then run the doctor:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File skills\dreamscape-ddk\scripts\ddk-doctor.ps1
```

## Evidence

References cite IDs (F-, TB-, RC-, NW-, ...) from an evidence tree, written `<re>`, that holds the unpacked vendor
packages, decompiled code, analysis notes and runtime logs. It is never published: build your own from your
installer with `dreamscape-ddk-re`.

## Safety

- Keep `DDK-Tarballs\`, extracted trees and builds private. Vendor `package.json` files embed a CI job token in
  `repository.url`, so never publish them.
- `start-ddk-player.ps1` strips empty-valued environment variables, and the shipped patch removes that crash class.
  The `DDK.AgentHooks` test hook compiles only into builds made with `-ddkAgentHooks`: ship builds without it.

## Contributing

Run `python -I skills/dreamscape-ddk-re/scripts/lint_skill.py --public skills/dreamscape-ddk skills/dreamscape-ddk-re`
before committing. It must print `findings=0`. Keep the V/O/I tags honest: V needs a log or artifact you checked.

## License

MIT for the contents of this repository (see `LICENSE`). Third-party names and the DDK itself remain their owners'.
