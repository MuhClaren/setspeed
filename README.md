**Fan‑Control Script (DELL R710, R720, R730, R730XD ‑ Proxmox) – Functional Summary**

- **Purpose** – Dynamically controls the server’s fan speed to keep CPU, GPU, and exhaust temperatures within safe limits while minimizing noise and wear.  
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

