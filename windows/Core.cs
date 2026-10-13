using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace VPNToggle;

public enum VpnState { Unknown, Connected, Disconnected, Busy }

/// Non-secret settings, kept in %APPDATA%\VPNToggle\settings.json.
public sealed class Settings
{
    // The CAS group signs in through a web page, which the CLI cannot do. The BTU-Account group takes
    // username + password (+ 2FA), so it is the default here.
    public string Host { get; set; } = "vpn-gate.b-tu.de";
    public string Group { get; set; } = "Anmeldung mit BTU-Account";
    public string Username { get; set; } = "";
    public bool AutoReconnect { get; set; } = true;

    static string Dir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "VPNToggle");
    static string FilePath => Path.Combine(Dir, "settings.json");

    public static Settings Load()
    {
        Settings s;
        try { s = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings(); }
        catch { s = new Settings(); }
        if (string.IsNullOrEmpty(s.Username)) s.Username = Cisco.PreferenceValue("DefaultUser") ?? "";
        return s;
    }

    public void Save()
    {
        Directory.CreateDirectory(Dir);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }
}

/// One timestamped line per event in %LOCALAPPDATA%\VPNToggle\VPNToggle.log, so a drop can be told apart from a click.
public static class Log
{
    public static string FilePath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VPNToggle", "VPNToggle.log");

    public static void Write(string text)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {text}{Environment.NewLine}");
        }
        catch { }
    }
}

/// Password, PIN and 2FA secret live in Windows Credential Manager ("VPNToggle:<name>"), never in a file.
public static class Secrets
{
    const int CRED_TYPE_GENERIC = 1;
    const int CRED_PERSIST_LOCAL_MACHINE = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL
    {
        public int Flags;
        public int Type;
        public string TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string? UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWrite(ref CREDENTIAL credential, int flags);

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr buffer);

    static string Target(string name) => "VPNToggle:" + name;

    public static string? Get(string name)
    {
        if (!CredRead(Target(name), CRED_TYPE_GENERIC, 0, out var p)) return null;
        try
        {
            var c = Marshal.PtrToStructure<CREDENTIAL>(p);
            return c.CredentialBlobSize == 0 ? null : Marshal.PtrToStringUni(c.CredentialBlob, c.CredentialBlobSize / 2);
        }
        finally { CredFree(p); }
    }

    public static void Set(string name, string? value)
    {
        CredDelete(Target(name), CRED_TYPE_GENERIC, 0);
        if (string.IsNullOrEmpty(value)) return;
        var bytes = Encoding.Unicode.GetBytes(value);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var c = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC,
                TargetName = Target(name),
                CredentialBlobSize = bytes.Length,
                CredentialBlob = blob,
                Persist = CRED_PERSIST_LOCAL_MACHINE,
                UserName = Environment.UserName,
            };
            CredWrite(ref c, 0);
        }
        finally
        {
            Marshal.Copy(new byte[bytes.Length], 0, blob, bytes.Length);
            Marshal.FreeHGlobal(blob);
            Array.Clear(bytes);
        }
    }
}

/// RFC 6238 TOTP (HMAC-SHA1, 30 s step, 6 digits).
public static class Totp
{
    /// Accepts a bare base32 secret, an otpauth:// URI, or a Google Authenticator export (otpauth-migration://).
    public static byte[]? SecretBytes(string? input)
    {
        if (string.IsNullOrWhiteSpace(input)) return null;
        var s = input.Trim();
        if (s.StartsWith("otpauth-migration://", StringComparison.OrdinalIgnoreCase)) return MigrationSecret(s);
        if (s.StartsWith("otpauth://", StringComparison.OrdinalIgnoreCase)) s = Query(s, "secret") ?? "";

        const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
        int bits = 0, value = 0;
        var output = new List<byte>();
        foreach (var c in s.ToUpperInvariant())
        {
            if (c is ' ' or '=' or '-') continue;
            var i = alphabet.IndexOf(c);
            if (i < 0) return null;
            value = (value << 5) | i;
            bits += 5;
            if (bits >= 8) { output.Add((byte)((value >> (bits - 8)) & 0xFF)); bits -= 8; }
        }
        return output.Count == 0 ? null : output.ToArray();
    }

