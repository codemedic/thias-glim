# Testing Autoinstall Profiles

Profiles can be tested with a local VM before copying to the GLIM USB stick. This avoids rebooting real hardware for every iteration.

## Prerequisites

```bash
sudo apt install quickemu mtools
```

## How It Works

Ubuntu's autoinstall reads seed files (`user-data` + `meta-data`) from a CIDATA source. The cleanest way to supply these to a local VM is a small FAT disk image labelled `CIDATA` — cloud-init detects it automatically without any kernel cmdline changes.

```mermaid
flowchart LR
    A[user-data\nmeta-data] -->|mcopy| B[cidata.img\nFAT / CIDATA]
    B -->|extra_args| C[QEMU VM]
    C -->|cloud-init nocloud| D[Autoinstall]
```

## Step-by-Step

### 1. Get a Ubuntu ISO

Download the Ubuntu desktop ISO into your quickemu VM directory:

```bash
mkdir -p ~/QuickEmuVMs/ubuntu-26.04
cd ~/QuickEmuVMs/ubuntu-26.04
# download ubuntu-26.04-desktop-amd64.iso here
```

### 2. Create a quickemu conf

Save as `~/QuickEmuVMs/ubuntu-26.04.conf`:

```bash
#!/usr/bin/quickemu --vm
guest_os="linux"
disk_img="ubuntu-26.04/disk.qcow2"
iso="ubuntu-26.04/ubuntu-26.04-desktop-amd64.iso"
disk_size="128G"
cpu_cores="8"
extra_args="-drive file=/home/USER/QuickEmuVMs/ubuntu-26.04/cidata.img,format=raw,if=virtio,readonly=on"
```

Replace `USER` with your username. The `extra_args` line attaches the CIDATA seed disk to the VM.

### 3. Build the CIDATA image

From this repository root, after editing a profile's `user-data` (hostname, username, password hash):

```bash
PROFILE=software-engineer
VM_DIR=~/QuickEmuVMs/ubuntu-26.04

dd if=/dev/zero of="${VM_DIR}/cidata.img" bs=1M count=1
mkfs.vfat -n CIDATA "${VM_DIR}/cidata.img"
mcopy -i "${VM_DIR}/cidata.img" docs/features/profiles/${PROFILE}/user-data ::user-data
mcopy -i "${VM_DIR}/cidata.img" docs/features/profiles/${PROFILE}/meta-data ::meta-data
```

#### Generating a password hash

The `identity.password` field requires a SHA-512 hash — never a plaintext password:

```bash
openssl passwd -6
```

Paste the output into `user-data` before building the CIDATA image.

### 4. Run the VM

```bash
# Fresh install — remove any previous disk first
rm -f ~/QuickEmuVMs/ubuntu-26.04/disk.qcow2

quickemu --vm ~/QuickEmuVMs/ubuntu-26.04.conf
```

Or launch via **quickgui** if you prefer a GUI — `extra_args` in the conf is picked up automatically.

> **Note:** If quickemu fails with a pipewire audio error, add `--sound-card none` to the command line. quickgui handles this automatically.

### 5. Monitor the install

The installer runs unattended. To watch progress, switch TTY inside the VM window:

| TTY | Content |
|-----|---------|
| `Ctrl+Alt+F1` | Subiquity installer UI |
| `Ctrl+Alt+F2` | Live system shell |
| `Ctrl+Alt+F3` | Kernel log |

From the live system shell (TTY2):

```bash
# Overall installer progress
tail -f /var/log/installer/subiquity-server-debug.log

# late-commands output (where custom installs run)
tail -f /var/log/installer/curtin-install.log
```

Or via the quickemu serial socket from the host:

```bash
socat -,echo=0,icanon=0 unix-connect:~/QuickEmuVMs/ubuntu-26.04/ubuntu-26.04-serial.socket
```

### 6. Verify first-boot steps

After the installer reboots into the new system, SSH in to check the Homebrew first-boot service:

```bash
ssh USER@localhost -p 22220 'journalctl -fu install-homebrew.service'
```

Once Homebrew finishes, the service disables itself and won't run again.

### 7. Iterate

After each fix:

```bash
# 1. Edit the profile user-data
# 2. Rebuild the CIDATA image (Step 3 above)
# 3. Delete the old disk
rm -f ~/QuickEmuVMs/ubuntu-26.04/disk.qcow2
# 4. Relaunch the VM
```

## Copying to the GLIM USB

Once the profile is verified in the VM:

```bash
PROFILE=software-engineer
USB=/media/$USER/GLIM

mkdir -p "${USB}/boot/iso/ubuntu/profiles/${PROFILE}"
cp docs/features/profiles/${PROFILE}/user-data \
   docs/features/profiles/${PROFILE}/meta-data \
   "${USB}/boot/iso/ubuntu/profiles/${PROFILE}/"

# Also update the GRUB config if not already done
cp grub2/inc-ubuntu.cfg "${USB}/boot/grub/inc-ubuntu.cfg"
```

The profile will appear in the GRUB menu automatically on next boot.
