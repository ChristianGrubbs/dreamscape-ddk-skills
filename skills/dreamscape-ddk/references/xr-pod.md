# XR platform, pod hardware, pod services

How a DDK experience reaches a headset (OpenXR features, hand input, Android manifest, desktop mode), what a
classroom pod really runs, and how to run or stub each pod service on a dev PC. Tags: **V** verified by running
a 6000.3.2f1 build on this machine, **O** observed in vendor code or shipped config, **I** inferred. PD- IDs and
R1-R4 index the evidence in `<re>\notes\70-platform-devices-pod-services.md`, TB-
in `10-templates-and-build.md`, F- in `05-lead-findings.md`, NW- in `networking.md`. V player lines come from
`_re\runtime\logs\e2e2-client-teacher.log` (headless MP client, no HMD); V service config from the Dev Deploy
output `_re\runtime\builds\MP\SDK\`. Builds: `build.md`. Player launch, `DSL_*` keys and login:
`runtime-config.md`. Rig simulator and content: `experience-authoring.md`. Seats, avatars and IK: `avatars-seats.md`.

## Recipe: Quest (Android) build

1. Personalise per `build.md` section 2: unique `applicationIdentifier` (V: an untouched template APK is
   `dev.dreamscapelearn.icstarterpack01` and overwrites another product, TB-06) and MP `InitManagerOnStart: 0` (TB-32).
2. OpenXR, Android block of `Assets/XR/Settings/OpenXR Package Settings.asset`: `DreamHandTracking`,
   `HandInteractionProfile`, `HandCommonPosesInteraction` on; `MetaQuestFeature`, `OculusQuestFeature` and Unity
   `HandTracking` off (PD-02). Controllers are optional: enable `OculusTouchControllerProfile` only if needed.
   Project Validation then shows zero errors; leave its Android "enable Hand Tracking" warning unfixed (PD-02).
3. Manifest: post-Gradle `ManifestInjector` writes `Assets/Settings/ManifestInjectorSettings.asset` entries into
   every Unity activity (SP also ships a custom manifest). V (`aapt2 dump badging` of the built APK): arm64-v8a,
   minSdk 32, targetSdk 36, INTERNET present, launchable `com.unity3d.player.UnityPlayerActivity`, meta-data for
   Quest (`com.oculus.supportedDevices` quest2|questpro|quest3|quest3s, `com.oculus.intent.category.VR`), Pico
   (`pvr.app.type vr`) and Wave (`com.htc.vr.enable_handtracking`). **Required** features (V):
   `oculus.software.handtracking` (its injector entry has `HasRequired: 0`, so no attribute = required),
   `wave.feature.handtracking` (`Required: 1`), `android.hardware.bluetooth` (implied by the injected
   `android.permission.BLUETOOTH`) and `android.hardware.vulkan.version`.
4. Quest-only store builds: in the injector asset set the Wave entry `Required: 0`, and drop the BLUETOOTH
   permission or add `android.hardware.bluetooth` with `HasRequired: 1, Required: 0` (TB-45; stores filter on
   required features, I). Merged permissions also include CAMERA, RECORD_AUDIO, MODIFY_AUDIO_SETTINGS, AD_ID,
   ACCESS_ADSERVICES_*, BILLING, WAKE_LOCK, RECEIVE_BOOT_COMPLETED, FOREGROUND_SERVICE (V): strip what your store
   rejects (`SKILL.md` step 3 removes the ads and purchasing packages). Done = `aapt2 dump badging <apk>` shows
   `wave.feature.handtracking` under `uses-feature-not-required` and no required `android.hardware.bluetooth`.
5. Runtime config: defaults only (`runtime-config.md`, Android headset), and no Vicon or haptics devices, so an
   APK is **untracked** by design.
6. Build: `scripts/run-ddk-build.ps1 -Step Android -Out <dir>\experience.apk` (`build.md` sections 3 and 5; V).
7. `adb install -r <dir>\experience.apk`, `adb shell am start -n <id>/com.unity3d.player.UnityPlayerActivity`,
   `adb logcat -s Unity`. Turn hand tracking on in the headset settings.
8. Done when logcat shows `Starting XR...` (XR Platform Initialization, Trace) and none of `Initializing XR
   Failed.`, `Failed to find descriptor 'DreamHandTrackingSubsystem'` or repeating `XRHandSubsystem not found!`.
   `Registering DreamHandTrackingSubsystem` prints in every player, the server included (V), so it proves nothing
   about XR. On-device immersive start is unverified (I).

## Recipe: PC VR (OpenXR on Windows)

1. Runtime: the pod reference is VIVE Focus 3 + VIVE Business Streaming (VBS) + SteamVR set as the OpenXR
   runtime. Any runtime exposing `XR_EXT_hand_tracking` should work (I).
2. Hands over VBS need the VBS hand-tracking implicit API layer, an HKLM system setting that the pod's
   `SDK\rv_start.bat` writes (V: the built `SDK\rv_start.bat` carries this line). Hand this exact command to the
   operator to run once as admin (PD-22):
   ```
   REG ADD "HKEY_LOCAL_MACHINE\SOFTWARE\Khronos\OpenXR\1\ApiLayers\Implicit" /v "C:\Program Files\VIVE Business Streaming\OpenXR\ViveVR_openxr\ViveOpenXRHandTracking\ViveOpenXRHandTracking.json" /t REG_DWORD /d 0 /f
   ```
   `SDK\start.bat` (calls `rv_start.bat`) and `rv_start.bat` stay operator tools: they write HKLM and start
   DreamStation.
3. OpenXR Standalone block as shipped; a controller-only dev headset needs one controller profile, `HandTracking` off.
4. Editor: toolbar Desktop Mode **off**, Play `Assets/Application/Application.unity`; the Console stays free of
   `Initializing XR Failed.` and the headset shows the scene.
5. Build `-Step WindowsClient` into the Dev Deploy root (`build.md`), giving `<root>\Experience\Client\experience.exe`.
6. Launch through `scripts/start-ddk-player.ps1` (`runtime-config.md`) with explicit device args, e.g. untracked
   against local stubs: `-PlayerArgs ($net + @('-DSL_DS_TRACKED_USER','false','-DSL_HCS_UNIVERSAL_CONTROLLER_IP',
   '127.0.0.1'))`, `$net` as in `runtime-config.md`.
7. Done when the player log has `Starting XR...` and no `Initializing XR Failed.`: the module reports success
   either way (PD-20, V).

## Recipe: desktop, no HMD

1. Editor: main-toolbar "Toggle Desktop Mode" on (EditorPrefs bool `Dreamscape DevKit/Desktop Mode Toggle`).
   `XRInitializationModule` skips XR and the rig spawns the XR Device Simulator.
2. Player: with no OpenXR runtime the simulator path runs by itself. V, in this order: `[XRHost|Trace]: Setup
   begin: DesktopSimulatorTrait` (rig setup in PlayerScene, before XR init), `[XR Platform Initialization|Error]:
   Initializing XR Failed.`, `Module XRInitializationModule initialized`; the trait then instantiates the XR Device
   Simulator, whose UI throws one `ArgumentOutOfRangeException` in `XRDeviceSimulatorUI.Initialize` under
   `-batchmode` (benign). Expect repeated `[XR Platform|Warn]: XRHandSubsystem not found! ... (This can be ignored
   in Desktop Mode)`. With a runtime installed, fail the loader for one process (I, Khronos loader): set
   `$env:XR_RUNTIME_JSON = 'C:\no-such-runtime.json'`, then call `start-ddk-player.ps1` from the same shell (it
   passes the environment on).
3. Boot time: `DeviceIntegrationService` takes 6.4-9.4 s (V, four runs) because haptics pings `10.1.1.20:11000`
   three times, then tries the HTTP audio stream on 8086 three times (V: two `Failed to connect to haptic universe
   controller after 3 tries.` lines); harmless on a dev PC. To cut it, untick `Activate` for the three
   haptic devices in `Assets/Application/Modules/Windows/Device Integration Module Windows Client.asset`, or run the
   HUC stub and pass `-DSL_HCS_UNIVERSAL_CONTROLLER_IP 127.0.0.1`.
4. Leave `DSL_DS_TRACKED_USER` unset so Vicon devices idle. Done (V): `[DreamSpace|Info]: Tracking Network
   Configuration indicates no tracked user. Skipping Vicon Routing Server initialization.` and `[DreamSpace|Debug]:
   Missing tracked user environment variable, SimulatedPelvis will initialize as seated.` Editor device states:
   menu `Dreamscape DevKit/Device Integration`. Headless login and IK limits: `avatars-seats.md`, Headless clients.

## Recipe: local classroom-pod rehearsal, one PC (R4) [I: assembled from code; end to end never run]

Real VRS in debug mode, a HUC stub, optional real DreamStation + Hostess; coturn, Q-SYS, HmdLink and DistLink
stay off without Docker and `system.xml`. Ports, all `127.0.0.1`: DreamStation 8080, CMS 8083, Unity Dream Connect
8085, HUC stub 8086 + UDP 11000 + UDP 10000-10099, VRS 8087 + UDP 8088, VRS pose injection UDP 8089, FishNet 9000,
Unity HCS local UDP 12000.
1. Before building the client, edit `Assets/Application/Devices/HapticsNetworkConfiguration.asset`:
   `_getClusterIdFromIpAddress: 0`, `_clusterId: 1` (PD-07), and an `_audioDeviceType` your stub accepts (PD-51).
   Build server and client into one root (`build.md`).
2. Content server per `runtime-config.md` (Content server).
3. VRS: copy `<root>\SDK\bin\Vicon\` (holds `publish\` and the classroom `TempData\`, V) to `D:\pod-sim\Vicon\`.
   Needs the VC++ 2015-2022 x64 runtime (PD-73). In its own terminal:
   ```
   Set-Location D:\pod-sim\Vicon\publish
   .\ViconRoutingServer.exe --NetworkOptions:FallbackIp=127.0.0.1 --Vicon:Mode=debug --Vicon:Host=8089
   ```
   Smoke: `Invoke-RestMethod http://127.0.0.1:8087/api/podLayout` -> `status: true`, 4.3 x 3.5 x 2.4384 m (the
   TempData values are V; the response is I).