    static string? Query(string uri, string key)
    {
        var q = uri.IndexOf('?');
        if (q < 0) return null;
        foreach (var part in uri[(q + 1)..].Split('&'))
        {
            var kv = part.Split('=', 2);
            if (kv.Length == 2 && kv[0].Equals(key, StringComparison.OrdinalIgnoreCase)) return Uri.UnescapeDataString(kv[1]);
        }
        return null;
    }

    /// Picks the TOTP entry whose name or issuer mentions BTU, or the only TOTP entry if there is one.
    static byte[]? MigrationSecret(string uri)
    {
        var b64 = Query(uri, "data");
        if (b64 == null) return null;
        b64 = b64.Replace('-', '+').Replace('_', '/');
        while (b64.Length % 4 != 0) b64 += "=";
        byte[] payload;
        try { payload = Convert.FromBase64String(b64); } catch { return null; }

        var entries = new List<(byte[] secret, string label)>();
        foreach (var (field, value) in Fields(payload))
        {
            if (field != 1 || value is not byte[] entry) continue;
            byte[] secret = Array.Empty<byte>();
            var label = "";
            ulong type = 2; // TOTP is the default
            foreach (var (f, v) in Fields(entry))
            {
                if (f == 1 && v is byte[] sec) secret = sec;
                else if ((f == 2 || f == 3) && v is byte[] text) label += Encoding.UTF8.GetString(text) + " ";
                else if (f == 6 && v is ulong t) type = t;
            }
            if (type == 2 && secret.Length > 0) entries.Add((secret, label));
        }
        var btu = entries.Where(e => e.label.Contains("btu", StringComparison.OrdinalIgnoreCase)
                                  || e.label.Contains("b-tu", StringComparison.OrdinalIgnoreCase)).ToList();
        if (btu.Count == 1) return btu[0].secret;
        return entries.Count == 1 ? entries[0].secret : null;
    }

    /// Minimal protobuf reader: varint (ulong) and length-delimited (byte[]) fields.
    static List<(int, object)> Fields(byte[] b)
    {
        var output = new List<(int, object)>();
        int i = 0;
        ulong? Varint()
        {
            ulong v = 0; int shift = 0;
            while (i < b.Length && shift < 64)
            {
                var x = b[i++];
                v |= (ulong)(x & 0x7F) << shift;
                if ((x & 0x80) == 0) return v;
                shift += 7;
            }
            return null;
        }
        while (i < b.Length)
        {
            var key = Varint();
            if (key == null) break;
            switch (key.Value & 7)
            {
                case 0:
                    var v = Varint();
                    if (v == null) return output;
                    output.Add(((int)(key.Value >> 3), v.Value));
                    break;
                case 2:
                    var n = Varint();
                    if (n == null || i + (int)n.Value > b.Length) return output;
                    output.Add(((int)(key.Value >> 3), b[i..(i + (int)n.Value)]));
                    i += (int)n.Value;
                    break;
                case 1: i += 8; break;
                case 5: i += 4; break;
                default: return output;
            }
        }
        return output;
    }

    public static string Code(byte[] secret, DateTimeOffset at)
    {
        var msg = BitConverter.GetBytes(at.ToUnixTimeSeconds() / 30);
        if (BitConverter.IsLittleEndian) Array.Reverse(msg);
        using var h = new HMACSHA1(secret);
        var mac = h.ComputeHash(msg);
        var o = mac[19] & 0x0F;
        var n = ((mac[o] & 0x7F) << 24) | (mac[o + 1] << 16) | (mac[o + 2] << 8) | mac[o + 3];
        return (n % 1_000_000).ToString("D6");
    }

    /// The current code, sent at once: 2FA servers accept codes from a window around now,
    /// so waiting for the next 30 s step only adds delay.
    public static string FreshCode(byte[] secret) => Code(secret, DateTimeOffset.UtcNow);
}

