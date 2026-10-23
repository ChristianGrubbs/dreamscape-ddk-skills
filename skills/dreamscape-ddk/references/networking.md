# Networking: DreamFish/FishNet, relay, voice, HTTP, backends

How a DDK multiplayer experience connects and talks: FishNet under DreamFish, the Relay message bus, RTC voice,
DreamConnect HTTP and the session-runtime backends. Tags: **V** verified by running a 6000.3.2f1 build (the log line
is quoted), **O** observed in vendor code, **I** inferred. Code shapes are **[I, not compiled]**. IDs (NW-, F-) index
the evidence in `<re>\notes\50-networking.md` and `05-lead-findings.md`. Secrets
(TURN credentials, RTC key, `x-api-key`) stay `<REDACTED>`. Launch commands, `DSL_*` keys, login and the session
marker lines: `runtime-config.md`. Boot order, asmdef, LMS and the CA- defects: `architecture.md`.

## Ready rules (every networked feature)

1. Treat `InstanceFinder.ClientManager.OnAuthenticated` as the client's **ready** signal and send relay messages and
   auth-required broadcasts only after it. `DreamNetworkManager.OnClientStarted` fires at transport Started, before
   auth, and FishNet kicks an unauthenticated sender of any broadcast registered with `requireAuthentication` (the
   default; Relay uses it) (NW-01).
2. First touch `Relay` only once the DreamFish Module is Active: `RelayImpl` captures the FishNet managers once, on
   first use (NW-04).
3. Start server logic in a `ServerService` or on `DreamNetworkManager.OnServerStarted`. In the server profile every
   LMS level call goes after `DreamFish Start Server` (CA-07).
4. Validate every client request on the server. Roles are client-chosen and relay `ClientId` is client-supplied
   (NW-20, NW-23); when identity matters use a `ServerRpc` and its `NetworkConnection`.
5. Wrap service init and every network handler in try/catch + log: DreamFish's async-void paths swallow exceptions,
   and one RTC handler exception stops signalling for that endpoint (NW-02, NW-34).

## Recipe: networked object

1. Scripts live in your asmdef (`architecture.md`) referencing `FishNet.Runtime`, plus `DreamscapeLearn.DreamFish`
   and `DreamscapeLearn.UserService` for roles. FishNet codegen skips assemblies named `Unity.*` or containing
   `Editor`.
2. Scene object: `NetworkObject` on the root inside a **level** scene (e.g. ClassroomScene) so it gets a SceneId.
   Fishnet, PlayerScene, ServerScene and LoginScene hold no NetworkObjects (O).
3. Spawned prefab: add `NetworkObject` and keep the prefab under `Assets/` (NW-32). Run Tools > Fish-Networking >
   Utility > Refresh Default Prefabs. It is forced, so it runs with `Enabled=false` in `Assets/FishNet.Config.XML`
   (O), and it rebuilds `Assets/DefaultPrefabObjects.asset` from the NetworkObject prefabs under `Assets/`, with
   hashes. Review the regenerated list and commit it (NW-31).
4. Spawn on the server only: `InstanceFinder.ServerManager.Spawn(Instantiate(prefab), ownerConnection)`. The
   NetworkManager prefab is not DontDestroyOnLoad and Fishnet loads Single, so later scenes load additively (LMS does).
5. Done = no `AssetPathHash is not set` line in the player logs, and a second client sees the spawn.

## Recipe: server-authoritative interaction