4. HUC stub: save as `D:\pod-sim\huc_stub.py`, run `python -I D:\pod-sim\huc_stub.py` (protocol: note 70 s3.5).
   V (loopback self-test, synthetic packets in the Unity `UdpMessage` layout): Ping -> 67-byte Pong (byte 0 = 6),
   a Set prints `CMD Set cluster=Seat_1 device= type=HapticFan value=0.500 ctl=0 ramp=0.00s`, `openStream` ->
   port 10000, `openStream/multi` -> 10001 + ids, 48000 samples -> `AUDIO port 10000 samples 48000`,
   `closeStream` -> `Port released`. Not yet run against a Unity client.
   ```python
   # huc_stub.py - HapticUniverseController stand-in: UDP 11000 commands, HTTP 8086, audio sinks 10000-10099
   import json, socket, struct, threading
   from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
   from urllib.parse import urlparse, parse_qs
   HOST, NAMES, next_port = '127.0.0.1', {0: 'Set', 1: 'Ramp', 2: 'Stop', 3: 'Play', 4: 'Pause', 5: 'Ping'}, [10000]
   def field(b, a, z): return b[a:z].split(b'\0')[0].decode('ascii', 'replace')
   def udp_commands():
       s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((HOST, 11000))
       while True:
           try: b, addr = s.recvfrom(2048)
           except OSError: continue                                   # WSAECONNRESET after a peer exits
           if b and b[0] == 5: s.sendto(bytes([6]) + bytes(66), addr)  # Ping -> 67-byte Pong
           elif len(b) >= 42:                                          # 67-byte command, layout s3.5
               v, = struct.unpack_from('<H', b, 31); r, = struct.unpack_from('<f', b, 34)
               print('CMD %s cluster=%s device=%s type=%s value=%.3f ctl=%d ramp=%.2fs' % (NAMES.get(b[0], b[0]),
                     field(b, 1, 11), field(b, 11, 21), field(b, 21, 31), v / 1000, b[33], r), flush=True)
   def audio_sink(port):                                               # 24-bit LE mono PCM, no header
       s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((HOST, port)); total = 0
       while True:
           n = len(s.recvfrom(65535)[0]) // 3
           if (total + n) // 48000 != total // 48000: print('AUDIO port', port, 'samples', total + n, flush=True)
           total += n
   def allocate():
       if next_port[0] > 10099: return -1
       p = next_port[0]; next_port[0] += 1
       threading.Thread(target=audio_sink, args=(p,), daemon=True).start(); return p
   class Api(BaseHTTPRequestHandler):
       def do_GET(self):
           u = urlparse(self.path); path = u.path.rstrip('/').lower(); ok = {'status': True, 'code': 200}
           if path == '/api/audiostream/openstream': body = dict(ok, message='Port allocated', port=allocate())
           elif path == '/api/audiostream/openstream/multi':
               body = dict(ok, message='Port allocated', port=allocate(), ids=parse_qs(u.query).get('deviceId', []))
           elif path.startswith('/api/audiostream/closestream/'): body = dict(ok, message='Port released')
           else: body = {'status': False, 'code': 404, 'message': 'not stubbed'}
           data = json.dumps(body).encode()
           self.send_response(200); self.send_header('Content-Type', 'application/json')
           self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
   threading.Thread(target=udp_commands, daemon=True).start()
   ThreadingHTTPServer((HOST, 8086), Api).serve_forever()
   ```
