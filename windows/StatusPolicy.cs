using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace VPNToggle;

public enum VpnState { Unknown, Connected, Disconnected, Busy }

public readonly record struct StatusReading(VpnState? State, string? Ip, int? Seconds);

public enum SessionStep { Wait, AskAgain, Done, CloseBlind }

public static class StatusPolicy
{
    public static readonly TimeSpan SettledPoll = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan UnsettledPoll = TimeSpan.FromSeconds(3);

    public static VpnState? StateFromBanner(string output)
    {
        var line = output.Split('\n').LastOrDefault(l => l.Contains("state:"));
        if (line == null) return null;
        return StateNamed(line.Split("state:").Last());
    }

    public static VpnState StateNamed(string text)
    {
        var name = text.Trim();
        if (name.StartsWith("Disconnected", StringComparison.Ordinal)) return VpnState.Disconnected;
        if (name.StartsWith("Connected", StringComparison.Ordinal)) return VpnState.Connected;
        return VpnState.Busy;
    }

    public static StatusReading ReadingFromStats(string output)
    {
        VpnState? state = null;
        string? ip = null;
        int? seconds = null;
        foreach (var raw in output.Split('\n'))
        {
            var parts = raw.Split(':', 2);
            if (parts.Length != 2) continue;
            var key = parts[0].Trim();
            var value = parts[1].Trim();
            if (value == "Not Available") continue;
            if (key == "Connection State") state = StateNamed(value);
            else if (key == "Client Address (IPv4)") ip = value;
            else if (key == "Duration") seconds = SecondsFromDuration(value) ?? seconds;
        }
        return new StatusReading(state ?? StateFromBanner(output), ip, seconds);
    }

    public const string SessionRegistered = "registered with local VPN subsystem";
    public const string SessionRequest = "stats";
    public const string SessionReplyStart = "[ Connection Information ]";
    public const string SessionPrompt = "VPN>";
    public const int SessionRequestLimit = 2;
    public const int SessionFailureLimit = 2;
    public static readonly TimeSpan SessionTimeout = TimeSpan.FromSeconds(4);
    public static readonly TimeSpan SessionBlindAfter = TimeSpan.FromSeconds(1);

    public static VpnState? RegisteredState(string output)
    {
        var marker = output.IndexOf(SessionRegistered, StringComparison.Ordinal);
        return marker < 0 ? null : StateFromBanner(output[..marker]);
    }

    public static int SessionReplies(string output) =>
        output.Split(SessionReplyStart).Skip(1).Count(part => part.Contains(SessionPrompt));

    public static StatusReading ReadingFromSession(string output)
    {
        var registered = RegisteredState(output);
        if (registered is { } state && state != VpnState.Connected) return new StatusReading(state, null, null);
        return ReadingFromStats(output);
    }

    public static SessionStep SessionStepFor(string output, int sent, TimeSpan elapsed, int limit = SessionRequestLimit)
    {
        var registered = RegisteredState(output);
        if (registered == null) return elapsed >= SessionBlindAfter ? SessionStep.CloseBlind : SessionStep.Wait;
        if (registered != VpnState.Connected) return SessionStep.Done;
        if (SessionReplies(output) < sent) return SessionStep.Wait;
        var r = ReadingFromSession(output);
        return r.State == VpnState.Connected && r.Seconds == null && sent < limit ? SessionStep.AskAgain : SessionStep.Done;
    }

    public static bool SessionUsable(StatusReading? reading)
    {
        if (reading is not { State: { } state } r || state == VpnState.Unknown) return false;
        return state != VpnState.Connected || (r.Ip != null && r.Seconds != null);
    }

    public static bool SessionAllowed(int failures) => failures < SessionFailureLimit;

    public static int? SecondsFromDuration(string text)
    {
        var m = Regex.Match(text, @"(?:(\d+)\s*day.*?\s)?(\d+):(\d+):(\d+)");
        if (!m.Success) return null;
        var days = m.Groups[1].Success ? int.Parse(m.Groups[1].Value) : 0;
        var h = int.Parse(m.Groups[2].Value);
        var min = int.Parse(m.Groups[3].Value);
        var sec = int.Parse(m.Groups[4].Value);
        return ((days * 24 + h) * 60 + min) * 60 + sec;
    }

    public static bool Settled(VpnState state, string? tunnelIp, ICollection<string> addresses)
    {
        if (state == VpnState.Disconnected) return true;
        return state == VpnState.Connected && tunnelIp != null && addresses.Contains(tunnelIp);
    }

    public static TimeSpan PollInterval(bool settled, bool watchingInterfaces) =>
        settled && watchingInterfaces ? SettledPoll : UnsettledPoll;

    public static TimeSpan CliInterval(VpnState state, bool watchingInterfaces)
    {
        if (state == VpnState.Disconnected) return TimeSpan.FromSeconds(watchingInterfaces ? 120 : 15);
        if (state == VpnState.Connected) return TimeSpan.FromSeconds(15);
        return TimeSpan.FromSeconds(5);
    }

    public static bool NeedsCli(bool force, bool addressesChanged, bool lostTunnel, DateTime now, DateTime nextCheck) =>
        force || addressesChanged || lostTunnel || now >= nextCheck;

    public static string? ConnectStep(string line)
    {
        var low = line.ToLowerInvariant();
        if (low.Contains("downloading"))
        {
            var last = line.Trim().Split(' ').Last();
            return last.EndsWith("%", StringComparison.Ordinal)
                ? $"Updating Cisco Secure Client ({last})"
                : "Updating Cisco Secure Client";
        }
        if (low.Contains("update checks") || low.Contains("checking for") || low.Contains("required updates"))
            return "Checking for Cisco updates";
        if (low.Contains("initiating connection")) return "Opening the tunnel";
        if (low.Contains("examining system")) return "Checking this computer";
        if (low.Contains("activating vpn adapter")) return "Activating the VPN adapter";
        if (low.Contains("configuring system")) return "Configuring the network";
        if (low.Contains("establishing vpn session")) return "Starting the session";
        if (low.Contains("contacting")) return "Contacting the server";
        return null;
    }

    public static string ReconnectNote(int attempt, int total, bool autoReconnect)
    {
        if (!autoReconnect) return "Reconnect when you are ready";
        if (attempt <= 0) return "Reconnecting automatically";
        return $"Reconnecting automatically, attempt {attempt} of {total}";
    }
}
