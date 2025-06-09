#!/usr/bin/env bash
set -euo pipefail

### ============================================================================
### proxmox_cluster_ctl.sh — Shutdown & Startup for Proxmox Cluster via NUT
### ============================================================================

USAGE="Usage: $0 {shutdown|startup}"

if [ $# -lt 1 ]; then
  echo "$USAGE" >&2
  exit 1
fi
ACTION=$1

######## 1. Settings — EDIT THESE BEFORE USE #######################################

# ----- Proxmox API ----------------------------------------------------------------
APIUSER="user@pve!nut"
APITOKEN="XXXXX"
PROXMOXIP="x.x.x.x"
BASEURL="https://${PROXMOXIP}:8006/api2/json"
AUTH="Authorization: PVEAPIToken=${APIUSER}=${APITOKEN}"

# ----- Cluster nodes ----------------------------------------------------------------
EXCLUDED_NODES=( "pvrserver" "thinkserver" "px0-oc" )
LAST_NODE="px0-rv"

# ----- Wake-on-LAN config ---------------------------------------------------------
# Format: ["nodename"]="MAC" 
# Find the MAC addresses of the PVE nodes (ping IP + arp -a)
declare -A WOL_NODES=(
  ["pve-nodeX"]="xx:xx:xx:xx:xx:xx"
  ["pve-nodeX"]="xx:xx:xx:xx:xx:xx"
  ["pve-nodeX"]="xx:xx:xx:xx:xx:xx"
)

# ----- UPS battery check (startup) -------------------------------------------------
UPS_NAME="apc1000@localhost"
MIN_BATTERY=50  # percent

# ----- Network ping targets -------------------------------------------------------
# Define some ping targets, used to check that the network is up and running
PING_TARGETS=( "x.x.x.1" "x.x.x.248" )  # ex gateway, main switch

# ----- Logging --------------------------------------------------------------------
LOGDIR="/var/log"
LOGFILE="${LOGDIR}/proxmox-cluster-${ACTION}.log"

# ----- Email notification ---------------------------------------------------------
# This part reguires local setup of mail relay for the NUT server
EMAIL="user@domainname.com"
FROM_HEADER="From: Proxmox Cluster <monitor@domainname.com>"
SUBJECT_PREFIX="Proxmox Cluster (${ACTION^^})"

# ----- Shutdown-script PID file ---------------------------------------------------
SHUTDOWN_PIDFILE="/var/run/proxmox-cluster-shutdown.pid"

# —— Persist the list of running guests across reboot/shutdown ——
DATAFILE="/var/run/proxmox-cluster-running.json"

### 2. Common Functions ###########################################################

log() {
    local ts msg
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    msg="${ts} - $1"
    echo "$msg" | tee -a "$LOGFILE"
}

log_to_all() {
    log "$1"
    wall "$1"
}

mail_started() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ${ACTION^} initiated on $(hostname)" \
      | mail -s "${SUBJECT_PREFIX}: STARTED" -a "$FROM_HEADER" "$EMAIL"
}

mail_completed() {
    mail -s "${SUBJECT_PREFIX}: COMPLETED" -a "$FROM_HEADER" "$EMAIL" < "$LOGFILE"
}

wait_for_ping() {
    local target=$1 timeout=${2:-60} interval=5 elapsed=0
    log "🔄 Waiting for $target…"
    while ! ping -c1 -W1 "$target" &>/dev/null; do
        log "⚠️  $target unreachable; retry in ${interval}s"
        sleep "$interval"
        elapsed=$((elapsed + interval))
        if [ "$elapsed" -ge "$timeout" ]; then
            log_to_all "❌ Timeout reaching $target; aborting"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Aborted: network unreachable $target" \
              | mail -s "${SUBJECT_PREFIX}: FAILED (network)" -a "$FROM_HEADER" "$EMAIL"
            exit 1
        fi
    done
    log "✅ $target reachable"
}

check_api() {
    log "🔄 Testing Proxmox API at $BASEURL…"
    local resp
    resp=$(curl -s -k -H "$AUTH" "$BASEURL/cluster/resources?type=node")
    if ! echo "$resp" | jq -e '.data' &>/dev/null; then
        log_to_all "❌ Proxmox API unreachable; aborting"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Aborted: Proxmox API down" \
          | mail -s "${SUBJECT_PREFIX}: FAILED (API)" -a "$FROM_HEADER" "$EMAIL"
        exit 1
    fi
    log "✅ Proxmox API OK"
}

wait_for_api() {
  log "Waiting for Proxmox API to come back…"
  while ! curl -s -k -H "$AUTH" "$BASEURL/cluster/resources?type=node" \
             | jq -e '.data' &>/dev/null; do
    log "Proxmox API still unreachable; retrying in 5s"
    sleep 5
  done
  log "✅ Proxmox API is back online"
}