5. Unity server and seated student client, station 01, through `scripts/start-ddk-player.ps1`, with `$S`, `$C`,
   `$L`, `$net` as in `runtime-config.md` (Local server + clients). Always pass the DS ports (PD-04); add its Login
   args, and `XR_RUNTIME_JSON` from the desktop recipe for a no-HMD run:
   ```powershell
   $pod = @('-DSL_CMS_ROOT_LOAD_PATH','http://127.0.0.1:8083/Content','-DSL_HCS_UNIVERSAL_CONTROLLER_IP','127.0.0.1',
            '-DSL_DS_SERVER_IP','127.0.0.1','-DSL_DS_SERVER_PORT','8087','-DSL_DS_UDP_PORT','8088')
   & scripts\start-ddk-player.ps1 -Exe $S -LogFile "$L\server.log" -PlayerArgs (@('--PLATFORM','WindowsServer','-batchmode','-nographics') + $net)
   & scripts\start-ddk-player.ps1 -Exe $C -LogFile "$L\st01.log" -PlayerArgs ($net + $pod + @('-DSL_STATION_ID','01'))
   ```
6. Tracked instructor (optional): `-PlayerArgs ($net + $pod + @('-DSL_STATION_ID','99','-DSL_DS_TRACKED_USER','true'))`
   (each key once, RC-01), started >= 2 s after any other instance (PD-71). Feed poses with
   `python -I D:\pod-sim\vicon_inject.py`; names match `TempData\SubjectData.json` (V: the 7 names below) and the
   template `TrackedUser.asset`, and the jitter beats the 6 s stillness rule (PD-76). V: a one-subject frame from
   these helpers equals the documented GetTracking reply (note 70 s3.6) byte for byte; not yet run against VRS.
   ```python
   # vicon_inject.py - raw MessagePack TrackingDataResponse [true, [[name,[x,y,z],[x,y,z,w]], ...]] to VRS debug port
   import math, socket, struct, time
   def mp_str(x): b = x.encode(); return (bytes([0xa0 | len(b)]) if len(b) < 32 else bytes([0xd9, len(b)])) + b
   def mp_f32(v): return b'\xca' + struct.pack('>f', v)
   def sample(n, p, r): return b'\x93' + mp_str(n) + b'\x93' + b''.join(map(mp_f32, p)) + b'\x94' + b''.join(map(mp_f32, r))
   POSES = {'Head_DF301_Red1': (0, 1.2, 0), 'HandL_DHF01_Red1': (-0.2, 0.9, 0.3), 'HandR_DHF01_Red1': (0.2, 0.9, 0.3),
            'FootL_DHF01_Red1': (-0.1, 0.05, 0), 'FootR_DHF01_Red1': (0.1, 0.05, 0),
            'DSL_Desk_Var01_01': (0, 0.75, 0.6), 'DSL_Chair_Var01_01': (0, 0.45, -0.2)}
   s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); t = 0.0
   while True:
       j = 0.002 * math.sin(t)
       body = b''.join(sample(n, (x + j, y, z), (0, 0, 0, 1)) for n, (x, y, z) in POSES.items())
       s.sendto(b'\x92\xc3' + bytes([0x90 | len(POSES)]) + body, ('127.0.0.1', 8089)); t += 0.05; time.sleep(1 / 60)
   ```
   Poses land only on subjects a client activated. In-Unity alternative: DS `DebugViconSender` (127.0.0.1:8089).
