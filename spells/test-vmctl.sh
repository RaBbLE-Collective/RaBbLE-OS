#!/usr/bin/env bash
# test-vmctl.sh — Exercise vmctl commands and report results
# Usage: bash spells/test-vmctl.sh
set -uo pipefail

VMCTL="./RaBbLE-OS-vmctl.sh"
PASS=0; FAIL=0; SKIP=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

pass() { echo -e "  ${GREEN}PASS${RESET}  $1"; (( PASS++ )); }
fail() { echo -e "  ${RED}FAIL${RESET}  $1${2:+ — $2}"; (( FAIL++ )); }
skip() { echo -e "  ${YELLOW}SKIP${RESET}  $1${2:+ — $2}"; (( SKIP++ )); }

section() { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }

# ── Sanity ────────────────────────────────────────────────────────────────────
section "Sanity Checks"

if [[ -x "$VMCTL" ]]; then
    pass "vmctl is executable"
else
    fail "vmctl is executable" "run: chmod +x $VMCTL"
fi

if bash -n "$VMCTL" 2>/dev/null; then
    pass "bash syntax check"
else
    fail "bash syntax check"
fi

if bash -n spells/vmctl-completions.sh 2>/dev/null; then
    pass "completions syntax check"
else
    fail "completions syntax check"
fi

# ── Help & No-Arg ─────────────────────────────────────────────────────────────
section "Help & Defaults"

out=$($VMCTL help 2>&1)
if echo "$out" | grep -q "Setup"; then
    pass "help shows categorized output"
else
    fail "help shows categorized output"
fi

for cmd in cast-ks recast status start stop connect ssh logs snapshot restore snapshots destroy; do
    if echo "$out" | grep -q "$cmd"; then
        pass "help lists '$cmd'"
    else
        fail "help lists '$cmd'"
    fi
done

out=$($VMCTL --help 2>&1)
if echo "$out" | grep -q "Setup"; then
    pass "--help alias works"
else
    fail "--help alias works"
fi

# ── Quiet Mode ────────────────────────────────────────────────────────────────
section "Quiet Mode"

out=$($VMCTL --quiet help 2>&1)
if echo "$out" | grep -q "Setup"; then
    pass "--quiet help still prints (help is never suppressed)"
else
    fail "--quiet help still prints"
fi

out=$($VMCTL --quiet status 2>&1)
if echo "$out" | grep -qv "\[vmctl\]"; then
    pass "--quiet suppresses [vmctl] info lines"
else
    fail "--quiet suppresses [vmctl] info lines"
fi

# ── Unknown Command ──────────────────────────────────────────────────────────
section "Error Handling"

out=$($VMCTL bogus-command 2>&1) ; rc=$?
if [[ $rc -ne 0 ]] && echo "$out" | grep -qi "unknown"; then
    pass "unknown command exits non-zero with message"
else
    fail "unknown command exits non-zero with message" "rc=$rc"
fi

# ── Dependency Check ─────────────────────────────────────────────────────────
section "Dependencies"

for dep in virsh virt-install virt-viewer setfacl; do
    if command -v "$dep" &>/dev/null; then
        pass "$dep found"
    else
        fail "$dep found" "install it first"
    fi
done

# ── VM-Aware Tests ───────────────────────────────────────────────────────────
section "VM State Detection"

VM_NAME="${RABBLE_VM_NAME:-rabble-os-dev}"
export LIBVIRT_DEFAULT_URI="qemu:///system"

vm_exists=false
vm_running=false

if virsh dominfo "$VM_NAME" &>/dev/null; then
    vm_exists=true
    pass "VM '$VM_NAME' exists"
    if virsh domstate "$VM_NAME" 2>/dev/null | grep -q running; then
        vm_running=true
        pass "VM is running"
    else
        pass "VM exists but is not running"
    fi
else
    skip "VM '$VM_NAME' does not exist" "cast-ks to create one"
fi

# ── Status Dashboard ─────────────────────────────────────────────────────────
section "Status Dashboard"

