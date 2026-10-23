# Core architecture: boot, modules, levels, services

How a DDK experience boots and where author code plugs in: ACS modules, LMS levels, CMS packs, config, console,
logging and the static service facades. Tags: **V** verified by a 6000.3.2f1 run on the evidence machine (log line
quoted; server `smoke-server-cleanenv.log`, headless MP client `e2e2-client-teacher.log`), **O** observed in vendor
code, **I** inferred. Code shapes are compile-checked (C# 9 against the evidence project's built assemblies, with
the asmdef references below) but have never run, so their behaviour is I.
IDs: CA- in `40-core-architecture.md`, TB- in `10-templates-and-build.md`, F- in `05-lead-findings.md` (evidence
machine: `<re>\notes\`; elsewhere rebuild with the `dreamscape-ddk-re` skill).
Launch flags, `DSL_*` keys and login: `runtime-config.md`. FishNet, relay, voice, HTTP: `networking.md`.

## Set up author code (do this first)

1. Put every script in your own asmdef. 43 DDK runtime asmdefs are not auto-referenced (ACS, CMS, ENV, Relay,
   DreamConnect, SessionRuntime, AudioSystem, ...), so `Assembly-CSharp` cannot see them (TB-29). The MP template's
   `Assets/Content/Content.asmdef` is the shape (it lists only four references); keep the references you use:
   ```json
   { "name": "MyExperience", "rootNamespace": "MyExperience", "autoReferenced": true, "references": [
     "UniTask", "DreamscapeLearn.Naming", "DreamscapeLearn.SystemLogger", "DreamscapeLearn.Utilities", "DreamscapeLearn.DataStore",
     "DreamscapeLearn.ApplicationControlSystem", "DreamscapeLearn.LevelManagementSystem", "ApplicationControlSystem-LMS",
     "DreamscapeLearn.EnvironmentManagement", "DreamscapeLearn.ContentManagementSystem", "Unity.Addressables",
     "Unity.ResourceManager", "DreamscapeLearn.DreamConsole", "DreamscapeLearn.DebugPanel", "DreamscapeLearn.EmergencyBroadcastSystem",
     "DreamscapeLearn.AudioSystem.Runtime", "DreamscapeLearn.ApplicationDatastore", "DreamscapeLearn.PermissionsFramework",
     "DreamscapeLearn.TraitsFramework", "DreamscapeLearn.XRPlatformService", "FishNet.Runtime", "DreamscapeLearn.DreamFish",
     "DreamscapeLearn.RelaySystem", "DreamscapeLearn.UserService" ] }
   ```
   FishNet codegen (SyncVar, RPCs) runs only on an assembly that references `FishNet.Runtime` and whose name neither
   starts with `Unity.`, `UnityEngine.`, `UnityEditor.` nor contains `Editor` (O). Newtonsoft comes from the
   auto-referenced DLL; `Result` lives in `DreamscapeLearn.Utilities`, which needs dreamfish, fishnet, ugui (CA-43).
2. Keep Enter Play Mode Options at "Reload Domain and Scene", the template default (see Domain reload).
3. Done: with one script in the asmdef that uses a DDK type (e.g. `MyLog` below), `scripts/run-ddk-build.ps1
   -Project <p> -Step Compile` prints `STEP_DONE ... exit=0 ... error_cs=0` (V route, F-34). **V:** the stock MP template
   builds all three targets with 0 `error CS` (F-27, F-28, F-30), so CA-40/41/42 (UnityEngine.UI refs, unguarded
   `using UnityEditor;`) need nothing.

## Add a module

1. Subclass `AbstractModule` (shape below): override `Identifier`, `InitializeModule`, `RestartModule`,
   `ShutdownModule`. The documented `Initialize()/Restart()/Shutdown()` are explicit interface members (CA-04).
2. Set `Status` yourself (`protected set`). ACS only reads it and runs `InitializeModule` only while it is `Disabled`.
3. Bound every await with your own timeout: ACS awaits each module with none (CA-05). A `false` or an exception is
   logged and the next module still runs; after the last one ACS throws `InitializationException: Failed to
   Initialize System` (O; V in the F-29 run `smoke-server.log`).
4. Create the asset (`Create > Dreamscape DevKit > Modules > ...`) and add it to **every** relevant profile in
   `Assets/Application/Profiles/`: after EnvironmentManagement if it reads `DSL_*`; after the Single-mode scene load
   (`LoadFishnetScene` MP, `Load Application Scene Module` SP) if it creates GameObjects, else keep them alive with
   `DontDestroyOnLoad` or a utilities `PersistentObject` (CA-03); after `DreamFish Start Server` if it calls LMS
   level APIs on the server (CA-07).
5. Give it an `Identifier` unique in the profile: a duplicate throws `Module Registration Failed`, nothing boots (CA-06).
6. Done: the log shows `[ApplicationControlService|Trace]: Module <Identifier> initialized in` (V format) and no
   `was not initialized` warning, and `ApplicationControlService.GetStatus("<Identifier>", out var s)` gives `Active`.

```csharp
using System; using System.Threading; using Cysharp.Threading.Tasks; using UnityEngine;
using DreamscapeLearn.ApplicationControlSystem; using DreamscapeLearn.ApplicationControlSystem.Framework;
[CreateAssetMenu(fileName = "My Feature Module", menuName = "Dreamscape DevKit/Modules/My Experience/My Feature")]
public sealed class MyFeatureModule : AbstractModule        // MyFeature, MyLog: your own code
{
    public override string Identifier => "MyExperience.MyFeature";
    protected override async UniTask<bool> InitializeModule()
    {
        Status = ModuleStatus.Initializing;
        try { using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
              await MyFeature.InitializeAsync(cts.Token); Status = ModuleStatus.Active; return true; }
        catch (Exception e) { MyLog.Error($"MyFeature init failed: {e}"); Status = ModuleStatus.Error; return false; }
    }
    protected override UniTask<bool> RestartModule() { Status = ModuleStatus.Disabled; return InitializeModule(); }
    protected override UniTask<bool> ShutdownModule()   // synchronous: editor Play exit abandons async continuations
    { Status = ModuleStatus.ShuttingDown; MyFeature.Dispose(); Status = ModuleStatus.Disabled; return UniTask.FromResult(true); }
}
```

## Add a level

**A. Embedded, with the wizard** (Project Configurator, Ctrl+Shift+D > Experience Setup > Level Management):
1. Create the scene from a template (MP `MultiplayerClassroomTemplate`, SP `Single Player Classroom`).
2. Management Type = Embedded, Lifecycle = Persistent, **Scope = Single in SP projects** (the wizard defaults to
   Multiplayer, which an SP client never loads, CA-14). Click Add to Build. The wizard writes `<SceneName>.asset`
   (LevelConfiguration, id = asset name), adds it to the first `RegisterLevelsModule` of each profile listed in
   `Assets/Settings/Dreamscape Learn/LMSPanelData.asset`, and appends the scene to Build Settings (O).
3. Start level: SP `Define Start Scenes Module` (aether-canvas class) > Default Level Id; MP server `Load Classroom
   Module` `_levelLoadArgs.Identifier`; MP client offline start: `Load Level Module Client` (`LoginScene`).

**B. Embedded, by hand:**
1. `Create > Dreamscape DevKit > Level Management System > Level Configuration`; asset name = level id (case-sensitive).
2. Set Scope, Source = Embedded, exactly **one** scene with Lighting ticked, then Persistent/Dynamic scenes.
3. Add the scenes to Build Settings (file names unique across build and Addressable scenes: FishNet and LMS match
   short names) and the configuration to `Register Embedded Levels Module *` in every profile that must know it
   (MP: client **and** server).

**C. Addressable level (content pack):**
1. Do B with Source = Addressable, then select the configuration in the Inspector once so the drawer writes each
   scene's `_identifier` and makes the scene addressable in the Default Local Group, which also ships inside the
   player (CA-13, CA-33). Check the ids are distinct.
2. `Create > Dreamscape DevKit > Content Packs > Level Pack`, assign the configuration (pack id = level id), click
   Create Addressable, then Build per target with `Versioned = false`, interactive or batch. In batch, rename the
   catalog to `catalog.json`/`catalog.hash` afterwards (TB-05); build.md section 9 has the exact steps. Keep
   `Versioned = false`: a version bakes `<id>/<ver>/<Target>` into the bundle load paths
   (`ContentEditorUtility.GetSerializableLoadDirectory`), while the runtime fetches the catalog from `<id>/<Target>`
   (CA-16), so catalog and bundles would need different folder layouts. Check `catalog.json` exists (TB-04).
3. Serve the `<Target>` folder at `{DSL_CMS_ROOT_LOAD_PATH}/<id>/<Target>/` (`runtime-config.md`): the runtime
   ignores versions, so drop the `<ver>` level when serving (CA-16).
4. Profile order in MP client **and** server: EnvironmentManagement, `ContentManagementModule` (non-empty
   `_rootLoadPath`), `LoadCatalogsModule` (id = level id), `RegisterRemoteLevelsModule` (server: after DreamFish
   Start Server), `LoadLevelModule`.
5. Labels are lower case (`config`, `scene`, `levelDependency`, `lighting`, `persistent`, `dynamic`); config address
   `dl/levels/<slug>/config`, slug = lower-cased id, non-`[a-z0-9]` runs -> `-`, edges trimmed, empty `unnamed` (O).

**Done** (every variant, V formats): a client logs `[LMS-Client|Debug]: OnUnitySceneLoaded (managed) <Scene>`; an
MP server logs `[LMS-Server|Trace]: [TransitionSync] Transition complete -> '<id>'`.

**Runtime API and lifecycle hooks** (statements inside an async method). Level event handlers are synchronous;
phase handlers are awaited with `WhenAll` before the transition continues (V, MP client: `[Phase] Preload:
awaiting preload handlers.` then `[Phase] Preload: all handlers done, sending Preloaded.`):
```csharp
using System.Threading; using Cysharp.Threading.Tasks; using DreamscapeLearn.Utilities;
using DreamscapeLearn.LevelManagementSystem; using DreamscapeLearn.LevelManagementSystem.Arguments;
using DreamscapeLearn.LevelManagementSystem.Framework.Handlers.Level; using DreamscapeLearn.LevelManagementSystem.Framework.Handlers.Phases;
Result r = await LevelManagementService.LoadLevel(new LevelLoadArgs { Identifier = "CourseA" }, token);
if (r.IsFailure) MyLog.Error(r.Error.Message);                                                // Error is an Exception
if (LevelManagementService.TryGetLevelConfiguration(out _))                                   // guard CA-15
    await LevelManagementService.LoadScene(new SceneLoadArgs { Identifier = "BossArena" }, token); // always additive
public sealed class LessonBootstrap : UnityEngine.MonoBehaviour, ILevelStartEventHandler, IPreloadPhaseHandler
{
    void Awake()     { EventService.RegisterLevelHandler(this); EventService.RegisterPhaseHandler(this); }
    void OnDestroy() { EventService.UnregisterLevelHandler(this); EventService.UnregisterPhaseHandler(this); }
    public void OnLevelStartEvent() { /* sync: persistent + lighting scenes are in */ }
    public async UniTask OnPreloadAsync(CancellationToken ct) { await WarmUpAsync(ct); } // awaited; MP gate 30 s
}
```

## Add a config variable (`DSL_*`)

1. Add a non-abstract `VariableBase` subclass with a public parameterless ctor; startup reflection finds it (O):
   ```csharp
   public sealed class LessonApiUrl : DreamscapeLearn.EnvironmentManagement.VariableBase
   {
       public LessonApiUrl() => DefaultValue = "http://localhost:9999";          // DefaultValue has a protected setter
       public override string Identifier => "DSL_MYEXP_LESSON_API";               // CLI -DSL_MYEXP_LESSON_API <url>, OS env
       public override string LocalJsonDataPath => "myexp-data.lesson-api";       // EnvironmentVariables.json section.key
   }
   ```
2. Read it in Start or later (Awake runs before the resolvers, CA-31): `EnvironmentService.GetValue<LessonApiUrl>()`
   returns the string, or null when unresolved. Avoid `GetValue<string>(id)`: it JSON-parses the raw value (CA-31).
   Resolution order and file locations: `runtime-config.md`.
3. Done: a player started with `-DSL_MYEXP_LESSON_API http://x` reads `http://x`. Pass each key once (RC-01).

## Add a console command

1. Put `Console.prefab` (dream-console) in **PlayerScene**: in Application.unity its output target is cleared and
   the scene is unloaded (CA-21, CA-03). Re-pick its Activation Key (e.g. F1): it ships `282`, the legacy `KeyCode.F1`,
   which Input System `Key` lacks, so `KeyActivator` rebinds `<Keyboard>/f1` to `<Keyboard>/282` (O; dead key I, CA-24).
2. Register a static command class; call it as `/<domain> <name> args`:
   ```csharp
   using Cysharp.Threading.Tasks; using DreamscapeLearn.DreamConsole; using DreamscapeLearn.DreamConsole.Attributes;
   public static class MyCommands
   {
       private const string Domain = "myexp";
       [UnityEngine.RuntimeInitializeOnLoadMethod(UnityEngine.RuntimeInitializeLoadType.AfterSceneLoad)]
       private static void Register() => Engine.RegisterType(typeof(MyCommands)).Forget(); // one member per frame
       [DreamCommand("level", Domain, "Load a level by id")]
       public static string Level(string id) { LoadAsync(id).Forget(); return $"Loading {id}"; } // LoadAsync: yours
       [DreamField("debugDraw", Domain, "Toggle gizmos")] public static bool DebugDraw;         // /myexp debugDraw true
   }
   ```
3. Use `int`/`float`/one-word `string` parameters and `bool` typed as `true`/`false`; return a `string` to print;
   run async work with `.Forget()` inside a try/catch (CA-25); prefer static commands that look up live objects
   (CA-26). Domains taken: `system`, `logSystem`, `debug`, `slack`, `checkpoint`, `sm` (a reused name: Fatal, ignored).
4. Lock admin commands: `isPasswordProtected: true` plus `Engine.Configure(new EngineConfiguration {
   _systemLockEnabled = true, _password = <from env var> })` after the prefab's `InitializeConsole` (it unlocks).
   Every command line is logged: take secrets from env vars (CA-50).
5. Done: `/myexp level CourseA` prints `Loading CourseA` in the console output (not yet run).

## Add a logger or log target

```csharp
using DreamscapeLearn.SystemLogger.Core; using DreamscapeLearn.SystemLogger.Framework;
using Logger = DreamscapeLearn.SystemLogger.Core.Logger;                      // avoids the UnityEngine.Logger clash
internal static class MyLog
{
    private static readonly Logger L = LogService.CreateLogger("MyExperience");  // one shared Logger per name
    public static void Info(string m, object c = null) => L.Log(LogLevel.Info, m, c);
    public static void Error(string m, object c = null) => L.Log(LogLevel.Error, m, c);
}
[UnityEngine.CreateAssetMenu(menuName = MonoTarget.MenuPath + "/My Target")]
public sealed class MyTarget : MonoTarget
{
    private readonly object _gate = new();                              // RenderEvent runs on the logging thread
    public override string Name { get; protected set; } = "MyTarget";   // a second same-Name target is ignored
    protected override void OnInitialize() { }
    protected override void RenderEvent(LogEventInfo e) { lock (_gate) { /* queue it; no UnityEngine.Object */ } }
}
```
1. Add the target asset to the System Logger module's `_targets`, the only runtime registration path (the Resources
   auto-load is editor-only). For builds set the module's Log Level to Info or Warn: the template ships Trace (CA-23).
