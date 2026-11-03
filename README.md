# StatLine

A tiny macOS menu bar app that shows CPU, RAM and network in **one** compact two-row item
(~90pt wide, or ~39pt in "Mini Bars" style), instead of three separate items.

```
CPU   7%  ↓ 131K
MEM  70%  ↑ 811K
```

Click it for details (CPU user/system, load average, memory breakdown, swap, pressure,
network interface and totals) plus settings: style, memory formula, network units
(bits/bytes), refresh interval, and Launch at Login.

## Build & install

Requires the Xcode command line tools (Swift 5.9+), macOS 13+.

```sh
./build.sh            # builds build/StatLine.app
./build.sh --install  # copies to ~/Applications and launches it
```

`StatLine --sample` prints a few readings to the terminal.

## Notes

- Reads counters straight from the kernel (`host_statistics`, `host_statistics64`,
  `NET_RT_IFLIST2` 64-bit interface counters); no shelling out. Effectively 0% CPU.
- Network counts physical `en*` interfaces only, so VPN tunnels don't double count.
- "Memory Used" defaults to Activity Monitor's definition (App + Wired + Compressed).
  The alternative (Active + Wired + Compressed) reads lower and is closer to the Usage app.
