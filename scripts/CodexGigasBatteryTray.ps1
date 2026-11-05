# Codex Gigas split-keyboard battery tray monitor
# Run on Windows with: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\CodexGigasBatteryTray.ps1
# Requires Windows PowerShell 5.1 or PowerShell 7 on Windows with Windows Forms available.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('CodexGigasHid' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class CodexGigasHid {
    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVICE_INTERFACE_DATA {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }
    [DllImport("hid.dll")]
    private static extern void HidD_GetHidGuid(out Guid guid);
    [DllImport("hid.dll", SetLastError=true)]
    private static extern bool HidD_GetFeature(SafeFileHandle handle, [In, Out] byte[] buffer, int length);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr SetupDiGetClassDevs(ref Guid classGuid, IntPtr enumerator, IntPtr hwndParent, int flags);
    [DllImport("setupapi.dll", SetLastError=true)]
    private static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr deviceInfoData, ref Guid guid, int index, ref SP_DEVICE_INTERFACE_DATA data);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail, int size, out int required, IntPtr deviceInfoData);
    [DllImport("setupapi.dll", SetLastError=true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern SafeFileHandle CreateFile(string path, uint access, uint shareMode, IntPtr securityAttributes, uint creationDisposition, uint flags, IntPtr template);

    public static string[] FindBatteryPaths() {
        Guid guid;
        HidD_GetHidGuid(out guid);
        IntPtr set = SetupDiGetClassDevs(ref guid, IntPtr.Zero, IntPtr.Zero, 0x12);
        if (set == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        var paths = new List<string>();
        try {
            for (int i = 0; ; i++) {
                var data = new SP_DEVICE_INTERFACE_DATA();
                data.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref guid, i, ref data)) {
                    int error = Marshal.GetLastWin32Error();
                    if (error == 259) break;
                    throw new Win32Exception(error);
                }
                int required;
                SetupDiGetDeviceInterfaceDetail(set, ref data, IntPtr.Zero, 0, out required, IntPtr.Zero);
                IntPtr detail = Marshal.AllocHGlobal(required);
                try {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetail(set, ref data, detail, required, out required, IntPtr.Zero))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    string path = Marshal.PtrToStringUni(IntPtr.Add(detail, 4));
                    if (path != null && path.IndexOf("vid_1d50&pid_615e", StringComparison.OrdinalIgnoreCase) >= 0 &&
                        path.IndexOf("mi_01", StringComparison.OrdinalIgnoreCase) >= 0)
                        paths.Add(path);
                } finally { Marshal.FreeHGlobal(detail); }
            }
        } finally { SetupDiDestroyDeviceInfoList(set); }
        return paths.ToArray();
    }

    public static int ReadBattery(string path, byte reportId) {
        foreach (uint access in new uint[] { 0xC0000000u, 0u }) {
            using (var handle = CreateFile(path, access, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
                if (handle.IsInvalid) continue;
                byte[] buffer = new byte[] { reportId, 0 };
                if (HidD_GetFeature(handle, buffer, buffer.Length)) {
                    if (buffer[0] != reportId || buffer[1] > 100) return -1;
                    return buffer[1];
                }
            }
        }
        return -1;
    }
}
'@
}

# A single tray icon displays the lower of the two battery percentages.
# Click it to see the separate left and right readings.
function New-BatteryIcon([int]$Level) {
    $bitmap = [System.Drawing.Bitmap]::new(32, 32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $font = [System.Drawing.Font]::new('Segoe UI', 14, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $color = if ($Level -lt 0) { [System.Drawing.Color]::Gray } elseif ($Level -le 20) { [System.Drawing.Color]::FromArgb(190, 45, 45) } else { [System.Drawing.Color]::FromArgb(28, 125, 70) }
        $brush = [System.Drawing.SolidBrush]::new($color)
        try { $graphics.FillEllipse($brush, 0, 0, 31, 31) } finally { $brush.Dispose() }
        $label = if ($Level -lt 0) { '?' } else { [string]$Level }
        $format = [System.Drawing.StringFormat]::new()
        try {
            $format.Alignment = [System.Drawing.StringAlignment]::Center
            $format.LineAlignment = [System.Drawing.StringAlignment]::Center
            $graphics.DrawString($label, $font, [System.Drawing.Brushes]::White, [System.Drawing.RectangleF]::new(0, 0, 32, 32), $format)
        } finally { $format.Dispose() }
        $hicon = $bitmap.GetHicon()
        try { return ([System.Drawing.Icon]::FromHandle($hicon)).Clone() }
        finally { [CodexGigasIconNative]::DestroyIcon($hicon) | Out-Null }
    } finally {
        $font.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

if (-not ('CodexGigasIconNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexGigasIconNative {
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@
}

$context = [System.Windows.Forms.ApplicationContext]::new()
$menu = [System.Windows.Forms.ContextMenuStrip]::new()
$leftItem = $menu.Items.Add('Left: checking...')
$leftItem.Enabled = $false
$rightItem = $menu.Items.Add('Right: checking...')
$rightItem.Enabled = $false
[void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
$refreshItem = $menu.Items.Add('Refresh now')
$exitItem = $menu.Items.Add('Exit')
$trayIcon = [System.Windows.Forms.NotifyIcon]::new()
$trayIcon.ContextMenuStrip = $menu
$trayIcon.Text = 'Codex Gigas: checking...'
$script:trayImage = $null
$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = 60000

function Update-BatteryTray {
    $leftLevel = -1
    $rightLevel = -1
    try {
        $paths = [CodexGigasHid]::FindBatteryPaths()
        $leftPath = $paths | Where-Object { $_ -match '&col01#' } | Select-Object -First 1
        $rightPath = $paths | Where-Object { $_ -match '&col02#' } | Select-Object -First 1
        if ($leftPath) { $leftLevel = [CodexGigasHid]::ReadBattery($leftPath, 0x05) }
        if ($rightPath) { $rightLevel = [CodexGigasHid]::ReadBattery($rightPath, 0x06) }
    } catch {
        # Missing/disconnected devices appear as unavailable.
    }

    $leftLabel = if ($leftLevel -ge 0) { "$leftLevel%" } else { 'unavailable' }
    $rightLabel = if ($rightLevel -ge 0) { "$rightLevel%" } else { 'unavailable' }
    $leftItem.Text = "Left: $leftLabel"
    $rightItem.Text = "Right: $rightLabel"
    $trayIcon.Text = "Codex Gigas - L: $leftLabel, R: $rightLabel"

    # Use the lower available level as a conservative at-a-glance indicator.
    $available = @($leftLevel, $rightLevel) | Where-Object { $_ -ge 0 }
    $displayLevel = if ($available.Count -gt 0) { ($available | Measure-Object -Minimum).Minimum } else { -1 }
    $newImage = New-BatteryIcon ([int]$displayLevel)
    $oldImage = $script:trayImage
    $trayIcon.Icon = $newImage
    $script:trayImage = $newImage
    if ($oldImage) { $oldImage.Dispose() }
    $trayIcon.Visible = $true
}

$refreshItem.add_Click({ Update-BatteryTray })
$exitItem.add_Click({ $context.ExitThread() })
$trayIcon.add_MouseClick({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $menu.Show([System.Windows.Forms.Cursor]::Position)
    }
})
$timer.add_Tick({ Update-BatteryTray })
try {
    Update-BatteryTray
    $timer.Start()
    [System.Windows.Forms.Application]::Run($context)
} finally {
    $timer.Stop()
    $timer.Dispose()
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    if ($script:trayImage) { $script:trayImage.Dispose() }
    $menu.Dispose()
    $context.Dispose()
}
