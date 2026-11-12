# edge-blocker

Keep Microsoft Edge from coming back after you remove it, and keep WebView2 working.

Windows reinstalls the Edge browser through Edge Update and Windows Update. This PowerShell script sets Microsoft's own documented policy values so Edge is not installed or updated again. WebView2, the part other apps use to draw their windows, stays allowed. A second script undoes every change.

## Who it is for

Windows 10 and 11 users who removed Edge and want it to stay removed, without breaking the apps that need WebView2.

## What it changes

Under `HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate`:

| Value | Set to | Meaning |
|---|---|---|
| `Install` + `Update` for Edge Stable, Beta, Dev, Canary | `0` | Do not install or update these Edge channels |
| `Install` + `Update` for WebView2 | `1` | WebView2 may install and update |
| `CreateDesktopShortcutDefault` | `0` | No Edge desktop shortcut |

Under `HKLM\SOFTWARE\Microsoft\EdgeUpdate`:

| Value | Set to | Meaning |
|---|---|---|
| `DoNotUpdateToEdgeWithChromium` | `1` | Windows Update does not deliver Edge |

It also sets the `MicrosoftEdgeElevationService` service to **Disabled** (skip this with `-KeepService`).

It does **not** uninstall Edge, delete files, or patch system files. If Edge is still installed, remove it first through Settings > Apps if your Windows version allows it.

## Requirements

- Windows 10 or 11.
- Windows PowerShell 5.1 (built in) or PowerShell 7.
- An administrator PowerShell window to apply changes. A dry run works without admin rights.

## Download

[Download the ZIP](https://github.com/zed-dz/edge-blocker/archive/refs/heads/main.zip) and unzip it.

## How to use

1. Right-click **Start**, choose **Terminal (Admin)** or **Windows PowerShell (Admin)**.
2. Go to the unzipped folder:

   ```powershell
   cd "$env:USERPROFILE\Downloads\edge-blocker-main"
   ```

3. See what would change, without changing anything:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\edge-block.ps1 -WhatIf
   ```

4. Apply it:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\edge-block.ps1
   ```

   It prints the final values when it is done.

`-DryRun` works the same as `-WhatIf`.

## How to undo

```powershell
powershell -ExecutionPolicy Bypass -File .\edge-unblock.ps1 -WhatIf   # see what it would restore
powershell -ExecutionPolicy Bypass -File .\edge-unblock.ps1           # restore
```

Before the first change, `edge-block.ps1` saves the old values to `C:\ProgramData\EdgeBlocker\backup.json`. The undo script reads that file and:

- gives every value that existed before its old value back,
- removes every value that did not exist before,
- removes a policy key only if the block script created it and it is now empty,
- sets the Edge helper service back to its old startup type.

If the backup file is missing, it removes the values listed above and sets the service back to Manual, the Windows default.

After undoing, Edge can be installed again from https://www.microsoft.com/edge.

## Safety notes

- Only documented Microsoft policy values are used. You can check them in Microsoft's Edge Update policy documentation.
- Running `edge-block.ps1` twice is safe. The first backup is kept, so undo still returns you to the state before the first run.
- Organisations that manage Edge through Group Policy or Intune may overwrite these values.
- Read the script before you run it as administrator. It is about 130 lines.

## Licence

MIT. See [LICENSE](LICENSE).

---

Made by Amine Hammou. Custom tools: https://aminehammou.vercel.app/tools.html