/// Cisco Secure Client / AnyConnect through its own command-line tool, vpncli.exe.
public static class Cisco
{
    public static readonly string? Cli = new[]
    {
        @"%ProgramFiles(x86)%\Cisco\Cisco Secure Client\vpncli.exe",
        @"%ProgramFiles%\Cisco\Cisco Secure Client\vpncli.exe",
        @"%ProgramFiles(x86)%\Cisco\Cisco AnyConnect Secure Mobility Client\vpncli.exe",
        @"%ProgramFiles%\Cisco\Cisco AnyConnect Secure Mobility Client\vpncli.exe",
    }.Select(Environment.ExpandEnvironmentVariables).FirstOrDefault(File.Exists);

    // The Cisco window blocks CLI connects ("Another AnyConnect application is running").
    static readonly string[] GuiProcesses = { "csc_ui", "vpnui" };

    // The status check (`vpncli state`/`stats`) in flight, so a click can cancel it instead of queueing behind it.
    static readonly object statusLock = new();
    static Process? statusProcess;

    public static void CancelStatusCheck()
    {
        lock (statusLock) { try { statusProcess?.Kill(); } catch { } }
    }

    /// IPv4 addresses on all network interfaces that are up. Instant, where `vpncli state` starts Cisco's
    /// CLI and takes seconds; the app watches the tunnel's own address instead.
    public static HashSet<string> TunnelAddresses()
    {
        var set = new HashSet<string>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                foreach (var a in nic.GetIPProperties().UnicastAddresses)
                    if (a.Address.AddressFamily == AddressFamily.InterNetwork) set.Add(a.Address.ToString());
            }
        }
        catch { }
        return set;
    }

    /// "12m", "1h 05m", "1d 2h 03m".
    public static string FormatDuration(int seconds)
    {
        int d = seconds / 86400, h = seconds / 3600 % 24, m = seconds / 60 % 60;
        if (d > 0) return $"{d}d {h}h {m:00}m";
        if (h > 0) return $"{h}h {m:00}m";
        return $"{Math.Max(m, 1)}m";
    }

    /// Runs `vpncli <args>` and returns its output.
    public static string Run(string args)
    {
        if (Cli == null) return "Cisco Secure Client (vpncli.exe) was not found.";
        var psi = new ProcessStartInfo(Cli, args)
        {
            RedirectStandardOutput = true,
            RedirectStandardInput = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        using var p = Process.Start(psi)!;
        lock (statusLock) statusProcess = p;
        try
        {
            p.StandardInput.Close();
            var output = p.StandardOutput.ReadToEndAsync();
            if (!p.WaitForExit(20_000)) { try { p.Kill(); } catch { } }
            return output.Wait(2_000) ? output.Result : "";
        }
        finally { lock (statusLock) if (statusProcess == p) statusProcess = null; }
    }

    public static VpnState State()
    {
        var line = Run("state").Split('\n').LastOrDefault(l => l.Contains("state:"));
        if (line == null) return VpnState.Unknown;
        if (line.Contains("Disconnected")) return VpnState.Disconnected;
        if (line.Contains("Connected")) return VpnState.Connected;
        return VpnState.Busy;
    }

    /// Client IP and seconds connected from `vpncli stats`, e.g. ("141.43.0.10", 3900). Slow.
    public static (string? ip, int? seconds) Info()
    {
        string? ip = null;
        int? seconds = null;
        foreach (var raw in Run("stats").Split('\n'))
        {
            var parts = raw.Split(':', 2);
            if (parts.Length != 2) continue;
            var (key, value) = (parts[0].Trim(), parts[1].Trim());
            if (value == "Not Available") continue;
            if (key == "Client Address (IPv4)") ip = value;
            if (key == "Duration")
            {
                // "00:12:05" or "1 day(s) 02:03:04"
                var m = Regex.Match(value, @"(?:(\d+)\s*day.*?\s)?(\d+):(\d+):(\d+)");
                if (!m.Success) continue;
                var days = m.Groups[1].Success ? int.Parse(m.Groups[1].Value) : 0;
                int h = int.Parse(m.Groups[2].Value), min = int.Parse(m.Groups[3].Value), sec = int.Parse(m.Groups[4].Value);
                seconds = ((days * 24 + h) * 60 + min) * 60 + sec;
            }
        }
        return (ip, seconds);
    }

    /// Returns true when a Cisco window was running (and has been closed).
    public static bool QuitGui()
    {
        var any = false;
        foreach (var name in GuiProcesses)
            foreach (var p in Process.GetProcessesByName(name))
                try { p.Kill(); any = true; } catch { }
        return any;
    }

    static IEnumerable<string> PreferenceFiles()
    {
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cisco");
        if (!Directory.Exists(root)) return Enumerable.Empty<string>();
        try { return Directory.GetFiles(root, "preferences.xml", SearchOption.AllDirectories); }
        catch { return Enumerable.Empty<string>(); }
    }

    public static string? PreferenceValue(string tag)
    {
        foreach (var f in PreferenceFiles())
        {
            try
            {
                var m = Regex.Match(File.ReadAllText(f), $"<{tag}>([^<]*)</{tag}>");
                if (m.Success && m.Groups[1].Value.Length > 0) return m.Groups[1].Value;
            }
            catch { }
        }
        return null;
    }

    /// The CLI asks the server for the group last used (DefaultGroup in preferences.xml). If that is a
    /// browser-login group, the server answers with SAML and the CLI aborts, so point it at our group first.
    public static void SetDefaultGroup(string group)
    {
        var escaped = group.Replace("&", "&amp;").Replace("<", "&lt;");
        foreach (var f in PreferenceFiles())
        {
            try
            {
                var xml = File.ReadAllText(f);
                var updated = Regex.Replace(xml, "<DefaultGroup>[^<]*</DefaultGroup>", $"<DefaultGroup>{escaped}</DefaultGroup>");
                if (updated != xml) File.WriteAllText(f, updated);
            }
            catch { }
        }
    }

    /// Starts `vpncli disconnect` and returns as soon as the tunnel's address is gone; Cisco's CLI may
    /// still be tidying up. Returns true when the tunnel is known to be down.
    public static bool Disconnect(string? tunnelIp)
    {
        if (Cli == null) return false;
        var psi = new ProcessStartInfo(Cli, "disconnect")
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        var p = Process.Start(psi)!;
        p.StandardInput.Close();
        _ = p.StandardOutput.ReadToEndAsync();  // keep its output pipe drained
        var deadline = DateTime.Now.AddSeconds(20);
        while (DateTime.Now < deadline && !p.HasExited)
        {
            if (tunnelIp != null && !TunnelAddresses().Contains(tunnelIp)) break;
            Thread.Sleep(50);
        }
        return tunnelIp != null && !TunnelAddresses().Contains(tunnelIp);
    }

    /// Connects with `vpncli -s`, answering each prompt as it appears. If prompts never show (some builds
    /// buffer them when output is redirected), it falls back to sending the answers in BTU's known order:
    /// group, username, password, 2FA code. `message` is a one-line reason on failure, null on cancel.
    public static (bool ok, string? message, string log) Connect(
        string host, string group, string user, string password, string? pin, byte[]? totp, Func<string?> askCode)
    {
        if (Cli == null) return (false, "Cisco Secure Client is not installed (vpncli.exe not found).", "");
        var psi = new ProcessStartInfo(Cli, "-s")
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        var p = Process.Start(psi)!;   // not disposed here: a delayed cleanup below may still stop it
        var stdin = p.StandardInput;
        stdin.AutoFlush = true;
        void Send(string s) { try { stdin.Write(s + "\n"); } catch { } }

        string? SecondFactor()
        {
            if (totp != null) return Totp.FreshCode(totp);
            if (!string.IsNullOrEmpty(pin)) return pin;
            return askCode();
        }

        Send($"connect {host}");
        var log = new StringBuilder();
        var pending = new StringBuilder();
        var asked = new Dictionary<string, int>();
        string? failure = null;
        var cancelled = false;
        var blindSent = false;
        var start = DateTime.Now;
        var timing = new List<string>();   // when each step happened, for the event log
        var deadline = start.AddSeconds(180);
        var buf = new char[4096];
        Task<int>? read = null;

        while (DateTime.Now < deadline)
        {
            read ??= p.StandardOutput.ReadAsync(buf, 0, buf.Length);
            if (!read.Wait(500))
            {
                if (p.HasExited) break;
                // Fallback for buffered prompts: nothing answered 10 s in, but the server was contacted.
                if (!blindSent && asked.Count == 0 && (DateTime.Now - start).TotalSeconds > 10
                    && log.ToString().Contains("ontacting"))
                {
                    blindSent = true;
                    Send(group); Send(user); Send(password);
                    var code = SecondFactor();
                    if (code == null) { cancelled = true; break; }
                    Send(code);
                }
                continue;
            }
            var n = read.Result;
            read = null;
            if (n <= 0) break;
            var chunk = new string(buf, 0, n).Replace("\r", "");
            log.Append(chunk);
            pending.Append(chunk);

            var tail = pending.ToString().Split('\n').Last().Trim();
            var low = tail.ToLowerInvariant();
            string? kind = null, reply = null;
            if (low.EndsWith("[y/n]:"))
            {
                // Accept the login banner only. Refuse anything else, e.g. an untrusted server certificate.
                kind = "yn"; reply = low.Contains("accept?") ? "y" : "n";
            }
            else if (low.StartsWith("group:")) { kind = "group"; reply = group; }
            else if (low.StartsWith("username:") && !low.Contains("password")) { kind = "user"; reply = user; }
            else if (low.EndsWith(":") && low.Contains("pin") && !string.IsNullOrEmpty(pin)) { kind = "pin"; reply = pin; }
            else if (low.EndsWith(":") && (low.StartsWith("answer") || low.Contains("second password") || low.Contains("pin")
                     || low.Contains("code") || low.Contains("passcode") || low.Contains("otp") || low.Contains("token")))
            {
                // BTU asks "Answer:" for its 2FA token.
                reply = SecondFactor();
                if (reply == null) { cancelled = true; break; }
                kind = "otp";
            }
            else if (low.EndsWith("password:")) { kind = "password"; reply = password; }

            if (kind != null && reply != null)
            {
                asked[kind] = asked.GetValueOrDefault(kind) + 1;
                if (asked[kind] > 2) { failure = "Login rejected. Check your password and 2FA code."; break; }
                pending.Clear();
                Send(reply);
                timing.Add($"{kind} {(DateTime.Now - start).TotalSeconds:0.0}s");
            }
            var all = log.ToString();
            if (all.Contains("state: Connected")) { timing.Add($"connected {(DateTime.Now - start).TotalSeconds:0.0}s"); break; }
            if (all.Contains("Login failed")) { failure = "Login rejected. Check your password and 2FA code."; break; }
        }

        Log.Write("connect timing: " + string.Join(", ", timing));
        // Do not wait for the CLI to exit; the tunnel is already up (or the login is over).
        if (!p.HasExited) Send("exit");
        var cli = p;
        _ = Task.Delay(2000).ContinueWith(_ => { try { if (!cli.HasExited) cli.Kill(); } catch { } });

        // Scrub secrets in case the CLI echoed an answer.
        var text = log.ToString();
        foreach (var secret in new[] { password, pin ?? "" }.Where(s => s.Length >= 3))
            text = text.Replace(secret, "••••");

        if (cancelled) return (false, null, text);
        if (failure != null) return (false, failure, text);
        // Cisco's own "state: Connected" line is enough; skip the slow `vpncli state` round trip.
        if (text.Contains("state: Connected") || State() == VpnState.Connected) return (true, null, text);
        var cliError = text.Split('\n').FirstOrDefault(l => l.Contains(">> error:"))?.Split(">> error:").Last().Trim();
        return (false, cliError ?? $"Could not connect to {host}.", text);
    }
}
