# udm-natpmp-qbit

NAT-PMP port forwarding for qBittorrent on Unifi Dream Machines (UDM/UDR) with ProtonVPN.

## Problem

qBittorrent needs inbound connections for seeding, but it's behind a VPN. ProtonVPN supports [NAT-PMP](https://en.wikipedia.org/wiki/NAT_Port_Mapping_Protocol) for dynamic port mappings, but only responds to the direct WireGuard peer — which is the Unifi gateway, not the machine running qBittorrent.

## Solution

A systemd service on the UDM that:

1. Requests a NAT-PMP port from ProtonVPN every 45 seconds (60-second lease)
2. Sets iptables DNAT+FORWARD rules to forward that port to qBittorrent
3. Locks qBittorrent's listening port to the first assigned port (stable primary port)
4. Accumulates firewall rules for all port rotations — all map to the primary port
5. Re-syncs qBit's port if it restarts with a stale value
6. Survives firmware updates via `/data/on_boot.d/` hook

```
ProtonVPN (NAT-PMP server)
    |
    | WireGuard tunnel
    |
UDM Gateway ──── natpmp-qbit.service
    |               1. natpmpc requests port from VPN
    |               2. iptables DNAT/FORWARD
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
- On the **first port assignment**, it sets the **primary port** — this becomes qBittorrent's stable listening port for the session
- When ProtonVPN rotates the external port (common with short leases), the script **accumulates** DNAT rules: all rotated ports forward to the primary port. qBit's listening port never changes
- On every cycle, verifies qBit's actual listening port matches the primary port — catches pod/container restarts that reset to a stale value
- If iptables rules disappear (Unifi rebuilds them on controller restart or UI changes), the script detects this and re-applies rules for **all known ports**
- No MASQUERADE — qBit's default route through the gateway handles return traffic, and preserving real peer source IPs prevents qBit from deduplicating all inbound connections as a single peer

## Resilience

| Scenario | Handled? | How |
|---|---|---|
| Port changes | Yes | Adds new DNAT rules mapping to primary port (accumulates, doesn't replace) |
| qBit pod/container restart | Yes | Detects port mismatch, re-pushes correct port |
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

## Gotchas

- **Do NOT use MASQUERADE rules.** MASQUERADE rewrites inbound peer source IPs to the gateway IP, causing qBittorrent to see all peers as the same address. This breaks peer deduplication and limits swarm participation to effectively one connection
- **Don't kill iptables rules while peers are connected.** Clearing firewall rules (e.g. `clear_fw_rules` or `iptables -F`) kills all existing connections immediately. A port change alone does NOT drop established connections — BitTorrent connections are long-lived and survive port rotation as long as the DNAT rules stay in place. The script accumulates rules for this reason
- **Short leases are fine with port accumulation.** ProtonVPN's 60-second leases cause frequent port rotation, but the script accumulates DNAT rules for every port seen. All rotated ports forward to the stable primary port, so peers connecting on any previously-assigned port still reach qBit
- **Disable UPnP/NAT-PMP in qBittorrent's settings.** The script handles port forwarding externally — qBit's built-in NAT-PMP would conflict and request a different mapping
- **VPN reset = new port.** Restarting the WireGuard tunnel or switching VPN servers almost always assigns a new port. This is expected — the script picks it up on the next cycle
- **qBit restart with stale port.** When qBittorrent restarts, it loads the last-saved listening port from config, which may not match the current NAT-PMP mapping. The script detects this mismatch every cycle and re-pushes the correct port (within `REFRESH_INTERVAL` seconds)
- **NAS disk I/O bottleneck.** If qBit downloads stall or error after starting fast, the NAS may be choking on concurrent writes (especially USB-attached volumes). Reduce qBit's active downloads (2-3), I/O threads (2), and file pool size (20) in Advanced settings

## Troubleshooting

- **NAT-PMP failures:** Check `journalctl -u natpmp-qbit`. Usually means the VPN tunnel is down or the VPN server changed
- **Firewall rules missing:** `iptables -t nat -L PREROUTING -n | grep natpmp` — if empty, the script will auto-recover on the next cycle
- **qBit port not updating:** Verify qBit is reachable: `curl -I http://<QBIT_HOST>:8080` from the UDM
- **Service not starting after reboot:** Check that `/data/on_boot.d/10-natpmp-qbit.sh` exists and is executable
- **All peers show same IP:** You have MASQUERADE rules active. Check `iptables -t nat -L POSTROUTING -n | grep natpmp` — if present, remove them. This script intentionally avoids MASQUERADE
- **Port keeps changing (flapping):** This is normal with short leases — the script handles it by accumulating DNAT rules. All rotated ports forward to the primary port. If qBit shows a different port than expected, wait one cycle for auto-correction
- **Downloads stall after initial burst:** Check NAS/disk health. Run `dmesg | grep -i cifs` on the host — "stuck for 15 seconds" or "reconnect" messages indicate SMB mount timeouts. Reduce qBit concurrent writes (see Gotchas above)
- **Port mismatch after qBit restart:** Wait up to `REFRESH_INTERVAL` seconds — the script auto-detects and corrects the mismatch. Check logs: `journalctl -u natpmp-qbit | grep mismatch`
- **Verify end-to-end:** From the qBit host, confirm the listening port matches: `netstat -tlnp | grep qbittorrent`. From the UDM, confirm DNAT is set: `iptables -t nat -L PREROUTING -n | grep natpmp`

## Recommended qBittorrent Settings

These WebUI settings complement the NAT-PMP script for best performance:

**Connection (Settings > Connection):**
- UPnP / NAT-PMP: **Disabled** (the script handles this)
- Global max connections: **300**
- Per-torrent max connections: **50**

**Speed (Settings > Speed):**
- Global rate limits: **Unlimited** (let VPN be the bottleneck)
- Apply rate to uTP: **No**
- Apply rate to LAN peers: **No**

**Downloads (Settings > Downloads):**
- Max active downloads: **2-3** (prevents NAS disk saturation)
- Max active uploads: **20**
- Max active torrents: **25**

**Advanced (Settings > Advanced):**
- Disk I/O threads: **2** (reduces concurrent NAS writes)
- File pool size: **20** (fewer open handles on NAS)
- DHT, PeX, LSD: **Enabled** (more peer discovery)

## License

MIT
