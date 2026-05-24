#!/usr/bin/env bash
# Quick diagnostic for VM network issues
# Run as: sudo bash spells/diagnose-vm-net.sh
set -euo pipefail

echo "=== libvirt networks ==="
virsh net-list --all

echo ""
echo "=== virbr0 interface ==="
ip addr show virbr0 2>/dev/null || echo "virbr0 not found"

echo ""
echo "=== libvirt default network XML ==="
virsh net-dumpxml default 2>/dev/null || echo "default network not defined"

echo ""
echo "=== DHCP leases (if any) ==="
virsh net-dhcp-leases default 2>/dev/null || echo "no leases / network inactive"

echo ""
echo "=== VM state ==="
virsh domstate rabble-os-dev 2>/dev/null || echo "VM not found"

echo ""
echo "=== nftables rules for virbr0 ==="
nft list ruleset 2>/dev/null | grep -A5 -B2 virbr0 || echo "no virbr0 nft rules found"