```csharp
using FishNet.Connection; using FishNet.Object; using FishNet.Object.Synchronizing; using FishNet.Transporting;
using DreamscapeLearn.DreamFish.Management; using DreamscapeLearn.UserService;
public sealed class Lever : NetworkBehaviour
{
    private readonly SyncVar<bool> _on = new();
    private void Awake() => _on.OnChange += (prev, next, asServer) => Animate(next);   // server and clients
    public void Pull() => RequestToggle();                                            // from local input
    [ServerRpc(RequireOwnership = false)]                                             // shared interactable
    private void RequestToggle(NetworkConnection caller = null)                       // FishNet fills caller
    {
        if (DreamNetworkManager.GetServerService<UserService>().GetUserRole(caller) != Role.Teacher) return;
        _on.Value = !_on.Value;                                                       // server writes, clients mirror
        PlayClunk();
    }
    [ObserversRpc(BufferLast = true)]                                                 // late joiners get the last call
    private void PlayClunk(Channel channel = Channel.Reliable) { /* one-shot effect */ }
}
```
Done = with a teacher and a student client connected, the teacher's pull flips the lever on both clients and the
student's pull changes nothing (I). No-code option: `NetworkComponentGroup` (Receive On Server/Clients).
`NetworkSyncedUnityEventBool` is marked "WIP: DO NOT USE" in code although the docs recommend it (NW-24).
`OwnershipCoordinator` lets any client claim ownership for any connection (NW-23).

## Recipe: relay message

```csharp
using DreamscapeLearn.RelaySystem; using DreamscapeLearn.RelaySystem.Attributes; using DreamscapeLearn.RelaySystem.Framework;
[RelayTypeIdRange("com.you.myexp", 30000, 30099)] internal static class MyIds { public const ushort Ping = 30000; }
public struct PingPayload : IMessagePayload
{
    public const ushort StaticTypeId = MyIds.Ping;   // the validator reads this const
    public ushort TypeId => StaticTypeId;
    public string Text;                              // public, Newtonsoft-serializable fields
}
// server, after OnServerStarted; keep the IDisposable and Dispose it to unsubscribe:
_sub = Relay.Subscribe<PingPayload>((p, env) => Relay.Ack(env, success: true));
// client, after ClientManager.OnAuthenticated:
AckMessage ack = await Relay.SendWithAck(new PingPayload { Text = "hi" });   // 3000 ms default timeout
if (!ack.Success) MyLog.Error($"ping failed: {(RelayCode)ack.Code} {ack.Message}");
```
1. The range class and the payload live in the **same assembly** (asmdef references `DreamscapeLearn.RelaySystem`,
   which is not auto-referenced). Stay clear of the taken ranges (Relay system reference).
2. Run `Dreamscape DevKit/Relay System/Validation`, or just build: the prebuild step fails on overlap or duplicates.
3. Done = the build log shows `[Relay] Validation passed. Ranges=5, Payloads=14.` (every template build logs
   `Ranges=4, Payloads=13.`, V) and the client gets `ack.Success` true.

## Recipe: local multiplayer smoke test

1. Launch the server and two clients as `runtime-config.md` "Local server + clients" describes. Give one client the
   teacher PIN and the other the student PIN (`runtime-config.md` Login). A second teacher is downgraded to Student
   (O). Headless clients need the hooked build and `-ddkAutoConfirm` (`runtime-config.md` Login).
2. For voice, use the PC's LAN IP instead of `127.0.0.1` (loopback ICE candidates are not gathered, I). Add
   `-DSL_VOIP_SERVER_URL stun:<lan>:3478` to the **server** only: a valid stub URL, never an empty value.
3. Done per client: the connect, auth, seat and avatar lines in `runtime-config.md` "Verify a session" (V: one
   teacher F-32; teacher + student F-33), plus the voice channel join (V for one client):
   - client `ChannelCache.OnReceivedJoinChannelResponse(response: ChannelId='Default' ClientId=<n> Error=None)`;
   - server `ChannelManager.ServerOnJoinChannelRequest(callersClientId: <n>, request: ChannelId='Default' ...)`.
4. Fail on `Client has been disconnected` (NW-01), `Invalid AuthForm type`, `Ack timeout`, or an RTC exception
   followed by silence (NW-34). One `AssetPathHash is not set for GameObject Networked_Avatar` per process is the
   template baseline (V, NW-31); any other prefab named there is a failure.
5. Relay: add the ping above with a marker log line and expect `Success` on both clients.
6. Voice: `Peer` logs signalling-state changes to stable. `OnIceConnectionChange` only logs, so grep `connected` or
   `completed`.

