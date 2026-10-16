# 🧩 fwserve — WSL2 sysfs firmware fallback helper

A tiny userspace daemon that feeds firmware blobs to the kernel through the sysfs fallback interface — the last-resort path for adapters whose firmware can't be staged into the WSL2 init namespace.

---

## 🧠 How WSL2 firmware loading actually works

`request_firmware()` in the kernel reads `/lib/firmware` in the **VM init mount namespace** (`kernel_read_file_from_path_initns`), not the distro's filesystem — files under Kali's `/lib/firmware` are invisible to it.

The init namespace (the WSL2 system distro, Azure Linux) usually runs a
`systemd-udevd`, but it ships a stub rule
`/usr/lib/udev/rules.d/50-firmware.rules` that writes `loading=-1` to
pending firmware requests within roughly 0.5–1 ms. The launcher disables
that rule when possible; if no init-namespace `udevd` is running, there is
nothing to execute the abort rule.

---

## 🚀 The preferred path (what the launcher does)

The launcher stages the **detected adapter profile's** `fw_stage` entries
into the init namespace before USB attach. There are two registry forms:

Preserve the firmware path for `rt73.bin`, `rtlwifi/*`, `rtw88/*`, and
similar entries:

```bat
wsl.exe -d kali-linux -u root -- sh -c "cd /lib/firmware && tar cf - rtlwifi/rtl8723bu_nic.bin" ^
  | wsl.exe --system -u root -e sh -c "P=$(pidof systemd-udevd | cut -d' ' -f1); nsenter -m -t ${P:-1} sh -c 'mkdir -p /lib/firmware && tar xf - -C /lib/firmware'"
```

Flatten a directory such as the AIC8800 `aic8800DC/.` entry into the
init-namespace firmware root:

```bat
wsl.exe -d kali-linux -u root -- sh -c "cd /lib/firmware/aic8800DC && tar cf - ." ^
  | wsl.exe --system -u root -e sh -c "P=$(pidof systemd-udevd | cut -d' ' -f1); nsenter -m -t ${P:-1} sh -c 'mkdir -p /lib/firmware && tar xf - -C /lib/firmware'"
```

Direct initns loading is preferred, but `fwserve` remains armed because
current WSL2 sessions can still issue sysfs firmware requests even after
staging. The launcher stages every `fw_stage` entry in the detected
adapter's registry profile, disables the `50-firmware.rules` stub when
present, enables the fallback, and starts `fwserve` **before USB attach**
and subsequent driver probing. The initns filesystem persists across WSL
restarts.

> ⚠️ Sessions where `systemd-udevd` isn't running used to fail with `nsenter: failed to parse pid` — the launcher falls back to PID 1 to enter the init namespace.

---

## 🛠️ fwserve (kept as a fallback helper)

With `force_sysfs_fallback=1` the kernel creates `/sys/class/firmware/<name>/` and waits for a blob. `fwserve` polls that directory, writes `1` to `loading`, streams the file to `data`, then writes `0`.

> ⚠️ **Name mangling:** the sysfs request dir is named after the full firmware name with `/` replaced by `!` (kobject rule) — a request for `rtlwifi/rtl8723bu_nic.bin` appears as the single flat dir `rtlwifi!rtl8723bu_nic.bin/`. `fwserve` decodes `!` back to `/` before looking the blob up under `/lib/firmware`.

| Step | Action |
| :--- | :--- |
| 1 | Enable it with `echo 1 > /proc/sys/kernel/firmware_config/force_sysfs_fallback` |
| 2 | Poll `/sys/class/firmware/` for pending requests |
| 3 | `echo 1 > loading` → stream blob to `data` → `echo 0 > loading` |
| 4 | Kernel finishes the `request_firmware()` call |

This works once the init-namespace udev stub has been disabled, or when
no init-namespace `udevd` is running to execute it. Otherwise udev can
abort the request in roughly 0.5–1 ms. This is the path that carried
`rt73.bin` and `rtlwifi/rtl8723bu_nic.bin` in sessions where direct initns
loading still produced a sysfs request.

---

## 🔨 Build & install (inside Kali)

```bash
# Run from the repository root inside Kali.
sudo gcc -O2 -o /usr/local/bin/fwserve fwserve/fwserve.c
sudo chmod 755 /usr/local/bin/fwserve
```

`wifi-control.bat provision` builds it when missing or when `fwserve.c`
is newer than the installed binary. The launcher enables the fallback and
starts
`nohup /usr/local/bin/fwserve >>/var/log/aiyuspot.log 2>&1 &` before
USB attach and driver probing. `wifi-control.bat stop` kills it together
with `hostapd`, `hostapd-wep`, and `dnsmasq`, then terminates the Kali
distro.
