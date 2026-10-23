# Experience authoring: logic graphs, checkpoints, UI, interaction

How to build experience content on the DDK authoring layer: Experience Logic graphs, the Checkpoint System,
Aether Canvas UI, XR Interaction Core with the joystick, and subtitles. Tags: **V** verified by a 6000.3.2f1 run on
the evidence machine (log line quoted; headless MP client `e2e2-client-teacher.log`), **O** observed in vendor code,
**I** inferred. Code shapes are compile-checked (C# 9 against the evidence project's built assemblies, with the
asmdef references named) but have never run, so their behaviour is I.
IDs (EXP-, CP-, AC-, XIC-, JOY-, SUB-, GEN-, XPS-F1, R1-R5) index `65-experience-authoring.md`, F- `05-lead-findings.md`
(evidence machine: `<re>\notes\`; elsewhere rebuild with the `dreamscape-ddk-re`
skill). Player launch and `DSL_*` config: `runtime-config.md`. XR runtime, desktop mode, devices: `xr-pod.md`.
Asmdefs, levels, console and debug panel: `architecture.md`.

## Ground rules (every recipe assumes them)

- Give content code its own asmdef: DDK runtime asmdefs are not autoReferenced (O). Runtime refs by feature:
  `DreamscapeLearn.ExperienceLogic.Core` + `.Essentials`, `DreamscapeLearn.CheckpointSystem`,
  `DreamscapeLearn.AetherCanvas`, `DreamscapeLearn.XRInteractionCore` (+ `Unity.XR.Hands` for effectors),
  `DreamscapeLearn.SubtitleSupport`. Custom graph nodes add an Editor-only asmdef referencing
  `DreamscapeLearn.ExperienceLogic.Core.Editor`, `Unity.GraphToolkit.Editor` and `Unity.GraphToolkit.Common.Editor`
  (home of `IPort`; without it the R2 node fails with CS0012 in the compile check), as the shipped Essentials.Editor
  asmdef does.
- The authoring packages are **islands**: neither template contains a `.logic_graph`, director, checkpoint or
  interactable, and no other package references Experience Logic or Checkpoints (O).
- Resolved pins (V, F-23: fresh resolve, 0 `error CS`): `com.unity.graphtoolkit 0.4.0-exp.2`, XRI 3.3.2,
  XR Hands 1.7.3, OpenXR 1.16.1, Localization 1.5.9.
- Graphs run **per-peer**: the server and every client execute their own copy (O). Shared state travels through
  DreamFish components (see "No networking in graphs").
- Console and Debug Panel steps assume the two template fixes in `architecture.md`: a re-picked console key
  (CA-24, "Add a console command") and the Debug Panel module moved after the Single-mode load (CA-03).
- Code beats docs. The docs describe nodes, fields and a package that do not ship (GEN-02).

## Recipe: trigger -> logic -> UI -> checkpoint (R1)

Keep the content scene in Build Settings, or open, whenever you save a graph (EXP-02).
1. Asmdefs: `Assets/Content/Logic/MyExp.Logic.asmdef` (EL Core, EL Essentials, CheckpointSystem) and
   `Assets/Content/Logic/Editor/MyExp.Logic.Editor.asmdef` (Editor only; MyExp.Logic, EL Core, EL Core.Editor,
   `Unity.GraphToolkit.Editor`, `Unity.GraphToolkit.Common.Editor`). Add the `ActivateCheckpoint` node from R2.
2. Checkpoints: three GameObjects with unique, stable names `Intro_Start` (StartCheckpoint), `Intro_Panel`
   (IntermediateCheckpoint), `Intro_End` (EndCheckpoint). Link both directions: Start.Child=Panel,
   Panel.Parent=Start, Panel.Child=End, End.Parent=Panel (CP-02). Wire each checkpoint's Activated UnityEvent
   to whatever restores the whole world for that step (a jump replays only the target, see Checkpoints).
3. UI: inside an `AetherLayerSetup` in this scene, author the panel as a child widget `InfoPanel`, inactive
   (build-safe layer, AC-01). Optional subtitle: a `LocalizedSubtitleDisplay` active at load and a
   `SubtitleServiceCaller`.
4. Trigger: GameObject `Gate` with a BoxCollider (Is Trigger) and `Basic Logic Director`. The entering object
   needs a Collider, a Rigidbody (kinematic is fine) and tag `Player`.
5. Graph: Create > Dreamscape DevKit > Experience Logic > Default Graph, name it `Gate`. Nodes:
   `OnTriggerEnter` (Tag `Player`) -> `SetActive` (Override Agent `Panel`, Active true) -> `ActivateCheckpoint`
   (`Intro_Panel`) -> `DebugLog`.
6. Bindings on Gate's director: Runtime Graph = `Gate`; GameObject Bindings `+`: Id `Panel`, GameObject `InfoPanel`.
7. Resync: with the scene open, right-click `Gate.logic_graph` > Reimport. Check in Inspector Debug mode that `Gate`
   now has a disabled `OnTriggerEnterEventRouter` and filled binding lists. Save the scene.
8. Play from `Assets/Application/Application.unity` with the graph window open: pulses run along the wires.
9. Multiplayer: put a `ServerOnly` gate right after the event, or keep the whole flow client-local (EXP-10, CP-03).
10. Done (not yet run): entering `Gate` shows `InfoPanel`, the Console has no `Missing required router` line, and
    `/checkpoint log` answers `Active checkpoint: Intro_Panel`.

No-code variant of step 5: `TriggerActivator` on `Gate` -> `Intro_Panel.Activate()`; the checkpoint's Activated
event -> `InfoPanel.SetActive(true)` + `SubtitleServiceCaller.ShowLocKey("intro_panel")`.

## Recipe: a custom node (R2)

```csharp
// Runtime asmdef MyExp.Logic
using System; using DreamscapeLearn.CheckpointSystem; using UnityEngine;
using DreamscapeLearn.ExperienceLogic.Core.Nodes.Framework; using DreamscapeLearn.ExperienceLogic.Core.Nodes.Variables;
namespace MyExp.Logic {
  [Serializable] public class ActivateCheckpointRuntime : LogicRuntimeFlow {
    [SerializeReference] public VariableSource<string> Identifier;            // constant or wired value
    public override void InvokeFlowOut(float deltaTime) {
      string id = Identifier?.GetValue();
      if (!string.IsNullOrEmpty(id)) CheckpointService.ActivateCheckpointRecursively(id);
      base.InvokeFlowOut(deltaTime);                                          // continue FlowOut
    } }
  [Serializable] public class ServerOnlyRuntime : LogicRuntimeFlow {          // asmdef also refs FishNet.Runtime
    public override void InvokeFlowOut(float dt) { if (FishNet.InstanceFinder.IsServerStarted) base.InvokeFlowOut(dt); } }
}
```
```csharp
// Editor-only asmdef MyExp.Logic.Editor
using System; using MyExp.Logic; using Unity.GraphToolkit.Editor;           // also brings DDK's PortCapacity/WithCapacity
using DreamscapeLearn.ExperienceLogic.Core.Editor.Graphs; using DreamscapeLearn.ExperienceLogic.Core.Editor.Nodes.Framework;
namespace MyExp.Logic.Editor {
  [Serializable, UseWithGraph(typeof(DefaultGraph))]                          // lists it in "Add a graph node"
  public class ActivateCheckpoint : LogicFlowNode<ActivateCheckpointRuntime> {
    protected override void OnDefinePorts(IPortDefinitionContext context) {
      base.OnDefinePorts(context);                                            // Reference out, Flow In, FlowOut
      context.AddInputPortAndDisplayName<string>(nameof(ActivateCheckpointRuntime.Identifier))
             .Build().WithCapacity(PortCapacity.Single); }
    protected override void OnSetupConnections(ActivateCheckpointRuntime runtime) {
      base.OnSetupConnections(runtime);                                       // resolves FlowOut
      runtime.Identifier = ResolveVariableSource<string>(
        GetInputPortByName(nameof(ActivateCheckpointRuntime.Identifier))); } }
  [Serializable, UseWithGraph(typeof(DefaultGraph))] public class ServerOnly : LogicFlowNode<ServerOnlyRuntime> { }
}
```
- Name each port after its runtime field: graphs persist port names and `{class, ns, asm}` triples, so rename
  with `[UnityEngine.Scripting.APIUpdating.MovedFrom]`. After editing a node class, reimport its graphs (EXP-07).
- Runtime classes: `[Serializable]`, public parameterless ctor, `[SerializeReference]` for runtimes,
  `VariableSource<T>` and `IRuntimeFlow[]`, `[SerializeField]` for plain data (IL2CPP keeps them via link.xml, O).
- **Custom event.** A receiver interface deriving `IEventReceiver`, a **public**, non-abstract router that derives
  `BasicEventRouter<TReceiver>` and also implements `TReceiver` (EXP-15), a runtime that calls `Invoke`, and an
  editor node. Add the node, then reimport the graph so the router component lands on the agent. Sketch:
  ```csharp
  // Runtime: using DreamscapeLearn.CheckpointSystem(.Framework.Events/.Framework.Progression),
  //          DreamscapeLearn.ExperienceLogic.Core.Events.Framework, ...Core.Nodes.Framework
  public interface IOnCheckpointActive : IEventReceiver { void OnCheckpointActive(string id); }
  public sealed class CheckpointActiveRouter : BasicEventRouter<IOnCheckpointActive>, IOnCheckpointActive,
      ICheckpointStateChangedEventHandler
  {
      private static readonly Action<IOnCheckpointActive, string> Notify = (r, id) => r.OnCheckpointActive(id);
      private void OnEnable() => CheckpointService.RegisterEventHandler(this);   // the director enables routers
      private void OnDisable() => CheckpointService.UnregisterEventHandler(this);
      public void OnCheckpointStateChanged(CheckpointProgress p)
      { if (p.State == CheckpointState.Active) NotifyReceivers(Notify, p.Identifier); }
      void IOnCheckpointActive.OnCheckpointActive(string id) { }
  }
  [Serializable] public class OnCheckpointActiveRuntime : LogicRuntimeEvent, IOnCheckpointActive
  {
      [SerializeField] public string Identifier;                                 // empty = any checkpoint
      void IOnCheckpointActive.OnCheckpointActive(string id)
      { if (string.IsNullOrEmpty(Identifier) || Identifier == id) Invoke(Time.deltaTime); }
  }
  // Editor: [Serializable, UseWithGraph(typeof(DefaultGraph))] public class OnCheckpointActive
  //   : LogicEventNode<OnCheckpointActiveRuntime, CheckpointActiveRouter>; add the Identifier port as above and set it in
  //   OnTranslateNodeToRuntimeNode(runtime) via this.GetInputPortValueByPortName<string>(nameof(...Identifier)).
  ```
- Per-director graph instances (EXP-01): use this director instead of `BasicLogicDirector` (the edit-mode branch
  returns the source asset, so resync still matches it by asset path):
  ```csharp
  public class InstancedLogicDirector : LogicDirector {   // DreamscapeLearn.ExperienceLogic.Core.Graphs(.Framework)
    [SerializeField] private BasicRuntimeGraph _runtimeGraph; private LogicRuntimeGraph _instance;
    public override LogicRuntimeGraph RuntimeGraph =>
      !Application.isPlaying ? _runtimeGraph : (_instance ??= _runtimeGraph ? Instantiate(_runtimeGraph) : null); }
  ```
- Done (not yet run): the node is listed in Add a graph node, the graph reimports with no Console error, and in
  Play the pulse passes through it.

## Recipe: a grabbable networked object (R3)

1. GameObject with MeshRenderer, Collider, Rigidbody and `XRGrabInteractable`. Set its Interaction Layer Mask
   to a layer the rig's Near-Far Interactor uses (`Assets/XRI/Settings/Resources/InteractionLayerSettings.asset`).
2. Create two effectors (Create > Dreamscape DevKit > Interaction Core > HandFX > Hand Pose Effector). Add
   `NetworkedInteractable` (single-player: `OfflineInteractable`) and fill Hand Effector Left **and** Right
   (XIC-02). Optional conditions: `StealingAllowed`, `GhostCondition`, `SnapOnGrabCondition`.
3. In its inspector press "Generate Default Network Object" and "Generate Default Network Transform", then
   change any property and save the scene so the generated values serialize (XIC-03). Result: `NetworkObject`
   + `NetworkTransform` (Rigidbody mode, client authoritative, sync parent).
4. Scene object: leave it in a level scene. Spawned object: a prefab with a real `AssetPathHash`, spawned by the
   server: `networking.md`, "Recipe: networked object" steps 3-4.
5. Each hand interactor carries `HandFXInteractor` pointing at its `HandFXProcessor`; the player scene has one
   `RegisterXRInteractionRig`.
6. Test with a server and two clients (`networking.md`, local multiplayer smoke test; a teacher + student pair on
   one PC is V, F-33): grab on A, watch B.
7. Done (not yet run): B sees A's grab move the object, and B's grab waits until A releases (unless the
   coordinator's `_instant` is ticked).

## Recipe: test without a headset (R4)

1. Editor: main toolbar "Toggle Desktop Mode" on (mechanism: `xr-pod.md`, desktop recipe). Press Play in
   `Assets/Application/Application.unity`. The rig's `DesktopSimulatorTrait` spawns the XR Device Simulator.
2. Keep the simulator reference the template ships; leave the "Desktop Simulator Trait" configuration task
   unrun and unaccepted (XIC-01).
3. Logic: graph window open during Play, `DebugLog` nodes in the flow. Reimport the graph before trusting
   initial blackboard values: Play mutates the imported asset (EXP-16).
4. Checkpoints: `/checkpoint activateAll <id>` jumps (recursive) and answers `Checkpoint '<id>' and its children
   activated.`; `/checkpoint log` prints the active one. The Checkpoint tab in `/debug open` also needs a
   `CheckpointTeleporter` (CP-07) and the early touch in Checkpoints.
5. Aether: assign the controller camera; look for `<scene>/<layer>` roots in the Hierarchy. Subtitles: display
   context menu "Preview Subtitle".
6. Joystick: with no physical stick the `VirtualJoystickDevice` is chosen; read values in the Input Debugger.
7. Multiplayer content needs a running server build: Play mode never selects the server profile.
8. Player smoke test: a headless no-HMD client takes the simulator path by itself (V, `xr-pod.md`). Good for
   boot and flow checks; hand-driven interaction needs the editor simulator or a headset.
9. Done: after `Module XRInitializationModule initialized` the XR Device Simulator instance sits under the XR
   origin in the Hierarchy, and the Console has no `Missing required router` line. `Setup complete:
   DesktopSimulatorTrait` alone proves nothing: it logs before XR init, ahead of the spawn (V order).

## Experience Logic

**Model (O).** Editor-only graph nodes (Graph Toolkit `Node` subclasses) describe ports and options. Import
translates each into a runtime `LogicRuntime` POCO held with `[SerializeReference]` in a ScriptableObject, so
players never load Graph Toolkit. Node kinds: Event (`LogicEventNode<TRuntime[,TAgent]>` -> `LogicRuntimeEvent`),
Flow (`LogicFlowNode<T>` -> `LogicRuntimeFlow`), Value (`LogicValueNode<T,V>` -> `LogicRuntimeValue<V>`). Every
node also has a `Reference` output so other nodes can hold it (e.g. `StopRepeating` -> `RepeatAsync`).
123 nodes ship; the 4 list nodes are undocumented; the 12 documented FishNet nodes do not ship.

**Where the runtime graph lives (O).** `Name.logic_graph` is GTK YAML (`GraphObjectImp`). The ScriptedImporter
`DefaultRootGraphImporter` adds a `BasicRuntimeGraph` sub-asset named `RuntimeGraph` as the main object, with the
fixed local fileID `-8116140793486648412`. A director in scene YAML therefore reads
`_runtimeGraph: {fileID: -8116140793486648412, guid: <graph .meta guid>, type: 3}`. The field is private with
no setter: assign it in the inspector or YAML, or subclass `LogicDirector` and override `RuntimeGraph`.

**Execution (O).** Flow is push: depth-first, synchronous, try/catch per target (exceptions are only logged; a
flow cycle overflows the stack, EXP-14). Values are pull: each input is a `VariableSource<T>` (upstream node or
inline constant). Async nodes (`DelayAsync`, `RepeatAsync`, `OnTimer`, `OnInterval`) run UniTask loops on Update
and cancel on disable; use them to break loops. The director binds, initializes and starts in Awake, stops in OnDisable.

**Variables and agents (O).** Blackboard types: float, bool, string, Vector3; Get/Set nodes exist for Float and
Bool only (EXP-09: use float counters). One runtime per variable, mutated in the imported asset (EXP-16). A node's
`Override Agent` option names a `GameObjectBindings.Id` on the director; empty = the director's own GameObject.

**Events and routers (O).** Unity messages reach hidden, disabled `EventRouter<TReceiver>` components on the
agent GameObject. Ten ship: OnStart, OnEnable, OnDisable, OnDestroy, OnUpdate, OnLateUpdate, OnFixedUpdate,
OnTriggerEnter, OnTriggerExit, UserTrigger. `UserTriggerEventRouter.Trigger()` is public, visible in the inspector
and UnityEvent-wirable: the entry point for script-to-graph and cross-graph events. `OnInputActionPerformed` enables
its own inline action. A router missing at runtime logs `Missing required router ... Make sure EventRouterSync ran
for this graph.` and that event never fires.

**Reimport-to-resync (O).** Routers and bindings are written only after a graph imports: `LogicResyncForGraph`
syncs directors in open scenes, rewrites dependent prefabs, and opens, syncs and **saves** every enabled
Build Settings scene that uses the graph (EXP-08). No inspector hook exists. So after assigning a graph, editing
bindings, or changing node code or a subgraph: open the scene (Addressable-only scenes are never visited),
then Reimport the graph. Commit scenes first and expect router/binding diffs.

**Graph Toolkit pin (EXP-04, EXP-05).** The editor assembly reaches 15 internal GTK members by reflection
(every port's capacity goes through internal `PortModel.Capacity`), injects public types into GTK's namespace,
and graph files persist GTK internal type names. Failures are swallowed into later NREs. Hold
`com.unity.graphtoolkit` at exactly `0.4.0-exp.2`: it still resolves and compiles (V), and nothing else requests
the package, so UPM keeps it. On editor load, `Failed to locate type` / `Failed to locate assembly` in the
Console means the pin moved. Whether the reflection paths survive a real graph import is untested (I).

**No networking in graphs (O, EXP-10).** EL has no FishNet, RPC or SyncVar code. Replace it with a `ServerOnly`
gate node (or its `ClientOnly` mirror), DreamFish components for shared state, `NetworkedInteractable` for objects,
and a server-validated checkpoint message. Headless-server physics and input events rarely match the clients'.

**experience-coordination is absent (O, GEN-01).** Seventeen doc pages describe `ExperienceCoordinationService`,
actions, events and Dream Connect routes `/experience/{snapshot,actions/invoke,actions/icon,subscribers/*,
lifecycle/*}`; zero code ships. DreamStation still calls those routes on each station's Dream Connect port 8085
(`DreamConnectPort` default), so Hostess experience triggers and lifecycle buttons fail. Replacement: Dream
Connect `[HttpRoute]` request classes on those paths (how: `networking.md`, DreamConnect HTTP 8085), routed to
`UserTriggerEventRouter.Trigger()` or checkpoint jumps by action id (R5, I). JSON shapes:
`_re\extract\docs_md\docs__packages__experience-coordination__transport.md`.

## Checkpoints

- Checkpoints are MonoBehaviours (the package text says ScriptableObjects). `Identifier` = the GameObject name,
  so names must be unique across loaded scenes and stable at runtime (CP-05). Linear types: `StartCheckpoint`
  (Child), `IntermediateCheckpoint` (Parent + Child), `EndCheckpoint` (Parent); Timeline variants replay a
  `PlayableDirector` from a frame count.
- State lives in the static `CheckpointService`: one active checkpoint globally, progress Inactive / Active /
  Complete per id, `OnCheckpointStateChanged` via `ICheckpointStateChangedEventHandler`.
- `ActivateCheckpoint(id)` activates one (a no-op if it is already Active). `ActivateCheckpointRecursively(id)`
  resets descendants (Child links), marks ancestors Complete (**Parent** links, which the docs never set: CP-02),
  then activates the target.
- **A jump replays only the target.** A recursive jump (`activateAll`, `LoadProgress`, the network echo) fires
  every descendant's Reset event and the target's Activated event (when its Trigger Events On Recursive
  Activation is ticked, the default). Ancestors are only marked Complete: their Activated events never fire. So
  each Activated event must restore the full world state of its step, not a delta (O).
- Persistence: `SaveProgress()` returns `{"ActiveCheckpointIdentifier":"<id>"}` and `LoadProgress(json)` jumps
  to it. World state comes back only through the checkpoints' UnityEvents; nothing is written to disk.
- `CheckpointTeleporter.Teleport(id)` copies the checkpoint's pose to its own transform (console `tp`, `tpid`).
  `TriggerActivator` / `CollisionActivator` fire UnityEvents from physics messages.
- Console commands and the Debug Panel tab register when `CheckpointService` is first used, normally at the first
  checkpoint's Awake. The tab then misses the panel, which merges tabs only on its first init (CA-28; O). Touch the
  service earlier: `[RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)] static void Warm() =>
  CheckpointService.GetCheckpoint();` (runs before ACS starts; I, not run).
- Networking: `BroadcastServerCheckpointActivation(id)` goes client -> server, which echoes it to all clients
  without applying it; auth is off and late joiners get nothing (CP-03). Classroom use: your own server-validated
  message that also applies on the server and replays the active id when a client connects.
- The asmdef needs FishNet, DreamFish, DebugPanel and UniTask though `package.json` omits them (CP-06; the
  templates have them). Keep checkpoints in a scene that outlives the active one (CP-01).

## Aether Canvas and layers

- One `AetherCanvasController` per scene; the first registered camera owns the service. Assign `_targetCamera`
  explicitly on XR rigs: `Camera.main` is sampled once in Awake (AC-03). Layer names are global and prefixed
  `<scene name>/`.
- Layers: static = rigid head-locked canvas at `distance`; dynamic = `Lerp`, `Smooth` (lazy follow) or `Locked`
  (world-anchored, default). Standalone follow components: `LazyFollowPanel`, `SmoothFollow`, `PinToWorldAnchor`,
  `Billboard`, `TurnTo`, `SeatAnchoredUI`, `AttachUIToSeatAnchor`.
- **Editor-only prefab load (AC-01).** Code-created layers load their prefab through `AssetDatabase` under
  `#if UNITY_EDITOR`; players get a bare scale-1 canvas. **V:** the stock MP client logs `[AetherCanvas] AetherLayer
  prefab not found. Creating layer manually for 'LoginScene/LoginDynamicLayer'.`, so the template LoginScene hits it.
  Build-safe pattern: author the layer root and its widgets in the scene under `AetherLayerSetup` (it registers
  existing children), or instantiate the layer prefab from a serialized reference and call `RegisterExisting*Layer`.
- **Theme from EditorPrefs (AC-02).** In the editor `AetherCanvasSettings.Instance` loads the path in
  EditorPrefs `AetherCanvas_SettingsAssetPath` (per user); players have only `SetInstance`, which nothing calls.
  Add a bootstrap to the first scene (asmdef ref `DreamscapeLearn.AetherCanvas`):
  ```csharp
  [DefaultExecutionOrder(-2000)] public class AetherThemeBootstrap : MonoBehaviour {
    [SerializeField] private DreamscapeLearn.AetherCanvas.Mono.ScriptableObject.AetherCanvasSettings _settings;
    private void Awake() => DreamscapeLearn.AetherCanvas.Mono.ScriptableObject.AetherCanvasSettings.SetInstance(_settings); }
  ```
- Keep the ~25 `Aether*` tags (styling is tag-driven; re-added to TagManager on every import). Pass a dedicated
  empty root as `AetherCanvasService.RegisterCamera(camera, customRoot)`: the service destroys it with the last
  controller (AC-04).
- The rig's `CameraFadeTrait` starts opaque (black). LMS level loads fade it out through the LMS `Fader` gate (V:
  after LoginScene the client logs `Fade to 0 (duration: 0.35)` from `Fader.TransitionComplete`). Call
  `originHost.FadeOut()` yourself only for content shown outside an LMS level load (XPS-F1).
- `UIRoleController` toggles teacher/student roots from the user role (client-side UI only). The single-player
  Cart/Pod/Dream Central modules are demo code with hardcoded hosts and default login codes (AC-05, AC-06).

## XR Interaction Core, hands, joystick

- XRI pins: aether-canvas asks 3.1.2, XIC 3.3.1, xr-avatar-calibration 3.3.2; UPM resolves **3.3.2** (V). The
  rig's simulator is the XRI **3.1.2** sample under `Assets/Samples/XR Interaction Toolkit/3.1.2/`; keep that
  folder (the rig references its prefab GUID).
- The template rig is hand-tracking only: Near-Far, Poke and Gaze interactors plus a hand visualizer, no
  locomotion, controller profiles off. `ControllerTrait` enables XRI move/turn providers in the editor only
  (toolbar "Toggle Controllers"); players need your own locomotion (XIC-04).
- Interactables: `OfflineInteractable` or `NetworkedInteractable` beside an `XRBaseInteractable`. On select they
  instantiate per-object copies of their `InteractionCondition` assets and push per-hand **hand effectors**
  (`HandEffectorBase` ScriptableObjects: `HandPoseEffector`, `UIPokeEffector`) to the grabbing hand's
  `HandFXInteractor` -> `HandFXProcessor`. `EmptyHandEffector` is not a `HandEffectorBase`; for a no-op hand use
  `public sealed class NoOpHandEffector : HandEffectorBase { public override void EffectHand(XRHand h, XRHandSubsystem s) { } }`
  with `[CreateAssetMenu]` (namespaces `DreamscapeLearn.XRInteractionCore.HandFX.Mono`, `UnityEngine.XR.Hands`).
- Networked grabs: `NetworkedInteractable : OwnershipCoordinator` (FishNet `NetworkBehaviour`; namespace
  `Integrations.DreamFishInteractions`, asmdef `DreamfishInteractions`, define `USING_DREAMFISH`). Grab sends a
  `RequestOwnership` ServerRpc; the server grants when unowned (or at once with `_instant`), else queues until
  release. Transforms are client authoritative, and any client can claim for any connection (NW-23). Docs call it
  experimental. `RegisterXRInteractionRig` fills the static `InteractionRigManager`; release it on rig destroy (XIC-05).
- **Desktop simulator.** The no-HMD path and its V log order live in `xr-pod.md`, "Recipe: desktop, no HMD".
  Authoring facts: `DesktopSimulatorTrait` (first rig trait) waits, fire-and-forget, for `XRInitializationModule`,
  then instantiates `_simulatorPrefab`, the XRI **3.1.2** sample prefab, under XRI 3.3.2 (the legacy
  `XRDeviceSimulator` still ships: V, in the sample UI's benign exception stack). Whether it drives the hand-only rig
  usefully is I. Its configuration task nulls that reference (XIC-01); it spawns once per trait setup, so reload
  the scene after a teardown (XIC-04).
- **Joystick:** `JoystickManager` activates the first available DIS device (`PhysicalJoystickDevice` when
  `Joystick.current` exists at start, else `VirtualJoystickDevice`), spawns it at `_joystickSpawnPoint`, and moves
  `_spawnPoint` by its actions. Read input through actions `Joystick/Direction` (Vector2), `Joystick/Dpad`,
  `Joystick/Rotation`, `Joystick/Trigger`, with an InputActionManager enabling the asset (JOY-01).

## Subtitles and localization

- Static `SubtitleSupportService`: displays register by string `Id` in `OnEnable`, plus a default display and
  category flags `Dialogue`, `SoundEffect`, `AlwaysVisible`. Displays must be **active at scene start** (they
  self-hide) and carry explicit unique Ids; the editor renames Id `Default` to the GameObject name (SUB-03).
- `LocalizedSubtitleDisplay` payloads: null/empty = the default `LocalizedString`, `loc:<key>` = key in that
  table, anything else = literal text. Keep "Update While Visible" on and the default table set (SUB-01).
  Also: Aether `SubtitleWidget`/`LocalizedSubtitleWidget`, a Timeline track, and `SubtitleServiceCaller`
  (UnityEvent-wirable `Show`, `ShowLocKey`, `Hide`).
- Localization Settings live inside the XR Avatar Calibration **sample** folder; tables are Addressables groups
  `Localization-*`. Move `Localization Settings.asset` to `Assets/Settings/Localization/` and re-register it
  before touching samples (SUB-02). `DDK.AgentBuild.DDKAgentBuild` builds Addressables before every player (V).

## Defects, ranked (dev-PC impact)

| id | sev | symptom | fix |
|---|---|---|---|
| EXP-02 | high | Events never fire; `Missing required router` | Reimport-to-resync, above |
| EXP-01 | high | Two directors on one graph cross-talk (shared variables, timers, bindings) | One graph per director, or `InstancedLogicDirector` |
| AC-01 | high (V) | UI layer looks right in editor, wrong in builds | Author layers in the scene (build-safe pattern) |
| AC-02 | high | Theme in editor, none in builds | `AetherThemeBootstrap` |
| CP-01 | high | `KeyNotFoundException` / `MissingReferenceException` after unloading the active checkpoint's scene | Persistent checkpoint scene, or `ResetAllCheckpoints()` before unloading |
| CP-02 | high | Recursive jump skips ancestors, or hangs | Set Parent and Child on every link; no self links or cycles |
| EXP-03 | high (I) | Flow out of / values into a subgraph dropped; a subgraph used twice shares nodes | Event-rooted or value-only subgraphs, each used once; Play-test each boundary |
| EXP-04/05 | high | All nodes NRE, or CS0433/CS0121 ambiguity, after a Graph Toolkit change | Restore the exact pin |
| XIC-01 | high | Simulator reference becomes null | Leave the configuration task unrun; restore the 3.1.2 sample prefab reference |
| GEN-01 | high | Hostess triggers and lifecycle buttons error | Implement `/experience/*` (R5) or tell operators |
| EXP-10 | med | Graph side effects run on server and every client | `ServerOnly` gate; DreamFish for shared state |
| CP-03 | med | Any client jumps everyone; late joiners unsynced; NRE without FishNet | Own server-validated message |
| CP-04 | med | Checkpoint console + Debug Panel tab ship in release; `load <path>` reads any file | Drop `dream-console`/`debug-panel` from release manifests, or gate in a fork |
| EXP-06 | med | NRE in `LogicDirector.Awake` in release builds only | Never leave Runtime Graph empty; also test a Development Build |
| EXP-07 | med | Edited node or subgraph has no runtime effect | Reimport dependent graphs |
| EXP-08 | med | Saving a graph rewrites unrelated scenes and prefabs | Commit first; expect diffs |
| EXP-09 | med | Int blackboard variable "Unsupported", disconnected | float, or custom Set/Get nodes |
| AC-03 | med | Static layers refused; follow panels frozen | Assign `_targetCamera`; tag `MainCamera`; `AetherCanvasService.RegisterCamera` after the rig spawns |
| AC-04 | med | Your `customRoot` destroyed on shutdown | Dedicated empty root |
| AC-05 | med (I) | Pod Api Initialization Module shows a missing script | Keep it out of profiles |
| AC-06 | med | Single-player backend: fixed editor MAC, unhandled `First()`, cached `system.xml`, default PIN codes | `override_files/system.xml` in editor; per-experience codes |
| XIC-02 | med | `The Object you want to instantiate is null` at Start | Both effector fields set (no-op effector above) |
| XIC-03 | med | Generated network settings lost; client-chosen owner; client-authoritative motion | Touch a property and save; validate ownership server-side in a fork |
| XIC-04 | med | No controller locomotion in players; simulator gone after teardown | Own locomotion providers; reload scene |
| SUB-01 | med (I) | Localized subtitle blank | Update While Visible on; default table set |
| SUB-02 | med | Localization breaks after sample re-import; tables missing in build | Move settings asset; build Addressables |
| XPS-F1 | med | Screen stays black; NRE on trait re-setup | `FadeOut()` when content shows outside an LMS load; run trait setup once |
| CP-05 | med | Duplicate-name checkpoint silently ignored | Unique names like `Scene_CP_Name` |

Low: EXP-11 (OnTrigger Tag filter may not round-trip; filter downstream), EXP-12 (only 3 of 8 samples
importable; copy `Samples~/<name>` from the package cache), EXP-13 (`Failed to get windowGraph for window.`
spam while another GTK window is open), EXP-15, EXP-17 (`LogicResyncForGraph` is editor-only; keep it off
GameObjects), CP-06, CP-07 (`_defaultTime` is frames), AC-07, XIC-05, XIC-06 (stay on 6000.3.x), JOY-01, SUB-03, GEN-02.
