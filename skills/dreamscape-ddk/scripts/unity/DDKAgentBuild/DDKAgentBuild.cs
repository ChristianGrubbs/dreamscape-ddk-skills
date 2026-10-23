// DDK agent build entry points (editor-only). Drop this folder into Assets/Editor/ of a DDK project.
// Invoke:  Unity.exe -batchmode -nographics -projectPath <p> -buildTarget <Win64|Android>
//            [-activeBuildProfile "Assets/Settings/Build Profiles/<Profile>.asset"]
//            -executeMethod DDK.AgentBuild.DDKAgentBuild.<Method> -ddkOut <root or apk path> -logFile <log>
// Methods: Compile (no build), WindowsClient, WindowsServer, WindowsSinglePlayer, Android, Profile (-ddkProfile <asset path>).
// Options: -ddkAgentHooks (adds DDK_AGENT_HOOKS), -ddkDefines "A;B" (extra defines); both are ignored by Profile.
// Exit codes: 0 ok, 1 build failed, 2 bad arguments/wrong active target, 3 Addressables failed, 4 output missing.
// Every decision is logged as one JSON line prefixed with "[DDK-CI] " so a later agent can grep the Unity log.
using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.AddressableAssets;
using UnityEditor.AddressableAssets.Build;
using UnityEditor.AddressableAssets.Settings;
using UnityEditor.Build;
using UnityEditor.Build.Profile;
using UnityEditor.Build.Reporting;
using UnityEngine;

namespace DDK.AgentBuild
{
    public static class DDKAgentBuild
    {
        static readonly string RunId = Guid.NewGuid().ToString("N").Substring(0, 8);

        static void LogEvent(string level, string evt, string ctxJson = "{}")
        {
            Debug.Log($"[DDK-CI] {{\"ts\":\"{DateTime.UtcNow:O}\",\"run_id\":\"{RunId}\",\"level\":\"{level}\",\"event\":\"{evt}\",\"loc\":\"DDKAgentBuild.cs\",\"ctx\":{ctxJson}}}");
        }

        // Keeps each [DDK-CI] record on one valid JSON line (Addressables errors can span several lines).
        static string Esc(string s) => (s ?? "").Replace("\\", "/").Replace("\"", "'").Replace("\r", " ").Replace("\n", " ").Replace("\t", " ");

