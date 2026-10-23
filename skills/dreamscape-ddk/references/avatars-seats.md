# Avatars, seats, groups, roles

How a multiplayer DDK player gets a role, a group, a seat and an avatar, and the traps at each step. Tags: **V**
verified by running a 6000.3.2f1 build, **O** observed in vendor code, **I** inferred. IDs (D-, M-) index
`<re>\notes\60-avatars-seats-groups.md`; F- is `05-lead-findings.md`, TB-
`10-templates-and-build.md`, NW- `networking.md`. Launching players, login, PIN codes and the headless hook:
`runtime-config.md`. V log lines, under `_re\runtime\logs\`: `smoke-server-cleanenv.log` (from line 5053) with
`e2e2-client-teacher.log` (one headless teacher), and `two-server.log` with `two-client1-teacher.log` /
`two-client2-student.log` (teacher and student).

## Ground rules (every seat or avatar change)

1. Test with a **dedicated server process** plus clients. Host mode (server and client in one process) gives the
   local player no avatar and silently drops its GMS commands (D-02).
2. Ship **twin builds**: server and client built from one committed set of scenes. Each client resolves the
   server's seat GUID in its own seat registry; a GUID that differs between the builds leaves the avatar unseated
   with IK off (D-04); V: separately built twins agree on all 31 pairs. The seat validator saves scenes during
   every build: commit after building (TB-16).
3. Keep the seats and `GroupInit` (`DefaultGroupInitializer`) in the same FishNet-loaded scene, `AutoRegisterSeat`
   on Awake. The server sizes the avatar pool from the seat count at GMS init; a count of 0 fails every spawn (D-01).
4. Keep the default avatar on a `PrefabAvatarSource` and `OverrideAvatars` on, as the template does (D-07, D-10).
5. Put recipe code in your own asmdef that names every assembly it touches: `DreamscapeLearn.{SeatManagementSystem,
   GroupManagementSystem,AvatarManagementSystem,TraitsFramework,UserService,DreamFish}`, `FishNet.Runtime`, `UniTask`
   (add `DreamscapeLearn.XRAvatarCalibration` for calibration code).

## Recipe: N-seat layout (MP, editor)

1. In the GMS scene, under `SeatRoot`, place N instances of the MP `Assets/Application/Prefabs/StandardSeat.prefab`
   (never the SP copy: same GUID, other content, D-38). Rotate the seat GameObject to set facing: the avatar copies
   the seat rotation.
2. On each instance set **Seat Number** 1..N and press **Regenerate GUID for this Seat**. Every copy starts with the
   prefab's Number 2 and the prefab's GUID, and nothing renumbers it (M-03). The button writes through
   SerializedObject, so the prefab override persists (D-11).
3. Teacher seat: duplicate a seat, replace `StandardSeat` with `InstructorSeat`, point `AutoRegisterSeat._seat` at
   it, Number 0. Add `ObserverSeat` / `FloatingSeat` seats when users with those roles will join (D-17).
4. Anchors on each seat GameObject: `DeskEdgeAnchor` (desk calibration) and `SeatVisualAnchor` (chair re-parent,
   `_avatarOffset`) are required; `DeskTopAnchor` hosts the Aether teacher/student panels and the joystick fallback;
   `JoystickAnchor` places the joystick. `DeskRootAnchor` is optional (only DS `ChairConstraintTrait` reads it). V:
   template StandardSeats register `DeskEdge`, `DeskTop`, `SeatVisual`, `JoystickAnchor`; only the instructor seat
   adds `DeskRoot`. An empty `AutoRegisterSeat._anchors` list takes every anchor on the seat GameObject (O).
5. Give each role at least as many seats of its type as users, and set `GroupInit` >
   `_configuration._maxUsersPerGroup` to at most that seat count. The template allows 32 users per group on 30
   StandardSeats, so students 31-32 stack on seat 1 (D-17). Auto-assign makes one group per role (Assignment, below).
6. Save, commit, make twin builds. Done = no `Duplicate seat number` / `Duplicate seat Identifier detected` in the
   build log, no scene diff after the build, the server log shows N+1 `Seat Added: GUID=` lines and
   `Cached N+1 instances of avatar '<prefab name>'.`, and a client logs the same GUID/Number pairs (plus LoginScene's
   `Workstation`). Dream Console (re-pick its activation key first: architecture.md, CA-24) `/sm countStandard` answers `There are N StandardSeat(s).` (O).

Seat Wizard (Project Configurator > Experience Setup > Layout; its menu item is compiled out, D-37) "Refresh
Numbering" renumbers all types together from 0 (M-04): restore Instructor 0 / Standard 1..N, then save the scene.

**Runtime variant [I, not compiled].** The vendor hook `ApplyRoomConfigurationAsync` rolls a random GUID per peer
(D-05), and validators skip runtime seats. Instead, in `Awake` of an object in the GMS scene on server and clients,
instantiate a seat prefab variant **without** `AutoRegisterSeat` (it registers in Awake, before you can set the id):

```csharp
// usings: System, System.Security.Cryptography, System.Text,
//         DreamscapeLearn.SeatManagementSystem.Framework.Mono (AbstractAnchorPoint), ...SeatManagementSystem.Internal.Seats
StandardSeat seat = Instantiate(_seatPrefab, transform).GetComponent<StandardSeat>();       // per seat n
seat.transform.SetLocalPositionAndRotation(new Vector3(n % 6, 0f, 2f * (n / 6)), Quaternion.identity);
seat.Number = n + 1;                                       // unique per seat type
using (MD5 md5 = MD5.Create())                             // derived id: every peer computes the same GUID
    seat.Identifier = new Guid(md5.ComputeHash(Encoding.UTF8.GetBytes($"{_layoutId}:{n}"))).ToString();
