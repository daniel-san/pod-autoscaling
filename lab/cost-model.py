#!/usr/bin/env python3
"""Back-of-the-envelope cost model used in the reports.

Prices: OCI public price list API, pay-as-you-go USD, fetched 2026-10-27
(https://apexapps.oracle.com/pls/apex/cetools/api/v1/products/?currencyCode=USD).
Discounts (annual flex, UCM) and regional differences are ignored.

Simplification: cost is attributed to *requested* resources, i.e. it assumes the node
autoscaler (Cluster Autoscaler / Karpenter) removes nodes when requests go down and
that nodes are well packed. Real savings are lower by your packing inefficiency.
"""

HOURS_PER_MONTH = 730
GIB_IN_GB = 1.073741824

# shape: (USD per OCPU-hour, USD per GB-hour, vCPUs per OCPU)
SHAPES = {
    "E4 Flex (AMD)":        (0.025,  0.0015, 2),
    "E5 Flex (AMD)":        (0.030,  0.0020, 2),
    "E6 Flex (AMD)":        (0.030,  0.0020, 2),
    "A1 Flex (Ampere)":     (0.010,  0.0015, 1),
    "A2 Flex (AmpereOne)":  (0.014,  0.0020, 2),
}


def per_vcpu(shape):
    ocpu, gb, vcpus = SHAPES[shape]
    return ocpu / vcpus, gb


def pod_hour(shape, cpu_cores, mem_gib, cpu_price_factor=1.0):
    vcpu_price, gb_price = per_vcpu(shape)
    cpu = cpu_cores * vcpu_price * cpu_price_factor
    mem = mem_gib * GIB_IN_GB * gb_price
    return cpu, mem


def section(title):
    print(f"\n## {title}\n")


section("1. Unit prices (Kubernetes CPU = 1 vCPU)")
print("| Shape | USD / vCPU-hour | USD / GB-hour | GB that cost the same as 1 vCPU |")
print("|---|---|---|---|")
for s in SHAPES:
    v, g = per_vcpu(s)
    print(f"| {s} | {v:.4f} | {g:.4f} | {v / g:.1f} |")

section("2. Where the money goes in one pod (E5 Flex, 24x7)")
print("| Requests | CPU USD/month | Memory USD/month | CPU share |")
print("|---|---|---|---|")
for cpu, mem in [(1.0, 2.0), (0.5, 1.0), (0.25, 1.0), (0.05, 1.0), (0.025, 0.5)]:
    c, m = pod_hour("E5 Flex (AMD)", cpu, mem)
    print(f"| {int(cpu * 1000)}m / {mem:g}Gi | {c * HOURS_PER_MONTH:.2f} | "
          f"{m * HOURS_PER_MONTH:.2f} | {c / (c + m):.0%} |")

section("3. Off-hours strategies for 30 services (E5 Flex)")
# Business hours: Mon-Fri 08:00-20:00 = 60 h/week; off-hours = 108 h/week.
BUSINESS, OFF = 60, 108
WEEKS_PER_MONTH = HOURS_PER_MONTH / 168
SERVICES = 30
day = 3 * sum(pod_hour("E5 Flex (AMD)", 0.5, 1.0))  # 3 replicas x (500m, 1Gi)

scenarios = {
    "A. Always 3 replicas x (500m, 1Gi)":                 3 * sum(pod_hour("E5 Flex (AMD)", 0.5, 1.0)),
    "B. Off-hours: 1 replica x (500m, 1Gi)":              1 * sum(pod_hour("E5 Flex (AMD)", 0.5, 1.0)),
    "C. Off-hours: 1 replica x (50m, 1Gi)  [CPU shrink]": 1 * sum(pod_hour("E5 Flex (AMD)", 0.05, 1.0)),
    "D. Off-hours: 1 replica x (500m, 512Mi) [mem shrink]": 1 * sum(pod_hour("E5 Flex (AMD)", 0.5, 0.5)),
    "E. Off-hours: 1 replica x (50m, 768Mi) [both]":      1 * sum(pod_hour("E5 Flex (AMD)", 0.05, 0.75)),
    "F. Off-hours: 0 replicas (true scale-to-zero)":      0.0,
}
base = None
print("| Scenario | USD/month (30 services) | Saving vs A |")
print("|---|---|---|")
for name, off_hour in scenarios.items():
    monthly = SERVICES * WEEKS_PER_MONTH * (BUSINESS * day + OFF * off_hour)
    base = base or monthly
    print(f"| {name} | {monthly:,.0f} | {1 - monthly / base:.0%} |")