2. Done: `[MyExperience|Info]: <message>` appears in Player.log and in the `PrintLogTarget` file
   `%USERPROFILE%\AppData\LocalLow\Dreamscape Learn\experience\Logs\<M-d-yy>\Log_HH-mm-ss.log` (V path, MP
   companyName; SP is `dreamscapelearn`). Every DDK line also carries its source path and line (CA-23, V).

## Receive emergency broadcasts

1. Register one static forwarder before ACS runs and fan out yourself (CA-01); scene objects join `Listeners` in
   OnEnable and leave in OnDisable. Leave `Initialize()` to the module: a second call duplicates deliveries.
   ```csharp
   using DreamscapeLearn.EmergencyBroadcastSystem; using DreamscapeLearn.EmergencyBroadcastSystem.Framework;
   public sealed class EmergencyRelay : IEmergencyHandler
   {
       public static readonly System.Collections.Generic.List<IEmergencyHandler> Listeners = new();
       [UnityEngine.RuntimeInitializeOnLoadMethod(UnityEngine.RuntimeInitializeLoadType.BeforeSceneLoad)]
       private static void Install() => EmergencyBroadcastService.RegisterHandler(new EmergencyRelay());
       public void Activate(EmergencyActivation a) { foreach (var l in Listeners.ToArray()) l.Activate(a); }
       public void Clear() { foreach (var l in Listeners.ToArray()) l.Clear(); }
   }
   ```