seat.RegisterSeat();
foreach (AbstractAnchorPoint a in seat.GetComponentsInChildren<AbstractAnchorPoint>(true)) seat.RegisterAnchor(a);
```

Done = server and every client log the same `Seat Added: GUID=<derived id> | Number=<n>` lines before the server's
`Cached ... instances` line.

## Recipe: players with avatars in a new scene (MP)

1. Duplicate `Assets/Application/Scenes/ClassroomScene/ClassroomScene.unity` (or use
   `MultiplayerClassroomTemplate.scenetemplate`). Keep `SeatRoot` and `GroupInit`.
2. Register it as a level in the MP client **and** server profiles and make it the server start level
   (`Load Classroom Module` `_levelLoadArgs.Identifier`): `architecture.md`, Add a level.
3. Default avatar: a `PrefabAvatarSource` whose prefab meets the networked-avatar contract (Avatar lifecycle) and is
   listed in `Assets/DefaultPrefabObjects.asset` (`networking.md`, Networked prefabs). Set
   `RegisterGlobalAvatar._avatarId` to that prefab's `AvatarController._identifier`, or leave it empty.
4. Give RoleDatabase every role that can log in (D-09).
5. Start a server, then a teacher client (PIN 1111) and a student client (PIN 0000) (`runtime-config.md`; Play Mode
   works as a client). Done = these lines in order (V, `two-server.log` and both client logs):
   - teacher: `Creating a new group 'Teacher Group'`, `Group 'Teacher Group|0' Creation => Succeeded: True,
     RoleRestriction: 20`, `(Role: Teacher) in Group 0.`, `User <id> assigned to seat 0 in group 0.`,
     `Avatar successfully spawned for user <id> at seat 0.`
   - student: `Group '0' skipped: role restriction mismatch (20 != 30).`, `Creating a new group 'Student Group'`,
     `Group 'Student Group|1' Creation => Succeeded: True, RoleRestriction: 30`, `(Role: Student) in Group 1.`,
     `User <id> assigned to seat 1 in group 1.`, `... at seat 1.` (later students: `Found suitable group`).
   - each client: `Set rig parent to <seat GameObject> for user <n>.`, `Avatar sync completed for Client ID ...`, and
     for the other user `Avatar for Client <m> parented to seat <guid>.` and `Initializing VOIP connection for user`.

   Client `No seat with id ... and role ...` = D-04; `XR rig aligned to seat at ...` logs only on the reset-view
   action (O). Live view: Project Configurator > Diagnostics > Gameplay > Group Tracker.

## Recipe: restrict an interaction to a role [I, not compiled]

Enforce it on the server with a GMS command processor, the idiom of the shipped `DisperseGroupProcessor`:

```csharp
// usings: DreamscapeLearn.GroupManagementSystem.{Commands,Framework.Mono}, DreamscapeLearn.UserService, FishNet.Broadcast
public struct StartQuizCommand : IBroadcast { public int QuizId { get; set; } }

