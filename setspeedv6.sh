#!/bin/bash
#
# ---------- IPMI (no key) ----------
IPMIHOST=<BMC_IP_ADDRESS>        
IPMIUSER=<IPMI_USERNAME>         
IPMIPW=<IPMI_PASSWORD>
IPMI_BASE=(ipmitool -I lanplus -H "$IPMIHOST" -U "$IPMIUSER" -P "$IPMIPW")
# ---------- GPU access (via QEMU guest agent in VM 102) ----------
GPU_VMID=102
GPU_QUERY_TIMEOUT=8     # seconds; a hung VM query must not stall the controller
# ---------- Tuning ----------
T_LOW=55                # CPU: at/below this -> min quiet speed (deg C)
T_HIGH=80               # CPU: at/above this -> max + hand off to BMC auto (deg C)
GPU_T_LOW=75            # GPU: at/below this -> GPU asks for min (keeps idle P4 quiet)
GPU_T_HIGH=88           # GPU: at/above this -> GPU asks for max + hand off to BMC auto
FAN_MIN=15              # % duty at min (your ~1560 RPM)
FAN_MAX=100             # % duty at max
MAX_STEP=15             # max % the fan may change in one cycle (the "gradual" part)
HYS_DOWN=2              # only lower speed when temp is this many C below the mapped target
EXHAUST_WARN=45         # warning-only: alert if exhaust exceeds this
COOL_RUNS=3             # consecutive all-cool runs before resuming manual from AUTO
STATE_FILE=/var/tmp/r730_fan_state

# Ensure required tools are found regardless of caller environment (cron, timer, shell)
export PATH="/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# CRITICAL: echo goes to STDERR so it never pollutes command substitution output
log() { printf "%s\n" "$1" | systemd-cat -t R730-IPMI-TEMP; echo "$1" >&2; }
# ---------- Fail fast if we can't even reach the BMC ----------
if ! "${IPMI_BASE[@]}" sdr type temperature &>/dev/null; then
    log "ERROR: cannot reach IPMI at $IPMIHOST - check host/user/password"
    exit 1
fi
#
# Read a temperature sensor by its EXACT SDR name (over IPMI).
#   $1 = sensor name  ;  $2 = "max" or "last"
# Output: integer deg C, or empty if not found.
read_ipmi_temp() {
    local name="$1" agg="$2" out
    out=$("${IPMI_BASE[@]}" sdr type temperature 2>/dev/null | awk -v name="$name" '
        {
            nm=$1
            for (i=2; i<=NF; i++) { if ($i ~ /^\|$/) break; nm=nm" "$i }
            if (nm != name) next
            v=""
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]+$/ && (i+1)<=NF && $(i+1) ~ /^degrees/) { v=$i; break }
            }
            if (v != "") print v
        }
    ')
    [[ -z "$out" ]] && return 0
    if [[ "$agg" == "max" ]]; then echo "$out" | sort -n | tail -1
    else echo "$out" | tail -1; fi
}
read_cpu_temp()     { read_ipmi_temp "Temp" max; }
read_exhaust_temp() { read_ipmi_temp "Exhaust Temp" last; }
read_gpu_temp() {
    local raw payload temps
    raw=$(timeout "$GPU_QUERY_TIMEOUT" \
        qm guest exec "$GPU_VMID" -- \
        nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null)
    [[ -z "$raw" ]] && { log "DEBUG: GPU raw was EMPTY (timeout or qm failed)"; return 0; }

    payload=$(printf '%s' "$raw" | sed -n 's/.*"out-data" *: *"\([^"]*\)".*/\1/p' | head -1)
    [[ -z "$payload" ]] && { log "DEBUG: GPU no out-data in: ${raw:0:80}"; return 0; }

    temps=$(printf '%b' "$payload" | grep -oE '[0-9]+')
    [[ -z "$temps" ]] && { log "DEBUG: GPU no digits in payload: '$payload'"; return 0; }

    printf '%s\n' "$temps" | sort -n | tail -1
}
# ---------- IPMI fan mode / speed setters ----------
set_auto()   { "${IPMI_BASE[@]}" raw 0x30 0x30 0x01 0x01; }
set_manual() { "${IPMI_BASE[@]}" raw 0x30 0x30 0x01 0x00; }
set_speed()  { local pct=$1 hex; hex=$(printf "%x" "$pct"); \
               "${IPMI_BASE[@]}" raw 0x30 0x30 0x02 0xff 0x$hex; }
# ---------- Map a temperature to a fan target using a given band ----------
band_target() {
    local t=$1 lo=$2 hi=$3
    if   (( t <= lo )); then echo "$FAN_MIN"
    elif (( t >= hi )); then echo "$FAN_MAX"
    else echo $(( FAN_MIN + (FAN_MAX - FAN_MIN) * (t - lo) / (hi - lo) )); fi
}
# ---------- Load previous state ----------
prev_speed=$FAN_MIN
mode="manual"
cool_count=0
if [[ -f "$STATE_FILE" ]]; then
    prev_speed=$(sed -n '1p' "$STATE_FILE")
    mode=$(sed -n '2p' "$STATE_FILE")
    cool_count=$(sed -n '3p' "$STATE_FILE")
    [[ -z "$prev_speed" ]] && prev_speed=$FAN_MIN
    [[ -z "$mode" ]] && mode="manual"
    [[ -z "$cool_count" ]] && cool_count=0