V (F-33): two hooked clients on one PC (PIN 1111 and 0000). Both authenticate, the teacher lands in
`Teacher Group` (id 0, seat 0) and the student in `Student Group` (id 1, seat 1), and both avatars spawn. The
second client's 8085/12000 port collisions do not block FishNet. Not run yet (I): the relay ping and a WebRTC
peer pair.

## Topology and ports

```
Pod server PC (x.y.z.20)                          Station PCs / Quest headsets (client profile)
experience.exe --PLATFORM WindowsServer           Tugboat client -> DSL_DREAMFISH_SERVER_IP:PORT
  FishNet/Tugboat UDP <game port>   <---------    RTCClient -> same IP, UDP 9045, after auth
  RTC signalling UDP 9045 (relay only)            WebRTC media peer <-> peer (host candidates or TURN)
  no DreamConnect, no WebRTC peer                 DreamConnect HTTP TCP 8085 (Windows) <- DreamStation, same PC
TURN relay (SDK/bin/turnserver); backend: pod (DSL_LINK/DIST_LINK) or cart (hint -> cfg_url); CMS HTTP 8083
```

| Purpose | Port | Status |
|---|---|---|
| FishNet game traffic | UDP, one value for every process; pods 9000 | **V** server binds 9000. The prefab's 7770 is always replaced by the Server Configuration asset (8300), which a resolved `DSL_DREAMFISH_SERVER_PORT` overrides (O) |
| RTC signalling | UDP 9045 (`DSL_VOIP_COMMUNICATION_PORT`), separate LiteNetLib socket | **V** bound by the server, joined by a client |
| DreamConnect | TCP 8085 HTTP on Windows clients (+ a LiteNetLib UDP transport) | **V** `HttpTransport listening on http://+:8085/`; UDP fails (NW-06) |
| TURN | URLs say 49160; the coturn sample listens 3478/5349, relays 49160-49200 | O (NW-42) |
| Camera feed | 8086 per camera | O |

- Bind (O): the server binds every interface, IPv4 + IPv6, unless `DSL_DREAMFISH_SERVER_IP` starts with `10` and
  ends `.20` (NW-18). DreamConnect binds a `10.0.x.20` NIC when present, else `+`.
- Firewall: server inbound UDP game port + UDP 9045; clients outbound UDP for WebRTC; Windows clients inbound TCP
  8085 for DreamStation. Pod production args: `runtime-config.md` Pod reference.

## Connection path

**Server (V up to the bind).** DreamFish Module -> `DreamNetworkManager.InitializeAsync`: registers managers in
`InstanceFinder`, runs every `GlobalService` (`AddressableService`), applies `ServerInfo` then env, applies the
AuthForm, logs `Initialization - Finished`. Start Server module -> `ServerManager.StartConnection()` and waits for
`Started` with no timeout (CA-05). On Started: RTCServer binds 9045, `DreamServer` creates every `ServerService` by
reflection and initializes them in ascending `InitializationPriority`, then registers every
`ServerBroadcastContract`. **V:** the static WebRTC updater starts under `-batchmode -nographics`
(`Starting WebRTC Update...`) with 0 exceptions. **V:** both server and client log
`Relay online. isClient=True, isServer=True`; it means both managers exist, not the role.

**Client (V for one headless teacher, F-32).** LoginScene `DreamscapeSession` -> PIN -> `PinCodeAuthForm` -> up to
3 x 10 s `DreamNetworkManager.StartClientConnection` -> transport Started: the authenticator sends
`PinCodeAuthBroadcast`, `DreamClient` creates `ClientService`s and client contracts -> server `PinCodeAuthenticator`
registers the user and role, fires `ProcessNewConnection`, replies `AuthResponseBroadcast` -> FishNet sends ids,
scenes, spawns -> `OnAuthenticated` -> RTCClient joins 9045 and gets `Configuration` (ICE servers incl. TURN
credentials) -> user-service asks for the role after a fixed 2 s (NW-11) -> LMS PrepareSync swaps in the passive
level container -> GMS creates and joins voice channel `Default`.

**Disconnect (O).** There is no reconnect anywhere: `DreamscapeSession` retries only the first connect, and a dropped
client goes back through login. Tugboat's timeout is fixed at 1800 s and the client `_remoteServerTimeout` is
Release-only, so an editor/dev client can miss a dead server for 30 min (NW-33); the server drops silent clients
after 60 s.

