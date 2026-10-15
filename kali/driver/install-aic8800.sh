#!/bin/bash
# ============================================================
# aiyuspot - build & install the AIC8800 driver inside Kali WSL2
# for the TP-Link Archer TX1U Nano (USB ID 3625:0110).
# https://github.com/teeprakorn1/aiyuspot
#
# Steps: install build deps -> clone/update saish660/aic8800dc ->
# patch in the TX1U VID:PID (mapped to AIC8800DW chip family) ->
# build aic_load_fw + aic8800_fdrv against /lib/modules/$(uname -r)/build
# -> install modules, firmware (aic8800DC) and the aic.rules udev
# eject rule -> depmod + modprobe aic8800_fdrv.
#
# Re-run after kernel updates. Invoked by `wifi-control.bat driver`.
# ============================================================
set -e

SRC=/usr/src/aic8800dc
REPO=https://github.com/saish660/aic8800dc.git
KVER=$(uname -r)
KDIR=/lib/modules/$KVER/build

[ -d "$KDIR" ] || { echo "Kernel build tree missing at $KDIR"; exit 1; }

apt-get update -qq
apt-get install -y -qq git make gcc bc usb-modeswitch python3

if [ -d "$SRC/.git" ]; then
    git -C "$SRC" pull --ff-only || echo "pull skipped; using existing tree"
else
    git clone --depth 1 "$REPO" "$SRC"
fi

# Add TX1U USB ID (3625:0110) to the driver - mapped to the AIC8800DW chip family
python3 - <<'PYEOF'
p = '/usr/src/aic8800dc/drivers/aic8800/aic8800_fdrv/aicwf_usb.c'
s = open(p).read()
if '0x3625' not in s:
    s = s.replace(
        '{USB_DEVICE(USB_VENDOR_ID_TENDA, USB_PRODUCT_ID_TENDA_U2)},',
        '{USB_DEVICE(USB_VENDOR_ID_TENDA, USB_PRODUCT_ID_TENDA_U2)},\n    {USB_DEVICE_AND_INTERFACE_INFO(0x3625, 0x0110, 0xff, 0xff, 0xff)},')
    s = s.replace(
        'pid == USB_PRODUCT_ID_AIC8800FC){',
        'pid == USB_PRODUCT_ID_AIC8800FC || (vid == 0x3625 && pid == 0x0110)){')
    open(p, 'w').write(s)
    s = open(p).read()
    assert '0x3625, 0x0110' in s, 'ID-table patch failed - upstream source changed?'
    assert 'vid == 0x3625' in s, 'chipmatch patch failed - upstream source changed?'
    print('TX1U patch applied')
else:
    print('TX1U patch already present')

# Firmware must go through request_firmware(): the driver's default
# filp_open() path fails under WSL2's probe context, while
# request_firmware() is served by fwserve via the sysfs fallback.
for mk in ('/usr/src/aic8800dc/drivers/aic8800/aic8800_fdrv/Makefile',
           '/usr/src/aic8800dc/drivers/aic8800/aic_load_fw/Makefile'):
    s = open(mk).read()
    if 'CONFIG_USE_FW_REQUEST = n' in s:
        open(mk, 'w').write(s.replace('CONFIG_USE_FW_REQUEST = n', 'CONFIG_USE_FW_REQUEST = y'))
        print('CONFIG_USE_FW_REQUEST=y in', mk)
    else:
        assert 'CONFIG_USE_FW_REQUEST = y' in s, 'FW_REQUEST flag missing - upstream Makefile changed?'
        print('CONFIG_USE_FW_REQUEST already set in', mk)
PYEOF

cd "$SRC/drivers/aic8800"
make clean >/dev/null 2>&1 || true
make
make install

cp "$SRC/aic.rules" /lib/udev/rules.d/
rm -rf /lib/firmware/aic8800DC
cp -r "$SRC/fw/aic8800DC" /lib/firmware/

rmmod aic8800_fdrv aic_load_fw 2>/dev/null || true
modprobe aic8800_fdrv && echo "aic8800_fdrv: OK"

echo "Driver installed for kernel $KVER. Re-run this script after kernel updates."