2. Done (not yet run): `POST http://<client>:8085/emergency/activate` with
   `{"identifier":"x","display":{"title":"t","message":"m"}}` reaches your listeners; `POST .../emergency/clear` clears.
   **V:** both routes register on the MP Windows client; the MP server logs no Dream Connect line, and MP Android has
   no Dream Connect module (O): no REST there. **V:** the template `AetherEmergencyWidget` registers before `Emergency
   Broadcast System initialized.`, so it works; `Widget 'AetherEmergancyWidget' already exists in layer` is non-fatal.

## Show the debug panel and add a tab

1. Move "Debug Panel Module Client" below `LoadFishnetScene` (MP) or `Load Application Scene Module` (SP) in every
   client profile. **V:** as shipped it initializes at client index 4, before `LoadFishnetScene` unloads
   Application.unity, so its GameObject is destroyed (CA-03; the destruction is I).
2. It needs a `PanelSettings` (default `DefaultDebugPanelSettings.asset`). Custom tab: subclass
   `DreamscapeLearn.DebugPanel.Core.DebugTab` (`base("Name")`, override `VisualElement CreateContent()`) and call
   `DebugPanelService.RegisterTab(new MyTab())` at `[RuntimeInitializeOnLoadMethod(BeforeSceneLoad)]`: tabs merge
   only on the first init (CA-28). Never restart the module (CA-49).
