# Runtime configuration, local runs, launcher

How a built DDK player (client or server) gets its settings, how to run and verify server + clients locally, and the
Experience Launcher's traps. Tags: **V** verified by running a 6000.3.2f1 build (the log line is quoted), **O**
observed in vendor code, **I** inferred. IDs (RC-, LR-, F-) index the evidence in
`<re>\notes\30-launcher-and-runtime-config.md` and `05-lead-findings.md`.
FishNet, relay, voice and HTTP internals: `networking.md`. `EnvironmentService` API and custom variables:
`architecture.md` (Add a config variable; Service catalogue).

## Launch a player (always this way)

1. Embed the patched environment-management package in every project (build.md, Vendor patches). Then start every
   player with `scripts/start-ddk-player.ps1 -Exe <exe> -LogFile <absolute path> -PlayerArgs @(...)`, one log path
   per process (all instances otherwise share `%USERPROFILE%\AppData\LocalLow\Dreamscape Learn\experience\Player.log`).
   Done: the script prints one JSON line with `pid` and `removed_empty_vars`.
   - Why (V, F-29): an unpatched IL2CPP player that inherits one empty-valued OS environment variable loses its whole
     variable system. Its log shows `NullReferenceException` at `EnvironmentVariableResolver.Initialize`, then
     `ArgumentException: An item with the same key has already been added. Key: <some env var>`, then
     `[ApplicationControlService|Fatal]: Failed to initialize module EnvironmentManagement.` ACS keeps going, so later
     modules still log `initialized`, and ACS finally throws `InitializationException: Failed to Initialize System`.
     No `Setting the Server Port to` line appears, the server binds the asset port 8300, and voice dies
     (`KeyNotFoundException: Variable DSL_VOIP_COMMUNICATION_PORT not found.`).
   - The script strips empty-valued variables, a second line of defence behind the patch. Agent shells, CI runners
     and IDE terminals can carry them (I).
2. Pass every `-flag` once, Unity flags included. The script appends `-logFile` itself, so keep it out of
   `-PlayerArgs`. O (RC-01): unpatched, a repeated key throws in `Dictionary.Add` and kills the variable system the
   same way as F-29. V (F-32): patched, the last value wins.
3. Triage each log: `python -I scripts/ddk_log_triage.py <log> --strict`. Done: `VERDICT: clean`, exit 0.
   `Missing DSL variables: none` alone proves nothing: the F-29 failure log prints it too (V). A healthy server also
   prints `Ports announced: {'dreamfish_server_port': ['9000'], 'rtc_port': ['9045']}` (V).

## Local server + clients

```powershell
$S = '<root>\Experience\Server\experience.exe'; $C = '<root>\Experience\Client\experience.exe'; $L = '<root>\logs'
$net = @('-DSL_DREAMFISH_SERVER_IP','127.0.0.1','-DSL_DREAMFISH_SERVER_PORT','9000')
& scripts\start-ddk-player.ps1 -Exe $S -LogFile "$L\server.log" -PlayerArgs (@('--PLATFORM','WindowsServer','-batchmode','-nographics') + $net)
Get-NetUDPEndpoint -LocalPort 9000,9045 -ErrorAction SilentlyContinue
& scripts\start-ddk-player.ps1 -Exe $C -LogFile "$L\client1.log" -PlayerArgs (@('-screen-fullscreen','0','-screen-width','960','-screen-height','540','-DSL_ENABLE_AUTO_LOGIN','true','-DSL_PIN','1111') + $net)
```

1. Start the server. Done (V): `Get-NetUDPEndpoint` lists UDP 9000 (FishNet/Tugboat) and UDP 9045 (RTC
   signalling), and the server log has, in order: `[DreamFish|Info]: Setting the Server IP address to 127.0.0.1`,
   `Setting the Server Port to 9000`, `[DreamNetworkManager]: Initialization - Finished`,
   `RTCServer.StartNetManager will start on port 9045`, `Module DreamFish Start Server Module Server initialized`.
2. Start each client. Done: "Verify a session" below.
3. Stop. Windowed players: `CloseMainWindow()`, a bounded wait, then `Stop-Process -Id`. Headless players have no
   window: `Stop-Process -Id`.

Rules:
- Use `127.0.0.1`, not `localhost` (Tugboat has IPv6 on; I). A bad port string logs `Invalid Server Port format:` and
  keeps the asset port (O).
