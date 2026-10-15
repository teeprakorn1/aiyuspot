# 🧩 fwserve — WSL2 sysfs firmware fallback helper

A tiny userspace daemon that feeds firmware blobs to the kernel through the sysfs fallback interface — the last-resort path for adapters whose firmware can't be staged into the WSL2 init namespace.

---

## 🧠 How WSL2 firmware loading actually works

`request_firmware()` in the kernel reads `/lib/firmware` in the **VM init mount namespace** (`kernel_read_file_from_path_initns`), not the distro's filesystem — files under Kali's `/lib/firmware` are invisible to it.

The init namespace (the WSL2 system distro, Azure Linux) does run a `systemd-udevd`, but it ships a stub rule `/usr/lib/udev/rules.d/50-firmware.rules` that writes `loading=-1` to **every** pending firmware request within ~1 ms — so the sysfs fallback path is aborted before any userspace helper can serve it.

---

## 🚀 The reliable path (what the launcher does)

Stage the blob into the init namespace's `/lib/firmware` directly:

```bat
wsl.exe -d kali-linux -u root -- sh -c "cd /lib/firmware/<dir> && tar cf - ." ^
  | wsl.exe --system -u root -e sh -c "P=$(pidof systemd-udevd | cut -d' ' -f1); nsenter -m -t ${P:-1} tar xf - -C /lib/firmware"
```

Once a blob lives in the initns `/lib/firmware`, `request_firmware()` hits it directly — no fallback needed. `wifi-control.bat` performs this staging for the AIC8800 blobs before probing `aic8800_fdrv`, and also disables the `50-firmware.rules` stub so pending requests stay pending. For the RT73, `rt73.bin` is staged the same way once (see [docs/prerequisites.md](../docs/prerequisites.md)); the initns filesystem persists across WSL restarts.

> ⚠️ Sessions where `systemd-udevd` isn't running used to fail with `nsenter: failed to parse pid` — the launcher falls back to PID 1 to enter the init namespace.

---

## 🛠️ fwserve (kept as a fallback helper)

With `force_sysfs_fallback=1` the kernel creates `/sys/class/firmware/<name>/` and waits for a blob. `fwserve` polls that directory, writes `1` to `loading`, streams the file to `data`, then writes `0`.

| Step | Action |
| :--- | :--- |
| 1 | Enable `force_sysfs_fallback` via `/proc/sys/kernel/firmware_config/` |
| 2 | Poll `/sys/class/firmware/` for pending requests |
| 3 | `echo 1 > loading` → stream blob to `data` → `echo 0 > loading` |
| 4 | Kernel finishes the `request_firmware()` call |

This only works once the init-namespace udev stub above has been disabled — otherwise udev aborts the request in under 1 ms. This is the path that carried `rt73.bin` in sessions where the initns `/lib/firmware` was empty.

---

## 🔨 Build & install (inside Kali)

```bash
gcc -O2 -o /usr/local/bin/fwserve fwserve.c
```

`wifi-control.bat` starts it automatically (`nohup fwserve &`) before driver probing. It is killed by `wifi-control.bat stop` together with hostapd/dnsmasq.