fi
# ---------- Sample all sources (each may be empty on failure) ----------
cpu=$(read_cpu_temp)
gpu=$(read_gpu_temp)
exhaust=$(read_exhaust_temp)
#
# Sanity: gpu must be a pure integer or it's treated as unreadable
#
if [[ -n "$gpu" && ! "$gpu" =~ ^[0-9]+$ ]]; then
    log "DEBUG: GPU temp read returned non-numeric: '$gpu'"
    gpu=""
fi
#
# FAIL-SAFE: if NEITHER CPU nor GPU can be read, do NOT change the fans.
# (A single missing source is fine - run on the other.)
#
if [[ -z "$cpu" || "$cpu" -lt 10 ]] && [[ -z "$gpu" || "$gpu" -lt 10 ]]; then
    log "WARN: no valid CPU or GPU temperature read (cpu='${cpu}' gpu='${gpu}') - holding fan at ${prev_speed}% (no change)"
    { echo "$prev_speed"; echo "$mode"; echo "$cool_count"; } > "$STATE_FILE"
    exit 0
fi
# ---------- Target = the HIGHER of the CPU-derived and GPU-derived targets ----------
target=""
cool_all=1
if [[ -n "$cpu" && "$cpu" -ge 10 ]]; then
    c=$(band_target "$cpu" "$T_LOW" "$T_HIGH"); target=$c
    (( cpu >= T_LOW )) && cool_all=0
else
    cool_all=0
fi
if [[ -n "$gpu" && "$gpu" -ge 10 ]]; then
    g=$(band_target "$gpu" "$GPU_T_LOW" "$GPU_T_HIGH")
    [[ -z "$target" ]] && target=$g
    (( g > target )) && target=$g
    (( gpu >= GPU_T_LOW )) && cool_all=0
else
    cool_all=0
fi
[[ -z "$target" ]] && target=$FAN_MIN
# A source at/above its T_HIGH forces max + auto hand-off
force_max=0
[[ -n "$cpu" && "$cpu" -ge "$T_HIGH" ]] && force_max=1
[[ -n "$gpu" && "$gpu" -ge "$GPU_T_HIGH" ]] && force_max=1
(( force_max )) && target=$FAN_MAX
# ---------- Sustained-cool counter (for returning from AUTO) ----------
if (( cool_all == 1 )); then cool_count=$((cool_count+1)); else cool_count=0; fi
# ---------- Hysteresis: ease downward a little slower than up ----------
hot=""
[[ -n "$cpu" && "$cpu" -ge 10 ]] && hot=$cpu
[[ -n "$gpu" && "$gpu" -ge 10 && ( -z "$hot" || "$gpu" -gt "$hot" ) ]] && hot=$gpu
if [[ -n "$hot" ]] && (( target < prev_speed && hot < target - HYS_DOWN )); then
    target=$prev_speed
fi
# ---------- Ramp limiting: never change more than MAX_STEP % per cycle ----------
delta=$(( target - prev_speed ))
if   (( delta >  MAX_STEP )); then speed=$(( prev_speed + MAX_STEP ))
elif (( delta < -MAX_STEP )); then speed=$(( prev_speed - MAX_STEP ))
else speed=$target; fi
(( speed < FAN_MIN )) && speed=$FAN_MIN
(( speed > FAN_MAX )) && speed=$FAN_MAX
# ---------- Act (3-state with hysteresis) ----------
if [[ "$mode" == "auto" ]]; then
    if (( cool_count >= COOL_RUNS )); then
        set_manual
        set_speed "$FAN_MIN"
        mode="manual"
        speed=$FAN_MIN
        prev_speed=$FAN_MIN
        log "OK: cpu=${cpu:-?}C gpu=${gpu:-?}C cool ${cool_count} runs -> resuming manual at ${FAN_MIN}%"
    else
        speed=$FAN_MAX
        log "AUTO: cpu=${cpu:-?}C gpu=${gpu:-?}C (cool ${cool_count}/${COOL_RUNS}) - BMC controlling fans"
    fi
else
    if (( force_max )); then
        set_manual
        set_speed "$FAN_MAX"
        set_auto
        mode="auto"
        speed=$FAN_MAX
        log "CRIT: cpu=${cpu:-?}C gpu=${gpu:-?}C >= T_HIGH - handing off to BMC AUTO"
    else
        if (( speed != prev_speed )); then
            set_manual
            set_speed "$speed"
            log "OK: cpu=${cpu:-?}C gpu=${gpu:-?}C -> manual fan ${speed}% (was ${prev_speed}%)"
        else
            log "OK: cpu=${cpu:-?}C gpu=${gpu:-?}C -> holding manual fan ${speed}%"
        fi
    fi
fi
# ---------- Exhaust warning (fan hardware / blockage indicator) ----------
if [[ -n "$exhaust" ]] && (( speed < FAN_MAX && exhaust > EXHAUST_WARN )); then
    log "WARN: cpu=${cpu:-?}C gpu=${gpu:-?}C OK but Exhaust ${exhaust}C > ${EXHAUST_WARN}C - check fans/airflow"
fi
# ---------- Persist (speed, mode, cool_count) ----------
{ echo "$speed"; echo "$mode"; echo "$cool_count"; } > "$STATE_FILE"
prev_speed=$speed
