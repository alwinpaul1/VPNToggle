using System;
using System.Linq;

public static class ConnectPolicy
{
    public static readonly TimeSpan IdleLimit = TimeSpan.FromSeconds(90);
    public static readonly TimeSpan HardLimit = TimeSpan.FromMinutes(15);
    public const string UpdatingMessage = "Cisco Secure Client is updating itself. Connect again once the update finishes.";

    public static string? TimeoutReason(DateTime now, DateTime started, DateTime lastOutput, TimeSpan? idleLimit = null, TimeSpan? hardLimit = null)
    {
        var idle = idleLimit ?? IdleLimit;
        var hard = hardLimit ?? HardLimit;
        if (now - started >= hard) return $"Gave up after {(int)hard.TotalMinutes} minutes.";
        if (now - lastOutput >= idle) return $"Cisco stopped responding for {(int)idle.TotalSeconds} s.";
        return null;
    }

    public static bool ServiceStopped(string log) => log.Contains("VPN service was stopped");

    public static string FailureMessage(string log, string host, string? timedOut)
    {
        var cliError = log.Split('\n').FirstOrDefault(l => l.Contains(">> error:"))?.Split(">> error:").Last().Trim();
        if (cliError != null) return cliError;
        if (ServiceStopped(log) || log.Contains("Performing any required updates") || log.Contains("Downloading Cisco Secure Client"))
            return UpdatingMessage;
        return timedOut ?? $"Could not connect to {host}.";
    }
}