## DreamFish over FishNet

DreamFish is a "thin wrapper around fishnet for auth support": no transport, no sync types. Gameplay is plain
FishNet 4 (`NetworkBehaviour`, `[ServerRpc]`, `[ObserversRpc]`, `[TargetRpc]`, `SyncVar<T>`, `NetworkTransform`).

| Piece | What it gives you |
|---|---|
| `DreamNetworkManager` (static) | `OnServerStarted/Stopped`, `OnClientStarted/Stopped` (pre-auth), server `ProcessNewConnection(conn, data)` (fires before FishNet marks the connection authenticated: store data only), `GetServerService<T>`, `GetClientService<T>`, `GetGlobalService<T>` |
| `ServerService` / `ClientService` / `GlobalService` | public `(NetworkManager)` ctor, `InitializeAsync(token)`, `ReleaseResources()`; found by reflection; call `Dispose()` (finalizers touch Unity off-thread, NW-07) |
| Broadcast contracts | `ServerBroadcastContract<T>` (+ `WithResponseToClient`, `WithResponseMultipleClients`, `AllClients`), `ClientBroadcastContract<T>`; public `(NetworkManager)` ctor; auto-registered; `ProcessResponse` exceptions are swallowed |
| `ConnectionService` (server) | `GetAuthForm<TForm>(conn)` |
| `AddressableService` (global) | downloads remote deps, adds Addressable NetworkObjects labelled `LevelDependency`/`Prefabs`/`Textures` (NW-08, NW-09) |
| `ServerConfiguration` asset | `Assets/Application/Configs/Server Configuration.asset`: IP/port defaults, MaxConnections 5000, AuthForm; `AutoStartHeadlessServer`/`AllowHostClient` have no readers (NW-30); Play Mode likely writes env overrides into it, so leave it unsaved after Play (NW-29, I) |

**FishNet version.** The DDK package is labelled 4.6.6 but is upstream **FishNet 4.6.22** (`FISHNET_VERSION`, CHANGELOG
"4.6.22R"); use 4.6.22 docs and APIs. DDK changes against 4.6.22 (O, full diff):
1. LiteNetLib moved to its own package (`com.dreamscape-learn.third-party.litenetlib`, asmdef
   `DreamscapeLearn.LiteNetLib`, namespace `LiteNetLib`), referenced by name from `FishNet.Runtime.asmdef` with
   GameKit.Dependencies and Unity.Mathematics. Keep upstream FishNet and other LiteNetLib copies out of the project:
   duplicate `LiteNetLib` types (I). DreamConnect and RTC use the same package.
2. `package.json`: renamed; newtonsoft 3.2.2, ugui 2.0.0, + litenetlib 1.0.9, + mathematics 1.3.3.
3. Editor `LogFeedbackLink()` commented out; `rb.velocity` -> `rb.linearVelocity` in prediction `#else` branches;
   demo `FindObjectOfType` -> `FindAnyObjectByType`. Warnings only. `FishNet.Demos` still compiles into players (NW-48).
4. 76 demo/observer assets re-serialized; every `.meta` gained an Asset Store `AssetOrigin` block; GUIDs match upstream.
5. Lost: DDK 4.6.0's "default prefabs in a Packages folder"; the generator needs `Assets\` again (NW-32).

Unchanged: NetworkManager, ServerManager, ClientManager, Tugboat, codegen. Defaults that matter: Tugboat MTU 1023,
IPv6 on, timeout fixed 1800 s; TickRate 30; no default observer conditions (everything visible unless a prefab has
a `NetworkObserver`); template `_startOnHeadless: 0`. FishNet's `CodeStripping` is inert, so a player run with
`--PLATFORM WindowsServer` runs the same networking code as a Server build. DDK RPC style: trailing
`Channel channel = Channel.Reliable`, `[ServerRpc(RequireOwnership = false)]` for shared interactables,
`[ObserversRpc(BufferLast = true)]` for late joiners.

