# Setspeed
## Fan‑Control Script (DELL R710, R720, R730, R730XD ‑ Proxmox) – Functional Summary

- **Purpose** – Dynamically controls the server’s fan speed to keep CPU, GPU, and exhaust temperatures within safe limits while minimizing noise and wear.
- **Use Case** - This setup is particularly useful for AI servers or high-performance computing hosts where the workload is heavily GPU-bound, meaning the GPUs generate significantly more heat than the CPU.
- **Sensor Inputs**  
  - *CPU*: hottest “Temp” sensor read via IPMI.  
  - *GPU*: hottest NVIDIA GPU temp read from the Proxmox VM (via QEMU guest agent).  
  - *Exhaust*: exhaust temperature read via IPMI.  
- **Fan‑Speed Mapping** – Each source (CPU, GPU) has its own temperature band:  
  - Below the low threshold → fan runs at **minimum** speed (15 %).  
  - Between low and high thresholds → fan speed rises linearly from 15 % to 100 %.  
  - At or above the high threshold → fan runs at **maximum** speed (100 %) and the script hands control to the BMC’s automatic fan algorithm.  
- **Operating Modes**  
  - **Manual** (default): fan speed set directly by the script based on sensor readings.  
  - **Auto**: when any source reaches or exceeds its high threshold, the script switches to BMC‑controlled auto mode and keeps the fan at full speed until all sources fall below their low thresholds for a configurable number of consecutive cycles, after which it re‑enters manual mode at the minimum speed.  
- **Safety & Stability Features**  
  - **Ramp Limiting** – fan speed changes are capped by a maximum step (15 %) per cycle to avoid abrupt jumps.  
  - **Hysteresis** – downward adjustments are slowed by a small buffer (2 °C) to reduce fan chatter.  
  - **Fail‑Safe** – if neither CPU nor GPU temperature can be read, the script preserves the last fan state and makes no changes.  
  - **Exhaust Warning** – if exhaust temperature exceeds 45 °C while the fan isn’t at maximum, the script logs a warning (no action taken).  
- **Persistence** – The current fan speed, mode, and cool‑run counter are stored in `/var/tmp/r730_fan_state` so that the script can resume the correct state after a reboot or crash.  
- **Execution** – Intended to run periodically (e.g., every 30–60 seconds) via cron or systemd‑timer, ensuring near‑real‑time fan adjustment.

# Installation / Deployment Guide

Installs a small bash script on the always-alive Proxmox host that acts as the **single writer** for the fans. It samples CPU temperature over IPMI and the hottest passed-through GPU via `qm guest exec` into the guest VM, then sets fan speed proportionally with ramp limiting, hysteresis, and a BMC-auto hand-off safety net.

## 1. Requirements

- Proxmox host with root (or a user with `ipmitool` + `qm` privileges).
- `ipmitool` and `proxmox-tools` installed on the host.
- IPMI enabled on the R730 BMC and reachable from the host.
- A dedicated IPMI user with permission to read sensors and set fan mode/speed (`raw 0x30 0x30`).
- QEMU guest agent running in the GPU VM (so `qm guest exec` works).
- `nvidia-smi` available inside the GPU VM.

## 2. Install the script

```bash
sudo cp setspeedv6.sh /usr/local/bin/setspeedv6.sh
sudo chmod 750 /usr/local/bin/setspeedv6.sh
```

## 3. Configure IPMI credentials

Create an IPMI user on the BMC (e.g. via `ipmitool user set` or the BMC web UI) with **User + Operator** privilege, then edit the top of `/usr/local/bin/setspeedv6.sh`:

```bash
IPMIHOST=<BMC_IP_ADDRESS>        
IPMIUSER=<IPMI_USERNAME>         
IPMIPW=<IPMI_PASSWORD>           
```

## 4. Configure the GPU VM

```bash
GPU_VMID=<VM_ID>                 # ID of the guest with the passed-through GPUs (e.g. 102)
GPU_QUERY_TIMEOUT=<SECONDS>      # default 8; a hung VM must not stall the controller
```

Make sure the QEMU guest agent is installed and running in that VM, and that `nvidia-smi` is on its PATH.

## 5. (Optional) Tune the bands and limits

All in the same file:

```bash
T_LOW=<CPU_MIN_TEMP_C>           # default 55: at/below -> FAN_MIN
T_HIGH=<CPU_MAX_TEMP_C>          # default 80: at/above -> FAN_MAX + hand off to BMC auto
GPU_T_LOW=<GPU_MIN_TEMP_C>       # default 75
GPU_T_HIGH=<GPU_MAX_TEMP_C>      # default 88
FAN_MIN=<MIN_FAN_PCT>            # default 15 (% duty)
FAN_MAX=<MAX_FAN_PCT>            # default 100
MAX_STEP=<MAX_DELTA_PCT_PER_CYCLE>  # default 15 (ramp limiter)
HYS_DOWN=<HYSTERESIS_C>          # default 2 °C
EXHAUST_WARN=<EXHAUST_WARN_C>    # default 45 (warning-only)
COOL_RUNS=<COOL_CYCLES>          # default 3 (before resuming manual from AUTO)
STATE_FILE=/var/tmp/r730_fan_state
```

## 6. Test once by hand

```bash
sudo /usr/local/bin/setspeedv6.sh
# Inspect logs:
journalctl -t R730-IPMI-TEMP -n 50
```

Expected on a healthy system: `OK: cpu=..C gpu=..C -> manual fan N%`.

## 7. Schedule it (cron or systemd timer)

Run every 30–60 s. Example cron (as root):

```cron
*/1 * * * * /usr/local/bin/setspeedv6.sh >> /var/log/setspeedv6.log 2>&1
```

Or, prefer a systemd timer so logs go through `systemd-cat` (tagged `R730-IPMI-TEMP`):

```ini
# /etc/systemd/system/r730-fan.service
[Unit]
Description=R730 proportional fan controller
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setspeedv6.sh

# /etc/systemd/system/r730-fan.timer
[Unit]
Description=Run R730 fan controller every 30 s

[Timer]
OnBootSec=30
OnUnitActiveSec=30
AccuracySec=5

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now r730-fan.timer
```

## 8. Verify

```bash
journalctl -t R730-IPMI-TEMP -f
ipmitool -I lanplus -H <BMC_IP_ADDRESS> -U <IPMI_USERNAME> -P <IPMI_PASSWORD> sdr type temperature
```

- `OK:` lines → normal manual control.
- `AUTO:` lines → BMC is in charge after a T_HIGH event; controller resumes manual after `COOL_RUNS` consecutive cool cycles.
- `WARN: no valid CPU or GPU temperature read` → the controller is holding the last speed; check IPMI and the guest agent.

## 9. Notes / Safety

- Only this script should touch the fans — do **not** run another fan controller inside the VM.
- If a sensor can't be read, that source is excluded; if **both** CPU and GPU fail, the last speed is held.
- At/above `T_HIGH` the fans are pinned to `FAN_MAX` and control is handed to BMC **auto** as a safety net.
- Exhaust temp is warning-only (no IPMI key needed).