3. Done (not yet run): `/debug open` or `DebugPanelService.OpenDebugPanel()` shows the panel with your tab.

## Boot sequence (contracts)

- **Pre-scene hooks** (AfterSceneLoad: after scene 0 Awake, before Start) resolve every `VariableBase` and init
  `DataStoreService`, `ApplicationState`, `MessageBus` and console/logger commands. Read config in Start+ (CA-31).
- **Scene 0 = `Assets/Application/Application.unity`**, one root `SystemInitialization` (`_default` +
  `_platformTargets`; MP maps WindowsServer 44 and LinuxServer 43 to the server profile). Profile choice: editor =
  active build target (see Domain reload); player = `--PLATFORM <RuntimePlatform>`, else `Application.platform`.
  The profile registers every module first (duplicate id = abort, CA-06), then awaits each `Disabled` one in order.
- **Application.unity is bootstrap-only.** MP `LoadFishnetScene` and SP `Load Application Scene Module` load
  Single and unload it. Long-lived scenes: MP client Fishnet + PlayerScene, MP server Fishnet + ServerScene, SP
  PlayerScene; levels load additively on top.
- **Shutdown:** player `wantsToQuit` -> modules in reverse, 5 s each -> `Application.Quit()` -> watchdog
  `Environment.Exit(0)` 5 s later (exit code always 0, CA-35). Editor: synchronous reverse shutdown on Play exit.

