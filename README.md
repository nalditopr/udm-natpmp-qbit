# udm-natpmp-qbit

NAT-PMP port forwarding for qBittorrent on Unifi Dream Machines (UDM/UDR) with ProtonVPN.

## Problem

qBittorrent needs inbound connections for seeding, but it's behind a VPN. ProtonVPN supports [NAT-PMP](https://en.wikipedia.org/wiki/NAT_Port_Mapping_Protocol) for dynamic port mappings, but only responds to the direct WireGuard peer — which is the Unifi gateway, not the machine running qBittorrent.

## Solution

A systemd service on the UDM that:

1. Requests a NAT-PMP port from ProtonVPN every 45 seconds
2. Sets iptables rules to forward that port to qBittorrent
3. Updates qBittorrent's listening port via the WebUI API
4. Survives firmware updates via `/data/on_boot.d/` hook

```
ProtonVPN (NAT-PMP server)
    |
    | WireGuard tunnel
    |
UDM Gateway ──── natpmp-qbit.service
    |               1. natpmpc requests port from VPN
    |               2. iptables DNAT/FORWARD/MASQUERADE
    | VLAN bridge   3. curl updates qBit listening port
    |
qBittorrent (VLAN IP)
```

## Requirements

- Unifi Dream Machine (UDM SE, UDM Pro, UDR) with SSH access
- WireGuard VPN client configured in Unifi Network (ProtonVPN or similar with NAT-PMP support)
- qBittorrent accessible from the gateway on a VLAN interface
- `natpmpc` installed on the UDM (`apt install natpmp-utils` or compile from source)
- `curl` (pre-installed on UDM)

## Setup

1. **Clone or copy** the repo to the UDM:
   ```bash
   ssh root@<udm-ip>
   cd /data/scripts
   git clone https://github.com/nalditopr/udm-natpmp-qbit.git
   cd udm-natpmp-qbit
   ```

2. **Configure** your environment:
   ```bash
   cp natpmp-qbit.env.example /data/scripts/natpmp-qbit.env
   vi /data/scripts/natpmp-qbit.env
   ```

   Required settings:
   | Variable | Description | Example |
   |---|---|---|
   | `GATEWAY` | VPN provider's NAT-PMP server (gateway inside tunnel) | `10.2.0.1` |
   | `WG_IFACE` | WireGuard interface on UDM | `wgclt1` |
   | `WG_SRC` | Local WireGuard IP | `10.2.0.2` |
   | `VLAN_IFACE` | VLAN bridge where qBit lives | `br971` |
   | `QBIT_HOST` | qBittorrent IP address | `192.168.97.150` |
   | `QBIT_PASS` | qBittorrent WebUI password | |

3. **Install**:
   ```bash
   sh install.sh
   ```

4. **Verify**:
   ```bash
   journalctl -u natpmp-qbit -f
   ```

## How It Works

- Every `REFRESH_INTERVAL` seconds (default 45), the script calls `natpmpc` to request a UDP+TCP port mapping with a `LEASE_TIME` second lease (default 60)
- When the assigned port changes, it:
  - Clears old iptables rules (tagged with `natpmp-qbit` comment)
  - Adds DNAT, FORWARD, and MASQUERADE rules to route traffic from the WG tunnel to qBittorrent's VLAN IP
  - Logs into qBittorrent WebUI and updates the listening port
- If iptables rules disappear (Unifi rebuilds them on controller restart or UI changes), the script detects this and re-applies them automatically

## Resilience

| Scenario | Handled? | How |
|---|---|---|
| Port changes | Yes | Detects new port, updates firewall + qBit |
| Unifi rebuilds iptables | Yes | Detects missing rules, re-applies next cycle |
| Firmware updates | Yes | `/data/on_boot.d/` hook reinstalls the systemd unit |
| VPN tunnel goes down | Yes | `natpmpc` fails gracefully, retries next cycle |
| qBit WebUI unreachable | Yes | Logs error, retries login next cycle |

## Uninstall

```bash
systemctl stop natpmp-qbit
systemctl disable natpmp-qbit
rm /etc/systemd/system/natpmp-qbit.service
rm /data/on_boot.d/10-natpmp-qbit.sh
systemctl daemon-reload
```

## Troubleshooting

- **NAT-PMP failures:** Check `journalctl -u natpmp-qbit`. Usually means the VPN tunnel is down or the VPN server changed
- **Firewall rules missing:** `iptables -t nat -L PREROUTING -n | grep natpmp` — if empty, the script will auto-recover on the next cycle
- **qBit port not updating:** Verify qBit is reachable: `curl -I http://<QBIT_HOST>:8080` from the UDM
- **Service not starting after reboot:** Check that `/data/on_boot.d/10-natpmp-qbit.sh` exists and is executable

## License

MIT