- Use one game port for every process. The defaults disagree: 8300 (Server Configuration asset, launcher), 9000 (MP
  `EnvironmentVariables.json`, pods, docs), 8085 (SP JSON) (RC-10).
- Run one server per machine per port pair (game port + 9045).
- Headless client: add `-batchmode -nographics`. XR fails over to `DesktopSimulatorTrait` (V). It needs the hooked
  build to log in (Login).
- A second client on one PC collides on Dream Connect `+:8085` and haptics RX UDP 12000. FishNet is unaffected
  (V, F-33: the teacher and student clients both logged in and spawned). Fixes: `networking.md` (Dream Connect
  HTTP 8085) and `xr-pod.md` (PD-08).

## Login (blocks every client until handled)

- Flow (O): calibration, then `LoginCanvas` activates, then the `DreamscapeSession` PIN pad (or auto-login), then a
  Confirm popup (`Welcome GenericTeacher?`), SelectExperience, LoadExperience and the connect: up to 3 attempts x 10 s,
  no reconnect after a drop.
- Windowed Windows client without XR: calibration applies the preset data and finishes by itself (O,
  `CalibrationDataStarter`). The Confirm popup still needs one press (RC-17).
- Headless (V, F-31): `CalibrationDataStarter.OnEnable` returns early in batchmode, so `LoginCanvas` stays inactive
  and a stock headless client never logs in.
- Headless automation (V, F-32): build the client with `-ExtraArgs -ddkAgentHooks` (adds the `DDK_AGENT_HOOKS` define
  to that build only), then start it with `-batchmode -nographics -ddkAutoConfirm -DSL_ENABLE_AUTO_LOGIN true
  -DSL_PIN 1111`. Done: the client log has `[DDK-HOOK]` JSON events `hook_armed`, `calibration_finished_invoked` and
  `press` with label `Confirm`. Ship builds without `-ddkAgentHooks`.
- Codes when no backend login is reachable (O): `1111` = teacher, `0000` = student. `0024` is the override, which
  is a student on a dev PC: teacher needs a station id ending `A-99`, and that needs both pod URLs (RC-14). Any other
  code returns the pad with `No connection to the session service. Use an override code.` With a backend,
  `0000` and `1111` go to pod-connect like any other code.
- Auto-login (O): `-DSL_ENABLE_AUTO_LOGIN true` submits `DSL_PIN`, or `0024` when `DSL_PIN` is unset.
- Login codes disagree across packages (F-26): user-service `RoleCodeAuthenticator` 000/111, aether-canvas
  `LoginAssistant` 000/111 and `LoginRoomPanelWidget` 0000/1111, session-runtime 0024/0000/1111. The docs describe
  only 000/111. What goes on the wire: `networking.md` (Authenticators and login codes).

## Verify a session (V, F-32 one headless teacher; F-33 teacher + student together)

These lines are Trace/Debug level; template builds log them (V).
1. Client, in order: `[DreamscapeSession] Game server connection attempt 1/3.`,
   `OnClientConnectionState: Started`, `Received AuthResponseBroadcast. Authentication result: True`,
   `RTCClient.StartNetManager will start <ip>:9045`, `ChannelCache.OnReceivedConfiguration()`.
2. Server, in order (the triage "Session milestones" block prints most of them):
   `Received AuthFormBroadcast from <ip>`, `Assigning role: teacher`, `[TransitionSync] Begin catch-up for client <n>`,
   `Received ClientReady message from Client <n>.`,
   `Assigned Seat <seatId> to User <userId> (Role: Teacher) in Group <g>.`,
   `User <userId> assigned to seat <n> in group <g>.`, `Avatar successfully spawned for user <userId> at seat <n>.`
   A student (PIN 0000) logs `Assigning role: student` and lands in its own role-restricted group
   (`Group 'Student Group|1' Creation => Succeeded: True, RoleRestriction: 30`, then `assigned to seat 1 in group 1.`).
   Teacher and students still see each other through `GlobalVisibilityRoles` (avatars-seats.md).
3. Fail on the client lines `Game server connection timed out after 10s.` or
   `Could not reach the game server after 3 attempts.`, and on the failure lines in `networking.md`
   (Recipe: local multiplayer smoke test).

The server line `Avatar is now owned by Client UserId: '' ... Role: 'Student'` is cosmetic, not a role bug (O, V).
`GroupParticipantTrait.OnStartServer` logs the prefab's default `UserDataModel` (`Role.Student`, group -1) before
`Configure` assigns the user. The later line `Assigning (Networked_Avatar(Clone)) => avatar to user ... Role: 'Teacher'`
shows the real data.