**MP server module order (V, logged identifiers):** SystemLogger, EnvironmentManagement, EmergencyBroadcastSystem,
Register Server Application Scenes, LoadFishnetScene, Load Server Scene, RoleService, DreamFish Module, DreamFish
Start Server Module Server, Register Embedded Levels Module Server, GlobalAvatarRegistration,
InitializeCustomizationService, RegisterAvatarAccessories, Load Classroom Module. Load Classroom Module runs the
whole first transition (`[Sync] Server load starting levelId=ClassroomScene` ... `[TransitionSync] Transition
complete -> 'ClassroomScene'`) before it logs `initialized` (V).

**MP Windows client module order (V):** SystemLogger, DreamConnectModule, BroadcastingServiceModule,
EnvironmentManagement, DebugPanel, SessionRuntime_Pod, RegisterClientApplicationScenes, LoadFishnetScene, DreamFish
Module, LoadPlayerScene, XRInitializationModule, AudioSystem, EmergencyBroadcastSystem, RoleService,
DeviceIntegrationService, Register Embedded Levels Module Client, GlobalAvatarRegistration,
InitializeCustomizationService, RegisterAvatarAccessories, Load Level Module Client (`LoginScene`). Every stock
module returns true (V). Dev-PC boot noise: `xr-pod.md` (desktop recipe), `runtime-config.md` (known-benign noise).

**Other profiles (O):** MP Android = the client list without Dream Connect, with Session Runtime Cart (before Debug
Panel) instead of Pod. SP has no DreamFish, Start Server, RoleService, RegisterGlobalAvatar or Fishnet; it adds Load
Application Scene (Single), Define Start Scenes and CachePrefabAvatars.

**Editor entry points (O):** `Dreamscape DevKit/Project Configurator` (Ctrl+Shift+D) > Experience Setup > Level
Management (level wizard), Diagnostics > Application > Module Wizard (live module status; its stand-alone menu exists
only without the configurator), Developer Tools > Deployment (`build.md`); `Dreamscape DevKit/System Logger/Logging
Wizard`. DDK Create and Add Component menus start at `Dreamscape DevKit` (naming package `CreationContext.Header`).

## Service catalogue (static facades over private static implementations; no DI container; main thread only)

