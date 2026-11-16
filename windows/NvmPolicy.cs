using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security;

namespace VPNToggle;

public enum NvmAction { None, Suspend, Resume }

public enum NvmStatus { Off, Active, NotRunning }

public readonly record struct NvmProcess(int Id, string Name, bool Suspended);

public static class NvmPolicy
{
    public const string AgentProcess = "acnvmagent";
    public const string TaskName = "VPNToggle NVM Pause";
    public const string PauseArgument = "--nvm-pause";
    public const string InstallArgument = "--nvm-install";
    public const string UninstallArgument = "--nvm-uninstall";
    public const string Title = "Pause Cisco Network Visibility";
    public const string Summary = "Saves about one CPU core; Network Visibility stops reporting";
    public const int ResumeLimit = 16;
    public static readonly TimeSpan Interval = TimeSpan.FromSeconds(1);

    public static bool IsAgent(string processName) =>
        string.Equals(processName, AgentProcess, StringComparison.OrdinalIgnoreCase);

    public static bool Suspended(IReadOnlyCollection<bool> threadsSuspended) =>
        threadsSuspended.Count > 0 && threadsSuspended.All(s => s);

    public static NvmAction PauseAction(NvmProcess p) =>
        IsAgent(p.Name) && !p.Suspended ? NvmAction.Suspend : NvmAction.None;

    public static NvmAction ResumeAction(NvmProcess p) =>
        IsAgent(p.Name) && p.Suspended ? NvmAction.Resume : NvmAction.None;

    public static string? Mode(string[] args)
    {
        foreach (var a in args)
        {
            if (a == PauseArgument) return "pause";
            if (a == InstallArgument) return "install";
            if (a == UninstallArgument) return "uninstall";
        }
        return null;
    }

    public static string InstalledExe(string programFiles) => Path.Combine(programFiles, "VPNToggle", "VPNToggle.exe");

    public static NvmStatus Status(bool installed, bool pauserRunning)
    {
        if (!installed) return NvmStatus.Off;
        return pauserRunning ? NvmStatus.Active : NvmStatus.NotRunning;
    }

    public static bool Installs(NvmStatus status) => status == NvmStatus.Off;

    public static string Note(NvmStatus status) => status switch
    {
        NvmStatus.Active => "Active. " + Summary,
        NvmStatus.NotRunning => "Installed but not running. Turn it off and on again",
        _ => Summary,
    };

    public static string TaskXml(string exe) =>
        "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\r\n" +
        "<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\r\n" +
        "  <RegistrationInfo>\r\n" +
        "    <Description>Keeps the Cisco Network Visibility agent suspended. Installed by VPNToggle.</Description>\r\n" +
        "  </RegistrationInfo>\r\n" +
        "  <Triggers>\r\n" +
        "    <BootTrigger>\r\n" +
        "      <Enabled>true</Enabled>\r\n" +
        "    </BootTrigger>\r\n" +
        "  </Triggers>\r\n" +
        "  <Principals>\r\n" +
        "    <Principal id=\"Author\">\r\n" +
        "      <UserId>S-1-5-18</UserId>\r\n" +
        "      <RunLevel>HighestAvailable</RunLevel>\r\n" +
        "    </Principal>\r\n" +
        "  </Principals>\r\n" +
        "  <Settings>\r\n" +
        "    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>\r\n" +
        "    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>\r\n" +
        "    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>\r\n" +
        "    <AllowHardTerminate>true</AllowHardTerminate>\r\n" +
        "    <StartWhenAvailable>true</StartWhenAvailable>\r\n" +
        "    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>\r\n" +
        "    <IdleSettings>\r\n" +
        "      <StopOnIdleEnd>false</StopOnIdleEnd>\r\n" +
        "      <RestartOnIdle>false</RestartOnIdle>\r\n" +
        "    </IdleSettings>\r\n" +
        "    <AllowStartOnDemand>true</AllowStartOnDemand>\r\n" +
        "    <Enabled>true</Enabled>\r\n" +
        "    <Hidden>false</Hidden>\r\n" +
        "    <RunOnlyIfIdle>false</RunOnlyIfIdle>\r\n" +
        "    <WakeToRun>false</WakeToRun>\r\n" +
        "    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>\r\n" +
        "    <Priority>7</Priority>\r\n" +
        "    <RestartOnFailure>\r\n" +
        "      <Interval>PT1M</Interval>\r\n" +
        "      <Count>999</Count>\r\n" +
        "    </RestartOnFailure>\r\n" +
        "  </Settings>\r\n" +
        "  <Actions Context=\"Author\">\r\n" +
        "    <Exec>\r\n" +
        "      <Command>" + SecurityElement.Escape(exe) + "</Command>\r\n" +
        "      <Arguments>" + PauseArgument + "</Arguments>\r\n" +
        "    </Exec>\r\n" +
        "  </Actions>\r\n" +
        "</Task>\r\n";
}
