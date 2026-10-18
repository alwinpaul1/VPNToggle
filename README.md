# VPNToggle

One click to turn the Cisco VPN on or off, from the macOS menu bar or the Windows system
tray. It logs in for you, including the 2FA code, so you never type your password or PIN.
Made for BTU Cottbus (`vpn-gate.b-tu.de`), but the server and group can be changed.

- Signs in through Cisco's own client and answers the group, username, password and 2FA
  questions for you.
- Makes the 2FA code itself from your authenticator secret. You can import that secret by
  pointing the camera at a Google Authenticator export QR code, or from a screenshot of it.
- Reconnects on its own if the VPN drops, shows a notification when it connects or drops,
  and can start when you log in.
- Your password, PIN and 2FA secret are kept in the macOS Keychain / Windows Credential
  Manager. They are never written to a file.

---

## What you need first

| | Windows | macOS |
|---|---|---|
| System | Windows 10 (version 2004 or newer) or Windows 11 | macOS 26 or newer |
| Cisco | **Cisco Secure Client** (or the older AnyConnect) installed | **Cisco Secure Client** installed |
| Account | Your BTU username and password | Your BTU username and password |
| 2FA (optional) | Your authenticator app, to import the 2FA secret once | same |

Get Cisco Secure Client from the BTU IT service page if you do not have it yet. Connect
with it once the normal way, to make sure your account works. You do **not** need to keep
the Cisco window open afterwards.

---

## Install on Windows

1. Open the **[Releases page](../../releases/latest)** and download **`VPNToggle.exe`**.
2. Move it somewhere permanent, for example `C:\Users\<you>\Apps\VPNToggle.exe`
   (not the Downloads folder, so it does not get deleted).
3. Double-click it.
   - If Windows shows **"Windows protected your PC"**, click **More info → Run anyway**.
     The app is not code-signed, which is why Windows warns.