## Resolution order (first match wins; O)

| Where | Order |
|---|---|
| Before ACS reaches the env module (all players) | CLI > `EnvironmentVariables.json` > OS env > class default |
| Windows client/server profile module | CLI > `<exe dir>\EnvironmentVariables.json` > `<CWD drive>:\Deployment\system.xml` > OS env > default |
| Android profiles | JSON (never found under the APK) > CLI > env > default = effectively defaults only (RC-04) |
| Editor Play Mode | Unity.exe args > `<project>\EnvironmentVariables.json` > `<project>\override_files\system.xml` > editor env > default |

The default chain runs before the first ACS module (V: the F-29 exception precedes `Module SystemLogger initialized`).

Parsing (O):
- `-KEY value` is two argv tokens, case-sensitive, with any number of leading dashes; there is no `=` form (RC-02).
- The token after any `-flag` becomes its value: `-batchmode -nographics` stores `batchmode="-nographics"`, which is
  harmless.
- JSON booleans come back as `True`: write them as strings, `"true"` (RC-07).
- The JSON beats OS env, so `$env:DSL_*` loses to a stale JSON file (RC-03).
- `EnvironmentService.TrySetVariable` overrides do not stick (RC-06).
- `--PLATFORM WindowsServer` (exact case) selects the server profile in a player, so a client exe given it boots as
  a server.

## Key table (O; C client, S server, A Android/cart)

| Key | JSON path | Default | Side | Notes |
|---|---|---|---|---|
| `DSL_DREAMFISH_SERVER_IP` | `network-data.server-ip` | `localhost` (Server Configuration asset) | C+S | client dial target; the server binds it only when it starts with `10` and ends `.20` |
| `DSL_DREAMFISH_SERVER_PORT` | `network-data.server-port` | `8300` (asset) | C+S | must match on both sides |
| `DSL_CMS_ROOT_LOAD_PATH` | `cms-data.root-load-path` | none | any | inert until a `ContentManagementModule` is in the profile (RC-05); catalog = `<root>/<packId>/[<ver>/]<StandaloneWindows64,Android,StandaloneLinux64>/catalog.json` |
| `DSL_VOIP_SERVER_URL` | `voip.server-url` | `turn:10.95.204.6:49160` (vendor LAN, RTC settings asset) | S | the server sends it to clients; off-LAN use a `stun:` URL or keep the default (host candidates work on one LAN, I) |
| `DSL_VOIP_COMMUNICATION_PORT` | `voip.ports.communication-port` | `9045` | C+S | RTC LiteNetLib signalling, must match |
| `DSL_VOIP_AUDIO_MAX_BITRATE` | `voip.audio.max-bitrate` | uncapped | C+S | |
| `DSL_VOIP_LISTEN_PORT`, `DSL_VOIP_TLS_LISTEN_PORT`, `DSL_VOIP_RELAY_PORT_MIN`, `DSL_VOIP_RELAY_PORT_MAX` | `voip.ports.listen-port`, `.tls-listen-port`, `.relay-min-port`, `.relay-max-port` | 3478, 5349, 43160, 43400 | C | port-checker diagnostics only |
| `DSL_HCS_UNIVERSAL_CONTROLLER_IP` | `haptics.universal-controller-ip` | `10.1.1.20` (Haptics asset) | C | haptics retries 3 times, then gives up (V, harmless) |
| `DSL_HCS_UNIVERSE_SEAT_CLUSTER_PREFIX` | `haptics.universe-seat-cluster-prefix` | `Seat_` | C | |
| `DSL_DS_SERVER_IP`, `DSL_DS_SERVER_PORT`, `DSL_DS_UDP_PORT` | `dream-space.server-ip`, `.server-port`, `.udp-port` | `10.0.5.20`, `5001`, `9000` (code fields) | C | the template asset's 8087/8088 are orphaned (RC-12, PD-04): always pass these |
| `DSL_DS_TRACKED_USER` | `dream-space.is-tracked-user` | unset | C+S | string `true`/`false` only (RC-08) |
| `DSL_STATION_ID` | `dream-space.station-id` | `0` | C | free-roam calibration |
| `DSL_PLATFORM_HMD` | `platform.hmd` | default negotiator | C | effectively no effect (read too early, against an empty list) |
| `DSL_ENABLE_AUTO_LOGIN`, `DSL_PIN` | `session-management.enable-auto-login`, `.pin` | off, `0024` | C, A | see Login |
| `DSL_POD_DSL_LINK_URL`, `_DIST_LINK_URL`, `_DSL_LINK_KEY`, `_POD_ID`, `_STATION_ID` | `session-management.pod.*` | none | C | normally from `system.xml`; absent on dev PCs, so the pod backend fails (normal, Known-benign) |
| `DSL_CART_APP_IDENTIFIER`, `_HINT_ENDPOINT`, `_CONFIG_ENDPOINT` | `session-management.cart.*` | `Application.identifier`, `http://hint.dreamscapelearn.com`, from hint | A | a successful cart app-get overwrites the server address |
| `DSL_DREAM_CENTRAL_ENDPOINT` | `dsl.endpoints.dream-central` | `http://localhost:8089` | C | aether-canvas single-player login widget |

