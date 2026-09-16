param(
    [switch]$Install,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$appName = 'BlueAudioSwitchSpeakerFallback'
$installDir = Join-Path $env:LOCALAPPDATA 'BlueAudioSwitch'
$installedScript = Join-Path $installDir 'SpeakerFallback.ps1'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$logFile = Join-Path $installDir 'BlueAudioSwitch.log'

function Stop-FallbackCopies {
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessId -ne $PID -and
                ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and
                $_.CommandLine -match '[\\/]SpeakerFallback\.ps1'
            } |
            ForEach-Object {
                Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
            }
    } catch {}
}

if ($Install) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Stop-FallbackCopies

    $source = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($source)) {
        throw 'Could not determine SpeakerFallback.ps1 path.'
    }

    if ((Resolve-Path $source).Path -ne $installedScript) {
        Copy-Item -LiteralPath $source -Destination $installedScript -Force
    }

    $command = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $installedScript
    New-ItemProperty -Path $runKey -Name $appName -Value $command -PropertyType String -Force | Out-Null

    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile',
        '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$installedScript`""
    )

    exit 0
}

if ($Uninstall) {
    Stop-FallbackCopies
    Remove-ItemProperty -Path $runKey -Name $appName -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $installedScript -Force -ErrorAction SilentlyContinue
    exit 0
}

