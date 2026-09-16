param(
    [Parameter(Mandatory = $true)]
    [string]$Target
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Target)) {
    throw "Target script not found: $Target"
}

$text = [System.IO.File]::ReadAllText($Target)

if ($text -match 'BAS-HS5-FALLBACK-V2') {
    exit 0
}

# 1) HS5 reader should only report link state on disconnect. The main PowerShell
# loop already knows current Bluetooth state and is the correct place to choose
# the fallback endpoint.
$oldDisconnect = @'
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
'@

$newDisconnect = @'
            else
            {
                // BAS-HS5-FALLBACK-V2
                // Only report the link-down event here. The PowerShell loop
                // decides where audio should go because it has the live
                // Bluetooth connection-order state.
                IsConnected = false;
                LastSwitchSucceeded = false;
            }
'@

if (-not $text.Contains($oldDisconnect)) {
    throw 'Could not find HS5 disconnect block to patch.'
}
$text = $text.Replace($oldDisconnect, $newDisconnect)

# 2) Add a built-in speaker finder before Get-BtDevices.
$anchor = 'function Get-BtDevices {'
$helper = @'
function Get-BuiltinSpeakerEndpointId {
    try {
        $candidates = @(
            Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction Stop |
            Where-Object {
                $_.Status -eq 'OK' -and
                $_.InstanceId -match '(?i)^SWD\\MMDEVAPI\\\{0\.0\.0\.' -and
                $_.FriendlyName -notmatch '(?i)DP-HS-1015|Bluetooth|HDMI|Display Audio|NVIDIA|AMD High Definition|headphones|headset|наушники'
            }
        )

        if ($candidates.Count -eq 0) {
            return $null
        }

        $scored = foreach ($endpoint in $candidates) {
            $name = [string]$endpoint.FriendlyName
            $score = 0

            if ($name -match '(?i)Speakers|Speaker|Динамики') { $score += 1000 }
            if ($name -match '(?i)Realtek|Conexant|SmartAmp|Synaptics|Cirrus') { $score += 200 }
            if ($name -match '(?i)USB') { $score -= 150 }

            [pscustomobject]@{
                Endpoint = $endpoint
                Score = $score
            }
        }

        $best = @($scored | Sort-Object Score -Descending | Select-Object -First 1)
        if ($best.Count -eq 0 -or $best[0].Score -le 0) {
            return $null
        }

        return ([string]$best[0].Endpoint.InstanceId).Substring('SWD\MMDEVAPI\'.Length)
    }
    catch {
        Write-Log ("Built-in speaker discovery failed: " + $_.Exception.Message)
        return $null
    }
}

function Get-BtDevices {
'@

if (-not $text.Contains($anchor)) {
    throw 'Could not find Get-BtDevices anchor.'
}
$text = $text.Replace($anchor, $helper)

# 3) Never remember the permanently-present HS5 USB endpoint as the ordinary fallback.
$oldInit = @'
if ($currentDefault -and -not $allBtIds.ContainsKey([string]$currentDefault)) {
    $fallbackEndpointId = [string]$currentDefault
}
'@
$newInit = @'
if ($currentDefault -and
    [string]$currentDefault -ne [string]$hs5EndpointId -and
    -not $allBtIds.ContainsKey([string]$currentDefault)) {
    $fallbackEndpointId = [string]$currentDefault
}
'@
if (-not $text.Contains($oldInit)) {
    throw 'Could not find initial fallback block.'
}
$text = $text.Replace($oldInit, $newInit)

# 4) When no Bluetooth endpoint remains, use this order:
#    remembered active fallback -> built-in speakers.
#    This also handles HS5 disconnect even when the previous Bluetooth device
#    disappeared while HS5 was active.
$oldNoBt = @'
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
'@

$newNoBt = @'
        else {
            # No Bluetooth audio remains. Preserve the existing last-connected
            # behavior, but never leave audio on the HS5 USB receiver after the
            # headset itself disconnects.
            if (-not $hs5Connected -and ($hs5DisconnectedThisPass -or $previousActiveGroups.Count -gt 0)) {
                $restoredFallback = $false

                if ($fallbackEndpointId -and
                    [string]$fallbackEndpointId -ne [string]$hs5EndpointId -and
                    [BtAudioNative]::IsEndpointActive($fallbackEndpointId)) {
                    [void][BtAudioNative]::SetDefaultRenderEndpoint($fallbackEndpointId)
                    Write-Log "External audio disconnected. Restored previous active output."
                    $restoredFallback = $true
                }

                if (-not $restoredFallback) {
                    $speakerEndpointId = Get-BuiltinSpeakerEndpointId
                    if ($speakerEndpointId -and [BtAudioNative]::IsEndpointActive($speakerEndpointId)) {
                        [void][BtAudioNative]::SetDefaultRenderEndpoint($speakerEndpointId)
                        $fallbackEndpointId = [string]$speakerEndpointId
                        Write-Log "No active external audio remains. Switched to built-in speakers."
                        $restoredFallback = $true
                    }
                    else {
                        Write-Log "No active external audio remains, but built-in speakers were not found."
                    }
                }
            }

            $defaultNow = [BtAudioNative]::GetDefaultRenderEndpointId()
            if (-not $hs5Connected -and
                $defaultNow -and
                [string]$defaultNow -ne [string]$hs5EndpointId -and
                -not $allBtIdsNow.ContainsKey([string]$defaultNow)) {
                $fallbackEndpointId = [string]$defaultNow
            }
'@

if (-not $text.Contains($oldNoBt)) {
    throw 'Could not find no-Bluetooth fallback block.'
}
$text = $text.Replace($oldNoBt, $newNoBt)

$text = $text.Replace(
    'Write-Log "Started. v0.2.0 + DP-HS-1015 HID"',
    'Write-Log "Started. v0.2.1 + DP-HS-1015 HID"'
)

[System.IO.File]::WriteAllText($Target, $text, (New-Object System.Text.UTF8Encoding($true)))
Write-Host 'BlueAudioSwitch fallback patch applied.' -ForegroundColor Green