| Facade | What it is | Main API | Trap |
|---|---|---|---|
| `ApplicationControlService` | module lifecycle | `GetStatus`, `TryGetModule<T>`, `GetModule<T>(id, out m)`, `RestartModule(id)` | no timeouts (CA-05); `GetModule` true with null on type mismatch (CA-34) |
| `LevelManagementService` | levels and scenes | `LoadLevel`, `LoadScene`/`UnloadScene`, `LoadApplicationScene`, `TryGetLevelConfiguration` | mode fixed on first level call (CA-07); scene calls NRE with no level (CA-15) |
| `EventService` (LMS) | level events, phases, gate | `RegisterLevelHandler`, `RegisterPhaseHandler`, `RegisterTransitionHandler` | one gate, last wins; none = MP client freeze (CA-08) |
| `ContentManagementService` | remote Addressables catalogs | `LoadContentCatalog(id)`, `UnloadContentCatalog`, `GetResourceLocations<T>` | inert until a module initializes it; `version` ignored (CA-16) |
| `EnvironmentService` | typed `DSL_*` config | `GetValue<TVariable>()`, `GetValue(string)` | Add a config variable above; empty OS env var kills it in players (F-29, SKILL.md traps) |
| `LogService` | named loggers to targets | `CreateLogger`, `SetLogLevel`, `SetLoggerEnabled` | targets run on the caller's thread (CA-22); cleared on Play exit (CA-20) |
| `Engine` (Dream Console) | attribute commands | `RegisterType`, `RegisterInstance`, `Configure` | `Convert.ChangeType` args (CA-25); no unregister (CA-26) |
| `DebugPanelService` | UI Toolkit runtime panel | `RegisterTab`, `OpenDebugPanel`, `/debug open` | tabs only before first init (CA-28); template panel destroyed (CA-03) |
| `EmergencyBroadcastService` | emergency activate/clear fan-out | `RegisterHandler(IEmergencyHandler)` | handlers added after init never fire (CA-01) |
| `AudioService` | one AudioSource per mixer group | `Play(group, clip, params, cts)`, `AdjustMasterVolume` | null CTS NRE (CA-10); volume formula silences (CA-17) |
| `DataStoreService`, `DataStore<TKey,TModel>` | type-keyed locator over in-memory model stores | `Register<T>`, `TryGetDataStore<T>`; store `Add`/`Update`/`Get` + `OnData*` | locator keyed by compile-time `T`, `GetDataStore` throws (CA-46); `Get` throws on a miss; `Remove`/`Clear` raise no events |
| `ApplicationState` | process-wide `IStateEntry` bag | `AddDataEntry`, `TryGetDataEntry<T>` | first match by type; `IDisposable` entries disposed on quit |
| `PermissionsProfile` | string permission set | `SetPermissions`, `HasPermission`, `PermissionsChanged` | fires on every Set, never on Reset (CA-47) |
| `MessageBus` (`DreamscapeLearn.Utilities.Messaging`) | in-process pub/sub by runtime type; messages implement `IMessage` | `Subscribe<T>`, `Unsubscribe<T>`, `Dispatch<T>` | (un)subscribing inside a handler throws (CA-29) |

## Level management

- **Router lock-in.** `ServiceRouter` picks Server (FishNet `IsServerStarted`) or Client on the **first** level-API
  call and never revisits it (CA-07). Application-scene calls do not trigger the choice.
- **Single player** (and an MP client offline): Preload event, gate fade-in, persistent scenes additive in list
  order, lighting additive + `SetActiveScene`, Start event, fade-out. Unload: End, fade-in, Dispose, dynamic,
  persistent in forward order (CA-36), lighting. The load plan silently drops duplicate scene ids.
- **MP client.** Offline it loads Single-scope levels only ("Cannot load multiplayer level without a server
  started."). Connected, every load becomes a request (`LevelChangeRequest`/`SceneLoadRequest`, 6 s ack) and the
  server's PrepareSync/Replace payload installs a passive container (a teacher's switch takes this path). After a
  real session drops it blacks out, unloads non-application scenes and reloads the last Single-scope level.
- **MP server.** Multiplayer scope only; persistent + lighting load as FishNet global scenes; it honours only
  authenticated requesters.
- **Handshake** (`TransitionSyncCoordinator`): server End, FadeIn, Dispose, [Unload], Load, Preload, FadeOut, Start;
  clients answer Ended, FadedIn, Disposed, Unloaded, Loaded, Preloaded, FadedOut, Started. Each gate waits for every
  authenticated client counted at the start, 30 s per gate (CA-11). In MP, Preload fires **after** the server
  load. Phases travel as relay messages (ids 2000-2399, `networking.md`). **V:** with zero clients the server runs
  every gate in order (`[Sync] Gate ENDED passed (0/0)` ... `Gate STARTED passed`) and sends `[2201]`; a late joiner
  gets `[2200]` PrepareSync, then `[TransitionSync] Begin catch-up for client 0` ... `Client 0 caught up to Start`.
