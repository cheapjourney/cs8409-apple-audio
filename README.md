# Cirrus CS8409 Audio Driver for Apple Macs

> [!IMPORTANT]
> **Tested Ubuntu kernel versions**
>
> - **7.0.0-27-generic** — supported with the original HDA structure layout
> - **7.0.0-28-generic** — supported with the Ubuntu ABI 28 compatibility fix
>
> Hardware tested: **Apple iMac18,3 with Cirrus Logic CS8409**

Kernel driver that enables **built-in speakers, headphone jack, and internal microphone** on Apple Intel Macs with **Cirrus Logic CS8409** HDA audio chips running Linux.

| 🍎 Hardware | Status |
|---|---|
| iMac18,3 (2017) | ✅ Working |
| iMac19,1 (2019) | ✅ Reported working |
| MacBook Pro 13" 2016–2019 | ✅ Reported working |
| MacBook Pro 15" 2016–2019 | ✅ Reported working |
| iMac Pro (2017) | ⚠️ Untested |
| MacBook Air 2018–2020 | ⚠️ Untested |

## The Problem

Apple uses a **Cirrus Logic CS8409** HDA bridge chip instead of the standard Realtek/Intel HDA codecs. The built-in Linux kernel driver (`snd-hda-codec-cs8409`) only supports Dell hardware. On Apple hardware:

- 🔇 **Speakers don't work** — the amplifier chips (MAX98706, SSM3515, or TAS5764L) are never initialized
- 🎧 **Headphone jack works intermittently** or not at all
- 🎤 **Internal microphone** may not work

This driver adds Apple-specific initialization, including **4-speaker stereo routing** (tweeter + woofer per channel), headphone jack detection, and I2C vendor commands.

## How It Works

This replaces only the CS8409 codec module — not the entire sound system. It's an **out-of-tree kernel module** that takes precedence over the stock driver.

- **No kernel recompilation** needed
- **No modprobe.d, GRUB, or ALSA config** changes required
- **No PipeWire/WirePlumber** custom config needed
- Works alongside your existing audio setup

## Quick Install

```bash
git clone https://github.com/cheapjourney/cs8409-apple-audio.git
cd cs8409-apple-audio
sudo ./install.sh
sudo reboot
```

### Prerequisites

```bash
sudo apt install build-essential linux-headers-$(uname -r)
```

## Manual Build

```bash
make clean
make
sudo make install   # copies to /lib/modules/<kernel>/updates/
sudo depmod -a
sudo reboot
```

## Verify It Works

```bash
# Check module is loaded
lsmod | grep cs8409

# List audio devices
aplay -l

# Test speakers
speaker-test -t wav -c 2

# Test using PulseAudio/PipeWire
pactl set-sink-volume @DEFAULT_SINK@ 50%
paplay /usr/share/sounds/alsa/Front_Center.wav
```

## Restore Stock Driver

```bash
sudo rm /lib/modules/$(uname -r)/updates/snd-hda-codec-cs8409.ko
sudo depmod -a
sudo reboot
```

If you backed up the stock module during install:

```bash
sudo cp /lib/modules/$(uname -r)/kernel/sound/pci/hda/snd-hda-codec-cs8409.ko.stock \
        /lib/modules/$(uname -r)/kernel/sound/pci/hda/snd-hda-codec-cs8409.ko
sudo depmod -a
sudo reboot
```

## After Kernel Updates

Kernel updates remove the custom module. Re-run the install:

```bash
cd cs8409-apple-audio
git pull
sudo ./install.sh
sudo reboot
```

## Hardware Details

| Component | Chip |
|---|---|
| HDA Bridge | Cirrus Logic CS8409 (PCI `1013:8409`) |
| Amplifier (iMac) | Maxim MAX98706 via I²C (vendor node `0x47`) |
| Amplifier (MacBook) | SSM3515 or TAS5764L |
| Speaker config | 4 speakers → 2-channel stereo (tweeter + woofer per channel) |

## Technical Notes

- **Kernel support**: 6.8+ (Ubuntu 24.04+), 7.0+ (Ubuntu 26.04)
- **Kernel 7.0 compat**: Uses `snd_hda_gen_remove()` instead of `snd_hda_gen_free()` — handled automatically
- Build flags: `-DAPPLE_PINSENSE_FIXUP -DAPPLE_CODECS -DCONFIG_SND_HDA_RECONFIG=1`
- The module installs to `/lib/modules/<kernel>/updates/` which takes precedence over the stock module at `/lib/modules/<kernel>/kernel/sound/pci/hda/`

## Kernel compatibility

| Kernel | Status | Required layout |
|---|---|---|
| **Ubuntu 7.0.0-27-generic** | ✅ Tested and working | Original `struct hda_multi_out` layout |
| **Ubuntu 7.0.0-28-generic** | ✅ Tested and working | Includes `share_spdif_kctl` compatibility |
| **Ubuntu ABI 28 and newer** | ⚠️ Compatibility code included, not every kernel individually tested | `share_spdif_kctl` enabled |
| **Upstream Linux 7.1 and newer** | ⚠️ Compatibility code included, not every kernel individually tested | `share_spdif_kctl` enabled |

The driver was physically tested on an **iMac18,3**. Internal speakers, headphone output and microphone detection work with Ubuntu kernels **7.0.0-27-generic** and **7.0.0-28-generic**.

## Credits

Based on the reverse-engineering work by [David Jo](https://github.com/davidjo/snd_hda_macbookpro) and the standalone build by [egorenar](https://github.com/egorenar/snd-hda-codec-cs8409).

## License

GPL-2.0 (inherited from the Linux kernel sound subsystem)

## DKMS Installation

This installs the CS8409 Apple audio driver as a DKMS module so it is rebuilt automatically after kernel updates.

```bash
sudo apt install -y dkms build-essential linux-headers-$(uname -r)

sudo mkdir -p /usr/src/cs8409-apple-audio-1.0
sudo rsync -a --delete --exclude='.git' ./ /usr/src/cs8409-apple-audio-1.0/

sudo dkms add -m cs8409-apple-audio -v 1.0
sudo dkms build -m cs8409-apple-audio -v 1.0 -k "$(uname -r)"
sudo dkms install -m cs8409-apple-audio -v 1.0 -k "$(uname -r)"

sudo reboot