Dead keys: `DSL_DREAM_POD_ENDPOINT`, `DSL_POD_HMD_LINK_URL`, `DSL_POD_OVERRIDES_ENABLED`,
`DSL_HCS_UNIVERSAL_CONTROLLER_PORT` (RC-15). Reading keys from your own code: `architecture.md`.

## Config files

- `EnvironmentVariables.json` lives next to `experience.exe` (player) or at the project root (editor).
  - The template copy under `Assets/Application/EnvironementVarsReference (Include With Build)/` is not copied into
    builds (TB-36).
  - V: a player logs `[EnvironmentManagement|Info]: Environment Variable File path: <exe dir>\experience_Data\..\EnvironmentVariables.json`.
    With no file it logs `[EnvironmentManagement|Warn]: File not found: <path>`, which is normal.
  - A file that fails to parse is reported only at Info: `Failed to parse JSON data:` (O).
  - Validate before use: `Get-Content -Raw -Encoding utf8 <file> | ConvertFrom-Json`.
  - Project Configurator "Publish to Project Root" writes broken JSON for nested keys (RC-09), so hand-write it.
- `system.xml` lives at `<CWD drive>:\Deployment\system.xml`. It is pod-only, so remove strays from dev drives (RC-11).
- `Assets/StreamingAssets/specialFiles/experience_config.xml`: `ExperienceName` is the Dev Deploy identity.

## Content server (CMS packs)

Serve `<root>\Content\<packId>\<Target>\catalog.json` with python, stdio redirected (the launcher's undrained pipes
can stall it, LR-10, I):

```powershell
Start-Process python -ArgumentList '-m','http.server','8083','--bind','127.0.0.1','--directory','<root>' `
  -RedirectStandardError '<logs>\cms.err.log' -RedirectStandardOutput '<logs>\cms.out.log' -WindowStyle Hidden
```

Done: `Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 http://127.0.0.1:8083/Content/<packId>/StandaloneWindows64/catalog.json`
returns 200. The DDK installs no Python (F-15). For a headset, use `--bind 0.0.0.0` and the PC's LAN IP.

## Android headset

No runtime injection path ships (RC-04). In order:
1. Change the LocalJson resolver `_basePath: 0` to `_basePath: 1` (persistent data) in
   `Assets/Application/Modules/Android/EnvironmentManagementModule Android Client.asset` and rebuild. Then run
   `adb push EnvironmentVariables.json /sdcard/Android/data/<appId>/files/` and restart the app (I).
   Done: `adb logcat -s Unity` shows `Setting the Server IP address to <PC LAN IP>`.
2. Or bake the PC LAN IP into `Assets/Application/Configs/Server Configuration.asset` for a dev build.
3. Allow inbound UDP game port, UDP 9045 and TCP 8083 in Windows Firewall.

Offline, the cart backend logs `SessionRuntime: hint initialization failed` (O); the bypass codes still work. A
successful cart app-get overwrites the server address (networking.md, Session-runtime backends).

## Experience Launcher (prefer the PowerShell route above)

It passes CLI args only (its env-var map is dead code). The defaults are `localhost`, `8300` and
`http://localhost:8083/Content`. Settings live in `%LOCALAPPDATA%\dreamscape_learn\dream_launcher\save_data\*.json` (I).
If you have to use it:
- Never put `-DSL_*`, `-batchmode` or `-nographics` in custom args, because they duplicate keys (LR-03, then RC-01).
- Keep spaces out of paths and arg values: args are split on single spaces (LR-04).
- Re-press Enter on client custom args before each Start Client: only the first client gets them (LR-02). Every
  client gets the same args, so per-client PINs are impossible (LR-21).