# Check the nodes to be handled by the script
get_active_nodes() {
  mapfile -t all_nodes < <(
    curl -s -k -H "$AUTH" "$BASEURL/cluster/resources?type=node" \
      | jq -r '.data[].node'
  )
  nodes=()
  for n in "${all_nodes[@]}"; do
    [[ ! " ${EXCLUDED_NODES[*]} " =~ " $n " ]] && nodes+=( "$n" )
  done
}

# wait_for_host_down <host> [timeout_seconds]
wait_for_host_down() {
    local host="$1"
    local timeout="${2:-120}"   # default 2 min
    local interval=5
    local elapsed=0

    log "🔄 Waiting for $host to stop responding to pings…"
    while ping -c1 -W1 "$host" &>/dev/null; do
        log "⚠️  $host still up; retry in ${interval}s"
        sleep "$interval"
        (( elapsed += interval ))
        if (( elapsed >= timeout )); then
            log_to_all "❌ $host still responding after ${timeout}s; aborting"
            exit 1
        fi
    done
    log "✅ $host no longer responds to ping — offline."
}

# Write an overview of all running hosts / guests
write_running_map() {
  local parts= vm_json lxc_json
  parts=()

  # for each node, build a little JSON object
  for n in "${nodes[@]}"; do
    # fetch the lists
    vm_json=$(curl -s -k -H "$AUTH" "$BASEURL/nodes/$n/qemu" \
               | jq -r '[.data[]|select(.status=="running")|.vmid]')
    lxc_json=$(curl -s -k -H "$AUTH" "$BASEURL/nodes/$n/lxc" \
                | jq -r '[.data[]|select(.status=="running")|.vmid]')

    # now build {"nodename":{qemu: [...], lxc: [...]}} and stash it
    parts+=("$(
      jq -c -n \
        --arg n "$n" \
        --argjson v "$vm_json" \
        --argjson l "$lxc_json" \
        '{($n):{qemu:$v,lxc:$l}}'
    )")
  done

  # merge them all into one object and write atomically
  printf '%s\n' "${parts[@]}" | jq -s 'add' > "${DATAFILE}.tmp"
  mv "${DATAFILE}.tmp" "$DATAFILE"
}

# Reads a JSON map of running guests and shuts each one down
shutdown_from_map() {
  local infile=$1
  local node vmid lxcid

  for node in $(jq -r 'keys[]' "$infile"); do
    # shutdown VMs
    for vmid in $(jq -r --arg n "$node" '.[$n].qemu[]?' "$infile"); do
      log "→ shutdown VM $vmid on $node"
      curl -s -k -H "$AUTH" \
        -X POST "$BASEURL/nodes/$node/qemu/$vmid/status/shutdown" \
        > /dev/null
      sleep 1
    done
    # shutdown LXCs
    for lxcid in $(jq -r --arg n "$node" '.[$n].lxc[]?' "$infile"); do
      log "→ shutdown LXC $lxcid on $node"
      curl -s -k -H "$AUTH" \
        -X POST "$BASEURL/nodes/$node/lxc/$lxcid/status/shutdown" \
        > /dev/null
      sleep 1
    done
  done
}

### 3. Shutdown Routine ###########################################################

shutdown_cluster() {
    echo $$ > "$SHUTDOWN_PIDFILE"
    > "$LOGFILE"
    mail_started
    log_to_all "=== STARTING PROXMOX CLUSTER SHUTDOWN ==="

    # Network & API checks
    for ip in "${PING_TARGETS[@]}"; do
        wait_for_ping "$ip" 30
    done

    # Check API is reachable
    check_api

    # determine which nodes we will operate on
    get_active_nodes

    log "Cluster nodes: ${all_nodes[*]}"
    log "To shut down:   ${nodes[*]}"

    # Gather and shutdown running guests *and* save which they were
    log "Scanning for running guests and saving to $DATAFILE"
    write_running_map "$DATAFILE"
    
    log "Shutting down guests"
    shutdown_from_map "$DATAFILE"

    # Wait for no running guests (with 5-minute timeout)
    timeout=300
    interval=5
    elapsed=0
    while true; do
    running=$(curl -s -k -H "$AUTH" "$BASEURL/cluster/resources?type=vm" \
        | jq '[.data[]|select(.status=="running")] | length')
    (( running == 0 )) && break
    log "Waiting for guests to stop… ($elapsed/$timeout)"
    sleep $interval
    (( elapsed += interval ))
    if (( elapsed >= timeout )); then
        log_to_all "❌ Guests still running after ${timeout}s; aborting"
        exit 1
    fi
    done
    log "All guests stopped"

    # Disable Ceph auto-recovery
    log "Halting Ceph autorecovery"
    for flag in noout norebalance norecover; do
        curl -s -k -X PUT --data "value=1" -H "$AUTH" \
            "$BASEURL/cluster/ceph/flags/$flag" > /dev/null
    done

    # Shutdown nodes
    for node in "${nodes[@]}"; do
        log "Shutting down node $node"
        curl -s -k -H "$AUTH" -X POST --data "command=shutdown" \
             "$BASEURL/nodes/$node/status" > /dev/null
        sleep 2
    done

    # Now *ensure* they really went offline via ping
    for node in "${nodes[@]}"; do
        wait_for_host_down "$node" 360   # waits up to 6 minutes per node
    done

    log_to_all "=== PROXMOX CLUSTER SHUTDOWN COMPLETE ==="
    mail_completed
    rm -f "$SHUTDOWN_PIDFILE"
}