$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, 'Local\BlueAudioSwitchSpeakerFallback_1D5B2C9E', [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

$nativeCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public sealed class FallbackEndpointInfo
{
    public string Id { get; set; }
    public string Name { get; set; }
}

public static class AudioFallbackNative
{
    private const int DEVICE_STATE_ACTIVE = 0x1;
    private const int STGM_READ = 0;
    private const int CLSCTX_ALL = 23;

    private static PROPERTYKEY PKEY_Device_FriendlyName = new PROPERTYKEY {
        fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"),
        pid = 14
    };

    public static FallbackEndpointInfo[] GetActiveRenderEndpoints()
    {
        List<FallbackEndpointInfo> result = new List<FallbackEndpointInfo>();
        IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();

        try
        {
            IMMDeviceCollection collection;
            int hr = enumerator.EnumAudioEndpoints(EDataFlow.eRender, DEVICE_STATE_ACTIVE, out collection);
            if (hr < 0 || collection == null)
                return result.ToArray();

            try
            {
                int count;
                collection.GetCount(out count);

                for (int i = 0; i < count; i++)
                {
                    IMMDevice device;
                    collection.Item(i, out device);
                    try
                    {
                        string id;
                        device.GetId(out id);
                        result.Add(new FallbackEndpointInfo {
                            Id = id,
                            Name = GetFriendlyName(device)
                        });
                    }
                    catch {}
                    finally { SafeRelease(device); }
                }
            }
            finally { SafeRelease(collection); }
        }
        finally { SafeRelease(enumerator); }

        return result.ToArray();
    }

    public static string GetDefaultRenderEndpointId()
    {
        IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        try
        {
            IMMDevice device;
            int hr = enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eMultimedia, out device);
            if (hr < 0 || device == null)
                return null;

            try
            {
                string id;
                device.GetId(out id);
                return id;
            }
            finally { SafeRelease(device); }
        }
        catch { return null; }
        finally { SafeRelease(enumerator); }
    }

    public static bool SetDefaultRenderEndpoint(string endpointId)
    {
        if (String.IsNullOrWhiteSpace(endpointId))
            return false;

        try
        {
            IPolicyConfig policy = (IPolicyConfig)new PolicyConfigClient();
            try
            {
                int r1 = policy.SetDefaultEndpoint(endpointId, ERole.eConsole);
                int r2 = policy.SetDefaultEndpoint(endpointId, ERole.eMultimedia);
                int r3 = policy.SetDefaultEndpoint(endpointId, ERole.eCommunications);
                return r1 >= 0 && r2 >= 0 && r3 >= 0;
            }
            finally { SafeRelease(policy); }
        }
        catch { return false; }
    }

    public static string[] GetConnectedBluetoothNames()
    {
        List<string> result = new List<string>();

        BLUETOOTH_DEVICE_SEARCH_PARAMS search = new BLUETOOTH_DEVICE_SEARCH_PARAMS();
        search.dwSize = Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_SEARCH_PARAMS));
        search.fReturnAuthenticated = true;
        search.fReturnRemembered = true;
        search.fReturnUnknown = false;
        search.fReturnConnected = true;
        search.fIssueInquiry = false;
        search.cTimeoutMultiplier = 0;
        search.hRadio = IntPtr.Zero;

        BLUETOOTH_DEVICE_INFO info = new BLUETOOTH_DEVICE_INFO();
        info.dwSize = Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_INFO));

        IntPtr find = BluetoothFindFirstDevice(ref search, ref info);
        if (find == IntPtr.Zero)
            return result.ToArray();

        try
        {
            while (true)
            {
                if (info.fConnected && !String.IsNullOrWhiteSpace(info.szName))
                    result.Add(info.szName);

                BLUETOOTH_DEVICE_INFO next = new BLUETOOTH_DEVICE_INFO();
                next.dwSize = Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_INFO));
                if (!BluetoothFindNextDevice(find, ref next))
                    break;
                info = next;
            }
        }
        finally { BluetoothFindDeviceClose(find); }

        return result.ToArray();
    }

    private static string GetFriendlyName(IMMDevice device)
    {
        IPropertyStore store;
        device.OpenPropertyStore(STGM_READ, out store);
        try
        {
            PROPVARIANT value;
            PROPERTYKEY key = PKEY_Device_FriendlyName;
            store.GetValue(ref key, out value);
            try
            {
                if (value.pwszVal == IntPtr.Zero)
                    return String.Empty;
                return Marshal.PtrToStringUni(value.pwszVal) ?? String.Empty;
            }
            finally { PropVariantClear(ref value); }
        }
        finally { SafeRelease(store); }
    }

    private static void SafeRelease(object obj)
    {
        if (obj == null)
            return;
        try
        {
            if (Marshal.IsComObject(obj))
                Marshal.ReleaseComObject(obj);
        }
        catch {}
    }

    private enum EDataFlow { eRender = 0, eCapture = 1, eAll = 2 }
    private enum ERole { eConsole = 0, eMultimedia = 1, eCommunications = 2 }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROPERTYKEY { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Explicit)]
    private struct PROPVARIANT
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pwszVal;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BLUETOOTH_DEVICE_SEARCH_PARAMS
    {
        public int dwSize;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnAuthenticated;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnRemembered;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnUnknown;
        [MarshalAs(UnmanagedType.Bool)] public bool fReturnConnected;
        [MarshalAs(UnmanagedType.Bool)] public bool fIssueInquiry;
        public byte cTimeoutMultiplier;
        public IntPtr hRadio;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct BLUETOOTH_DEVICE_INFO
    {
        public int dwSize;
        public ulong Address;
        public uint ulClassofDevice;
        [MarshalAs(UnmanagedType.Bool)] public bool fConnected;
        [MarshalAs(UnmanagedType.Bool)] public bool fRemembered;
        [MarshalAs(UnmanagedType.Bool)] public bool fAuthenticated;
        public SYSTEMTIME stLastSeen;
        public SYSTEMTIME stLastUsed;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 248)] public string szName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEMTIME
    {
        public ushort wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds;
    }

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PROPVARIANT pvar);

    [DllImport("bthprops.cpl", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr BluetoothFindFirstDevice(ref BLUETOOTH_DEVICE_SEARCH_PARAMS pbtsp, ref BLUETOOTH_DEVICE_INFO pbtdi);

    [DllImport("bthprops.cpl", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BluetoothFindNextDevice(IntPtr hFind, ref BLUETOOTH_DEVICE_INFO pbtdi);

    [DllImport("bthprops.cpl")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BluetoothFindDeviceClose(IntPtr hFind);

    [ComImport]
    [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumerator {}

    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(EDataFlow dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport]
    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDba1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetAt(int index, out PROPERTYKEY key);
        [PreserveSig] int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        [PreserveSig] int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        [PreserveSig] int Commit();
    }

    [ComImport]
    [Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
    private class PolicyConfigClient {}

    [ComImport]
    [Guid("F8679F50-850A-41CF-9C72-430F290290C8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPolicyConfig
    {
        [PreserveSig] int GetMixFormat(string deviceId, IntPtr format);
        [PreserveSig] int GetDeviceFormat(string deviceId, bool isDefault, IntPtr format);
        [PreserveSig] int ResetDeviceFormat(string deviceId);
        [PreserveSig] int SetDeviceFormat(string deviceId, IntPtr endpointFormat, IntPtr mixFormat);
        [PreserveSig] int GetProcessingPeriod(string deviceId, bool isDefault, IntPtr defaultPeriod, IntPtr minimumPeriod);
        [PreserveSig] int SetProcessingPeriod(string deviceId, IntPtr period);
        [PreserveSig] int GetShareMode(string deviceId, IntPtr mode);
        [PreserveSig] int SetShareMode(string deviceId, IntPtr mode);
        [PreserveSig] int GetPropertyValue(string deviceId, bool store, ref PROPERTYKEY key, out PROPVARIANT value);
        [PreserveSig] int SetPropertyValue(string deviceId, bool store, ref PROPERTYKEY key, ref PROPVARIANT value);
        [PreserveSig] int SetDefaultEndpoint(string deviceId, ERole role);
        [PreserveSig] int SetEndpointVisibility(string deviceId, bool visible);
    }
}
'@

try {
    Add-Type -TypeDefinition $nativeCode -Language CSharp
} catch {
    exit 1
}

function Normalize-Name([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $n = $Name.Trim().ToLowerInvariant()
    $open = $n.IndexOf('(')
    $close = $n.LastIndexOf(')')
    if ($open -ge 0 -and $close -gt $open) {
        $inner = $n.Substring($open + 1, $close - $open - 1).Trim()
        if ($inner) { $n = $inner }
    }
    return ($n -replace '\s+', ' ')
}

function Get-EndpointScore($Endpoint) {
    $n = ([string]$Endpoint.Name).ToLowerInvariant()
    $score = 0
    if ($n.Contains('stereo')) { $score += 400 }
    if ($n.Contains('a2dp')) { $score += 500 }
    if ($n.Contains('headphones')) { $score += 200 }
    if ($n.Contains('speaker')) { $score += 150 }
    if ($n.Contains('hands-free') -or $n.Contains('hands free') -or $n.Contains('ag audio')) { $score -= 700 }
    if ($n.Contains('headset')) { $score -= 350 }
    return $score
}

function Find-EndpointForBluetoothName([string]$PhysicalName, $Endpoints) {
    $needle = Normalize-Name $PhysicalName
    if (-not $needle) { return $null }

    $matches = @(
        $Endpoints | Where-Object {
            $_.Name -notmatch '(?i)DP-HS-1015' -and
            (
                (Normalize-Name ([string]$_.Name)) -eq $needle -or
                (Normalize-Name ([string]$_.Name)).Contains($needle) -or
                $needle.Contains((Normalize-Name ([string]$_.Name)))
            )
        }
    )

    if ($matches.Count -eq 0) { return $null }
    return @($matches | Sort-Object @{Expression={ Get-EndpointScore $_ }; Descending=$true} | Select-Object -First 1)[0]
}

function Get-RecentBluetoothNames {
    if (-not (Test-Path -LiteralPath $logFile)) { return @() }

    $names = New-Object System.Collections.ArrayList
    try {
        $lines = @(Get-Content -LiteralPath $logFile -ErrorAction Stop)
        [array]::Reverse($lines)

        foreach ($line in $lines) {
            $name = $null
            if ($line -match 'Latest Bluetooth device -> (.+)$') {
                $name = $matches[1].Trim()
            }
            elseif ($line -match 'Physical Bluetooth connected: (.+)$') {
                $name = $matches[1].Trim()
            }

            if ($name -and -not ($names -contains $name)) {
                [void]$names.Add($name)
            }
        }
    } catch {}

    return @($names)
}

function Get-BuiltinSpeakerEndpoint($Endpoints) {
    $scored = foreach ($ep in @($Endpoints)) {
        $n = ([string]$ep.Name).ToLowerInvariant()
        if ($n -match 'dp-hs-1015|bluetooth|hdmi|display audio|nvidia|amd high definition|headphones|headset|наушники') {
            continue
        }

        $score = 0
        if ($n -match 'speakers|speaker|динамики') { $score += 1000 }
        if ($n -match 'realtek|conexant|smartamp|synaptics|cirrus') { $score += 200 }
        if ($n -match 'usb') { $score -= 150 }

        [pscustomobject]@{ Endpoint = $ep; Score = $score }
    }

    $best = @($scored | Sort-Object Score -Descending | Select-Object -First 1)
    if ($best.Count -eq 0 -or $best[0].Score -le 0) { return $null }
    return $best[0].Endpoint
}

function Select-Hs5DisconnectFallback {
    $endpoints = @([AudioFallbackNative]::GetActiveRenderEndpoints())
    if ($endpoints.Count -eq 0) { return }

    $connectedBt = @([AudioFallbackNative]::GetConnectedBluetoothNames())
    $connectedNormalized = @{}
    foreach ($name in $connectedBt) {
        $connectedNormalized[(Normalize-Name $name)] = $name
    }

    foreach ($recent in @(Get-RecentBluetoothNames)) {
        $key = Normalize-Name $recent
        if (-not $connectedNormalized.ContainsKey($key)) { continue }

        $ep = Find-EndpointForBluetoothName -PhysicalName $recent -Endpoints $endpoints
        if ($null -ne $ep) {
            [void][AudioFallbackNative]::SetDefaultRenderEndpoint([string]$ep.Id)
            return
        }
    }

    foreach ($name in $connectedBt) {
        $ep = Find-EndpointForBluetoothName -PhysicalName $name -Endpoints $endpoints
        if ($null -ne $ep) {
            [void][AudioFallbackNative]::SetDefaultRenderEndpoint([string]$ep.Id)
            return
        }
    }

    $speaker = Get-BuiltinSpeakerEndpoint $endpoints
    if ($null -ne $speaker) {
        [void][AudioFallbackNative]::SetDefaultRenderEndpoint([string]$speaker.Id)
    }
}

# Start at the current end of the log so old disconnect events are ignored.
$position = 0L
if (Test-Path -LiteralPath $logFile) {
    try { $position = (Get-Item -LiteralPath $logFile).Length } catch {}
}

while ($true) {
    try {
        if (-not (Test-Path -LiteralPath $logFile)) {
            Start-Sleep -Milliseconds 300
            continue
        }

        $length = (Get-Item -LiteralPath $logFile).Length
        if ($length -lt $position) { $position = 0L }

        if ($length -gt $position) {
            $stream = [System.IO.File]::Open($logFile, 'Open', 'Read', 'ReadWrite')
            try {
                [void]$stream.Seek($position, [System.IO.SeekOrigin]::Begin)
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true, 4096, $true)
                try {
                    while (-not $reader.EndOfStream) {
                        $line = $reader.ReadLine()
                        if ($line -like '*DP-HS-1015 disconnected (HID 55-6B-01).*') {
                            Start-Sleep -Milliseconds 150
                            Select-Hs5DisconnectFallback
                        }
                    }
                }
                finally { $reader.Dispose() }
                $position = $stream.Position
            }
            finally { $stream.Dispose() }
        }
    }
    catch {}

    Start-Sleep -Milliseconds 250
}
