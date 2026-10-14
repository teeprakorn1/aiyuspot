# fwserve — WSL2 firmware fallback for rt73.bin

The WSL2 kernel cannot deliver firmware requests to userspace (there is
no udev firmware path). When `rt73usb` probes it requests `rt73.bin`;
with `force_sysfs_fallback=1` the kernel creates
`/sys/class/firmware/rt73.bin/` and waits for a blob to appear.

`fwserve` is a tiny daemon that polls for that sysfs directory and
copies `/lib/firmware/rt73.bin` into `.../data` after writing `1` to
`.../loading`, then writes `0` to finish.

## Build & install (inside Kali)

```bash
gcc -O2 -o /usr/local/bin/fwserve fwserve.c
```

`wifi-control.bat` starts it automatically (`nohup fwserve &`) right
before `modprobe rt73usb` — no manual step at runtime. It is killed by
`wifi-control.bat stop` together with hostapd/dnsmasq.