## Authenticators and login codes

- Template: user-service `PinCodeAuthenticator` (a `DreamAuthenticator<PinCodeAuthForm, PinCodeAuthBroadcast>`) on
  the NetworkManager prefab, matched by AuthForm `PinCodeAuthForm` in the Server Configuration asset. A custom
  authenticator needs a matching form type, or `ApplyAuthForm` throws `Invalid AuthForm type provided` and the
  DreamFish Module goes Error.
- Three login-code schemes conflict across packages (F-26); which code to type: `runtime-config.md` Login.
  `DreamscapeSession` turns the PIN-pad result into a form with `PinCode` 000 or 111 before connecting.
- On the wire the server maps `PinCode` 000 -> Student and 111 -> Teacher (max one teacher; a second becomes Student);
  any other code falls back to the client-supplied `Role` string (O).
- Client side (O): for 000/111 the authenticator sends its own default form, user name `DefaultStudent` or
  `DefaultTeacher` with its own GUID, and drops the name and id from `DreamscapeSession`. V: the server logs
  `Username: 'DefaultTeacher'`. Other codes from 1 to 999 call dream-api `LoginPin` + `GetUserInfo` first.
  `SendAuthFormBroadcast` is async void and sends nothing for codes >= 1000 or when that backend call fails, so custom
  login UIs send 000/111 (NW-12).
- Results: the client logs `Received AuthResponseBroadcast. Authentication result: True|False`, plus
  `AuthResponseBroadcast Message: <reason>` on failure. Rejection = failed response, then `Disconnect(true)`, so the
  reason may never arrive (NW-13).
- Server-side lookups: `DreamNetworkManager.GetServerService<UserService>().GetUserRole(conn)` /
  `.UserHasPermission(conn, perm)`; the raw form via
  `GetServerService<ConnectionService>().GetAuthForm<PinCodeAuthForm>(conn)`.

## Relay system (reference)

- **Envelope** `Message : IBroadcast {Version, CorrelationId, SentUnixMs, Flags, ClientId, TypeId, Payload}`; the
  payload is Newtonsoft JSON of a `struct : IMessagePayload`. Correlation id = bit 63 server flag, bits 62-32 client
  id, bits 31-0 sequence. **V** server trace: `[SERVER][2201] Server->Clients | Version: 1 | ... | Client : -1 | ...`
  and `[SERVER][2200] SendTo: Server->Client=0 | ...`.
- **Ack** `AckMessage {RequestCorrelationId, Success, ushort Code, Message, ProcessedUnixMs}`; `RelayCode` = gRPC
  codes 0-16 plus 17 DuplicateCorrelationId; default timeout 3000 ms; a `WaitFor` timeout throws
  `OperationCanceledException`, not `TimeoutException` (NW-22).
- **API** `Send`, `SendTo(clientId)`, `SendToMany`, `SendWithAck`, `SendToWithAck`, `Subscribe<T>((payload, env) => ...)`
  (returns `IDisposable`), `WaitFor<T>`, `Ack`, `AckTo`, `Purge`. Mono helpers: `DreamscapeLearn.RelaySystem.Framework.Mono`
  (`AbstractRelaySender/Receiver/Requestor/WaitFor/ServerForwarder`). In host mode `Send` goes to clients only,
  never to server handlers (NW-21).
- **Taken id ranges:** relay-system 10-99, LMS client 2000-2199, LMS server 2200-2399, avatar-management
  6000-6199, dream-space 12093 (no declared range; a build warning), Chat sample 61000-61199.
- **Validator** (prebuild order 0, and the Validation window): `Start > End`, overlapping ranges and duplicate
  TypeIds fail the build; a payload outside its assembly's range only warns.

## Networked prefabs and DefaultPrefabObjects

- The MP generator is off (`Assets/FishNet.Config.XML` `Enabled=false`, `SaveChanges=true`), so
  `Assets/DefaultPrefabObjects.asset` is hand-curated: one entry, `Networked_Avatar.prefab`, with `AssetPathHash 0`.