- The CMS URL can't be set in the UI, and editing IP or port nulls it (LR-01). Edit `environment.json` with the
  launcher closed.
- Custom server args are lost on every restart (LR-05).
- "Running" never notices a crash (LR-07). Toggle the switch, or check the PID.
- Stop is a hard kill, and children outlive a launcher crash (LR-08):
  `Get-Process experience,python -ErrorAction SilentlyContinue | Stop-Process -Force`.
- Process stdout is discarded (LR-09), so use `-logFile`. The server inherits the launcher's install dir as its CWD
  (LR-06).
- The content server needs `python` on PATH; a Store-alias python exits while the UI shows Running (LR-11).
- Pick `experience.exe` with a lowercase `.exe`; an uppercase `.EXE` hides the controls (LR-13).

## Pod reference (production args DreamStation passes; O)

- Server, or any host whose IP ends `.20`: `--PLATFORM WindowsServer -nographics -batchmode` first.
- Everyone: `-DSL_VOIP_SERVER_URL turn:<S>:49160`, `-DSL_DREAMFISH_SERVER_IP <S> -DSL_DREAMFISH_SERVER_PORT 9000`,
  `-DSL_CMS_ROOT_LOAD_PATH http://<S>:8083/Content`, `-DSL_HCS_UNIVERSAL_CONTROLLER_IP <S>`, the dead
  `-DSL_HCS_UNIVERSAL_CONTROLLER_PORT 8086`, `-DSL_DS_SERVER_IP <S> -DSL_DS_SERVER_PORT 8087 -DSL_DS_UDP_PORT 8088`
  and `-DSL_STATION_ID <id>`.
- `-DSL_DS_TRACKED_USER true` is added for a station id ending `99` when the feature flag `walk_around_professor` is
  on, and for every station when `free_roam_experience` is on. With both flags, a `99` station gets the key twice: an
  RC-01 trigger on unpatched builds.
- `<S>` is the pod's `x.y.z.20`: one /24 per pod, `.10` is the controller. DreamStation starts the exe elevated
  (`runas`) in its own folder. Pod values (`DSL_POD_*`) come from `system.xml`.

## Known-benign log noise (V)

`scripts/ddk_log_triage.py` tags the first two exceptions, and the second-client `SocketException` below, as benign.
Keep its `BENIGN` list in sync with this section.
- `ArgumentOutOfRangeException: Specified argument was out of the range of valid values.`, once at headless client
  boot. The stack is the template's XR Interaction Toolkit 3.1.2 sample `XRDeviceSimulatorUI.Initialize` (V in four
  headless client logs). It reads `action.controls[0]` while no input device exists (I).
- `ObjectDisposedException: The CancellationTokenSource has been disposed.` from UniTask `PlayerLoopTimer`, once
  after a successful connect (F-32). It is a real but harmless session-runtime defect (O):
  `DreamscapeSession.TryConnectAsync` discards the timer from `CancelAfterSlim(10 s)` and disposes the token source
  when the attempt ends early. When the timer fires, it calls `Cancel()` on the disposed source. If you embed
  session-runtime, keep that timer in a `using` declared after the token source.
- `SocketException: Address already in use` at `DefaultHttpTransport.StartListening` on the second client on one
  PC: Dream Connect 8085 is already taken (NW-06; V, F-33 `two-client2-student.log`).
- `[Dream Connect|Error]: [DefaultUdpTransport] StartListening failed: System.FormatException: An invalid IP address was specified.`
  (NW-06). `ConnectedUdpTransport` raises it, despite the prefix.
- `Failed to connect to haptic universe controller after 3 tries` (no pod hardware).
- `[EnvironmentManagement|Debug]: Failed to resolve variable: <KEY>` for every unset key.
- `File not found: ...EnvironmentVariables.json` (Warn) when no JSON sits next to the exe.
- `PodBackendService: neither system.xml nor EnvironmentManagement gives both service URLs`, then
  `[SessionRuntime|Error]: SessionRuntime: initialization failed, so the session has no configuration to run on.`
  (Windows client, no pod backend).
- `XRHandSubsystem not found! ... (This can be ignored in Desktop Mode)` (Warn, repeated).
- `Curl error 6: Could not resolve host: cdp.cloud.unity3d.com` (Unity services, offline PC).
- `AssetPathHash is not set for GameObject Networked_Avatar.` once per process (template baseline,
  `networking.md` NW-31).
- At build time: `Duplicate assembly 'System.Runtime.CompilerServices.Unsafe.dll' with different versions detected`.
