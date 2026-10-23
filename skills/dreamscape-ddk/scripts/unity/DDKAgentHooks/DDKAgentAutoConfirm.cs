// DDK agent test hook: lets a headless/batchmode client get past the DreamscapeSession confirmation popups.
// Compiled only when DDK_AGENT_HOOKS is defined (asmdef defineConstraints), which DDKAgentBuild adds through
// BuildPlayerOptions.extraScriptingDefines when invoked with -ddkAgentHooks. Runtime-inert unless the player is
// started with -ddkAutoConfirm. Pair with -DSL_ENABLE_AUTO_LOGIN true -DSL_PIN 1111 (teacher) / 0000 (student).
// Log lines are JSON prefixed with "[DDK-HOOK] " so a log triage can follow the flow.
using System;
using System.Collections;
using System.Linq;
using System.Reflection;
using UnityEngine;
using UnityEngine.UI;

namespace DDK.AgentHooks
{
    public sealed class DDKAgentAutoConfirm : MonoBehaviour
    {
        static readonly string[] ConfirmLabels = { "Confirm", "START" };
        const int MaxPresses = 6;
        int _presses;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void Bootstrap()
        {
            if (!Environment.GetCommandLineArgs().Any(a => string.Equals(a, "-ddkAutoConfirm", StringComparison.OrdinalIgnoreCase)))
                return;
            var go = new GameObject("DDKAgentAutoConfirm");
            DontDestroyOnLoad(go);
            go.AddComponent<DDKAgentAutoConfirm>();
            Emit("hook_armed", "{}");
        }

        static void Emit(string evt, string ctx) =>
            Debug.Log($"[DDK-HOOK] {{\"ts\":\"{DateTime.UtcNow:O}\",\"event\":\"{evt}\",\"loc\":\"DDKAgentAutoConfirm.cs\",\"ctx\":{ctx}}}");

        // In batchmode CalibrationDataStarter.OnEnable returns early, so its CalibrationFinished event (which activates
        // the session LoginCanvas in the templates) never fires and a headless client never reaches login (F-31).
        bool _calibrationReleased;

        void ReleaseCalibrationGate()
        {
            if (_calibrationReleased) return;
            foreach (var mb in FindObjectsByType<MonoBehaviour>(FindObjectsInactive.Exclude, FindObjectsSortMode.None))
            {
                if (mb == null || mb.GetType().Name != "CalibrationDataStarter") continue;
                var prop = mb.GetType().GetProperty("CalibrationFinished", BindingFlags.Public | BindingFlags.Instance);
                if (prop?.GetValue(mb) is UnityEngine.Events.UnityEvent finished)
                {
                    _calibrationReleased = true;
                    Emit("calibration_finished_invoked", $"{{\"object\":\"{mb.name}\"}}");
                    finished.Invoke();
                    return;
                }
            }
        }

        IEnumerator Start()
        {
            var wait = new WaitForSecondsRealtime(1f);
            while (_presses < MaxPresses)
            {
                yield return wait;
                if (Application.isBatchMode) ReleaseCalibrationGate();
                foreach (var button in FindObjectsByType<Button>(FindObjectsInactive.Exclude, FindObjectsSortMode.None))
                {
                    if (!button.interactable || !button.isActiveAndEnabled) continue;
                    string label = LabelOf(button);
                    if (label == null || !ConfirmLabels.Any(l => string.Equals(label.Trim(), l, StringComparison.OrdinalIgnoreCase))) continue;
                    _presses++;
                    Emit("press", $"{{\"label\":\"{label.Trim()}\",\"object\":\"{button.name}\",\"n\":{_presses}}}");
                    button.onClick.Invoke();
                    break;
                }
            }
            Emit("hook_done", $"{{\"presses\":{_presses}}}");
        }

        // Works for both uGUI Text and TextMeshPro without a hard TMP reference: read any string "text" property.
        static string LabelOf(Button button)
        {
            foreach (var c in button.GetComponentsInChildren<Component>(true))
            {
                if (c == null) continue;
                PropertyInfo p = c.GetType().GetProperty("text", BindingFlags.Public | BindingFlags.Instance);
                if (p != null && p.PropertyType == typeof(string))
                {
                    string s = p.GetValue(c) as string;
                    if (!string.IsNullOrWhiteSpace(s)) return s;
                }
            }
            return null;
        }
    }
}