### 4. Startup Routine ###########################################################

startup_cluster() {
    > "$LOGFILE"
    mail_started
    log_to_all "=== STARTING PROXMOX CLUSTER STARTUP ==="

    # Wait for pending shutdown
    if [ -f "$SHUTDOWN_PIDFILE" ]; then
        log "Shutdown in progress; waiting to finish…"
        while [ -f "$SHUTDOWN_PIDFILE" ]; do sleep 5; done
        log "Shutdown done; delaying 60s"
        sleep 60
    fi

    # Network checks
    for ip in "${PING_TARGETS[@]}"; do
        wait_for_ping "$ip" 30
    done

    # UPS battery
    log "Checking UPS battery level"
    while true; do
        local charge
        charge=$(upsc "$UPS_NAME" battery.charge 2>/dev/null || echo "")
        if [[ "$charge" =~ ^[0-9]+$ ]] && (( charge >= MIN_BATTERY )); then
            log "UPS battery at ${charge}%"
            break
        fi
        log "Battery ${charge:-?}% < ${MIN_BATTERY}%; retry in 60s"
        sleep 60
    done

    # Wake nodes via WOL
    log "Sending WOL packets"
    for node in "${!WOL_NODES[@]}"; do
        mac=${WOL_NODES[$node]}
        log "WOL ➤ $node ($mac)"
        wakeonlan "$mac"
        sleep 2
    done

    log "Delaying 60s for boot"
    sleep 60

    # Wait for Proxmox API to come back
    wait_for_api
    
    # Re-enable Ceph
    log "Re-enabling Ceph autorecovery"
    for flag in noout norebalance norecover; do
        curl -s -k -X PUT --data "value=0" -H "$AUTH" \
            "$BASEURL/cluster/ceph/flags/$flag" >/dev/null
    done

    # Wait for HEALTH_OK
    for i in {1..20}; do
      if curl -s -k -H "$AUTH" "$BASEURL/cluster/ceph/status" \
           | jq -e '.data.health.status=="HEALTH_OK"' &>/dev/null; then
        log "Ceph HEALTH_OK"
        break
      fi
      log "Waiting for Ceph HEALTH_OK (${i}/20)"
      sleep 20
    done

    if [ -f "$DATAFILE" ]; then
        log "Restoring guests from $DATAFILE"
        # For each node, start VMs then LXCs
        for node in $(jq -r 'keys[]' "$DATAFILE"); do
            qemus=$(jq -r --arg n "$node" '.[$n].qemu[]?' "$DATAFILE")
            lxcs=$(jq -r --arg n "$node" '.[$n].lxc[]?'  "$DATAFILE")

            for vmid in $qemus; do
                log "→ Starting VM $vmid on $node"
                curl -s -k -H "$AUTH" -X POST \
                    "$BASEURL/nodes/$node/qemu/$vmid/status/start" > /dev/null
                sleep 1
            done

            for lxcid in $lxcs; do
                log "→ Starting LXC $lxcid on $node"
                curl -s -k -H "$AUTH" -X POST \
                    "$BASEURL/nodes/$node/lxc/$lxcid/status/start" > /dev/null
                sleep 1
            done
        done

        rm -f "$DATAFILE"
        log "Guest-restore complete; removed $DATAFILE"
    else
        log "No previous guest list found; skipping restore"
    fi

    # Start any auto-start guests - in case not started before
    get_active_nodes
    for n in "${nodes[@]}"; do
        log "Starting all boot-enabled guests on $n"
        curl -s -k -H "$AUTH" -X POST "$BASEURL/nodes/$n/startall" > /dev/null
        sleep 2
    done

    log_to_all "=== PROXMOX CLUSTER STARTUP COMPLETE ==="
    mail_completed
}

### 5. Main #####################################################################

case "$ACTION" in
  shutdown) shutdown_cluster ;;
  startup)  startup_cluster  ;;
  *)        echo "$USAGE" >&2; exit 1 ;;
esac