7. DreamStation + Hostess (optional): copy only the files of `<root>\SDK\bin` (no subfolders, so the supervisor
   finds nothing to launch) to `D:\pod-sim\SDK\bin`, and blank `DistlinkApi.ApiKey` in the copied
   `appsettings.json` (PD-32). Then from that folder:
   ```
   $env:override_settings_enabled = 'true'                        # shipped overrides.ActiveProfiles = [Server] (V)
   $env:Kestrel__Endpoints__Http__Url = 'http://127.0.0.1:8080'   # code UseUrls ignores --urls (PD-38)
   .\DreamStation.exe
   ```
   Hostess: copy the whole `<root>\SDK\bin\Hostess\` folder and run its `dream_hostess.exe` (V config `testIp
   127.0.0.1`, `port 8080`, `allowDebugLoopback true`; whether it targets loopback is I).
8. Done when: VRS logs `[HELLO] ... => token=`; the stub prints `CMD Set cluster=Seat_1 ...`; the client logs
   `Successfully connected to Universe Controller DMX at 127.0.0.1:11000`; the tracked instructor logs
   `Pod Layout retrieved successfully:`.
9. One client per PC gets haptics and Dream Connect (UDP 12000, `+:8085`, PD-08, NW-06); more stations need more PCs.

## XR platform service

- `XRInitializationModule` (ACS) waits for XR Management, calls `InitializeLoader()` + `StartSubsystems()` and
  **always reports success**; read `XRActiveAndInitialized` or the log lines instead (PD-20, V). Editor Desktop
  Mode skips XR. Shutdown waits 500 ms for SteamVR.
- One `XROriginHost` per process (`PlatformCore.RegisterHost` throws on a second). Use the template rig
  `Assets/Samples/XR Interaction Core/Full Stack Interaction Rig/Prefabs/XrRigParentInteraction.prefab`; the XPS
  `XR Origin.prefab` has no origin and no traits (PD-06). Rig traits in order (V `Setup begin:` lines):
  DesktopSimulator, CameraFade, TrackedLimb, SimulatedPelvis, TrackedPod, ChairConstraint from the prefab, then
  `CameraFeedBroadcasterTrait` (real-time-communication camera feed), which the template PlayerScene adds as a
  prefab override. Done = `XROriginHost(XrRigParentInteraction) initialized.`
- **Hand-only input.** Both targets enable `DreamHandTracking` (a copy of Unity's XR Hands OpenXR feature, ext
  `XR_EXT_hand_tracking`), `HandInteractionProfile`, `HandCommonPosesInteraction`; every controller profile is off.
  Per frame the subsystem runs a *tracked* negotiator when OpenXR reports joints (rescale, headset joint profile,
  Vicon corroboration) and an *untracked* Vicon-only negotiator when it does not. XR Hands resolves to 1.7.3 (V,
  generated project lock), which lacks `XR_HANDS_1_8`, so the subsystem advertises no aim/pinch/poke/grip poses:
  read poses from `HandInteractionProfile` (PD-18). The negotiator assets serialize DreamSpace types: keep
  dream-space installed (PD-03).
- **Headset chosen by build target.** Standalone default negotiator = Vive Focus 3 joint profile; Android = Pico 4
  UE profile (PD-23); the Android manifest targets Quest 2/Pro/3/3S, Pico and HTC Wave; no vendor OpenXR plugin
  package is installed. **`DSL_PLATFORM_HMD` is effectively dead** (PD-01): templates ship
  `TrackedNegotiators: []`, and the lookup runs at SubsystemRegistration, before `DSL_*` variables resolve.
- Validator rules beyond `build.md` section 10: `InitManagerOnStart = 0` on both targets; layers 28-31 = Invisible,
  XR Hand, XR Simulation, Teleport; `Assets/XR/Resources/XR Platform Settings.asset` must exist (loaded by name,
  no null check). Warnings: Vulkan first, GLES3 second, ASTC, multithreaded, landscape-left, no HDR.

## Pod reality

- **Classroom pod = PC VR.** Each seat PC runs the Windows client and streams to a VIVE Focus 3 through VBS, with
  SteamVR as OpenXR runtime; DreamStation's Client profile starts VBS `RRConsole.exe` and SteamVR.
- **Vicon and haptics are Windows-only**: only the Windows client profile registers them. The Android profile
  has joysticks and virtual input only; the server profile has no XR or device modules (PD-11, V for the server).
- **Who is tracked**: DreamStation adds `-DSL_DS_TRACKED_USER true` only for a station id ending `99` with feature
  flag `walk_around_professor`, or with `free_roam_experience` (`SDK\feature-flags.json`, both false as shipped,
  V). Seated students are HMD-only.
- **IP roles (the .20 rule)**: one /24 per pod; last octet `.20` = server (DreamStation Server, Unity server,
  VRS, HUC, coturn, Hostess), `.10` = controller (Hostess), anything else = seat client. VRS and HUC bind the
  first `10.x.x.20` address; template assets use `10.0.5.20` (VRS) and `10.1.1.20` (HUC); the DMX node is `.25`.
  Shipped app lists (O): Server = HUC, TurnServer, VRS, both Unity servers, Hostess; Client = both Unity clients;
  Controller = Hostess.

| Owner | Ports (server PC unless noted) |
|---|---|
| DreamStation | 8080 HTTP API (Hostess is the client); 8100 UDP experience events |
| Unity | 9000 UDP FishNet server; 8085 HTTP Dream Connect (`+:8085`, every instance); 12000 UDP HCS local (each client) |
| HUC | 8086 HTTP audio-stream API; 11000 UDP commands; 10000-10099 UDP audio in; 6454 UDP Art-Net out to the DMX node |
| VRS | 8087 HTTP layout/associations; 8088 UDP subject stream; client of TCP 801 (Vicon DataStream) and 52800 (Evoke) |
| Other | 8083 HTTP CMS content; 49160 TURN (coturn); 1702 TCP / 5560 UDP Q-SYS heartbeat / fire alarm |

O: the shipped DreamStation `appsettings.json` lists 8080, 8085, 8086, 11000, 8087, 8088, 8100, 1702 and 5560.

## Dream Space and tracking

- Dream Space is the Unity client of VRS: HTTP pod layout and station associations, UDP MessagePack subject
  stream, Vicon Core command bus, plus calibration and negotiators fusing Vicon with the HMD.
- **Untracked is the default.** `DSL_DS_TRACKED_USER` must be the string `true` (or `_overrideTrackedUser` set),
  otherwise the VRS handler never starts and every Vicon trait early-returns (V lines in the desktop recipe).
- **The PD-04 port trap.** `TrackingNetworkConfiguration.asset` stores `_serverAddress/_serverPort/_udpPort`
  (8087/8088), the code fields are `ServerAddress/ServerPort/UDPPort`, so code defaults win: `10.0.5.20`, HTTP
  **5001**, UDP **9000** (the FishNet port). DreamStation masks it by passing 8087/8088. Always pass
  `-DSL_DS_SERVER_IP/_PORT/_UDP_PORT`, or re-enter the values in the inspector and save the asset.
- `DSL_STATION_ID` is compared as a string with VRS associations: `01`, not `1`. Classroom data maps station `01`
  to `Head_DF301_Red1` (V, built TempData); subject names must equal VRS `SubjectData.json` and `TrackedUser.asset`.
- Handshake: Ping -> Hello (token) -> RequestByName head, hands, feet (+ desk, chair seated) -> GetTracking at 90 Hz
  -> ReleaseAll on stop. Poses stay valid 500 ms after a change, 6 s unchanged. Wire layouts: note 70 section 3.6.

## Device integration and haptics

- Devices are ScriptableObject assets in the per-platform `Device Integration Module`, started one by one and
  awaited, so hardware timeouts add up (PD-09, desktop recipe step 3). A missing asset in that list throws at boot
  (PD-10): keep `Assets/Samples/XR Platform Service/1.6.1/` and the Joystick sample. Play mode mutates the assets (PD-14).
- HCS client: UDP commands from local 12000 to `<HUC>:11000` (Ping/Pong handshake, then fire-and-forget 67-byte
  messages), audio via `GET /api/audioStream/openStream` on 8086 then raw 24-bit PCM to the returned port.
  Only the IP has a variable (`DSL_HCS_UNIVERSAL_CONTROLLER_IP`); ports live in `HapticsNetworkConfiguration.asset`
  (PD-05). Wire format: note 70 section 3.5.
- **Seat cluster** = prefix `Seat_` + (last octet of the first IPv4 - 30). V: this dev PC computed `Seat_110`
  (PD-07). Pin the seat with `_getClusterIdFromIpAddress: 0` + `_clusterId`.
- **Device type names disagree** (PD-51): server classroom devices are `HapticButtkicker` (V: 32 in the built
  `DeviceData.json`), server TypeData and Unity UDP use `Buttkicker`, Unity streaming asks for `HapticButtkicker`
  (V: `... with cluster Seat_110 and device type HapticButtkicker.`). Align all three.

## Pod services

Building a client into the Dev Deploy layout copies DreamStation, Hostess, Vicon, Universe and turnserver into
`<root>\SDK\bin` (V; `DreamStation.exe` 114,486,993 bytes), set to the classroom variant (V: HUC `PodMode: Seated`,
VRS station `01`). DreamStation launches each app relative to its CWD `SDK\bin`, Unity from `..\..\Experience\...`.
- **DreamStation** (.NET 10, single file, Debug build): pod-PC supervisor and HTTP hub on 8080. Role from the IP
  (.20 rule); launches and restarts Unity, HUC, VRS (`runas`), coturn (only if Docker answers) and Hostess; proxies
  Hostess to stations (8085), VRS and HMDs; Q-SYS fire-alarm watchdog. Dev PC: rehearsal step 7. Unity never calls it.
- **HapticUniverseController** (.NET 9): HTTP 8086, UDP 11000, audio 10000-10099, Art-Net to DMX. It binds UDP
  11000 first, then **blocks forever** until service `dvs.manager` and the "Dante Virtual Soundcard (x64)" ASIO
  driver exist (PD-50). Dev PC: the stub. With DVS installed, from `publish\` (reads `..\TempData\`):
  `HapticUniverseController.exe --PodMode=Seated --NetworkOptions:FallbackIp=127.0.0.1 --NetworkOptions:BindPort=8086`.
- **ViconRoutingServer** (.NET 9): HTTP 8087, UDP 8088; client of Vicon DataStream (`localhost:801`) and Evoke
  (`127.0.0.1:52800`), retrying quietly when absent. Dev PC: real, debug mode (rehearsal step 3). Unity calls only
  `GET /api/podLayout`, `/api/associations`, `/api/pulsars/all-pulsars` (probe), `POST /api/subjects/enable-all|disable-all`.
- **Hostess** (Flutter release build): operator UI. Talks to DreamStation 8080, directly to VRS 8087/8088, and to
  station WebRTC signalling from 8090. Configure only through `data\flutter_assets\assets\config\app_config.json`.
- **turnserver**: `setup-coturn.bat` clones a GitHub repo and runs `docker compose` with hardcoded TURN
  credentials (TB-22). Off-pod use a `stun:` URL or the default (`runtime-config.md`, VoIP key).

## Security notes (exposure and mitigation)

- DreamStation serves 76 anonymous HTTP routes with CORS for any origin, including machine-reboot and
  process-control routes, and off-pod it binds `0.0.0.0:8080` (PD-30). Mitigation: run it only on an isolated pod
  network; on a dev PC bind loopback with `Kestrel__Endpoints__Http__Url` (I) and keep 8080 closed in the firewall.
- VRS and HUC ship `FallbackIp 0.0.0.0` (O, built SDK copies) and have no authentication; VRS decodes network MessagePack with a
  contractless resolver (PD-79). Mitigation: `--NetworkOptions:FallbackIp=127.0.0.1` on dev PCs, isolated pods.
- Shipped secrets, written here as `<REDACTED>`: DreamStation `appsettings.json` `DistlinkApi.ApiKey`, GitLab CI
  tokens in 29 `package.json` files, TURN credentials in `setup-coturn.bat`. Blank them in copies; quote no values.
- DreamStation's `runas` launches re-prompt UAC every 5 s when declined (PD-34), and stopping an app kills
  **every** process with that exe name, your own `experience.exe` included (PD-35). The rehearsal copy holds no
  managed exes, which avoids both.

## Defects, ranked (dev-PC impact; pod-only noted)

| id | sev | symptom | fix |
|---|---|---|---|
| PD-50 | blocker | HUC never serves HTTP | HUC stub |
| PD-73/74 | blocker | VRS exits at start (`DllNotFoundException`, port in use, bad TempData, non-numeric debug `Vicon:Host`) | VC++ x64 runtime; keep `publish\Integrations\`; free 8087/8088; validate JSON |
| PD-04 | high | Unity dials VRS on 5001 / 9000 | Pass the three `DSL_DS_*` keys |
| PD-07 | high | Haptics address the wrong seat (`Seat_110` here, V) | Asset `_clusterId` |
| PD-31 | high | DreamStation on a dev PC picks Client, starts VBS/SteamVR, posts to `<subnet>.20` | `override_settings_enabled=true` (Server) |
| PD-30/34 | high | LAN-reachable reboot and process control; endless UAC prompts | Security notes |
| PD-51 | high | Buttkicker control and streaming cannot both work (V names) | Align device type names |
| PD-72 | high | VRS drop-outs under concurrent register/release | Register once at start |
| PD-52-56 | high | HUC UDP loop dies; DMX ramps stop halfway; classroom fan never changes; ids > 10 chars throw; free-roam audio mis-addressed | Restart HUC; Set not Ramp; fans via `HapticDeviceController`; ids <= 10 chars; patch `deviceId:` |
| PD-05 | high (pod) | Hardcoded pod IPs in assets and code (VRS 10.0.5.20, HUC 10.1.1.20, TURN) | `DSL_DS_SERVER_IP`, `DSL_HCS_UNIVERSAL_CONTROLLER_IP`; HCS ports are asset-only |
| PD-33 | high (pod) | Fire-alarm emergency 30 s after boot on a pod without `QsysServer` | `settings.QSys.Enabled=false` or set `QSys.Host` |
| PD-22 | med | No hands on PC VR | Operator REG ADD (PC VR recipe) or a controller profile |
| PD-70/71/75-77 | med | Stale reservations; two instances clash at start; host stops on bad Evoke/debug input; origin poses count as valid; late replies consumed | ReleaseAll on exit; stagger >= 2 s; valid frames only; jittered injection; restart VRS per rehearsal |
| PD-35 | med | DreamStation kills your own `experience.exe` | Security notes |
| PD-20 | med | Dead OpenXR runtime silently runs the simulator (V) | Health-check `Starting XR...` / `Initializing XR Failed.` |
| PD-01 | med | `DSL_PLATFORM_HMD` changes nothing | Per-target default negotiator |
| PD-02 | med | Validator "Fix All" enables Unity HandTracking on Android | Keep it off; ignore that warning and the XPS tests |
| PD-03 | med | Hand corrections missing; missing SerializeReference warnings | Keep dream-space installed |
| PD-08/09 | med | 1-3 s main-thread freeze per haptic try; second local client loses haptics | Deactivate haptic devices, or stub; per-instance `_receivingPort` |
| PD-10 | med | ACS boot throws on a missing device asset | Keep sample folders; remove null entries |
| PD-11 | med | `ArgumentOutOfRangeException` in server calibration and `api/props` | Register a `TrackedServer` device on the server |
| PD-36 | med | Station logout via the server logs the user in | Call the station logout route directly |
| PD-37/38/39 | med | VRS/HUC ignore DreamStation's port args; `--urls` ignored; wrong NIC (vEthernet/VPN) chosen | Their own appsettings; `Kestrel__Endpoints__Http__Url`; disable extra adapters |
| PD-40 | med (I) | Unity -> DreamStation UDP 8100 events never arrive: the template Dream Connect UDP transport fails to bind (V `StartListening failed ... invalid IP address`) | `networking.md` NW-06 |
| PD-57/58/59 | med | HUC port drift; one missing cluster member aborts the command; leaked stream ports | Keep 8086; consistent data; restart HUC per session |
| PD-60 | med | Haptic audio encoders wrap at full scale (+1.0 -> -1) | Keep haptic audio below 0 dBFS |
| TB-45 | med (V) | APK requires Wave and Oculus hand tracking and Bluetooth | Quest recipe step 4 |

Low: PD-06, PD-12 (one tracking receiver per process), PD-13, PD-15, PD-17, PD-19 (call `PlatformCore.TryGetHost`
before subscribing), PD-23 (rotated hands on Quest: assign a Quest `HeadsetHandAdjustmentProfile`), PD-41, PD-61,
PD-62, PD-78, PD-80. Resolved by running: PD-16 (Windows and Android IL2CPP builds compile, V) and PD-21 (INTERNET
present in the APK, V).