4. A setup window opens the first time. Fill in (see [Setup](#setup-both-systems) below) and click **Save**.
5. The app now lives in the **system tray**, next to the clock, as a small shield icon.
   - **Can't see it?** Click the **^** arrow by the clock. Drag the shield from there onto
     the taskbar so it always stays visible.
6. Click the shield to open the card and press the round **power button** to connect.

After the first start the app appears in the **Start menu**: search "VPNToggle" to open it
again after quitting. To start it automatically, open the card → **⋯** → **Launch at startup**.

## Install on macOS

1. Open the **[Releases page](../../releases/latest)** and download **`VPNToggle-macOS.zip`**.
2. Double-click the zip, then drag **VPNToggle.app** into your **Applications** folder.
3. The first time, **right-click** the app → **Open** → **Open**. (It is not notarized by
   Apple, so a normal double-click is blocked the very first time.)
4. A setup window opens. Fill it in (see [Setup](#setup-both-systems)) and click **Save**.
5. A shield appears in the **menu bar** at the top right. Click it and press the round
   **power button** to connect.
6. macOS asks whether VPNToggle may use your Keychain. Type your Mac password and click
   **Always Allow** (not just "Allow", or it will ask every time).

To start it automatically, open the card → **⋯** → **Launch at Login**. If you quit it, open it
again from Applications or Spotlight.

---

## Setup (both systems)

The setup window (also under **⋯ → Credentials…**) asks for:

| Field | What to enter |
|---|---|
| Server | `vpn-gate.b-tu.de` (already filled in) |
| Group | `Anmeldung mit BTU-Account` (already filled in, leave it) |
| Username | Your BTU username |
| Password | Your BTU password |
| PIN | Leave empty (BTU does not use a fixed PIN) |
| 2FA secret | Optional, see below. Leave empty to type the 6-digit code yourself each time |

Why not "Anmeldung per CAS"? That group signs in through a web page, which an app cannot
fill in. "Anmeldung mit BTU-Account" asks the same questions in plain form, so the app can.

### Making the 2FA code automatic (optional)

Without this, the app asks you for the 6-digit code each time you connect. With it, there is
nothing to type at all. You need the secret that your authenticator app holds:

**From Google Authenticator** (on your phone):
1. Open Google Authenticator → menu **⋯** (or ☰) → **Transfer accounts** → **Export accounts**.
2. Select **only the BTU entry** → **Next**. A QR code appears. (Your phone keeps the account.)
3. In VPNToggle's setup window click **Scan with camera…** and hold the phone up to the
   webcam, **or** take a screenshot of the QR code, put it on the computer and click
   **Read QR image…**.
4. You should see "2FA secret read". Click **Save**.
5. If you used a screenshot, delete it afterwards (including from the bin / Recently Deleted).

**From another authenticator app** (1Password, Bitwarden, Aegis, 2FAS…): copy the BTU
entry's secret (letters and digits) or its `otpauth://` link into the **2FA secret** field.

**Security note:** with the secret stored on the computer, anyone who gets into your unlocked
user account has both your password and your second factor. If that worries you, leave the
field empty and type the code yourself.

---

## Everyday use

- **Click the icon**: the card shows whether you are connected, your VPN IP address, how long
  you have been connected, and the round power button.
- **Power button**: one click connects, one click disconnects. The ring turns green when you
  are connected.
- **Hover over the icon**: a small status bubble.
- **⋯ menu**: Credentials, Launch at startup/login, Copy IP address, Show log, Quit.
- **Auto-reconnect** (switch in the card): if the VPN drops, the app reconnects by itself.

For scripts and shortcuts: `vpntoggle://connect`, `vpntoggle://disconnect`,
`vpntoggle://toggle`, `vpntoggle://show` (macOS: `open vpntoggle://connect`; Windows:
`start vpntoggle://connect` or `VPNToggle.exe --connect`).

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Nothing seems to happen when I open it (Windows) | It is in the tray. Click **^** by the clock, then drag the shield onto the taskbar. Opening it again also shows the card. |
| "Cisco Secure Client not found" | Install Cisco Secure Client first, then start VPNToggle again. |
| "Login rejected" | Check the username and password under **⋯ → Credentials…**. If the 2FA secret is wrong, clear it and type the code instead. |
| "The requested authentication type is not supported" | The Group must be `Anmeldung mit BTU-Account`, not "Anmeldung per CAS". |
| Asks for the code every time | No 2FA secret is saved. See [Making the 2FA code automatic](#making-the-2fa-code-automatic-optional). |
| macOS keeps asking for Keychain access | Click **Always Allow**, not Allow. |
| Camera scan does not start | Allow camera access: Windows → Settings → Privacy & security → Camera → "Let desktop apps access your camera"; macOS → System Settings → Privacy & Security → Camera. Or use **Read QR image…**. |
| It connected slowly | The log shows each step's time: **⋯ → Show log** (`connect timing` and `cisco steps` lines). Most of the time is spent by Cisco and the BTU server. |

Log files: Windows `%LOCALAPPDATA%\VPNToggle\VPNToggle.log`, macOS `~/Library/Logs/VPNToggle.log`.
Error pop-ups have a **Copy details** button with Cisco's full output.

### Mac slow? Cisco's `acnvmagent` growing (macOS, optional)

Cisco Secure Client can install a Network Visibility Module whose agent, `acnvmagent`, looks
at every network connection. On a Mac that ran for weeks it was seen using 70% CPU under
heavy traffic and growing past 1.3 GB of memory. It is separate from the VPN, so
restarting it does not drop the tunnel; Cisco's `vpnagentd` starts it again within seconds.

`nvm-watchdog/` keeps it small. It checks every 5 minutes and restarts the agent when it
passes 400 MB, plus once a day at the first check after midnight. It also gives the agent
background priority, so on Apple silicon it runs on the efficiency cores and stops slowing
down your apps. It logs to
`/var/log/nvm-watchdog.log` and starts that log over past 64 KB.

```sh
sudo sh nvm-watchdog/install.sh     # install (runs the first check at once)
sudo sh nvm-watchdog/uninstall.sh   # remove
```

Change the limit with `CAP_MB` at the top of `nvm-watchdog/nvm-watchdog.sh` before installing.
If Activity Monitor shows no `acnvmagent`, your Cisco install has no NVM and you do not need this.

### Uninstall

- **Windows:** quit it (⋯ → Quit), turn off Launch at startup first if you enabled it, then
  delete `VPNToggle.exe`, the Start menu entry, and `%APPDATA%\VPNToggle`. Saved secrets are in
  Credential Manager → Windows Credentials → entries starting with `VPNToggle:`.
- **macOS:** quit it, turn off Launch at Login, delete VPNToggle.app. Saved secrets are in
  Keychain Access under "VPNToggle".

---

## Building from source (optional)

You only need this to change the code; the Releases page has ready-made downloads.

**Windows** (also builds on macOS/Linux): install the [.NET 9 SDK](https://dotnet.microsoft.com/download/dotnet/9.0), then

```sh
cd windows
dotnet publish -c Release -o publish
```

The result is `windows/publish/VPNToggle.exe`. If you see `NU1100 Unable to resolve ...`,
your computer cannot reach nuget.org (check `dotnet nuget list source`, a proxy or the network).
Dependencies are downloaded automatically: ZXing.Net (QR codes) and the Windows SDK projection.

**macOS:** install Xcode (or its command-line tools) and `rsvg-convert` (`brew install librsvg`), then

```sh
./build.sh      # builds and installs ~/Applications/VPNToggle.app
```

The app's version comes from the newest `v*` git tag, so tag a release before building its zip.

No other dependencies: it uses only Apple's frameworks (AppKit, SwiftUI, AVFoundation, Vision).
