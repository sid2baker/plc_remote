# PLC Remote Nerves System for IPCBOX-CM5-A with CM4

This is the Raspberry Pi CM4 Nerves system retained for PLC Remote hardware
qualification. The [Waveshare IPCBOX-CM5-A](https://docs.waveshare.com/IPCBOX-CM5-A)
is electrically designed for CM5: its Type-A USB power switches use module pin
111 (`VBUS_EN` on CM5), while CM4 defines that pin as `VDAC_COMP`. Consequently,
the carrier's four Type-A ports—including the USB hub and second Ethernet
controller—are not expected to operate with CM4. The CM4 system therefore keeps
USB2 in device mode for recovery through the carrier's Type-C connector. Use the
`rpi5` target and a CM5 for full IPCBOX-CM5-A operation.

It is derived from `nerves-project/nerves_system_rpi4` 2.1.1 and retains its
CM4 device tree and 64-bit ARM toolchain. The local customization enables the
carrier's native Gigabit Ethernet plus common drivers for its second USB 2.5G
Ethernet controller:

- `CONFIG_BCMGENET=y` for the CM4 native Gigabit port
- `CONFIG_USB_RTL8152=m` for RTL8152/RTL8153/RTL8156-family controllers
- `CONFIG_USB_NET_AX88179_178A=m` as a fallback for AX88179-family controllers
- `CONFIG_USB_NET_CDCETHER=m` and `CONFIG_USB_NET_CDC_NCM=m` for standards-based USB Ethernet
- `CONFIG_R8169=m` as a fallback for a PCIe Realtek controller

Both Ethernet interfaces boot disabled. PLC Remote discovers their actual
VintageNet hardware paths and persists role assignments by hardware path, never
by `eth0`/`eth1`. This prevents kernel enumeration differences from swapping the
Internet and isolated PLC networks.

Waveshare specifies the carrier I/O as:

- IN1: GPIO23, isolated and active-low at the Pi
- IN2: GPIO24, isolated and active-low at the Pi
- OUT1: GPIO27, external open-drain output enabled by GPIO-high
- OUT2: GPIO22, external open-drain output enabled by GPIO-high
- USER1: GPIO25, active-low LED
- USER2: GPIO26, active-low LED

Build this system through the parent project:

```sh
MIX_TARGET=rpi4 mix deps.get
MIX_TARGET=rpi4 mix firmware
```

Physical qualification must confirm both Ethernet hardware paths, the loaded
USB controller driver, GPIO polarity, and external I/O voltage/current limits.