if [[ "$vm_exists" == "true" ]]; then
    out=$($VMCTL status 2>&1)
    echo -e "${DIM}${out}${RESET}"
    echo ""

    if echo "$out" | grep -q "State:"; then
        pass "status shows State"
    else
        fail "status shows State"
    fi

    if echo "$out" | grep -q "RAM:"; then
        pass "status shows RAM"
    else
        fail "status shows RAM"
    fi

    if echo "$out" | grep -q "vCPUs:"; then
        pass "status shows vCPUs"
    else
        fail "status shows vCPUs"
    fi

    if echo "$out" | grep -q "Snapshots:"; then
        pass "status shows snapshot count"
    else
        fail "status shows snapshot count"
    fi

    if echo "$out" | grep -q "Disk:"; then
        pass "status shows disk info"
    else
        fail "status shows disk info"
    fi

    if [[ "$vm_running" == "true" ]]; then
        if echo "$out" | grep -qE "(IP:|waiting for DHCP)"; then
            pass "status shows IP or DHCP status"
        else
            fail "status shows IP or DHCP status"
        fi

        if echo "$out" | grep -q "Uptime:"; then
            pass "status shows uptime"
        else
            skip "status shows uptime" "qemu process may not match"
        fi

        if echo "$out" | grep -qE "SPICE:"; then
            pass "status shows SPICE URI"
        else
            skip "status shows SPICE URI" "display may not be active"
        fi
    else
        skip "running-state fields (IP, uptime, SPICE)" "VM not running"
    fi
else
    out=$($VMCTL status 2>&1)
    if echo "$out" | grep -qi "does not exist"; then
        pass "status gracefully handles missing VM"
    else
        fail "status gracefully handles missing VM"
    fi
    skip "status dashboard fields" "no VM"
fi

# ── No-Arg Dashboard ─────────────────────────────────────────────────────────
section "No-Arg Behavior"

out=$($VMCTL 2>&1)
if [[ "$vm_exists" == "true" ]]; then
    if echo "$out" | grep -q "State:"; then
        pass "no-arg shows status dashboard (VM exists)"
    else
        fail "no-arg shows status dashboard (VM exists)"
    fi
else
    if echo "$out" | grep -q "Setup"; then
        pass "no-arg shows help (no VM)"
    else
        fail "no-arg shows help (no VM)"
    fi
fi

# ── SSH & Logs (running VM only) ─────────────────────────────────────────────
section "SSH & Logs"

if [[ "$vm_running" == "true" ]]; then
    # Try to get IP
    mac=$(virsh domiflist "$VM_NAME" 2>/dev/null | awk '/virtio/{print $5}')
    ip=$(virsh net-dhcp-leases default 2>/dev/null \
        | awk -v m="$mac" '$3==m {gsub(/\/.*/, "", $5); print $5; exit}')

    if [[ -n "$ip" ]]; then
        pass "VM has IP: $ip"

        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=5 "root@${ip}" true 2>/dev/null; then
            pass "SSH connection works"

            out=$($VMCTL ssh hostname 2>&1)
            if [[ $? -eq 0 ]]; then
                pass "vmctl ssh runs remote command: $(echo "$out" | tail -1)"
            else
                fail "vmctl ssh runs remote command"
            fi
        else
            skip "SSH connection" "key not set up or SSH not running in VM"
        fi
    else
        skip "SSH & logs tests" "no IP assigned yet (still booting?)"
    fi
else
    skip "SSH & logs tests" "VM not running"
fi

# ── Snapshots ─────────────────────────────────────────────────────────────────
section "Snapshots"

if [[ "$vm_exists" == "true" ]]; then
    out=$($VMCTL snapshots 2>&1)
    if [[ $? -eq 0 ]]; then
        pass "snapshots command runs"
        snap_count=$(virsh snapshot-list "$VM_NAME" --count 2>/dev/null || echo 0)
        echo -e "  ${DIM}${snap_count} snapshot(s) found${RESET}"
    else
        fail "snapshots command runs"
    fi
else
    skip "snapshot tests" "no VM"
fi

# ── Stop Flags (parse only, don't actually stop) ─────────────────────────────
section "Stop Flag Parsing"

if [[ "$vm_exists" == "true" && "$vm_running" != "true" ]]; then
    out=$($VMCTL stop 2>&1)
    if echo "$out" | grep -qi "already stopped"; then
        pass "stop on stopped VM is a no-op"
    else
        fail "stop on stopped VM is a no-op"
    fi

    out=$($VMCTL stop --force 2>&1)
    if echo "$out" | grep -qi "already stopped"; then
        pass "stop --force on stopped VM is a no-op"
    else
        fail "stop --force on stopped VM is a no-op"
    fi
else
    skip "stop flag parsing" "VM running or doesn't exist — won't test stop"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Summary"
echo ""
echo -e "  ${GREEN}${PASS} passed${RESET}  ${RED}${FAIL} failed${RESET}  ${YELLOW}${SKIP} skipped${RESET}"
echo ""

if (( FAIL > 0 )); then
    echo -e "  ${RED}Some tests failed — review output above.${RESET}"
    exit 1
else
    echo -e "  ${GREEN}All executed tests passed.${RESET}"
    exit 0
fi
