param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Test,
    [switch]$Once,
    [int]$ReconnectIntervalSeconds = 15
)

$ErrorActionPreference = "Stop"

$appName = "BlueAudioSwitch"
$installDir = Join-Path $env:LOCALAPPDATA $appName
$installedScript = Join-Path $installDir "BlueAudioSwitch.ps1"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$logFile = Join-Path $installDir "BlueAudioSwitch.log"

function Write-Log([string]$Message) {
    try {
        if (-not (Test-Path $installDir)) {
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        }
        $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch {}
}

function Stop-BackgroundCopies([switch]$IncludeLegacy) {
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessId -ne $PID -and
                ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and
                (
                    $_.CommandLine -match '[\\/]BlueAudioSwitch\.ps1' -or
                    ($IncludeLegacy -and $_.CommandLine -match '[\\/]BluetoothAudioAuto\.ps1')
                )
            } |
            ForEach-Object {
                Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
            }
    } catch {}
}

if ($Install) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null

    # Stop the previous build before replacing the installed script. Also migrate
    # the early BluetoothAudioAuto startup entry if the user tested that build.
    Stop-BackgroundCopies -IncludeLegacy
    Remove-ItemProperty -Path $runKey -Name "BluetoothAudioAuto" -ErrorAction SilentlyContinue

    $source = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($source)) {
        throw "Не удалось определить путь к скрипту."
    }

    if ((Resolve-Path $source).Path -ne $installedScript) {
        Copy-Item -LiteralPath $source -Destination $installedScript -Force
    }

    $command = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $installedScript
    New-ItemProperty -Path $runKey -Name $appName -Value $command -PropertyType String -Force | Out-Null

    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
        "-NoProfile",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$installedScript`""
    )

    Write-Host ""
    Write-Host "BlueAudioSwitch installed." -ForegroundColor Green
    Write-Host "It will now start automatically with Windows."
    Write-Host "Paired Bluetooth audio devices can now reconnect automatically."
    Write-Host "Dark Project HS5 link-state detection is enabled for DP-HS-1015."
    Write-Host "The most recently connected supported audio device becomes the default output."
    Write-Host ""
    exit 0
}

if ($Uninstall) {
    Stop-BackgroundCopies -IncludeLegacy
    Remove-ItemProperty -Path $runKey -Name $appName -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $runKey -Name "BluetoothAudioAuto" -ErrorAction SilentlyContinue
    try {
        Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
    } catch {}

    Write-Host ""
    Write-Host "BlueAudioSwitch removed from startup." -ForegroundColor Yellow
    Write-Host "If a hidden instance is still running, sign out or restart Windows to stop it."
    Write-Host ""
    exit 0
}

if ($Test) {
    # A test run must not compete with an older hidden installed copy.
    Stop-BackgroundCopies -IncludeLegacy
    Start-Sleep -Milliseconds 300
}

# One instance per user.
$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, "Local\BlueAudioSwitch_7D1E1C79", [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

$nativeCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public sealed class BtEndpointInfo
{
    public string Id { get; set; }
    public string Name { get; set; }
    public string ContainerId { get; set; }
    public bool Connected { get; set; }
}

public sealed class BtPhysicalDeviceInfo
{
    public ulong Address { get; set; }
    public string Name { get; set; }
    public bool Connected { get; set; }
    public bool Remembered { get; set; }
    public bool Authenticated { get; set; }
}

public static class BtAudioNative
{
    private const int DEVICE_STATE_ACTIVE = 0x1;
    private const int DEVICE_STATE_UNPLUGGED = 0x8;
    private const int STGM_READ = 0;
    private const int CLSCTX_ALL = 23;

    private const uint KSPROPERTY_TYPE_GET = 0x00000001;
    private const uint KSPROPERTY_TYPE_BASICSUPPORT = 0x00000200;
    private const uint KSPROPERTY_ONESHOT_RECONNECT = 0;

    private static readonly Guid KSPROPSETID_BtAudio =
        new Guid("7FA06C40-B8F6-4C7E-8556-E8C33A12E54D");

    private static PROPERTYKEY PKEY_Device_FriendlyName = new PROPERTYKEY {
        fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"),
        pid = 14
    };

    private static PROPERTYKEY PKEY_Device_ContainerId = new PROPERTYKEY {
        fmtid = new Guid("8c7ed206-3f8a-4827-b3ab-ae9e1faefc6c"),
        pid = 2
    };

    public static BtEndpointInfo[] GetBluetoothAudioDevices()
    {
        List<BtEndpointInfo> result = new List<BtEndpointInfo>();
        IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();

        try
        {
            IMMDeviceCollection collection;
            int hr = enumerator.EnumAudioEndpoints(
                EDataFlow.eRender,
                DEVICE_STATE_ACTIVE | DEVICE_STATE_UNPLUGGED,
                out collection);

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
                        if (!IsBluetoothEndpoint(device))
                            continue;

                        string id;
                        int state;
                        device.GetId(out id);
                        device.GetState(out state);

                        result.Add(new BtEndpointInfo {
                            Id = id,
                            Name = GetFriendlyName(device),
                            ContainerId = GetContainerId(device),
                            Connected = state == DEVICE_STATE_ACTIVE
                        });
                    }
                    catch
                    {
                        // Ignore one broken endpoint and continue.
                    }
                    finally
                    {
                        SafeRelease(device);
                    }
                }
            }
            finally
            {
                SafeRelease(collection);
            }
        }
        finally
        {
            SafeRelease(enumerator);
        }

        return result.ToArray();
    }

    public static BtPhysicalDeviceInfo[] GetClassicBluetoothDevices()
    {
        List<BtPhysicalDeviceInfo> result = new List<BtPhysicalDeviceInfo>();

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
                result.Add(new BtPhysicalDeviceInfo {
                    Address = info.Address,
                    Name = info.szName ?? String.Empty,
                    Connected = info.fConnected,
                    Remembered = info.fRemembered,
                    Authenticated = info.fAuthenticated
                });

                BLUETOOTH_DEVICE_INFO next = new BLUETOOTH_DEVICE_INFO();
                next.dwSize = Marshal.SizeOf(typeof(BLUETOOTH_DEVICE_INFO));

                if (!BluetoothFindNextDevice(find, ref next))
                    break;

                info = next;
            }
        }
        finally
        {
            BluetoothFindDeviceClose(find);
        }

        return result.ToArray();
    }

    public static bool RequestReconnect(string endpointId)
    {
        if (String.IsNullOrWhiteSpace(endpointId))
            return false;

        IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();

        try
        {
            IMMDevice endpoint;
            int hr = enumerator.GetDevice(endpointId, out endpoint);
            if (hr < 0 || endpoint == null)
                return false;

            try
            {
                IKsControl ks = GetKsControl(endpoint);
                if (ks == null)
                    return false;

                try
                {
                    KSPROPERTY prop = new KSPROPERTY {
                        Set = KSPROPSETID_BtAudio,
                        Id = KSPROPERTY_ONESHOT_RECONNECT,
                        Flags = KSPROPERTY_TYPE_GET
                    };

                    uint returned;
                    int r = ks.KsProperty(
                        ref prop,
                        (uint)Marshal.SizeOf(typeof(KSPROPERTY)),
                        IntPtr.Zero,
                        0,
                        out returned);

                    return r >= 0;
                }
                finally
                {
                    SafeRelease(ks);
                }
            }
            finally
            {
                SafeRelease(endpoint);
            }
        }
        catch
        {
            return false;
        }
        finally
        {
            SafeRelease(enumerator);
        }
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
            finally
            {
                SafeRelease(policy);
            }
        }
        catch
        {
            return false;
        }
    }

    public static string GetDefaultRenderEndpointId()
    {
        IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();

        try
        {
            IMMDevice device;
            int hr = enumerator.GetDefaultAudioEndpoint(
                EDataFlow.eRender,
                ERole.eMultimedia,
                out device);

            if (hr < 0 || device == null)
                return null;

            try
            {
                string id;
                device.GetId(out id);
                return id;
            }
            finally
            {
                SafeRelease(device);
            }
        }
        catch
        {
            return null;
        }
        finally
        {
            SafeRelease(enumerator);
        }
    }

    public static bool IsEndpointActive(string endpointId)
    {
        if (String.IsNullOrWhiteSpace(endpointId))
            return false;

        IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();

        try
        {
            IMMDevice device;
            int hr = enumerator.GetDevice(endpointId, out device);
            if (hr < 0 || device == null)
                return false;

            try
            {
                int state;
                device.GetState(out state);
                return state == DEVICE_STATE_ACTIVE;
            }
            finally
            {
                SafeRelease(device);
            }
        }
        catch
        {
            return false;
        }
        finally
        {
            SafeRelease(enumerator);
        }
    }

    private static bool IsBluetoothEndpoint(IMMDevice device)
    {
        IKsControl ks = null;

        try
        {
            ks = GetKsControl(device);
            if (ks == null)
                return false;

            KSPROPERTY prop = new KSPROPERTY {
                Set = KSPROPSETID_BtAudio,
                Id = KSPROPERTY_ONESHOT_RECONNECT,
                Flags = KSPROPERTY_TYPE_BASICSUPPORT
            };

            IntPtr buffer = Marshal.AllocHGlobal(64);
            try
            {
                uint returned;
                int hr = ks.KsProperty(
                    ref prop,
                    (uint)Marshal.SizeOf(typeof(KSPROPERTY)),
                    buffer,
                    64,
                    out returned);

                return hr >= 0;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
        catch
        {
            return false;
        }
        finally
        {
            SafeRelease(ks);
        }
    }

    private static IKsControl GetKsControl(IMMDevice endpoint)
    {
        Guid topologyIid = typeof(IDeviceTopology).GUID;
        object topologyObject;

        int hr = endpoint.Activate(
            ref topologyIid,
            CLSCTX_ALL,
            IntPtr.Zero,
            out topologyObject);

        if (hr < 0 || topologyObject == null)
            return null;

        IDeviceTopology topology = (IDeviceTopology)topologyObject;

        try
        {
            uint connectorCount;
            topology.GetConnectorCount(out connectorCount);

            for (uint i = 0; i < connectorCount; i++)
            {
                IConnector connector;
                topology.GetConnector(i, out connector);

                try
                {
                    bool isConnected;
                    connector.IsConnected(out isConnected);
                    if (!isConnected)
                        continue;

                    IConnector other;
                    connector.GetConnectedTo(out other);

                    try
                    {
                        IPart part = (IPart)other;
                        IDeviceTopology otherTopology;
                        part.GetTopologyObject(out otherTopology);

                        try
                        {
                            string deviceId;
                            otherTopology.GetDeviceId(out deviceId);

                            IKsControl ks = ActivateKsControl(deviceId);
                            if (ks != null)
                                return ks;
                        }
                        finally
                        {
                            SafeRelease(otherTopology);
                        }
                    }
                    finally
                    {
                        SafeRelease(other);
                    }
                }
                finally
                {
                    SafeRelease(connector);
                }
            }
        }
        finally
        {
            SafeRelease(topology);
        }

        return null;
    }

    private static IKsControl ActivateKsControl(string deviceId)
    {
        IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();

        try
        {
            IMMDevice device;
            int hr = enumerator.GetDevice(deviceId, out device);
            if (hr < 0 || device == null)
                return null;

            try
            {
                Guid ksIid = typeof(IKsControl).GUID;
                object ksObject;

                hr = device.Activate(
                    ref ksIid,
                    CLSCTX_ALL,
                    IntPtr.Zero,
                    out ksObject);

                if (hr < 0 || ksObject == null)
                    return null;

                return (IKsControl)ksObject;
            }
            finally
            {
                SafeRelease(device);
            }
        }
        finally
        {
            SafeRelease(enumerator);
        }
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
                    return "(Bluetooth Audio)";

                string s = Marshal.PtrToStringUni(value.pwszVal);
                return String.IsNullOrWhiteSpace(s) ? "(Bluetooth Audio)" : s;
            }
            finally
            {
                PropVariantClear(ref value);
            }
        }
        finally
        {
            SafeRelease(store);
        }
    }

    private static string GetContainerId(IMMDevice device)
    {
        IPropertyStore store;
        device.OpenPropertyStore(STGM_READ, out store);

        try
        {
            PROPVARIANT value;
            PROPERTYKEY key = PKEY_Device_ContainerId;
            store.GetValue(ref key, out value);

            try
            {
                // VT_CLSID = 72. For PROPVARIANT, the GUID is referenced by a pointer
                // stored in the same union slot used by pwszVal in this minimal layout.
                if (value.vt != 72 || value.pwszVal == IntPtr.Zero)
                    return null;

                Guid g = (Guid)Marshal.PtrToStructure(value.pwszVal, typeof(Guid));
                return g.ToString("D");
            }
            finally
            {
                PropVariantClear(ref value);
            }
        }
        catch
        {
            return null;
        }
        finally
        {
            SafeRelease(store);
        }
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

    private enum EDataFlow
    {
        eRender = 0,
        eCapture = 1,
        eAll = 2
    }

    private enum ERole
    {
        eConsole = 0,
        eMultimedia = 1,
        eCommunications = 2
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROPERTYKEY
    {
        public Guid fmtid;
        public int pid;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct PROPVARIANT
    {
        [FieldOffset(0)]
        public ushort vt;

        [FieldOffset(8)]
        public IntPtr pwszVal;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KSPROPERTY
    {
        public Guid Set;
        public uint Id;
        public uint Flags;
    }

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PROPVARIANT pvar);

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
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 248)]
        public string szName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEMTIME
    {
        public ushort wYear;
        public ushort wMonth;
        public ushort wDayOfWeek;
        public ushort wDay;
        public ushort wHour;
        public ushort wMinute;
        public ushort wSecond;
        public ushort wMilliseconds;
    }

    [DllImport("bthprops.cpl", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr BluetoothFindFirstDevice(
        ref BLUETOOTH_DEVICE_SEARCH_PARAMS pbtsp,
        ref BLUETOOTH_DEVICE_INFO pbtdi);

    [DllImport("bthprops.cpl", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BluetoothFindNextDevice(
        IntPtr hFind,
        ref BLUETOOTH_DEVICE_INFO pbtdi);

    [DllImport("bthprops.cpl")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BluetoothFindDeviceClose(IntPtr hFind);

    [ComImport]
    [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumerator
    {
    }

    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig]
        int EnumAudioEndpoints(EDataFlow dataFlow, int stateMask, out IMMDeviceCollection devices);

        [PreserveSig]
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);

        [PreserveSig]
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);

        [PreserveSig]
        int RegisterEndpointNotificationCallback(IntPtr client);

        [PreserveSig]
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport]
    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceCollection
    {
        [PreserveSig]
        int GetCount(out int count);

        [PreserveSig]
        int Item(int index, out IMMDevice device);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig]
        int Activate(
            ref Guid iid,
            int clsCtx,
            IntPtr activationParams,
            [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);

        [PreserveSig]
        int OpenPropertyStore(int access, out IPropertyStore properties);

        [PreserveSig]
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);

        [PreserveSig]
        int GetState(out int state);
    }

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDba1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        [PreserveSig]
        int GetCount(out int count);

        [PreserveSig]
        int GetAt(int index, out PROPERTYKEY key);

        [PreserveSig]
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);

        [PreserveSig]
        int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);

        [PreserveSig]
        int Commit();
    }

    [ComImport]
    [Guid("2A07407E-6497-4A18-9787-32F79BD0D98F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDeviceTopology
    {
        [PreserveSig] int GetConnectorCount(out uint count);
        [PreserveSig] int GetConnector(uint index, out IConnector connector);
        [PreserveSig] int GetSubunitCount(out uint count);
        [PreserveSig] int GetSubunit(uint index, out IntPtr subunit);
        [PreserveSig] int GetPartById(uint id, out IntPtr part);
        [PreserveSig] int GetDeviceId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetSignalPath(IntPtr from, IntPtr to, bool rejectMixed, out IntPtr parts);
    }

    [ComImport]
    [Guid("9C2C4058-23F5-41DE-877A-DF3AF236A09E")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IConnector
    {
        [PreserveSig] int GetType(out int type);
        [PreserveSig] int GetDataFlow(out int flow);
        [PreserveSig] int ConnectTo(IConnector connector);
        [PreserveSig] int Disconnect();
        [PreserveSig] int IsConnected([MarshalAs(UnmanagedType.Bool)] out bool connected);
        [PreserveSig] int GetConnectedTo(out IConnector connector);
        [PreserveSig] int GetConnectorIdConnectedTo([MarshalAs(UnmanagedType.LPWStr)] out string connectorId);
        [PreserveSig] int GetDeviceIdConnectedTo([MarshalAs(UnmanagedType.LPWStr)] out string deviceId);
    }

    [ComImport]
    [Guid("AE2DE0E4-5BCA-4F2D-AA46-5D13F8FDB3A9")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPart
    {
        [PreserveSig] int GetName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        [PreserveSig] int GetLocalId(out uint id);
        [PreserveSig] int GetGlobalId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetPartType(out int partType);
        [PreserveSig] int GetSubType(out Guid subtype);
        [PreserveSig] int GetControlInterfaceCount(out uint count);
        [PreserveSig] int GetControlInterface(uint index, out IntPtr controlInterface);
        [PreserveSig] int EnumPartsIncoming(out IntPtr parts);
        [PreserveSig] int EnumPartsOutgoing(out IntPtr parts);
        [PreserveSig] int GetTopologyObject(out IDeviceTopology topology);
        [PreserveSig] int Activate(int clsCtx, ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);
        [PreserveSig] int RegisterControlChangeCallback(ref Guid iid, IntPtr notify);
        [PreserveSig] int UnregisterControlChangeCallback(IntPtr notify);
    }

    [ComImport]
    [Guid("28F54685-06FD-11D2-B27A-00A0C9223196")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IKsControl
    {
        [PreserveSig]
        int KsProperty(
            ref KSPROPERTY property,
            uint propertyLength,
            IntPtr propertyData,
            uint dataLength,
            out uint bytesReturned);

        [PreserveSig]
        int KsMethod(
            IntPtr method,
            uint methodLength,
            IntPtr methodData,
            uint dataLength,
            out uint bytesReturned);

        [PreserveSig]
        int KsEvent(
            IntPtr evt,
            uint eventLength,
            IntPtr eventData,
            uint dataLength,
            out uint bytesReturned);
    }

    [ComImport]
    [Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
    private class PolicyConfigClient
    {
    }

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
    Write-Log ("Embedded C# compile error: " + $_.Exception.Message)
    throw
}

$hs5NativeCode = @'
using System;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public sealed class Hs5HidReader : IDisposable
{
    private const uint GENERIC_READ = 0x80000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint OPEN_EXISTING = 3;

    private readonly SafeFileHandle handle;
    private readonly int reportLength;
    private readonly ConcurrentQueue<byte[]> reports = new ConcurrentQueue<byte[]>();
    private readonly Thread readerThread;
    private readonly string renderEndpointId;
    private readonly MethodInfo getDefaultEndpoint;
    private readonly MethodInfo setDefaultEndpoint;
    private readonly MethodInfo isEndpointActive;
    private volatile bool disposed;

    public bool IsConnected { get; private set; }
    public bool LastSwitchSucceeded { get; private set; }
    public string FallbackEndpointId { get; private set; }
    public DateTime LastReportUtc { get; private set; }

    public Hs5HidReader(string path, int reportLength, string renderEndpointId)
    {
        if (String.IsNullOrWhiteSpace(path))
            throw new ArgumentNullException("path");
        if (reportLength <= 0)
            throw new ArgumentOutOfRangeException("reportLength");
        if (String.IsNullOrWhiteSpace(renderEndpointId))
            throw new ArgumentNullException("renderEndpointId");

        this.reportLength = reportLength;
        this.renderEndpointId = renderEndpointId;

        Type audioType = null;
        foreach (Assembly assembly in AppDomain.CurrentDomain.GetAssemblies())
        {
            audioType = assembly.GetType("BtAudioNative", false);
            if (audioType != null)
                break;
        }
        if (audioType == null)
            throw new InvalidOperationException("BtAudioNative type was not found.");

        getDefaultEndpoint = audioType.GetMethod("GetDefaultRenderEndpointId", BindingFlags.Public | BindingFlags.Static);
        setDefaultEndpoint = audioType.GetMethod("SetDefaultRenderEndpoint", BindingFlags.Public | BindingFlags.Static);
        isEndpointActive = audioType.GetMethod("IsEndpointActive", BindingFlags.Public | BindingFlags.Static);
        if (getDefaultEndpoint == null || setDefaultEndpoint == null || isEndpointActive == null)
            throw new InvalidOperationException("Required audio methods were not found.");
        handle = CreateFile(
            path,
            GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero,
            OPEN_EXISTING,
            0,
            IntPtr.Zero);

        if (handle.IsInvalid)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open HS5 HID collection.");

        readerThread = new Thread(ReadLoop);
        readerThread.IsBackground = true;
        readerThread.Name = "DP-HS-1015 HID reader";
        readerThread.Start();
    }

    public byte[] ReadAvailable()
    {
        byte[] report;
        return reports.TryDequeue(out report) ? report : null;
    }

    private void ReadLoop()
    {
        while (!disposed)
        {
            byte[] buffer = new byte[reportLength];
            uint bytesRead;
            bool ok = ReadFile(handle, buffer, buffer.Length, out bytesRead, IntPtr.Zero);
            if (!ok)
            {
                if (disposed)
                    return;
                Thread.Sleep(100);
                continue;
            }

            if (bytesRead == 0)
                continue;

            if (bytesRead != buffer.Length)
            {
                byte[] trimmed = new byte[bytesRead];
                Array.Copy(buffer, trimmed, bytesRead);
                buffer = trimmed;
            }

            HandleLinkState(buffer);
            reports.Enqueue(buffer);
        }
    }

    private void HandleLinkState(byte[] report)
    {
        if (report == null || report.Length != 64 || report[0] != 0x55 || report[1] != 0x6B)
            return;
        if (report[2] != 0x00 && report[2] != 0x01)
            return;

        LastReportUtc = DateTime.UtcNow;

        try
        {
            if (report[2] == 0x00)
            {
                string current = getDefaultEndpoint.Invoke(null, null) as string;
                if (!String.IsNullOrWhiteSpace(current) &&
                    !String.Equals(current, renderEndpointId, StringComparison.OrdinalIgnoreCase))
                {
                    FallbackEndpointId = current;
                }

                LastSwitchSucceeded = String.Equals(current, renderEndpointId, StringComparison.OrdinalIgnoreCase) ||
                    (bool)setDefaultEndpoint.Invoke(null, new object[] { renderEndpointId });
                IsConnected = true;
            }
            else
            {
                IsConnected = false;
                LastSwitchSucceeded = false;
                if (!String.IsNullOrWhiteSpace(FallbackEndpointId) &&
                    (bool)isEndpointActive.Invoke(null, new object[] { FallbackEndpointId }))
                {
                    LastSwitchSucceeded = (bool)setDefaultEndpoint.Invoke(
                        null,
                        new object[] { FallbackEndpointId });
                }
            }
        }
        catch
        {
            LastSwitchSucceeded = false;
        }
    }

    public void Dispose()
    {
        if (disposed)
            return;

        disposed = true;
        CancelIoEx(handle, IntPtr.Zero);
        handle.Dispose();
        if (readerThread != null && readerThread.IsAlive)
            readerThread.Join(1000);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadFile(
        SafeFileHandle file,
        byte[] buffer,
        int bytesToRead,
        out uint bytesRead,
        IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CancelIoEx(
        SafeFileHandle file,
        IntPtr overlapped);
}
'@

try {
    Add-Type -TypeDefinition $hs5NativeCode -Language CSharp
} catch {
    Write-Log ("HS5 HID compile error: " + $_.Exception.Message)
    throw
}

function Get-Hs5HidPath {
    $interfaceClass = "{4d1e55b2-f16f-11cf-88cb-001111000030}"
    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$interfaceClass"

    try {
        $key = Get-ChildItem -LiteralPath $registryPath -ErrorAction Stop |
            Where-Object {
                $_.PSChildName -match '(?i)^##\?#HID#VID_10D6&PID_B011&MI_00&Col03#.*#\{4d1e55b2-f16f-11cf-88cb-001111000030\}$'
            } |
            Select-Object -First 1

        if ($null -eq $key) {
            return $null
        }

        return ('\\?\' + $key.PSChildName.Substring(4))
    } catch {
        Write-Log ("HS5 HID discovery failed: " + $_.Exception.Message)
        return $null
    }
}

function Get-Hs5RenderEndpointId {
    try {
        $endpoint = Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction Stop |
            Where-Object {
                $_.FriendlyName -like '*DP-HS-1015*' -and
                $_.InstanceId -match '(?i)^SWD\\MMDEVAPI\\\{0\.0\.0\.'
            } |
            Select-Object -First 1

        if ($null -eq $endpoint) {
            return $null
        }

        return ([string]$endpoint.InstanceId).Substring('SWD\MMDEVAPI\'.Length)
    } catch {
        Write-Log ("HS5 render endpoint discovery failed: " + $_.Exception.Message)
        return $null
    }
}

function Get-BtDevices {
    try {
        return @([BtAudioNative]::GetBluetoothAudioDevices())
    } catch {
        Write-Log ("GetBluetoothAudioDevices: " + $_.Exception.Message)
        return @()
    }
}

function Get-PhysicalBtDevices {
    try {
        return @([BtAudioNative]::GetClassicBluetoothDevices())
    } catch {
        Write-Log ("GetClassicBluetoothDevices: " + $_.Exception.Message)
        return @()
    }
}

function Normalize-BluetoothName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    $n = $Name.Trim()

    # Audio endpoint names are commonly:
    # "Headphones (WH-1000XM5)" / "Speakers (JBL Flip 6)".
    # The Classic Bluetooth API usually reports only the physical device name.
    $open = $n.IndexOf('(')
    $close = $n.LastIndexOf(')')
    if ($open -ge 0 -and $close -gt $open) {
        $inner = $n.Substring($open + 1, $close - $open - 1).Trim()
        if (-not [string]::IsNullOrWhiteSpace($inner)) {
            $n = $inner
        }
    }

    # Some Apple endpoints append service suffixes.
    $dash = $n.IndexOf(" - ")
    if ($dash -gt 0) {
        $n = $n.Substring(0, $dash)
    }

    return ($n.Trim().ToLowerInvariant() -replace '\s+', ' ')
}

function Find-ActiveGroupForPhysicalName(
    [string]$PhysicalName,
    $ActiveGroups
) {
    $needle = Normalize-BluetoothName $PhysicalName
    if ([string]::IsNullOrWhiteSpace($needle)) {
        return $null
    }

    $exact = @()
    $fuzzy = @()

    foreach ($key in @($ActiveGroups.Keys)) {
        foreach ($ep in @($ActiveGroups[$key])) {
            $epName = Normalize-BluetoothName ([string]$ep.Name)

            if ($epName -eq $needle) {
                $exact += $key
                break
            }

            if (
                $epName -and
                ($epName.Contains($needle) -or $needle.Contains($epName))
            ) {
                $fuzzy += $key
                break
            }
        }
    }

    if ($exact.Count -gt 0) {
        return $exact[0]
    }

    if ($fuzzy.Count -gt 0) {
        return $fuzzy[0]
    }

    return $null
}

function Get-EndpointScore($Endpoint) {
    $name = [string]$Endpoint.Name
    $n = $name.ToLowerInvariant()
    $score = 0

    # Prefer normal playback/A2DP endpoints over the call-quality HFP endpoint.
    if ($n.Contains("stereo"))      { $score += 400 }
    if ($n.Contains("headphones"))  { $score += 200 }
    if ($n.Contains("speaker"))     { $score += 150 }
    if ($n.Contains("speakers"))    { $score += 150 }
    if ($n.Contains("a2dp"))        { $score += 500 }

    if ($n.Contains("hands-free"))  { $score -= 700 }
    if ($n.Contains("hands free"))  { $score -= 700 }
    if ($n.Contains("ag audio"))    { $score -= 700 }
    if ($n.Contains("headset"))     { $score -= 350 }

    return $score
}

function Get-PreferredEndpoint($Endpoints) {
    $list = @($Endpoints)
    if ($list.Count -eq 0) {
        return $null
    }

    $scored = foreach ($ep in $list) {
        [pscustomobject]@{
            Endpoint  = $ep
            Connected = if ($ep.Connected) { 1 } else { 0 }
            Score     = Get-EndpointScore $ep
        }
    }

    # If a physical device already has an active endpoint, keep that first.
    # Otherwise prefer the playback/stereo endpoint for the reconnect request.
    return ($scored |
        Sort-Object Connected, Score -Descending |
        Select-Object -First 1).Endpoint
}

function Get-EndpointGroupKey($Endpoint) {
    if ($Endpoint.ContainerId -and -not [string]::IsNullOrWhiteSpace([string]$Endpoint.ContainerId)) {
        return "container:" + ([string]$Endpoint.ContainerId).ToLowerInvariant()
    }

    # Fallback for drivers that don't expose PKEY_Device_ContainerId.
    $name = ([string]$Endpoint.Name).Trim()
    $open = $name.IndexOf('(')
    $close = $name.LastIndexOf(')')
    if ($open -ge 0 -and $close -gt $open) {
        $name = $name.Substring($open + 1, $close - $open - 1)
    }
    return "name:" + $name.Trim().ToLowerInvariant()
}

function Get-ReconnectCandidates($Endpoints) {
    $groups = @{}

    foreach ($ep in @($Endpoints)) {
        $key = Get-EndpointGroupKey $ep
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = New-Object System.Collections.ArrayList
        }
        [void]$groups[$key].Add($ep)
    }

    $result = @()
    foreach ($key in @($groups.Keys)) {
        $preferred = Get-PreferredEndpoint @($groups[$key])
        if ($null -ne $preferred) {
            $result += $preferred
        }
    }

    return @($result | Sort-Object @{Expression={ Get-EndpointScore $_ }; Descending=$true})
}

function Get-ActiveEndpointGroups($Endpoints) {
    $groups = @{}

    foreach ($ep in @($Endpoints | Where-Object { $_.Connected })) {
        $key = Get-EndpointGroupKey $ep
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = New-Object System.Collections.ArrayList
        }
        [void]$groups[$key].Add($ep)
    }

    return $groups
}

function Wait-ForBluetoothGroupActive(
    [string]$GroupKey,
    [int]$TimeoutMilliseconds = 4500
) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    do {
        [void](Process-Hs5Reports)
        if ($script:hs5Connected) {
            return $null
        }

        $scan = Get-BtDevices
        $matching = @(
            $scan | Where-Object {
                $_.Connected -and (Get-EndpointGroupKey $_) -eq $GroupKey
            }
        )

        if ($matching.Count -gt 0) {
            return Get-PreferredEndpoint $matching
        }

        Start-Sleep -Milliseconds 250
    }
    while ($sw.ElapsedMilliseconds -lt $TimeoutMilliseconds)

    return $null
}

function Set-DefaultBtEndpoint($Endpoint) {
    if ($null -eq $Endpoint) {
        return $false
    }

    [void](Process-Hs5Reports)
    if ($script:hs5Connected) {
        return $false
    }

    $targetId = [string]$Endpoint.Id

    # The endpoint may have only just transitioned to ACTIVE. Give EndpointBuilder
    # a brief moment, then set and verify the default device. Retry because Windows
    # sometimes accepts the first call before the sound picker is fully refreshed.
    Start-Sleep -Milliseconds 350

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            [void][BtAudioNative]::SetDefaultRenderEndpoint($targetId)
        } catch {}

        for ($i = 0; $i -lt 8; $i++) {
            Start-Sleep -Milliseconds 150
            try {
                $defaultId = [BtAudioNative]::GetDefaultRenderEndpointId()
                if ($defaultId -eq $targetId) {
                    Write-Log ("Default audio output -> " + $Endpoint.Name)
                    return $true
                }
            } catch {}
        }

        Start-Sleep -Milliseconds 250
    }

    Write-Log ("Could not verify default output: " + $Endpoint.Name)
    return $false
}

function Request-BluetoothReconnect($Devices) {
    $disconnected = @($Devices | Where-Object { -not $_.Connected })
    if ($disconnected.Count -eq 0) {
        return $null
    }

    # Reconnect one PHYSICAL Bluetooth audio device at a time.
    $candidates = @(Get-ReconnectCandidates $disconnected)
    if ($candidates.Count -eq 0) {
        return $null
    }

    foreach ($device in $candidates) {
        [void](Process-Hs5Reports)
        if ($script:hs5Connected) {
            return $null
        }

        $groupKey = Get-EndpointGroupKey $device

        try {
            if (-not [BtAudioNative]::RequestReconnect([string]$device.Id)) {
                Write-Log ("Reconnect request rejected: " + $device.Name)
                continue
            }

            Write-Log ("Reconnect request: " + $device.Name)

            # The reconnect request is asynchronous. Wait until this physical
            # device exposes a real ACTIVE render endpoint before switching audio.
            $activeEndpoint = Wait-ForBluetoothGroupActive `
                -GroupKey $groupKey `
                -TimeoutMilliseconds 4500

            if ($null -ne $activeEndpoint) {
                return $activeEndpoint
            }

            Write-Log ("No ACTIVE audio endpoint after reconnect request: " + $device.Name)
        }
        catch {
            Write-Log ("Reconnect request failed: " + $device.Name)
        }
    }

    return $null
}

Write-Log "Started. v0.2.0 + DP-HS-1015 HID"

$hs5Reader = $null
$hs5Connected = $false
$hs5FallbackEndpointId = $null
$hs5HidPath = Get-Hs5HidPath
$hs5EndpointId = Get-Hs5RenderEndpointId
if ($hs5HidPath -and $hs5EndpointId) {
    try {
        $hs5Reader = [Hs5HidReader]::new($hs5HidPath, 64, $hs5EndpointId)
        Write-Log "DP-HS-1015 immediate HID listener started."
    } catch {
        Write-Log ("DP-HS-1015 HID listener failed: " + $_.Exception.Message)
    }
} else {
    Write-Log "DP-HS-1015 HID collection or render endpoint was not found."
}

$hs5DisconnectedPending = $false

function Process-Hs5Reports {
    $disconnected = $false
    if ($null -eq $script:hs5Reader) {
        return $false
    }

    while ($true) {
        $report = $script:hs5Reader.ReadAvailable()
        if ($null -eq $report) {
            break
        }

        if (
            $report.Length -ne 64 -or
            $report[0] -ne 0x55 -or
            $report[1] -ne 0x6B -or
            ($report[2] -ne 0x00 -and $report[2] -ne 0x01)
        ) {
            continue
        }

        if ($report[2] -eq 0x00) {
            $script:hs5Connected = $script:hs5Reader.IsConnected
            $script:hs5FallbackEndpointId = $script:hs5Reader.FallbackEndpointId
            if ($script:hs5Reader.LastSwitchSucceeded) {
                Write-Log "DP-HS-1015 connected (HID 55-6B-00). USB headset selected immediately."
            } else {
                Write-Log "DP-HS-1015 connected, but immediate endpoint switching failed."
            }
        } else {
            $script:hs5Connected = $script:hs5Reader.IsConnected
            $script:hs5FallbackEndpointId = $script:hs5Reader.FallbackEndpointId
            $script:hs5DisconnectedPending = $true
            $disconnected = $true
            Write-Log "DP-HS-1015 disconnected (HID 55-6B-01)."
            if ($script:hs5Reader.LastSwitchSucceeded) {
                Write-Log "DP-HS-1015 disconnected. Restored previous output."
            }
        }
    }

    return $disconnected
}

$all = Get-BtDevices
$allBtIds = @{}
foreach ($d in $all) {
    $allBtIds[[string]$d.Id] = $true
}

$currentDefault = [BtAudioNative]::GetDefaultRenderEndpointId()
$fallbackEndpointId = $null

if ($currentDefault -and -not $allBtIds.ContainsKey([string]$currentDefault)) {
    $fallbackEndpointId = [string]$currentDefault
}

# Endpoint activation is useful for audio readiness, but it is not always a reliable
# signal for "which physical Bluetooth device connected last". v0.1.3 therefore
# tracks physical Classic Bluetooth fConnected transitions separately.
$connectionSequence = 0
$groupConnectionOrder = @{}
$previousActiveGroups = @{}
$previousPhysicalConnected = @{}
$pendingPhysicalWinnerName = $null
$pendingPhysicalWinnerSince = [DateTime]::MinValue

$initialActive = @($all | Where-Object { $_.Connected })
$initialGroups = Get-ActiveEndpointGroups $initialActive
$initialPhysical = @(Get-PhysicalBtDevices | Where-Object { $_.Connected })

foreach ($p in $initialPhysical) {
    $pn = Normalize-BluetoothName ([string]$p.Name)
    if ($pn) {
        $previousPhysicalConnected[$pn] = $true
    }
}

# At process start historical connection order is unknown. Preserve the current
# Bluetooth default if there is one; otherwise initialize active groups in discovery order.
$currentDefaultBtGroup = $null
foreach ($ep in $initialActive) {
    if ([string]$ep.Id -eq [string]$currentDefault) {
        $currentDefaultBtGroup = Get-EndpointGroupKey $ep
        break
    }
}

foreach ($key in @($initialGroups.Keys)) {
    if ($key -eq $currentDefaultBtGroup) {
        continue
    }

    $connectionSequence++
    $groupConnectionOrder[$key] = $connectionSequence
}

if ($currentDefaultBtGroup -and $initialGroups.ContainsKey($currentDefaultBtGroup)) {
    $connectionSequence++
    $groupConnectionOrder[$currentDefaultBtGroup] = $connectionSequence
}

foreach ($key in @($initialGroups.Keys)) {
    $previousActiveGroups[$key] = $true
}

$lastReconnectAttempt = [DateTime]::MinValue

while ($true) {
    try {
        $devices = Get-BtDevices
        $activeNow = @($devices | Where-Object { $_.Connected })
        $activeGroupsNow = Get-ActiveEndpointGroups $activeNow

        $physicalNow = @(Get-PhysicalBtDevices)
        $physicalConnectedNow = @(
            $physicalNow | Where-Object { $_.Connected }
        )

        $allBtIdsNow = @{}
        foreach ($d in $devices) {
            $allBtIdsNow[[string]$d.Id] = $true
        }

        [void](Process-Hs5Reports)
        $hs5DisconnectedThisPass = $script:hs5DisconnectedPending
        $script:hs5DisconnectedPending = $false

        # 1) Detect the actual PHYSICAL Bluetooth connection event.
        # This is the authoritative "last connected wins" signal.
        $newPhysical = @()
        foreach ($p in $physicalConnectedNow) {
            $pn = Normalize-BluetoothName ([string]$p.Name)
            if ($pn -and -not $previousPhysicalConnected.ContainsKey($pn)) {
                $newPhysical += $p
            }
        }

        foreach ($p in $newPhysical) {
            $pendingPhysicalWinnerName = [string]$p.Name
            $pendingPhysicalWinnerSince = Get-Date
            Write-Log ("Physical Bluetooth connected: " + $p.Name)

            # If the audio endpoint is already ACTIVE, promote it immediately.
            $matchedGroup = Find-ActiveGroupForPhysicalName `
                -PhysicalName $pendingPhysicalWinnerName `
                -ActiveGroups $activeGroupsNow

            if ($matchedGroup) {
                $connectionSequence++
                $groupConnectionOrder[$matchedGroup] = $connectionSequence
                Write-Log ("Latest Bluetooth device -> " + $p.Name)
                $pendingPhysicalWinnerName = $null
            }
        }

        # 2) The physical link often appears before A2DP is ready. Keep the newly
        # connected device pending and switch the moment its ACTIVE audio endpoint appears.
        if ($pendingPhysicalWinnerName) {
            $matchedGroup = Find-ActiveGroupForPhysicalName `
                -PhysicalName $pendingPhysicalWinnerName `
                -ActiveGroups $activeGroupsNow

            if ($matchedGroup) {
                $connectionSequence++
                $groupConnectionOrder[$matchedGroup] = $connectionSequence
                Write-Log ("Audio endpoint ready for latest device: " + $pendingPhysicalWinnerName)
                $pendingPhysicalWinnerName = $null
            }
            elseif (((Get-Date) - $pendingPhysicalWinnerSince).TotalSeconds -gt 12) {
                Write-Log ("Timed out waiting for audio endpoint: " + $pendingPhysicalWinnerName)
                $pendingPhysicalWinnerName = $null
            }
        }

        # 3) Endpoint-state fallback. This handles drivers/devices not surfaced by the
        # Classic Bluetooth API and also keeps the previous behavior as a safety net.
        foreach ($key in @($activeGroupsNow.Keys)) {
            if (-not $previousActiveGroups.ContainsKey($key)) {
                # Only use endpoint activation as the ordering signal if it was not
                # already promoted through the physical Bluetooth event above.
                if (-not $groupConnectionOrder.ContainsKey($key) -or
                    [int64]$groupConnectionOrder[$key] -lt $connectionSequence) {
                    $connectionSequence++
                    $groupConnectionOrder[$key] = $connectionSequence
                }

                Write-Log ("Bluetooth audio group became active: " + $key)
            }
            elseif (-not $groupConnectionOrder.ContainsKey($key)) {
                $connectionSequence++
                $groupConnectionOrder[$key] = $connectionSequence
            }
        }

        if ($activeGroupsNow.Count -gt 0) {
            # Remember the ordinary output before the first Bluetooth device takes over.
            if ($previousActiveGroups.Count -eq 0) {
                $defaultBeforeSwitch = [BtAudioNative]::GetDefaultRenderEndpointId()
                if ($defaultBeforeSwitch -and -not $allBtIdsNow.ContainsKey([string]$defaultBeforeSwitch)) {
                    $fallbackEndpointId = [string]$defaultBeforeSwitch
                }
            }

            # Bluetooth always wins. Among active Bluetooth devices, the device with
            # the highest connection order (the most recently connected one) wins.
            $winnerGroup = @($activeGroupsNow.Keys) |
                Sort-Object {
                    if ($groupConnectionOrder.ContainsKey($_)) {
                        [int64]$groupConnectionOrder[$_]
                    } else {
                        [int64]0
                    }
                } -Descending |
                Select-Object -First 1

            if ($winnerGroup -and -not $hs5Connected) {
                $target = Get-PreferredEndpoint @($activeGroupsNow[$winnerGroup])

                if ($null -ne $target) {
                    $defaultNow = $null
                    try {
                        $defaultNow = [BtAudioNative]::GetDefaultRenderEndpointId()
                    } catch {}

                    if ([string]$defaultNow -ne [string]$target.Id) {
                        [void](Set-DefaultBtEndpoint $target)
                    }
                }
            }
        }
        else {
            # No Bluetooth audio remains: restore the previous non-Bluetooth output.
            if (-not $hs5Connected -and $previousActiveGroups.Count -gt 0 -and $fallbackEndpointId) {
                if ([BtAudioNative]::IsEndpointActive($fallbackEndpointId)) {
                    [void][BtAudioNative]::SetDefaultRenderEndpoint($fallbackEndpointId)
                    Write-Log "Bluetooth audio disconnected. Restored previous output."
                }
            }

            $defaultNow = [BtAudioNative]::GetDefaultRenderEndpointId()
            if (-not $hs5Connected -and $defaultNow -and -not $allBtIdsNow.ContainsKey([string]$defaultNow)) {
                $fallbackEndpointId = [string]$defaultNow
            }

            if (-not $hs5Connected -and ((Get-Date) - $lastReconnectAttempt).TotalSeconds -ge $ReconnectIntervalSeconds) {
                $lastReconnectAttempt = Get-Date

                $connectedEndpoint = Request-BluetoothReconnect $devices
                if ($null -ne $connectedEndpoint) {
                    $afterReconnect = Get-BtDevices
                    $afterGroups = Get-ActiveEndpointGroups @($afterReconnect | Where-Object { $_.Connected })
                    $connectedGroupKey = Get-EndpointGroupKey $connectedEndpoint

                    if ($afterGroups.ContainsKey($connectedGroupKey)) {
                        $connectionSequence++
                        $groupConnectionOrder[$connectedGroupKey] = $connectionSequence

                        $target = Get-PreferredEndpoint @($afterGroups[$connectedGroupKey])
                        if ($null -eq $target) {
                            $target = $connectedEndpoint
                        }

                        [void](Set-DefaultBtEndpoint $target)
                    }
                }
                else {
                    Write-Log "Reconnect attempt finished without an ACTIVE audio endpoint."
                }
            }
        }

        # Save physical Bluetooth state for the next edge-detection pass.
        $previousPhysicalConnected = @{}
        foreach ($p in $physicalConnectedNow) {
            $pn = Normalize-BluetoothName ([string]$p.Name)
            if ($pn) {
                $previousPhysicalConnected[$pn] = $true
            }
        }

        # Save audio endpoint state after reconnect activity.
        $latest = Get-BtDevices
        $latestGroups = Get-ActiveEndpointGroups @($latest | Where-Object { $_.Connected })

        $previousActiveGroups = @{}
        foreach ($key in @($latestGroups.Keys)) {
            $previousActiveGroups[$key] = $true
        }

        if ($Once) {
            break
        }
    }
    catch {
        Write-Log ("Loop error: " + $_.Exception.Message)
        if ($Once) {
            throw
        }
    }

    Start-Sleep -Milliseconds 500
}

if ($null -ne $hs5Reader) {
    $hs5Reader.Dispose()
}

Write-Log "Stopped."
