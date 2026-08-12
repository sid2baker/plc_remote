# PLC Remote Nerves System for IPCBOX-CM5-A

This is the Raspberry Pi CM5 Nerves system used by PLC Remote on the
[Waveshare IPCBOX-CM5-A](https://docs.waveshare.com/IPCBOX-CM5-A).

It is derived from `nerves-project/nerves_system_rpi5` 2.1.1 and retains its
CM5/CM5 Lite device trees and 64-bit ARM toolchain. The local customization
enables USB Ethernet drivers required for the carrier's second, 2.5G port:

- `CONFIG_USB_RTL8152=m` for RTL8152/RTL8153/RTL8156-family adapters
- `CONFIG_USB_NET_AX88179_178A=m` as a fallback for AX88179-family modules
- CDC Ethernet/NCM support from the upstream system for standards-based USB adapters
- `CONFIG_R8169=m` as a fallback for a PCIe Realtek controller

The IPCBOX-CM5-A schematic identifies the 2.5G interface as a USB 2.5G Ethernet
module but does not identify its controller. Confirm the runtime driver and
VintageNet hardware paths on the first production unit.

Both ports boot disabled. The commissioning portal persists hardware-path role
assignments so kernel `ethN` enumeration cannot swap the PLC and Internet
networks. Select roles from detected hardware identities; do not assume a
physical connector will always be `eth0` or `eth1`.

Waveshare specifies the carrier I/O as:

- IN1: GPIO23 (`PIN16` on CM5), isolated and active-low at the Pi
- IN2: GPIO24 (`PIN18`), isolated and active-low at the Pi
- OUT1: GPIO27 (`PIN13`), external open-drain output enabled by GPIO-high
- OUT2: GPIO22 (`PIN15`), external open-drain output enabled by GPIO-high
- USER1: GPIO25 (`PIN22`), active-low LED
- USER2: GPIO26 (`PIN37`), active-low LED

Build this system through the parent project:

```sh
MIX_TARGET=rpi5 mix deps.get
MIX_TARGET=rpi5 mix firmware
```