- **Gate.** The shipped `ITransitionGate` is the LMS `Fader` in the XR rig's `CameraFadeTrait`. Client FishNet
  scene loads wait until a gate is `Active` (CA-08; V: `Load pending gate: ClassroomScene`, later `Gate active` ...
  `flushing 1 pending load(s).`). A custom gate (`...LevelManagementSystem.Framework.Handlers.Transitions`) implements
  `bool Active`, `UniTask TransitionStart(TransitionArgs, CancellationToken)`, `void ProgressRefresh(TransitionArgs)`,
  `UniTask TransitionComplete(TransitionArgs, CancellationToken)`; register it with
  `EventService.RegisterTransitionHandler`. Unregistering any gate clears whichever gate is set (O).

## CMS runtime

- Inert until a `ContentManagementModule` or `ContentInitializer` calls `Initialize`; neither template has one, so
  `-DSL_CMS_ROOT_LOAD_PATH` does nothing by default (O). A resolved `DSL_CMS_ROOT_LOAD_PATH` beats `_rootLoadPath`.
- Catalog URL `{root}/{id}/{StandaloneWindows64|StandaloneLinux64|Android}/catalog.json` (servers use standalone).
  Bundles load from `{ContentManagementService.RootLoadPath}/{id}/[BuildTarget]`, which throws before init.
- Load each pack once through `LoadCatalogsModule` (`DownloadDependenciesModule` also pre-downloads every key), then
  load by address (default = asset path). A concurrent second load returns null, and a scene `CatalogLoader`
  unloads on OnDisable without ref counting (CA-18). A failed `LoadCatalogsModule` stays Initializing (CA-19).
  `PrefabLoader`/`TextureLoader` only raise `UnityEvent<T>`.

## Audio, traits, permissions, data stores

- **Audio.** The Audio module calls `AudioService.Initialize(mixer, "MasterVolume")`; the internal
  `AudioGroupSourceHandler` on the XR rig root makes one child AudioSource per mixer group (template: Master,
  Emergency, UI, Silent, Voip; no exposed parameters). `Play` stops whatever plays on that group; pass a new
  `CancellationTokenSource` (CA-10). Set volume with `20*log10(v)` on a parameter you expose (CA-17). Custom
  playback: subclass `AudioPlaybackController`, override `UniTask Action(CancellationTokenSource)` and
  `OnCompletion(bool)`, cancel in OnDestroy (CA-45).
- **Traits.** Subclass `DreamscapeLearn.XRPlatformService.Framework.Mono.Traits.AbstractXROriginTrait`, override
  `UniTask SetupAsync(CancellationToken)` (`Host.XROrigin` is ready; touching it needs an asmdef reference to
  `Unity.XR.CoreUtils`, CS0012 otherwise) and `TeardownAsync`, add the component to the rig and append it to
  `XROriginHost._traits` (one instance per type). Editor installers implement `ITraitConfigurationTask<XROriginHost>`
  and return `Validate` via `UniTask.FromResult` (`out` param, CA-48).
- **Permissions** come per user from user-service on the server (`networking.md`). **Data stores:** `AddInternal`
  must add the model to `DataModels` itself; `Add` throws when it returns false (O). Shapes:

```csharp
public static class MyPermissions   // dotted, lower-case, module-prefixed, must be const
{ [DreamscapeLearn.PermissionsFramework.Attributes.PermissionId] public const string Grade = "myexp.grade"; }
public sealed class Score : DreamscapeLearn.DataStore.Framework.DataModel { public int Points; }   // Id = new GUID
public sealed class ScoreStore : DreamscapeLearn.DataStore.Framework.DataStore<string, Score>
{ protected override bool AddInternal(Score m, out string key) { key = m.Id; return DataModels.TryAdd(key, m); } }
// DataStoreService.Register(new ScoreStore()); if (DataStoreService.TryGetDataStore(out ScoreStore s)) s.Add(...);
```

## Domain reload and Play Mode

- Keep "Reload Domain and Scene": only a domain reload resets the facades' static state. Without it (CA-30) the next
  Play session gets missing app scenes that "load" instantly, LMS stuck in the old mode, MessageBus NRE on every
  dispatch, duplicate console registrations and stale catalog handles.
