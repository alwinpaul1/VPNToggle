using System;
using System.Xml.Linq;
using VPNToggle;
using Xunit;

public class NvmPolicyTests
{
    [Theory]
    [InlineData("acnvmagent", true)]
    [InlineData("ACNVMAGENT", true)]
    [InlineData("acnvmagent.exe", false)]
    [InlineData("acnvmagent2", false)]
    [InlineData("xacnvmagent", false)]
    [InlineData("acnvm", false)]
    [InlineData("", false)]
    [InlineData("csc_vpnagent", false)]
    [InlineData("vpnagent", false)]
    [InlineData("csc_ui", false)]
    [InlineData("vpnui", false)]
    [InlineData("vpncli", false)]
    [InlineData("acumbrellaagent", false)]
    [InlineData("csc_iseagent", false)]
    [InlineData("csc_iseposture", false)]
    [InlineData("csc_swgagent", false)]
    [InlineData("csc_zta_agent", false)]
    [InlineData("acsock", false)]
    [InlineData("VPNToggle", false)]
    public void OnlyTheNvmAgentMatches(string name, bool expected) =>
        Assert.Equal(expected, NvmPolicy.IsAgent(name));

    [Fact] public void RunningAgentIsSuspended() =>
        Assert.Equal(NvmAction.Suspend, NvmPolicy.PauseAction(new NvmProcess(1, "acnvmagent", false)));

    [Fact] public void SuspendedAgentIsLeftAlone() =>
        Assert.Equal(NvmAction.None, NvmPolicy.PauseAction(new NvmProcess(1, "acnvmagent", true)));

    [Theory]
    [InlineData("csc_vpnagent")]
    [InlineData("acnvmagent2")]
    [InlineData("acumbrellaagent")]
    public void OtherProcessesAreNeverSuspended(string name) =>
        Assert.Equal(NvmAction.None, NvmPolicy.PauseAction(new NvmProcess(1, name, false)));

    [Fact] public void SuspendedAgentIsResumed() =>
        Assert.Equal(NvmAction.Resume, NvmPolicy.ResumeAction(new NvmProcess(1, "acnvmagent", true)));

    [Fact] public void RunningAgentNeedsNoResume() =>
        Assert.Equal(NvmAction.None, NvmPolicy.ResumeAction(new NvmProcess(1, "acnvmagent", false)));

    [Theory]
    [InlineData("csc_vpnagent")]
    [InlineData("acnvmagent2")]
    public void OtherProcessesAreNeverResumed(string name) =>
        Assert.Equal(NvmAction.None, NvmPolicy.ResumeAction(new NvmProcess(1, name, true)));

    [Fact] public void AllThreadsSuspendedMeansSuspended() =>
        Assert.True(NvmPolicy.Suspended(new[] { true, true, true }));

    [Fact] public void OneRunningThreadMeansNotSuspended() =>
        Assert.False(NvmPolicy.Suspended(new[] { true, false, true }));

    [Fact] public void NoThreadsMeansNotSuspended() =>
        Assert.False(NvmPolicy.Suspended(Array.Empty<bool>()));

    [Theory]
    [InlineData("--nvm-pause", "pause")]
    [InlineData("--nvm-install", "install")]
    [InlineData("--nvm-uninstall", "uninstall")]
    [InlineData("--connect", null)]
    [InlineData("--startup", null)]
    [InlineData("vpntoggle://connect", null)]
    [InlineData("--NVM-PAUSE", null)]
    public void ModeFromArguments(string argument, string? expected) =>
        Assert.Equal(expected, NvmPolicy.Mode(new[] { argument }));

    [Fact] public void NoArgumentsIsTheApp() =>
        Assert.Null(NvmPolicy.Mode(Array.Empty<string>()));

    [Fact] public void NotInstalledIsOff() =>
        Assert.Equal(NvmStatus.Off, NvmPolicy.Status(installed: false, pauserRunning: false));

    [Fact] public void InstalledAndRunningIsActive() =>
        Assert.Equal(NvmStatus.Active, NvmPolicy.Status(installed: true, pauserRunning: true));

    [Fact] public void InstalledWithoutAPauserIsNotRunning() =>
        Assert.Equal(NvmStatus.NotRunning, NvmPolicy.Status(installed: true, pauserRunning: false));

    [Fact] public void OffInstalls() => Assert.True(NvmPolicy.Installs(NvmStatus.Off));

    [Fact] public void ActiveUninstalls() => Assert.False(NvmPolicy.Installs(NvmStatus.Active));

    [Fact] public void NotRunningUninstalls() => Assert.False(NvmPolicy.Installs(NvmStatus.NotRunning));

    [Fact] public void NoteWhenOffIsTheSummary() => Assert.Equal(NvmPolicy.Summary, NvmPolicy.Note(NvmStatus.Off));

    [Fact] public void NoteSaysActive() => Assert.StartsWith("Running", NvmPolicy.Note(NvmStatus.Active));

    [Fact] public void SummaryNamesTheSavingAndTheLostReports()
    {
        Assert.Contains("CPU core", NvmPolicy.Summary);
        Assert.Contains("stops usage reports", NvmPolicy.Summary);
    }

    [Fact] public void InstalledExeIsUnderProgramFiles() =>
        Assert.EndsWith("VPNToggle.exe", NvmPolicy.InstalledExe("C:\\Program Files"));

    [Fact] public void TaskXmlIsWellFormedAndRunsThePauserAsSystem()
    {
        var doc = XDocument.Parse(NvmPolicy.TaskXml("C:\\Program Files\\VPNToggle\\VPNToggle.exe").Replace("encoding=\"UTF-16\"", ""));
        XNamespace ns = "http://schemas.microsoft.com/windows/2004/02/mit/task";
        var exec = doc.Root!.Element(ns + "Actions")!.Element(ns + "Exec")!;
        Assert.Equal("C:\\Program Files\\VPNToggle\\VPNToggle.exe", exec.Element(ns + "Command")!.Value);
        Assert.Equal("--nvm-pause", exec.Element(ns + "Arguments")!.Value);
        Assert.Equal("S-1-5-18", doc.Root.Element(ns + "Principals")!.Element(ns + "Principal")!.Element(ns + "UserId")!.Value);
        var settings = doc.Root.Element(ns + "Settings")!;
        Assert.Equal("false", settings.Element(ns + "DisallowStartIfOnBatteries")!.Value);
        Assert.Equal("false", settings.Element(ns + "StopIfGoingOnBatteries")!.Value);
        Assert.Equal("PT0S", settings.Element(ns + "ExecutionTimeLimit")!.Value);
        Assert.NotNull(doc.Root.Element(ns + "Triggers")!.Element(ns + "BootTrigger"));
    }

    [Fact] public void TaskXmlEscapesThePath()
    {
        var xml = NvmPolicy.TaskXml("C:\\A&B\\<x>\\VPNToggle.exe");
        Assert.Contains("C:\\A&amp;B\\&lt;x&gt;\\VPNToggle.exe", xml);
        var doc = XDocument.Parse(xml.Replace("encoding=\"UTF-16\"", ""));
        XNamespace ns = "http://schemas.microsoft.com/windows/2004/02/mit/task";
        Assert.Equal("C:\\A&B\\<x>\\VPNToggle.exe", doc.Root!.Element(ns + "Actions")!.Element(ns + "Exec")!.Element(ns + "Command")!.Value);
    }
}