- **V:** every MP player logs `AssetPathHash is not set for GameObject Networked_Avatar.` from
  `DefaultPrefabObjects.Sort()` in `NetworkManager.Awake`. **O:** `Sort` then returns early, and a **second** hash-0
  prefab makes `Dictionary.Add` throw inside NetworkManager init (NW-31). Fix both with the Refresh step in the
  networked-object recipe.
- `AddressableService` appends Addressable NetworkObjects to collection "Default" in catalog order; per-platform
  catalogs that differ spawn the wrong prefab (NW-09). Keep networked prefabs in DefaultPrefabObjects.
- SP has no NetworkManager prefab, Fishnet scene or DreamFish modules (networking compiles but is unwired), and its
  DefaultPrefabObjects holds a dangling GUID: clear it before adding networking (NW-47).

## MessagePack and IL2CPP

- Only RTC (pre-generated `DreamscapeLearnRealTimeCommunicationResolver`) and dream-space use MessagePack. DreamFish
  uses FishNet serializers and Relay uses Newtonsoft; prefer those for your own messages.
- RTC registers its resolver at BeforeSceneLoad and overwrites `MessagePackSerializer.DefaultOptions` globally.
- IL2CPP has no dynamic resolver generation, while the editor uses the dynamic one, so a MessagePack type that works
  in Play Mode fails in players (NW-45). `MessagePackBuildProcessor` skips batchmode, and both templates list no
  assemblies in `Assets/MessagePack/Editor/MessagePackSettings.asset`: generate resolvers with a pinned `mpc`,
  commit them, register with `MessagePackRegistryService.Register`.
- No `link.xml` or `[Preserve]` ships. Reflection-only paths: DreamFish services/contracts (`Activator`), relay JSON
  payloads, `VariableBase` discovery. **V:** template builds at the default stripping level boot through these paths;
  if you raise Managed Stripping Level, add a `link.xml` that preserves your assemblies (I).

## RTC and voice

- Signalling is not FishNet: RTC runs its own LiteNetLib socket on 9045 (hard-coded key `<REDACTED>`), messages
  `[byte type][int len][MessagePack]`, all `ReliableUnordered`. The server only relays; it creates no WebRTC peers.
- `FishNetSignalingService` (on the NetworkManager prefab, under `DREAMSCAPE_FISHNET_RTC`) bridges lifecycle:
  client OnAuthenticated -> RTCClient connects; client Starting -> port check + init; server Started -> RTCServer.
- Voice needs `FishNetSignalingService` on the NetworkManager, `LocalConnectionBehaviour` on the local rig,
  `RemoteConnectionBehaviour` + a receiver on the networked avatar, and a channel join (GMS does it; V for channel
  `Default`). Perfect negotiation; polite = higher client id.
- ICE/TURN comes from the **server**: `Resources/Real Time Communications Settings` (template copy under
  `Assets/Real Time Communications/Resources/`), and a non-empty server-side `DSL_VOIP_SERVER_URL` replaces the URL
  list. Credentials always come from the asset and travel in cleartext to every client (NW-43). Clients cannot
  override TURN; the cart's `turnServerUrl` is never read (NW-05).
- Off the pod the default `turn:10.95.204.6:49160` is unreachable. With transport policy All, host candidates still
  pair peers on one LAN (I). Keep a syntactically valid URL (`stun:<lan>:3478`): an empty list, or `turn:` with empty
  credentials, fails peer creation (I). ICE failure is unhandled; `OnIceConnectionChange` only logs.
- Client `PortChecker` probes 244 **TCP** ports (9045, 3478, 5349 and 43160-43400) on every connect and logs
  `Port N is not available` for each one in use: noise (NW-38). V: a clean run logs `Starting Port checks...` and
  nothing else. Android skips it.
- Mic: a main-thread spin at start (NW-37); no runtime permission request anywhere, so request
  `Permission.Microphone` on Android before RTC starts (NW-41); channel joins re-enable a muted mic (NW-40).
- `Time.timeScale = 0` stalls signalling (NW-39). Camera-feed broadcasting rides DreamConnect routes (NW-44).

## DreamConnect HTTP 8085

