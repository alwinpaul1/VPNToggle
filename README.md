# VPNToggle

One-click menu bar (macOS) / system tray (Windows) toggle for Cisco Secure Client
(AnyConnect), made for BTU Cottbus's `vpn-gate.b-tu.de` but configurable.

- Connects through Cisco's own command-line client, answering the group, username,
  password and 2FA prompts itself.
- Generates the 2FA code (TOTP) from a saved secret. The secret can be imported from a
  Google Authenticator export QR code, from a screenshot ("Read QR image…") or live from
  the camera ("Scan with camera…").
- Status card from the menu bar / tray icon, a hover card with IP and connected time,
  auto-reconnect when the tunnel drops, notifications, launch at login, an event log.
- `vpntoggle://connect`, `vpntoggle://disconnect`, `vpntoggle://toggle`, `vpntoggle://show`
  links for shortcuts and scripts.
- Password, PIN and 2FA secret are stored in the macOS Keychain / Windows Credential
  Manager, never in a file.

BTU note: the default "Anmeldung per CAS" group signs in through a web page, which the
CLI cannot do. The app uses the "Anmeldung mit BTU-Account" group instead.

Security note: storing the 2FA secret on the same computer means anyone with access to
your unlocked account has both factors. Leave the 2FA secret empty to be asked for the
code each time instead.

## macOS (macOS 26 or later)

```sh
cd VPNToggle && ./build.sh      # builds and installs ~/Applications/VPNToggle.app
open ~/Applications/VPNToggle.app
```

Needs Xcode command-line tools and `rsvg-convert` (`brew install librsvg`) for the icon.
Click the shield in the menu bar for the status card; hover for a quick status.
From the terminal: `open vpntoggle://connect`.

## Windows (10 or 11)

Build (on Windows, macOS or Linux, with the .NET 9 SDK):

```sh
cd windows
dotnet publish -c Release -o publish
```

This produces a single self-contained `publish/VPNToggle.exe`; copy it anywhere and run it.
Needs Windows 10 2004 or later and Cisco Secure Client (or AnyConnect). Left-click the
tray shield for the status card, hover for a quick status, right-click for a quick menu.
On first start it asks for the credentials. From a script: `start vpntoggle://connect`
or `VPNToggle.exe --connect`.
Windows 11 22H2+ gets the acrylic background; older versions a solid one.
Log: `%LOCALAPPDATA%\VPNToggle\VPNToggle.log`.