[CreateAssetMenu(menuName = "MyGame/Commands/StartQuiz")]
public sealed class StartQuizProcessor : AbstractGroupCommandProcessor<StartQuizCommand>
{
    public override CommandResult Execute(StartQuizCommand command, UserInfo userInfo)
    {
        if (userInfo == null) return CommandResult.Failure;
        Role role;
        try { role = userInfo.GetRole(); } catch { return CommandResult.Unauthorized; } // throws for unmapped roles (D-09)
        if (role > Role.Teacher) return CommandResult.Unauthorized;                     // Admin, Ghost, Teacher pass
        // server-side effect: a FishNet broadcast or a Relay payload in your own [RelayTypeIdRange]
        return CommandResult.Success;
    }
}
```

1. Create the asset and add it to `GroupInit` > `_configuration._groupCommandProcessors`. Done = server log
   `<asset name>: Registered command StartQuizCommand.` and `Registered Group Operator: StartQuizCommand for command
   <hash>` (V for the template's `MuteCommand` and `HapticCommand`).
2. Send it from a **client** process: `GroupManagementService.ProcessCommand(new StartQuizCommand { QuizId = 3 });`.
   On a server or host the call returns without sending (D-02, M-07). Done = server log
   `Command StartQuizCommand received from <clientId> on channel <channel>` and no
   `Command StartQuizCommand execution failed.` (O). `Unauthorized` is not logged: log it in `Execute` yourself.
3. Other server code: `DreamNetworkManager.GetServerService<UserService>().FindUser(u => u.Connection == conn)
   ?.IsUserRole(Permissions.TeacherRole)`. `FindUser` returns null where the `GetUser*` overloads throw (D-21).
4. Client-side gating is cosmetic: aether-canvas `UIRoleController` (V: `[UIRoleController] Role detected: Teacher`),
   or `UserServiceClient.GetUserRole()` in try/catch, which returns `Teacher` / `Student` about 2 s after auth (D-23).

## Recipe: calibration in the editor without hardware

1. Keep the template LoginScene: `CalibrationDataStarter._savedCalibrations` = `PresetCalibration`. On WindowsEditor
   and WindowsPlayer it injects the preset desk + height data when XR is not initialized **or** the rig's
   `ControllerTrait` reports controllers active, and skips the hand session (O); otherwise an initialized headset
   runs the hand session, so disconnect XR. Done = log
   `XR is not active and initialized, injecting preset calibration data.`
2. Own preset: after one real calibration, **Dreamscape DevKit > Calibration > Save Current Calibration** overwrites
   `Assets/Settings/Dreamscape Learn/AvatarCalibrations/PresetCalibration.asset` (needs desk and height data, D-31).
3. ACS alternative: an `Apply Preset Calibrations` module with **both** desktop and HMD presets assigned (D-28).
4. Keep domain reload on in Enter Play Mode settings: calibration hooks bind in `SubsystemRegistration` (I).
5. Android always runs the hand session (the preset paths are Windows-only, O). Headless players skip calibration
   entirely (Headless clients, below).

## Recipe: custom avatar or role override [I, not compiled]

1. Duplicate `Assets/Content/CompleteAvatars/Networked/Networked_Avatar.prefab` and swap the body, or Rig-Build a
   Humanoid model and copy the template's AMS/GMS/FishNet components onto it. Check it against the contract below.
2. Give it a unique `AvatarController._identifier`, list its root NetworkObject in `DefaultPrefabObjects.asset` and
   refresh the AssetPathHashes (`networking.md`, Networked prefabs). Wrap the prefab in a `PrefabAvatarSource`.
3. As the default avatar: assign it to `_configuration._defaultAvatar` and match `RegisterGlobalAvatar._avatarId`.
4. As a role override: once `_avatarOverrides` has any entry, every user's spawn key is the Role enum name
   (`Teacher`, `Student`) and a key with no cached prefab means no avatar (O). Give each role that logs in its own
   prefab whose identifier is that exact name; the entry's `_role` field plays no part in the lookup (D-08).
5. Add behaviour as a trait on the AvatarController GameObject. Traits run sorted by Priority (stable); one whose
   `SetupAsync` throws is logged and skipped.
6. Done = server log `Found Traits for Avatar: <your trait count>`, `Customization Trait enabling Animator`,
   `Customization Trait enabling Rig Builder`, `Avatar successfully spawned for user ...`; an override also logs
   `Cached 1 instances of avatar '<prefab name>'.` at GMS init (O).

```csharp
public sealed class BadgeTrait : AbstractAvatarTrait     // ...AvatarManagementSystem.Framework.Mono.Traits
{
    [SerializeField] private NetworkObject _networkObject;
    [SerializeField] private GameObject _badge;
    public override int Priority => 10;                   // after AnchorContainerTrait (-2), CustomizationTrait (-1)
    protected override UniTask SetupAsync(CancellationToken token) { _badge.SetActive(false); return UniTask.CompletedTask; }
    protected override UniTask OnAvatarSyncCompleteAsync(CancellationToken token)   // owner, after seating
    { _badge.SetActive(_networkObject != null && _networkObject.IsOwner); return UniTask.CompletedTask; }
    protected override UniTask TeardownAsync(CancellationToken token) => UniTask.CompletedTask;
}
```

## Headless (batchmode) clients: calibration gate and IK (F-31)

- O: `CalibrationDataStarter.OnEnable` and `AvatarCalibrationTrait.TryCalibrate` return early under
  `Application.isBatchMode` (and on server platforms): no preset or session, `LoginCanvas` stays inactive, and the
  owner avatar is never activated (no `EnableGroup()`, `IKRig` off, IK targets still). `CustomizationTrait` still
  enables Animator and RigBuilder (idle clip, I).
- `-ddkAutoConfirm` (`runtime-config.md`) unblocks login, not IK. V (AMS Trace on): `calibration_finished_invoked`,
  `Set rig parent to StandardSeat for user 0.`, 15 `Calling AvatarSyncComplete on trait:`, zero `Attempting to
  activate avatar.`; the Trace `Client ... is enabling avatar IKRig` enables nothing.
- Use headless runs for auth, groups, seats, spawn, voice join and accessories; check IK in a windowed or editor
  client: done = `AvatarCalibrationTrait will now attempt to apply calibration.` then `Attempting to activate avatar.`
- Benign (V) when LoginScene unloads: `Failed to locate the registered calibration target for token 0.`,
  `Removed seat 0 (<guid>) of type StandardSeat.` (the Workstation).

## Placeholder user data (`Role: 'Student'` for a teacher)

- V: `Avatar is now owned by Client UserId: '', ... Role: 'Student'` (server), `Notifying server that client is
  ready: UserId: '' ...` and `Avatar Became Alive = Client ...` (client) precede the real record
  `Assigning (Networked_Avatar(Clone)) => avatar to user ... Role: 'Teacher'`.
- O, not a defect: they print the serialized placeholder `UserDataModel` (`_role` defaults to `Role.Student`) of
  `GroupParticipantTrait` / `ClientVrController` before GMS `Configure`. `ClientReady` is an empty struct, the server
  takes everything from UserService (`Generated User: ... Role: 'Teacher'`), and `GroupVisibilityCondition` sees the
  avatar only after `_avatarRegistry.TryAdd`, in the same synchronous block as `Configure`.
- Trap: `SetupAsync` runs before `Configure` on every peer (V order), so `Host.UserData()` there is the placeholder;
  read it in `OnAvatarSyncCompleteAsync` (owner), `AbstractUserInfoTrait.OnUserInfoUpdated` or after
  `IGroupParticipant.ConfiguredEvent`. DS `ChairConstraintTrait` hits it (V: `No seat assigned yet for user ''
  (registry hit: False).` x4) and retries on the next registry refresh or `CalibrationComplete` (O; outcome I).

## Authority model

| Thing | Owner | Mechanism |
|---|---|---|
| Users, roles, permissions | server `UserService`, keyed by connection | role reaches the client by broadcast after a fixed 2 s (D-23) |
| Groups, user records, seat assignment | server GMS `ServerOrchestrator` | whole-registry `UserRegistryRefresh` / `GroupRegistryRefresh` broadcast on every change |
| Seats | every peer, locally | `AutoRegisterSeat` fills the static `SeatManagementService`; never networked; matched by GUID |
| Avatar existence | server | FishNet pool, `Spawn(avatar, ownerConnection)` |
| Avatar parent (seat) | every peer, locally | each peer looks up `SeatIdentifier` in its own registry |
| Who sees whom | server | `NetworkObserver` + `GroupVisibilityCondition` |
| Head/limb pose, fingers, tracking flags, visemes | owner client | NetworkTransforms on IK targets, `HandSyncBehaviour`, `IKRigSynchronizer`, `NetworkAnimator` |
| Accessories (skin, hair, attire) | server stores them, trusts the payload's ClientId (D-19) | relay payloads 6000-6002 (V `[SERVER][6001] Server->Clients`) |
| Calibration | owner client, in `ApplicationState`; never networked | the height result reaches others through a scale-only NetworkTransform |
| Mute, haptics | server, role-checked | GMS commands |

`UserDataModel` / `GroupDataModel` ride inside the registry broadcasts: a new field changes every client's wire format.

## Seats

- Types Standard, Instructor, Observer, Floating are empty subclasses that only pick a role's seats (M-05).
  **Number** is unique per concrete seat type; at runtime a duplicate Number replaces the earlier seat (warning).
- **Identifier** (`_seatId`, a GUID string): unique across loaded scenes and identical in twin builds. A component
  added at runtime gets a random GUID from a field initializer; a prefab copy inherits the prefab's GUID.
- **Build validator** (`build.md` section 10, TB-16): per scene it fails on a duplicate Number within a type and
  swaps a duplicate GUID for `Guid.NewGuid()`, then saves; runtime seats are unseen. A regenerated GUID on a prefab
  instance may not persist, so each build can roll a new one and break twin builds (D-11 -> D-04).
- **Template layout** (V: the server registers exactly these 31): InstructorSeat 0 (GameObject `StandardSeat`) at the
  origin (`ProfessorSeatGroup`, the only seat with a Vicon chair follower); StandardSeat 1-30 in 5 rows of 6, x
  -2.5..2.5 step 1 m, z 4.5..12.5 step 2 m (O). Clients also register LoginScene `Workstation` as StandardSeat 0 and
  remove it when LoginScene unloads (V). Seats sit on layer XR Hand (29).

## Assignment and visibility (O unless tagged)

- On `ClientReady` the server builds the user record, picks a group (`AutoAssignUsers`, `MaxUsersPerGroup`), then
  assigns the **lowest free Number** among seats of the role's type. Occupancy is a per-group map
  (`_groupSeatAssignments[groupId]`), so every group numbers its seats from scratch. No free seat -> the lowest
  StandardSeat even when occupied (D-17); zero StandardSeats -> exception. V: `Next available seat for Role Teacher
  in Group 0 is <guid>='0'.`, `Next available seat for Role Student in Group 1 is <guid>='1'.`
- **One group per role, by design.** A new group gets `RoleRestriction` = the creator's role, and
  `FindSuitableGroup` skips groups of another role (open role -777 excepted); V for both roles (recipe above). The
  teacher and the students never share a GroupId: code that assumes they do (group commands, group voice
  channels, "my group" UI) acts on the teacher alone (I).
- Visibility: both users share a group, or either role is in `GlobalVisibilityRoles` (template
  `_groupVisibilityRoles` = Teacher, Admin); V: teacher and student each spawn the other (recipe above).
  Config-dependent: remove Teacher from that list and teacher and students vanish for each other.
- **Overflow (O).** Users of one role past `MaxUsersPerGroup` open a second group of that role, which restarts at
  the lowest seat: student 33 gets StandardSeat 1 again, with the same GUID as student 1. The two student groups
  cannot see each other, but the teacher (global role) sees both avatars on one seat. With the template (32 per
  group, 30 StandardSeats) students 31-32 first stack on seat 1 inside `Student Group` (D-17). Fix: StandardSeats >=
  students and `_maxUsersPerGroup` <= the StandardSeat count.
- Role -> seat type (`RoleSeatMap`, static): Teacher, AssistantTeacher -> Instructor; Ghost -> Floating; Observer ->
  Observer; Student, Admin and the rest -> Standard. The Instructor seat is never contended by students.
- Voice: with `_defaultVoiceChannel` empty and `_groupVoiceChannels` off (template), every user joins the shared
  channel `Default` (V for both roles: `Client <n>|<n> successfully switched to channel 'Default'.`). Group channels
  on would put the teacher alone in `Teacher Group`'s channel, and RenameGroup then NREs (D-15).
- V template config: `MaxUsersPerGroup=32, AutoAssignUsers=True, AllowEmptyGroups=False, OverrideAvatars=True,
  AvatarOverrides=[]`. Disconnect -> unassign seat, leave group, disperse the group if empty, despawn (O; not yet run).

## Roles and permissions

- `Role` enum: Admin 0, Ghost 10, Teacher 20, AssistantTeacher 25, Student 30, Observer 40. Lower = more privileged.
  The shipped processors reject `role > Role.Teacher`, which rejects AssistantTeacher too.
- `UserService.RegisterUser` loads the RoleService entry `role.ToString().ToLower()` (`teacher`, `assistantteacher`);
  `UserInfo.GetRole()` throws unless the user holds a `role.user-type.<x>` permission (hyphenated:
  `role.user-type.assistant-teacher`). `Assets/Application/Configs/RoleDatabase.asset` defines only `teacher` and
  `student` (V `Module RoleService initialized`, `Assigning role: teacher`, `Assigning role: student`).
- Template auth (`PinCodeAuthenticator`) yields Teacher (the first; later teachers become Students) or Student. Each
  client process sends its own random UserId, so ids stay unique per process (D-06). Other roles need a custom
  authenticator, RoleDatabase entries and seats of their type. "Operator" is pod tooling, not an in-app role.

## Avatar lifecycle (MP)

1. ACS boot (module order: `architecture.md`): `GlobalAvatarRegistration` attaches `AvatarData("Networked_Avatar")`
   to each connection (V `Added AvatarData:  Networked_Avatar`); the server then loads ClassroomScene (V).
2. Server GMS init, after FishNet loads the seat scene: caches the default avatar x SeatCount in the FishNet pool
   (V: `Cached 31 instances of avatar 'Networked_Avatar'.`), overrides at 1 instance each, then registers the
   `ClientReady` handler (D-10). On `ClientReady`: user record -> group -> seat -> pooled instance -> `Spawn`.
3. Traits: `AvatarController.InitializeAsync` awaits each trait by Priority (V: `Found Traits for Avatar: 15`,
   `AnchorContainerTrait` (-2), `CustomizationTrait` (-1), then the rest at 0 in component order). `CustomizationTrait`
   waits for `IsSpawned && Owner.IsValid`, enables the prefab-disabled Animator and RigBuilder on every peer (V) and
   applies the accessory snapshot.
4. Configure (every peer): parent under the seat at zero pose (V `Avatar for Client <n> parented to seat <guid>.`),
   VoIP for remotes, user info traits, owner lip sync, chair `SeatVisual` re-parented under the IK rig; a seat not
   registered yet -> it finishes on `SeatAdded`. Remote avatars get `EnableRemoteArms` and `IKRig.enabled = false`.
5. Owner: joins voice; `ClientVrController.AvatarSyncComplete` re-parents the **XR Origin under the seat** at local
   zero (V `Set rig parent to ...`), or logs `No seat with id ...` and returns (D-04). `AvatarCalibrationTrait` then
   applies desk (XR Origin against the seat's `DeskEdge`), height (avatar scale) and additional calibrations,
   then `NetworkComponentGroup.EnableGroup()` + `IKRig.enabled = true` (which enables `IKTargetFollowXRRig` and
   `RigAnimatorController`).
   **IK turns on only when all hold**: owner, not a server platform, not `-batchmode` (F-31, V), AvatarSyncComplete
   received, SeatIdentifier set. Missing calibration only warns.
6. LMS preload waits up to 10 s for the local avatar, then continues without it (V `local avatar configured`).

**Networked avatar contract** (template `Networked_Avatar`): root `NetworkObject`, `AvatarController`
(`_identifier`), `NetworkBridge`, and 15 traits (V): `AnchorContainerTrait`, `CustomizationTrait`,
`GroupVisibilityConditionTrait`, `AvatarRigTrait`, `BalloonHeadTrait`, `AvatarHeadTrait`,
`AvatarCalibrationTargetTrait`, `HandScalingTrait`, `NetworkedAvatarTrait`, `LipSyncTrait`, `DefaultAccessorySetter`,
`AvatarCalibrationTrait`, `RealTimeCommunicationTrait`, `GroupParticipantTrait` (its `_userInfoTraits` include
`AvatarCalibrationTrait`), `NameplateTrait`. Rig child: Animator, RigBuilder and IKRig/IKTargetFollowXRRig/
RigAnimatorController disabled; `AvatarCalibrationSettings` with non-zero heights; nested NetworkObject +
NetworkObserver (GroupVisibilityCondition); `NetworkAnimator`; 2x `HandSyncBehaviour`; `IKRigSynchronizer`;
scale-only NetworkTransform; NetworkTransforms on the IK targets. Despawn type Destroy (D-46).

**XR Origin**: exactly one `XROriginHost`, registered by `InitializeXROriginHost` with a `TrackedLimbTrait`, before
any avatar enables (D-24; V `XROriginHost(XrRigParentInteraction) initialized.` at boot). Every enabled
`IKTargetFollowXRRig` follows the local user, hence owner-only IK. `_resetAction` re-centres the head over the seat
and logs `XR rig aligned to seat at ...`. SP: `AvatarRigBinder` sits on the **seat** (M-14), spawns a local avatar
and re-parents the XR Origin keeping world position. `DSL_DS_TRACKED_USER=true` adds feet tracking.

## Rig Builder (editor only)

- Project Configurator > Experience Setup > Rig Builder turns a Humanoid model into a prefab with RigBuilder layers
  0 Spine, 1 Left Arm, 2 Right Arm, 3 Left Leg, 4 Right Leg, 5 Head, plus `IKRig`, `IKTargetFollowXRRig`,
  `RigAnimatorController`, `BoneRenderer` and (XR Avatar Calibration installed) `AvatarCalibrationSettings`. It still
  needs the networked-avatar contract.
- Before running: layer XR Hand (29), a fresh model instance (a re-run duplicates constraints), an existing output
  folder (D-35). After: `AvatarCalibrationSettings._seatedHeight` and `_height` > 0 (D-29); Animator bools
  `IsLeftTracking`, `IsRightTracking`; Animator, RigBuilder and IKRig disabled in the prefab.
- `RigAnimatorController` `_left/_rightArmLayerIndex` and `_left/_rightFootLayerIndex` are RigBuilder layers; the
  `...AnimatorLayerIndex` fields are Animator layers (M-17). `IKTargetFollowXRRig._headOffset` is a rotation (M-18).

## Lip sync

- `LipSyncPhonemeAnalyzer` (MFCC, Burst, Jobs, unsafe) reads an `AudioSourceProxy` or its own `OnAudioFilterRead`,
  not the mic (M-21). The owner analyzes `ClientVrController._audioSourceProxy`; `NetworkAnimator` replicates visemes
  (clips arrive as an accessory, V `Attached accessory 'AfricanFemaleLipSyncClips' to 'LipSyncClips' ...`).
- Keep Burst AOT on for Android ARM64; RECORD_AUDIO comes from the XPS manifest injector. Assign the proxy once and
  disable analyzers before destroying audio sources (D-32). `LIP_SYNC_DEBUG` is a manual diagnostics define.

## avatar-assets: weight and import errors

- Every init profile, server included, runs `RegisterAvatarAccessories` (V), which pulls in the whole accessory
  catalogue (D-42). Package source is 514 MB: 182 PNG (390 MB), 57 FBX (197 MB) (O).
- V build reports (uncompressed user assets; avatar-assets share): Android 166.9 MB (textures 68.6%; about 110 MB;
  largest `T_Eye_AN2.png` 16.0 MB; APK 153.7 MiB), Windows client 208.8 MB (about 117 MB), Windows server 52.7 MB
  (textures stripped to 2.0 MB, meshes kept at 13.6 MB as on every target; about 22 MB).
- O: 32 of the 41 textures `RegisterAvatarAccessories` reaches have no Android override (2048 max); all 57 FBX import
  blend shapes with mesh compression off.
- Fix: a project-local `RegisterAvatarAccessories` listing only the accessories you use, in all five init profiles.
  Embed the package or copy the assets into `Assets/` to set Android max size 1024/512 (the package cache is
  read-only, I). Dev builds only: Build Profile "Asset Import Overrides" max texture size caps everything (I).
- V import ERRORs that block neither compile nor build (F-24): `SK_Basemesh_Male_rig 1.fbx` (`Required human bone
  'Head' not found`), `SK_Basemesh_Female_rig_1.fbx` (animation import warnings),
  `SK_Basemesh_M_Body_001@Sitting_Idle.fbx` and its XR Avatar Calibration sample copy (`Copied Avatar Rig
  Configuration mis-match`). O: the template avatars use `SK_Basemesh_Female_rig_1.fbx`, whose controller plays
  Sitting_Idle; the runtime effect is unverified.

## Defects, ranked

| # | ID | Symptom | Workaround |
|---|---|---|---|
| 1 | D-02 | Host player gets no avatar; its GMS commands do nothing | Dedicated server process; ignore `AllowHostClient` for avatar flows |
| 2 | D-04 | Avatar unseated on clients, XR Origin not parented, owner IK never on; client `No seat with id` | Twin builds; derived GUIDs for runtime seats |
| 3 | D-01 | Every spawn fails `Failed to retrieve cached prefab using key`, after `Invalid parameters: prefab null or instance count` | Seats registered before GMS init: same scene, `AutoRegisterSeat` on Awake |
| 4 | F-31 | Headless clients: no login without the hook; owner avatar never activated, IK off (V) | `-ddkAutoConfirm` for login; IK checks in a windowed client |
| 5 | D-11, TB-16 | Builds rewrite and save scenes; a regenerated prefab-instance GUID may not stick | Fix GUIDs with the per-seat inspector button; save before, commit after building |
| 6 | D-09 | `User does not have a role.`: AddUser throws for a role absent from RoleDatabase | Add the role lowercase with its `role.user-type.*` permission |
| 7 | D-08 | Role-override avatars never spawn | Override prefab identifier = exact Role name, one per role that logs in |
| 8 | D-07 | With `OverrideAvatars=false` the first spawn of each per-user Addressable avatar fails | Keep it true, or pre-cache every avatar (address `AssetSource:<AvatarIdentifier>`) |
| 9 | D-10 | Async default-avatar source: `ClientReady` arrives before its handler and is lost (I) | `PrefabAvatarSource` for the default avatar |
| 10 | D-03 | Listeners registered after GMS init never get group/user/client events | Register in Awake in a scene loaded before the GMS scene (PlayerScene), or poll `GetAllGroups()` |
| 11 | D-06 | NRE, `assigned but visually missing`, half-created avatar | One unique UserId per connection (the template PIN path does this) |
| 12 | D-17 | Seats of a role's type exhausted: avatars stack on StandardSeat 1; no StandardSeat throws | Seats >= users per type; keep at least one StandardSeat |
| 13 | D-29 | Height calibration scales the avatar to Infinity/NaN | Non-zero `AvatarCalibrationSettings` heights |
| 14 | D-26 | `AvatarController.SpawnAsync` hangs on a networked prefab | Use it for offline avatars only; GMS spawns networked ones |
| 15 | D-24 | NRE in `IKTargetFollowXRRig.Update`, pelvis never followed | Register the XR Origin host with `TrackedLimbTrait` first |

Covered where they bite: D-05, D-15, D-21, D-23, D-28, D-31, D-32, D-35, D-37, D-38, D-42, D-46. The rest:
- Seats: **D-12** no `SeatRemovedEvent` from `RemoveSeat` / `ClearAllSeats`, `ClearAllSeatsOfType` throws -> track
  removals yourself. **D-44** stale seat transforms for new observers -> keep `NetworkTransformRefreshOnObserverSpawn`.
- Groups: **D-13** Disperse with members throws, group half-dispersed -> move users with `MoveUserCommand`.
  **D-14** after any unassign, auto-assign stalls on empty group -1 -> avoid unassign while `AutoAssignUsers` is on.
  **D-16** Rebalance leaves users seatless, seats double-booked -> follow with per-user `MoveUserCommand`. **D-18** a
  student can lift a teacher mute -> patch `MuteCommandProcessor` if mutes must stick.
- Users and auth: **D-19** client-supplied identity, role, customization ClientId and component-group toggles are
  trusted -> validate the sender in your own handlers. **D-20** `RoleCodeAuthenticator` swaps teacher name and id ->
  use `PinCodeAuthenticator`. **D-22** `GetUsersWithPermission` always returns empty -> filter `GetUsers()`.
- Avatar runtime: **D-25** NRE when an avatar shuts down before sync -> null-guard callers. **D-27** the local
  registry keeps destroyed avatars -> `AvatarSpawningService.DespawnAvatarAsync`. **D-39** `EnableGroup` toggles only a
  debug BoneRenderer -> IK comes from CustomizationTrait and IKRig. **D-40** `AvatarToRigSyncTrait` is obsolete (M-13)
  -> leave it out. **D-41** `GroupVisibilityCondition.asset` lives in a GMS `Editor/` folder -> copy it into
  `Assets/` for custom avatars. **D-43** `CachePrefabAvatars` NREs on null entries, `AvatarRigBinder` on level end
  before binding -> clean lists. **D-45** GMS NREs without a NetworkManager or `GroupParticipantTrait` -> keep both.
- Calibration, IK, packaging: **D-30** "Collection was modified", no `CalibrationComplete` -> one session active,
  none loaded mid-run. **D-33** odd `[BurstCompile]` uses -> V builds have 0 errors; act only on Burst errors.
  **D-34** `RigAnimatorController` leaks CancellationTokenSources -> harmless. **D-36** hidden dependencies -> keep
  dream-console, dreamfish and lip-sync. Docs: 10 command processors ship, not 3 (M-09); nothing auto-initializes an
  AvatarController (M-15).