section("4. Node price levers for the same 1 warm pod (50m, 1Gi), 24x7")
print("| Placement | USD/month |")
print("|---|---|")
c, m = pod_hour("E5 Flex (AMD)", 0.05, 1.0)
print(f"| E5 Flex managed node, on-demand | {(c + m) * HOURS_PER_MONTH:.2f} |")
print(f"| E5 Flex burstable, 50% baseline | {(c * 0.5 + m) * HOURS_PER_MONTH:.2f} |")
print(f"| E5 Flex burstable, 12.5% baseline | {(c * 0.125 + m) * HOURS_PER_MONTH:.2f} |")
c, m = pod_hour("A1 Flex (Ampere)", 0.05, 1.0)
print(f"| A1 Flex (Arm) managed node | {(c + m) * HOURS_PER_MONTH:.2f} |")
# Virtual nodes: allocation rounded up to whole OCPU and whole GB, +0.25 GB overhead,
# requests must equal limits. Assumes billing at the E4 Flex compute rate.
vn_ocpu, vn_gb = 1, 2  # 1Gi + 0.25 GB overhead = 1.32 GB -> 2 GB
ocpu_p, gb_p, _ = SHAPES["E4 Flex (AMD)"]
print(f"| Virtual node (Pod.Standard.E4.Flex), excluding the $0.015/h per-virtual-node fee | "
      f"{(vn_ocpu * ocpu_p + vn_gb * gb_p) * HOURS_PER_MONTH:.2f} |")


section("5. Pod density: when IP addresses, not CPU/memory, limit packing")
# Tiny idle pods (25m CPU, 128Mi memory requests) on E5 Flex nodes.
# Assumptions: allocatable ~95% of vCPU and ~90% of memory; 4 pod slots per node
# already taken by DaemonSets (kube-proxy, CNI, log/metrics agents).
# VCN-native CNI (standard config): max pods = MIN((VNICs - 1) * 31, 256);
# E5 Flex VNICs: 2 for 1 OCPU, 1 per OCPU from 2 OCPUs (max 24).
# flannel: not limited by shape; kubelet default max-pods 110.
POD_CPU, POD_GIB, DS_SLOTS = 0.025, 0.125, 4
ocpu_p, gb_p, vcpu_per_ocpu = SHAPES["E5 Flex (AMD)"]
print("| Node (E5 Flex) | USD/month | Pods by CPU/memory | VCN-native max | flannel max "
      "| USD per tiny pod, VCN-native | USD per tiny pod, flannel |")
print("|---|---|---|---|---|---|---|")
for ocpus, gb in [(1, 8), (2, 16), (4, 32), (8, 64)]:
    node_month = (ocpus * ocpu_p + gb * gb_p) * HOURS_PER_MONTH
    by_res = int(min(ocpus * vcpu_per_ocpu * 0.95 / POD_CPU, gb / GIB_IN_GB * 0.9 / POD_GIB))
    vnics = 2 if ocpus == 1 else min(ocpus, 24)
    vcn = min((vnics - 1) * 31, 256)
    fl = 110
    eff_vcn = max(min(by_res, vcn) - DS_SLOTS, 1)
    eff_fl = max(min(by_res, fl) - DS_SLOTS, 1)
    print(f"| {ocpus} OCPU / {gb} GB | {node_month:.2f} | {by_res} | {vcn} | {fl} "
          f"| {node_month / eff_vcn:.2f} | {node_month / eff_fl:.2f} |")

section("6. What keeps costing money when an environment is at zero replicas")
# Prices: OCI price list API, PAYG USD (2026-10-27).
ENHANCED_CLUSTER_H = 0.10            # capped at USD 74.40/month
LB_BASE_H = 0.0113                   # flexible LB; first 744 LB-hours/month free per tenancy
BV_GB_MONTH = 0.0255 + 10 * 0.0017   # block volume, balanced (10 VPU/GB)
BOOT_GB = 50                         # OKE default boot volume size
sys_node = (1 * ocpu_p + 8 * gb_p) * HOURS_PER_MONTH + BOOT_GB * BV_GB_MONTH
rows = [
    ("Enhanced cluster control plane (basic cluster: free)", min(ENHANCED_CLUSTER_H * HOURS_PER_MONTH, 74.40)),
    ("System node pool: 2 x E5 Flex 1 OCPU / 8 GB + 50 GB boot volume", 2 * sys_node),
    ("System node pool, single node (dev only, no HA)", sys_node),
    ("Flexible load balancer, beyond the free one (each)", LB_BASE_H * HOURS_PER_MONTH),
    ("Network load balancer (each)", 0.0),
    ("Persistent volume 50 GB, balanced (each)", 50 * BV_GB_MONTH),
    ("App node pool scaled to 0 nodes", 0.0),
]
print("| Item | USD/month |")
print("|---|---|")
for name, usd in rows:
    print(f"| {name} | {usd:.2f} |")
