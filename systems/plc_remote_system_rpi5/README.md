# PLC Remote Nerves System for IPCBOX-CM5-A

This is the Raspberry Pi CM5 Nerves system used by PLC Remote on the
[Waveshare IPCBOX-CM5-A](https://docs.waveshare.com/IPCBOX-CM5-A).

It is derived from `nerves-project/nerves_system_rpi5` 2.1.1 and retains its
CM5/CM5 Lite device trees and 64-bit ARM toolchain. The local customization
enables USB Ethernet drivers required for the carrier's second, 2.5G port:

- `CONFIG_USB_RTL8152=m` for RTL8152/RTL8153/RTL8156-family adapters
- `CONFIG_USB_NET_AX88179_178A=m` as a fallback for AX88179-family modules

The IPCBOX-CM5-A schematic identifies the 2.5G interface as a USB 2.5G Ethernet
module but does not identify its controller. Confirm the runtime driver and
VintageNet hardware paths on the first production unit.

Both ports boot disabled. The commissioning portal persists hardware-path role
assignments so kernel `ethN` enumeration cannot swap the PLC and Internet
networks. Select the native CM5 Gigabit interface for the isolated machine LAN
and the USB 2.5G interface for the Internet uplink.

Build this system through the parent project:

```sh
MIX_TARGET=rpi5 mix deps.get
MIX_TARGET=rpi5 mix firmware
```