        static string Arg(string name)
        {
            var args = Environment.GetCommandLineArgs();
            for (int i = 0; i < args.Length - 1; i++)
                if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase)) return args[i + 1];
            return null;
        }

        static void Exit(int code, string reason)
        {
            LogEvent(code == 0 ? "info" : "error", "exit", $"{{\"code\":{code},\"reason\":\"{Esc(reason)}\"}}");
            EditorApplication.Exit(code);
        }

        static string[] EnabledScenes() => EditorBuildSettings.scenes.Where(s => s.enabled).Select(s => s.path).ToArray();

        // -ddkAgentHooks compiles the DDK.AgentHooks test assembly into this build only (no ProjectSettings change).
        // -ddkDefines "A;B" adds arbitrary extra defines for this build only.
        static string[] ExtraDefines()
        {
            var defines = new System.Collections.Generic.List<string>();
            if (Environment.GetCommandLineArgs().Any(a => string.Equals(a, "-ddkAgentHooks", StringComparison.OrdinalIgnoreCase)))
                defines.Add("DDK_AGENT_HOOKS");
            string extra = Arg("-ddkDefines");
            if (!string.IsNullOrEmpty(extra))
                defines.AddRange(extra.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries));
            return defines.ToArray();
        }

        /// <summary>Import + compile gate. Reaching this method at all means scripts compiled.</summary>
        public static void Compile()
        {
            LogEvent("info", "compile_ok", $"{{\"target\":\"{EditorUserBuildSettings.activeBuildTarget}\",\"scenes\":{EnabledScenes().Length}}}");
            Exit(0, "compiled");
        }

        public static void WindowsClient() => Build(BuildTarget.StandaloneWindows64, (int)StandaloneBuildSubtarget.Player, "Experience/Client/experience.exe");
        public static void WindowsServer() => Build(BuildTarget.StandaloneWindows64, (int)StandaloneBuildSubtarget.Server, "Experience/Server/experience.exe");
        public static void WindowsSinglePlayer() => Build(BuildTarget.StandaloneWindows64, (int)StandaloneBuildSubtarget.Player, "Experience/experience.exe");
        public static void Android() => Build(BuildTarget.Android, 0, "experience.apk");

        /// <summary>Build with a Unity 6 Build Profile asset (-ddkProfile), which carries the target and its overrides.</summary>
        public static void Profile()
        {
            string profilePath = Arg("-ddkProfile");
            string outPath = Arg("-ddkOut");
            if (string.IsNullOrEmpty(profilePath) || string.IsNullOrEmpty(outPath)) { Exit(2, "need -ddkProfile and -ddkOut"); return; }
            var profile = AssetDatabase.LoadAssetAtPath<BuildProfile>(profilePath);
            if (profile == null) { Exit(2, "profile not found: " + profilePath); return; }
            if (ExtraDefines().Length > 0)
                LogEvent("warn", "defines_ignored", "{\"reason\":\"BuildPlayerWithProfileOptions has no extra defines; use WindowsClient/WindowsServer/Android\"}");
            if (!BuildAddressables()) return;
            var options = new BuildPlayerWithProfileOptions { buildProfile = profile, locationPathName = outPath, options = BuildOptions.None };
            LogEvent("info", "build_start", $"{{\"profile\":\"{Esc(profilePath)}\",\"out\":\"{Esc(outPath)}\"}}");
            Report(BuildPipeline.BuildPlayer(options), outPath);
        }

        static void Build(BuildTarget target, int subtarget, string relative)
        {
            string root = Arg("-ddkOut");
            if (string.IsNullOrEmpty(root)) { Exit(2, "need -ddkOut <root>"); return; }
            if (EditorUserBuildSettings.activeBuildTarget != target)
            {
                // Switching targets inside the method triggers a domain reload mid-build; require -buildTarget instead.
                Exit(2, $"active target {EditorUserBuildSettings.activeBuildTarget} != {target}; relaunch with -buildTarget");
                return;
            }
            string outPath = relative.EndsWith(".apk") && root.EndsWith(".apk") ? root : Path.Combine(root, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPath)));
            if (!BuildAddressables()) return;
            var opts = new BuildPlayerOptions
            {
                scenes = EnabledScenes(),
                target = target,
                targetGroup = BuildPipeline.GetBuildTargetGroup(target),
                subtarget = subtarget,
                locationPathName = outPath,
                options = BuildOptions.None,
                extraScriptingDefines = ExtraDefines(),
            };
            LogEvent("info", "build_start", $"{{\"target\":\"{target}\",\"subtarget\":{subtarget},\"scenes\":{opts.scenes.Length},\"defines\":\"{Esc(string.Join(";", opts.extraScriptingDefines))}\",\"out\":\"{Esc(outPath)}\"}}");
            Report(BuildPipeline.BuildPlayer(opts), outPath);
        }

        static bool BuildAddressables()
        {
            var settings = AddressableAssetSettingsDefaultObject.Settings;
            if (settings == null) { LogEvent("warn", "addressables_skipped", "{\"reason\":\"no settings\"}"); return true; }
            AddressableAssetSettings.BuildPlayerContent(out AddressablesPlayerBuildResult result);
            if (!string.IsNullOrEmpty(result.Error)) { Exit(3, "addressables: " + result.Error); return false; }
            string duration = result.Duration.ToString("F1", System.Globalization.CultureInfo.InvariantCulture);
            LogEvent("info", "addressables_ok", $"{{\"duration_s\":{duration},\"output\":\"{Esc(result.OutputPath)}\"}}");
            return true;
        }

        static void Report(BuildReport report, string outPath)
        {
            var s = report.summary;
            string sizeMb = (s.totalSize / 1048576.0).ToString("F1", System.Globalization.CultureInfo.InvariantCulture);
            string seconds = s.totalTime.TotalSeconds.ToString("F0", System.Globalization.CultureInfo.InvariantCulture);
            LogEvent(s.result == BuildResult.Succeeded ? "info" : "error", "build_result",
                $"{{\"result\":\"{s.result}\",\"errors\":{s.totalErrors},\"warnings\":{s.totalWarnings},\"size_mb\":{sizeMb},\"seconds\":{seconds}}}");
            if (s.result != BuildResult.Succeeded) { Exit(1, "build " + s.result); return; }
            if (!File.Exists(outPath)) { Exit(4, "output missing: " + outPath); return; }
            Exit(0, "built " + outPath);
        }
    }
}
