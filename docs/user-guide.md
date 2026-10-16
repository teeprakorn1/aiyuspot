# 📘 aiyuspot User Guide

This guide explains how to use the Windows menu, what each button does,
and which command to use from a terminal.

## Before You Start

1. Complete the installation in [SETUP.md](../SETUP.md).
2. Connect the USB Wi-Fi adapter.
3. Make sure the `kali-linux` WSL2 distribution is installed.
4. Run **Setup → Auto-setup adapter** once for the detected adapter.

The launcher keeps Windows networking unchanged. USB passthrough, the
access point, DHCP, forwarding, and NAT are managed through Kali WSL2.

## Interactive Menu

Start the menu from the repository folder:

```bat
wifi-control.bat
```

### Navigation Keys

| Key | Action |
| :--- | :--- |
| `Up` / `Down` | Move the highlighted selection |
| `Enter` | Select an item or confirm the displayed command |
| `Esc` | Go back or cancel |
| `Backspace` | Go back or cancel |

The menu has two levels. Select a category first, then select an action.
After an action completes, press `Enter` at the result screen to return
to the menu.

### Start hotspot

| Button | What it does |
| :--- | :--- |
| **WPA2-PSK (recommended)** | Starts a password-protected WPA2 access point. Prompts for SSID and passphrase. |
| **WEP (custom key)** | Starts legacy WEP. The key must be exactly 5 or 13 printable ASCII characters. |
| **WEP (default key)** | Starts WEP with SSID `aiyuspot` and key `aiyu1`. Use only for testing. |
| **Open (insecure)** | Starts an unencrypted access point. Use only temporarily for testing. |

The menu displays a command preview before running it. Select **Enter**
to continue or **Esc/Backspace** to cancel.

### Tools

| Button | What it does |
| :--- | :--- |
| **Check adapters** | Shows USB, PnP, driver, WSL, interface, hostapd, and dnsmasq status. Run this first when setup is unclear. |
| **Error log** | Shows recent Windows and Kali error-log entries. |
| **Stop WiFi** | Stops hostapd, DHCP, and firmware helper processes, detaches USB, and terminates the Kali runtime. |

`Stop WiFi` detaches the adapter from WSL but does not remove the
usbipd binding. Use `usbipd unbind` separately when the host binding
must also be removed.

### Setup

| Button | What it does |
| :--- | :--- |
| **Auto-setup adapter** | Detects the adapter and installs its packages, firmware, kernel requirements, and driver requirements. |
| **Advanced: build kernel** | Builds the custom WSL2 kernel with the modules declared in `adapters.conf`. This can take 20–40 minutes. |
| **Advanced: TX1U driver build** | Builds the out-of-tree AIC8800 driver for the TP-Link Archer TX1U Nano. |

Use **Auto-setup adapter** first. Use the advanced actions only when
you need to rebuild a kernel or specifically repair the TX1U driver.

### Reset adapter state

This is a destructive recovery action. It:

- detaches and unbinds the detected adapter;
- removes matching Windows PnP device nodes;
- purges the adapter's Windows USB registry state through a SYSTEM task;
- restarts the usbipd service and rescans hardware.

Use it only when the adapter is stuck in a PnP/USB state such as Code 19,
`Device busy (exported)`, repeated USB transfer failures, or
`failed to read EFuse`. The menu asks you to type `YES`.

## Starting a Hotspot

### Recommended: WPA2

Select **Start hotspot → WPA2-PSK (recommended)**, then enter:

- SSID: 1–32 printable ASCII characters;
- passphrase: 8–63 printable ASCII characters.

Example CLI:

```bat
wifi-control.bat wpa2 MyNetwork StrongPass123
```

### WEP

Select **WEP (custom key)** or run:

```bat
wifi-control.bat wep MyNetwork abcde
```

WEP is insecure and should only be used for legacy hardware or testing.

### Open

Select **Open (insecure)** or run:

```bat
wifi-control.bat open MyNetwork
```

Open mode has no encryption. Anyone nearby can associate with the AP.

## Command Reference

| Command | Purpose |
| :--- | :--- |
| `wifi-control.bat` | Open the interactive menu |
| `wifi-control.bat default` | Start WPA2 with the public defaults |
| `wifi-control.bat wpa2 SSID PASS` | Start WPA2-PSK |
| `wifi-control.bat wep SSID KEY` | Start WEP with a 5- or 13-character key |
| `wifi-control.bat open [SSID]` | Start an open AP |
| `wifi-control.bat check` | Run the adapter health report |
| `wifi-control.bat diag` | Show collected Windows and Kali logs |
| `wifi-control.bat stop` | Stop the AP and detach the adapter |
| `wifi-control.bat provision` | Install requirements for the detected adapter |
| `wifi-control.bat kernel` | Build the custom WSL2 kernel |
| `wifi-control.bat driver` | Build the TX1U AIC8800 driver |
| `wifi-control.bat reset` | Run destructive adapter recovery |
| `wifi-control.bat help` | Show command-line help |

`provision` reports a kernel-switch requirement but does not apply the
switch itself. Start a hotspot command afterward and confirm the
kernel-switch prompt, or follow [kernel-build.md](kernel-build.md).

## What the Progress Messages Mean

Typical startup stages are:

1. **Starting Kali WSL runtime** — keeps the target WSL distribution alive.
2. **Starting USB monitor driver** — starts `VBoxUSBMon`.
3. **Detecting WiFi adapter** — matches the device against `adapters.conf`.
4. **Provisioning adapter requirements** — checks packages, firmware, kernel, and driver.
5. **Preparing firmware environment** — stages the matched profile's firmware.
6. **Starting firmware helper** — arms `fwserve` before USB attach.
7. **Binding / Resetting / Attaching USB adapter** — passes the device into WSL2.
8. **Loading driver** — displays live kernel messages and stops after the bounded timeout.
9. **Starting WiFi** — selects the interface, checks AP capability, starts hostapd, DHCP, and NAT.

On success, the launcher prints:

```text
=== RESULT: success ===
```

On failure, it prints the exit code and suggests `wifi-control.bat diag`.
The elevated child window may remain open on failure so the error can be
read. The parent menu still receives the result and returns to the menu.

## Network Details

| Item | Value |
| :--- | :--- |
| Hotspot subnet | `192.168.50.0/24` |
| Client address pool | `192.168.50.10`–`192.168.50.200` |
| Gateway | `192.168.50.1` |
| DNS | `10.255.255.254` (WSL2 host DNS proxy) |
| Windows networking | Unchanged |

## If Something Fails

1. Run **Tools → Check adapters** or `wifi-control.bat check`.
2. Run **Tools → Error log** or `wifi-control.bat diag`.
3. If the adapter is wedged, stop the AP, physically unplug/replug it,
   then try again.
4. Use **Reset adapter state** only for persistent PnP/USB failures.

For firmware internals, see [fwserve/README.md](../fwserve/README.md).
For adapter profiles, see [adapters.md](adapters.md). For measured
throughput and latency, see [benchmarks.md](benchmarks.md).
