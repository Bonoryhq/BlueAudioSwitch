# DP-HS-1015 link-state protocol

This note documents the passive signal used by BlueAudioSwitch HS5. It is deliberately limited to observed input traffic; no vendor command was required or inferred.

## Device layout

```text
USB\VID_10D6&PID_B011
├─ USB Audio interface
└─ HID interface
   ├─ Consumer control
   ├─ Telephony
   ├─ Vendor page FF90, report 55
   └─ Vendor page FF82, report 41
```

The link-state event arrives on interrupt-IN endpoint `0x82` as a 64-byte report belonging to the `FF90` collection.

## Observed reports

Connected:

```text
55-6B-00-4E-F2-02-FD-4E-F4-44-50-2D-48-53-2D-31-30-31-35-00-00-...
```

Disconnected:

```text
55-6B-01-4E-F2-02-FD-4E-F4-44-50-2D-48-53-2D-31-30-31-35-00-00-...
```

| Offset | Value | Meaning |
|---:|---|---|
| 0 | `55` | HID report ID |
| 1 | `6B` | Link-state event |
| 2 | `00` / `01` | Connected / disconnected |
| 9–18 | `DP-HS-1015` | ASCII product identifier |

## Validation

The transition was first isolated in a passive USB capture. Two complete power cycles produced the same alternating sequence. The report was then read through the standard Windows HID API with no capture driver present in the application path.

The production listener keeps one blocking read pending on the HID collection. This matters because the receiver emits an edge event, not a continuously queryable state value.

## Safety boundary

The implementation:

- reads input reports only;
- does not write output or feature reports;
- does not send guessed vendor commands;
- does not update or flash firmware;
- does not ship or require USBPcap.

