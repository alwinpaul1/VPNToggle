using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace VPNToggle;

public static class NvmPause
{
    const uint ProcessSuspendResume = 0x0800;
    const int ErrorCancelled = 1223;

    [DllImport("ntdll.dll")]
    static extern int NtSuspendProcess(IntPtr process);

    [DllImport("ntdll.dll")]
    static extern int NtResumeProcess(IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int id);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    public static string InstalledExe =>
        NvmPolicy.InstalledExe(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles));

    public static string LogPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "VPNToggle", "nvm-pause.log");

    static void Note(string text)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            if (File.Exists(LogPath) && new FileInfo(LogPath).Length > 64 * 1024) File.Delete(LogPath);
            File.AppendAllText(LogPath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {text}{Environment.NewLine}");
        }
        catch { }
    }

    static bool ThreadsSuspended(Process p)
    {
        var states = new List<bool>();
        foreach (ProcessThread t in p.Threads)
        {
            var suspended = false;
            try { suspended = t.ThreadState == System.Diagnostics.ThreadState.Wait && t.WaitReason == ThreadWaitReason.Suspended; }
            catch { }
            states.Add(suspended);
        }
        return NvmPolicy.Suspended(states);
    }

    static List<NvmProcess> Agents()
    {
        var list = new List<NvmProcess>();
        foreach (var p in Process.GetProcessesByName(NvmPolicy.AgentProcess))
        {
            try { list.Add(new NvmProcess(p.Id, p.ProcessName, ThreadsSuspended(p))); }
            catch { }
            finally { p.Dispose(); }
        }
        return list;
    }

    static bool Change(int id, bool suspend)
    {
        var handle = OpenProcess(ProcessSuspendResume, false, id);
        if (handle == IntPtr.Zero) return false;
        try { return (suspend ? NtSuspendProcess(handle) : NtResumeProcess(handle)) >= 0; }
        finally { CloseHandle(handle); }
    }

    public static int RunPauser()
    {
        Note("pauser started; " + NvmPolicy.AgentProcess + " kept suspended");
        var failed = new HashSet<int>();
        while (true)
        {
            foreach (var agent in Agents())
            {
                if (NvmPolicy.PauseAction(agent) != NvmAction.Suspend) continue;
                if (Change(agent.Id, suspend: true)) Note($"suspended {agent.Name} {agent.Id}");
                else if (failed.Add(agent.Id)) Note($"could not suspend {agent.Name} {agent.Id}");
            }
            Thread.Sleep(NvmPolicy.Interval);
        }
    }

    static bool ResumeAgents()
    {
        for (var round = 0; round < NvmPolicy.ResumeLimit; round++)
        {
            var waiting = Agents().Where(a => NvmPolicy.ResumeAction(a) == NvmAction.Resume).ToList();
            if (waiting.Count == 0) return true;
            foreach (var agent in waiting)
                Note(Change(agent.Id, suspend: false) ? $"resumed {agent.Name} {agent.Id}" : $"could not resume {agent.Name} {agent.Id}");
            Thread.Sleep(100);
        }
        return Agents().All(a => NvmPolicy.ResumeAction(a) != NvmAction.Resume);
    }

    static (int code, string output) Schtasks(string arguments)
    {
        var psi = new ProcessStartInfo("schtasks.exe", arguments)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        try
        {
            using var p = Process.Start(psi)!;
            var error = p.StandardError.ReadToEndAsync();
            var output = p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            return (p.ExitCode, (output + error.Result).Trim());
        }
        catch (Exception e) { return (-1, e.Message); }
    }

    static bool TaskExists() => Schtasks($"/Query /TN \"{NvmPolicy.TaskName}\"").code == 0;

    static List<Process> Pausers()
    {
        var list = new List<Process>();
        foreach (var p in Process.GetProcessesByName("VPNToggle"))
        {
            if (p.Id != Environment.ProcessId && p.SessionId == 0) list.Add(p);
            else p.Dispose();
        }
        return list;
    }

    static void StopPauser()
    {
        try { Process.EnterDebugMode(); } catch { }
        if (TaskExists()) Schtasks($"/End /TN \"{NvmPolicy.TaskName}\"");
        var installed = InstalledExe;
        foreach (var p in Process.GetProcessesByName("VPNToggle"))
        {
            try
            {
                if (p.Id == Environment.ProcessId) continue;
                if (!string.Equals(p.MainModule?.FileName, installed, StringComparison.OrdinalIgnoreCase)) continue;
                p.Kill();
                p.WaitForExit(5000);
            }
            catch { }
            finally { p.Dispose(); }
        }
    }

    public static int Install()
    {
        try
        {
            var source = Environment.ProcessPath ?? throw new InvalidOperationException("no process path");
            var target = InstalledExe;
            StopPauser();
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            if (!string.Equals(source, target, StringComparison.OrdinalIgnoreCase))
            {
                for (var attempt = 0; ; attempt++)
                {
                    try { File.Copy(source, target, overwrite: true); break; }
                    catch (Exception) when (attempt < 20) { Thread.Sleep(250); }
                }
            }
            var xml = Path.Combine(Path.GetTempPath(), $"vpntoggle-nvm-task-{Guid.NewGuid():N}.xml");
            File.WriteAllText(xml, NvmPolicy.TaskXml(target), Encoding.Unicode);
            var created = Schtasks($"/Create /TN \"{NvmPolicy.TaskName}\" /XML \"{xml}\" /F");
            try { File.Delete(xml); } catch { }
            if (created.code != 0) { Note("install: task not created: " + created.output); return 2; }
            var started = Schtasks($"/Run /TN \"{NvmPolicy.TaskName}\"");
            if (started.code != 0) { Note("install: task not started: " + started.output); return 3; }
            Note("installed");
            return 0;
        }
        catch (Exception e)
        {
            Note("install failed: " + e.Message);
            return 1;
        }
    }

    public static int Uninstall()
    {
        try
        {
            StopPauser();
            if (TaskExists())
            {
                var deleted = Schtasks($"/Delete /TN \"{NvmPolicy.TaskName}\" /F");
                if (deleted.code != 0) { Note("uninstall: task not deleted: " + deleted.output); return 2; }
            }
            var resumed = ResumeAgents();
            var target = InstalledExe;
            if (!string.Equals(Environment.ProcessPath, target, StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    for (var attempt = 0; ; attempt++)
                    {
                        try { File.Delete(target); break; }
                        catch (Exception) when (attempt < 20) { Thread.Sleep(250); }
                    }
                    var folder = Path.GetDirectoryName(target)!;
                    if (Directory.Exists(folder)) Directory.Delete(folder);
                }
                catch (Exception e) { Note("uninstall: files not removed: " + e.Message); return 4; }
            }
            Note(resumed ? "uninstalled; agent resumed" : "uninstalled; agent still suspended");
            return resumed ? 0 : 3;
        }
        catch (Exception e)
        {
            Note("uninstall failed: " + e.Message);
            return 1;
        }
    }

    public static int? RunMode(string[] args) => NvmPolicy.Mode(args) switch
    {
        "pause" => RunPauser(),
        "install" => Install(),
        "uninstall" => Uninstall(),
        _ => null,
    };

    public static bool CopyStale(string runningVersion)
    {
        try
        {
            if (!File.Exists(InstalledExe)) return false;
            return UpdatePolicy.CopyStale(FileVersionInfo.GetVersionInfo(InstalledExe).FileVersion, runningVersion);
        }
        catch { return false; }
    }

    public static NvmStatus CurrentStatus()
    {
        var pausers = Pausers();
        var running = pausers.Count > 0;
        pausers.ForEach(p => p.Dispose());
        return NvmPolicy.Status(File.Exists(InstalledExe), running);
    }

    public static string? Change(bool install)
    {
        var exe = Environment.ProcessPath;
        if (exe == null) return "Could not find the VPNToggle program file.";
        try
        {
            var psi = new ProcessStartInfo(exe, install ? NvmPolicy.InstallArgument : NvmPolicy.UninstallArgument)
            {
                UseShellExecute = true,
                Verb = "runas",
            };
            using var p = Process.Start(psi);
            if (p == null) return "Could not ask for administrator rights.";
            p.WaitForExit();
            return p.ExitCode == 0 ? null : $"The change did not complete (code {p.ExitCode}). Details are in {LogPath}.";
        }
        catch (Win32Exception e) when (e.NativeErrorCode == ErrorCancelled) { return null; }
        catch (Exception e) { return e.Message; }
    }
}