- Inbound local control plane: `DreamConnectRouter` with `DefaultHttpTransport` (HttpListener, CORS `*`, 404 when no
  route matches, handlers on the main thread) and `ConnectedUdpTransport`. Profiles: MP WindowsClient only; SP both
  platforms; never MP server or MP Android.
- **V** on a headless MP client: `HttpTransport listening on http://+:8085/` and `Module DreamConnectModule initialized`
  on a PC with no URL ACL for 8085, launched from a non-elevated shell (I: Unity's HttpListener is managed, not
  http.sys). Then
  `[DefaultUdpTransport] StartListening failed ... invalid IP address` (`+` parsed as an IP, NW-06), raised by
  `ConnectedUdpTransport` despite the prefix.
- **V** routes registered during boot: POST `/broadcasting/start`, `/broadcasting/stop`, GET `/broadcasting/status`,
  `/broadcasting/screenshot`, POST `/emergency/activate`, `/emergency/clear` (test body: `architecture.md`).
- DreamStation calls `http://<station IPv4>:8085/api/gameplay/calibrate[/{station}]`, `/api/props[/{station}]`,
  `/api/avatar[/{set}]`, `/api/login`, `/api/logout` (O). The template client registered none of them during boot (V),
  so they 404 unless a package adds them later (I).
- Add a route: an `IDreamRequest` marked `[HttpRoute(HttpRequestType.Post, "/myexp/thing")]`, registered with
  `await DreamConnectRouter.RegisterCommand(request)` after the Dream Connect module is Active (returns false with no
  transport). asmdef `DreamscapeLearn.DreamConnect` is not auto-referenced. Done = the client log has
  `[Dream Connect|Debug]: Route registered: Post '/myexp/thing'`.
- A second client on one PC cannot bind 8085; FishNet is unaffected (I). For clean logs set the `_dreamEndpoint`
  `_address: +` in `Assets/Application/Modules/Shared/Dream Connect Module.asset` to `127.0.0.1` (dev only:
  DreamStation can no longer reach it), or drop Dream Connect + BroadcastingServiceModule (NW-06).

## Session-runtime backends

- Windows client profile = Session Runtime Pod (V `Module SessionRuntime_Pod initialized`); Android = Cart.
  Multiplayer vs individual = `InstanceFinder.NetworkManager != null`. Keyed calls send `x-api-key: <REDACTED>`;
  2 attempts per call; Android first waits up to 10 s for Wi-Fi.
- **Pod:** `DSL_POD_*` keys (normally from `system.xml`; `runtime-config.md`). App-get
  `GET {DIST_LINK}/dist/config/{mac}?active=true` (uses adapter `[0]`, NW-17); pod-connect
  `POST {DSL_LINK}/pod-connect/code`; grade passback `PUT {DSL_LINK}/pod-connect/userdata/{UserSessionId}/{EventId}`.
- **Cart:** hint `GET http://hint.dreamscapelearn.com` (override `DSL_CART_HINT_ENDPOINT`) -> `cfg_url`; app-get
  `GET {cfg_url}/{appId}?hmd={device}` -> station id, `client_api_url`, PincodeLogin, ClientApiKey, `GiK` (game
  server host), `game_server_port`, `turnServerUrl`. A successful app-get overwrites the Tugboat address and the env
  values. Pod-connect `POST {client_api_url}/pod-connect/code` (+ `x-dreamscape-experience`); passback PUT under
  `{cfg_url}/pod-connect/userdata/...` (docs say `/grade-passback`).
- Logs leak at Info level: cart app-get logs its whole response, `ClientApiKey` included (NW-14), and pod-connect
  logs `Full response:` with the booking and roster names (O). Redact both before sharing logs.
- No backend on a dev PC: the pod initialization error is normal (`runtime-config.md`, Known-benign log noise); use
  the bypass codes.
- dream-api `ServiceClient`: subclass `Request<TForm,TResponse>` (POST JSON, 30 s timeout); the endpoint registry is
  first-write-wins, so register overrides first (NW-15); errors carry no HTTP status (NW-16). `http://` backends need
  `insecureHttpOption: 2` (the template has it).

## Defects ranked (NW)