- Play Mode profile = active build target. The MP template ships `_override: 0` with `_platformOverride: 11`
  (Android): ticking Override alone runs Android; set Platform Override = WindowsServer (44) for the server profile.
- On Play exit `SystemLoggerModule` clears every log target: DDK editor-tool logs vanish until a recompile (CA-20).

## Defects ranked (CA)

| # | ID | Symptom | Workaround |
|---|---|---|---|
| 1 | CA-07 | MP server loads no level: "Cannot load multiplayer level without a server started" | every server-profile LMS level call after `DreamFish Start Server` |
| 2 | CA-03 | debug panel never shows; GameObjects from early modules vanish | module after the Single-mode load, or `DontDestroyOnLoad` |
| 3 | CA-01 | emergency handlers registered after EBS init never fire | static forwarder at BeforeSceneLoad |
| 4 | CA-08 | MP client frozen on a black or old scene during a server load | keep `CameraFadeTrait` + LMS `Fader`, or register your own gate |
| 5 | CA-02 | client refused forever: "Request already in progress." | request only registered MP levels other than the current one; restart the server to clear |
| 6 | CA-06 | "Module Registration Failed", nothing boots | unique ids; one asset per fixed-id module type per profile |
| 7 | CA-05 | boot hangs, or runs on past a failed dependency | timeouts inside modules; check `GetStatus` first |
| 8 | CA-04 | documented module code does not compile | override `InitializeModule`/`RestartModule`/`ShutdownModule` |
| 9 | CA-09 | Unload Scene / Unload Application Scene components never unload (NRE) | call `LevelManagementService.UnloadScene`/`UnloadApplicationScene` |
| 10 | CA-10/17 | `AudioService.Play` NRE; `AdjustMasterVolume(1f)` silences; mute-all does nothing | pass a new `CancellationTokenSource`; own exposed parameter, `20*log10(v)` |
| 11 | CA-11/12 | level switch fails half-way, clients black; server global load awaits the wrong completion | fast phase handlers; `Time.timeScale` above 0; no parallel server scene loads; re-issue `LoadLevel` |
| 12 | CA-13/14/15 | Addressable level loads only its first scene; SP wizard level never loads; `LoadScene` NRE | select the configuration in the Inspector; Scope = Single in SP; `TryGetLevelConfiguration` first |
| 13 | CA-30 | second Play session broken | keep domain reload on |
| 14 | CA-31 | config values null, or startup exceptions | read in Start+; `GetValue<TVariable>()`; CLI duplicates: `runtime-config.md` |
| 15 | CA-16/18/19/33 | versioned packs never load; second load returns null; `LoadCatalogsModule` stuck Initializing; pack assets may come from the player build [Unknown] | flatten the version folder; load once via a module; wrap the module in yours that sets Error; untick Include in Build on pack groups |
| 16 | CA-20/21/24 | DDK editor logs vanish after Play; console shows no output or cannot open | recompile or re-enter Play; Console in PlayerScene; re-pick its key |
| 17 | CA-22/23 | garbled, doubled or huge `Log_*.log`; frame cost | `PrintLogTarget._captureUnityConsoleLogs` off; lock or queue in targets; Log Level Info/Warn |
| 18 | CA-25/26 | enum, `"1"` bool or quoted args fail; async commands lose exceptions; commands hit destroyed objects | simple types; `.Forget()` in try/catch; static commands |
| 19 | CA-27/28/49 | Log tab frozen at 50 lines; late tabs missing; restart duplicates UI | CLEAR; register at BeforeSceneLoad; leave the module running |
| 20 | CA-29/46/47 | MessageBus throws when a handler (un)subscribes; `GetDataStore` throws; `PermissionsChanged` fires on every Set | unsubscribe next frame, dispatch the concrete type; `Register<Concrete>` + `TryGetDataStore`; debounce |

Low (workaround in its section, or harmless): CA-32 published `EnvironmentVariables.json` breaks on `"` or `\`
(forward slashes, validate); CA-34; CA-35; CA-36; CA-37 `DeferActivation` is a no-op; CA-38 let cancelled
Addressable loads finish; CA-39 `HasApplicationSceneLoaded` stays true after unload; CA-44 `PersistentObject`
teardown exception; CA-45; CA-48; CA-50 Slack token in PlayerPrefs; CA-51 stay on Unity 6000.3.
Environment-management's top defects (F-29 empty env var, RC-01 repeated CLI key): `scripts/apply_ddk_patches.py`.