| # | ID | Symptom | Workaround |
|---|---|---|---|
| 1 | NW-01 | client kicked ("ExploitAttempt") right after connecting | send only after `ClientManager.OnAuthenticated` |
| 2 | NW-31 | **V** hash-0 error at every boot; a 2nd hash-0 prefab throws in NetworkManager init | Refresh Default Prefabs, commit hashes (recipe) |
| 3 | NW-04 | Relay NRE or silently dead | first touch after DreamFish Module is Active |
| 4 | NW-06 | **V** DreamConnect UDP "invalid IP address"; 2nd local client cannot bind 8085 (I) | endpoint `127.0.0.1` in the module asset, or drop Dream Connect + Broadcasting from a test profile |
| 5 | NW-02/03 | `OnServerStarted`/`OnClientStarted` never fire; failed connect never raises `OnClientStopped` | try/catch in services; subscribe `ClientManager.OnClientConnectionState` |
| 6 | NW-34/35 | one bad RTC packet kills signalling (server = everyone); voice pair never connects | try/catch in RTC handlers; patch to `ReliableOrdered`, buffer by PeerId, offer timeout + `RestartIce` |
| 7 | NW-09 | wrong prefab spawned when networked prefabs are Addressable | keep them in DefaultPrefabObjects |
| 8 | NW-28/29 | client and server on different ports; Play Mode persists env into the Server Configuration asset | pass IP/port to both; leave the asset unsaved after Play |
| 9 | NW-33 | dead server unnoticed for up to 30 min in editor/dev | set the ClientManager `_remoteServerTimeout` to Development in `Assets/Application/Scenes/Fishnet.unity` |
| 10 | NW-45 | MessagePack types fail only in IL2CPP players | commit pre-generated resolvers |
| 11 | NW-41/40/37 | Android mic silent; muted mic re-enabled on join; main-thread stall at mic start | request `Permission.Microphone`; re-apply mute after joins; start mic off the critical path |
| 12 | NW-42/05/43 | TURN unreachable as shipped; cart TURN ignored; credentials in cleartext | `turn:<host>:3478` or a `stun:` stub on the server; treat RTC as LAN-only |
| 13 | NW-11/12/13 | role late or lost; PIN >= 1000 never authenticates; rejection reason lost | react to `UserRoleBroadcast`; send 000/111; `Disconnect(false)` in a custom authenticator |
| 14 | NW-20/23 | relay acks spoofable; any client claims Teacher or ownership | validate on the server; identity from `ServerRpc` connections |
| 15 | NW-07/08/10 | main-thread errors at GC; Addressable teardown destroys assets; DreamServer types broken by a bad assembly | `Dispose()` services; own release logic; no assemblies with unresolvable types in players |
| 16 | NW-14/15/16/17 | ClientApiKey in logs; endpoint override ignored; no HTTP status; wrong MAC to pod app-get | redact; register first; log `responseCode`; patch NIC choice to the 10.x adapter |
| 17 | NW-18/19 | server listens on every interface; first DreamConnect/RTC poll off the main thread | set the Tugboat bind address; marshal to the main thread |
| 18 | NW-36/38/39/44 | host-mode RTC leaks; port-check noise; `timeScale = 0` stalls RTC; Android BroadcastingService fails | use a dedicated server for voice; ignore client port errors; keep timeScale above 0; add Dream Connect or drop the module |
| 19 | NW-32 | prefabs inside packages cannot be auto-registered | keep networked prefabs under `Assets/` |

Low: NW-21 host-mode `Relay.Send` skips server handlers (call server logic directly); NW-22 catch
`OperationCanceledException`; NW-24 prefer `NetworkComponentGroup`; NW-25 = duplicate CLI keys (`runtime-config.md`);
NW-26 trust code over docs; NW-27 hard-coded hosts (override via env/CLI); NW-30 `AutoStartHeadlessServer`/
`AllowHostClient` do nothing; NW-46 duplicate `System.Runtime.CompilerServices.Unsafe.dll` warning; NW-47 SP
dangling prefab GUID; NW-48 FishNet Demos ship in players.
