# NavLink BLE protocol (v1)

The **ESP32-S3 is the BLE peripheral (GATT server)** and advertises as **`NavDisplay`**.
The **phone is the central**. All multi-byte numbers are **little-endian**.

| | UUID | Properties | Direction |
|---|---|---|---|
| Service | `872ad000-4757-4f7a-b4e4-dc3d400d7ff4` | | |
| `NAV_RX` | `872ad001-4757-4f7a-b4e4-dc3d400d7ff4` | Write Without Response (+ Write) | phone → ESP32 |
| `STATUS` | `872ad002-4757-4f7a-b4e4-dc3d400d7ff4` | Read + Notify | ESP32 → phone |

## Link setup

* The phone connects, discovers the service, subscribes to `STATUS`, and sends `TIME_SYNC`.
* The ESP32 requests a 247-byte MTU; iOS negotiates the MTU itself (normally 185) and
  uses 2M PHY when both sides support it. **Every message must fit in `MTU − 3` bytes**;
  the phone sizes `ROUTE_CHUNK` from the negotiated MTU (minimum MTU 23 → 20-byte payload).
* The phone sends **`PING` every 2 s** when there is nothing else to send. The display shows
  **"Signal lost"** after **5 s** without any message and keeps the last data on screen.

## Messages phone → ESP32 (`NAV_RX`)

Every message starts with a 1-byte **type**.

| Type | Name | Payload after the type byte | Size |
|---|---|---|---|
| `0x01` | `ROUTE_BEGIN` | `u16 routeId`, `u16 pointCount`, `u32 totalDistance_m`, `u32 eta_unix` | 13 |
| `0x02` | `ROUTE_CHUNK` | `u16 routeId`, `u16 chunkIndex`, `u16 firstPointIndex`, `u8 count`, then `count` points | ≤ MTU−3 |
| `0x03` | `ROUTE_END` | `u16 routeId`, `u16 crc16` | 5 |
| `0x10` | `POSITION` | `i32 lat_e6`, `i32 lon_e6`, `u16 heading_deg×10`, `u16 speed_kmh×10` | 13 |
| `0x20` | `MANEUVER` | `u8 turn`, `u8 roundaboutExit`, `u16 distanceToTurn_m`, `u32 remaining_m`, `u32 eta_unix`, `u8 nameLen`, `nameLen` bytes UTF-8 street (≤ 32) | 14 + n |
| `0x30` | `REROUTE` | `u16 newRouteId` — clear the route, a new `ROUTE_BEGIN` follows | 3 |
| `0x40` | `CLEAR` | — navigation ended | 1 |
| `0x50` | `TIME_SYNC` | `u32 unix`, `i16 utcOffset_min` — **extension:** lets the display show clock times | 7 |
| `0x7F` | `PING` | — keepalive | 1 |

### Route points (`ROUTE_CHUNK`)

Points are `lat`/`lon` as **int32 × 1e6** (micro-degrees). Inside the route they are sent
as **deltas from the previous point**; the first point of the route (index 0) is a delta
from `(0, 0)`, i.e. absolute. Each delta is **zig-zag + varint** encoded, latitude first:

```
zigzag(v)  = (v << 1) ^ (v >> 31)        // 32-bit
varint     = 7 bits per byte, low bits first, bit 7 = "more bytes follow"
```

A typical simplified route point costs 2–4 bytes, so a 180-byte chunk carries ~45 points.
Chunks are sent in order (`chunkIndex` 0, 1, 2 …) and `firstPointIndex` lets the
receiver detect gaps. The phone simplifies the route with Douglas-Peucker (≈5 m
tolerance) and caps it at **4000 points**.

### CRC (`ROUTE_END`)

**CRC-16/CCITT-FALSE** (poly `0x1021`, init `0xFFFF`, no reflection, no xor-out) over
all points in order, each point as **absolute `i32 lat_e6` then `i32 lon_e6`, little-endian**
(8 bytes per point). Test vector: CRC of ASCII `"123456789"` = `0x29B1`.

### Turn types (`MANEUVER.turn`)

| Value | Turn | Value | Turn |
|---|---|---|---|
| 0 | straight / continue | 6 | sharp right |
| 1 | slight left (keep, fork, exit) | 7 | U-turn |
| 2 | left | 8 | roundabout (`roundaboutExit` = exit number, 0 = unknown) |
| 3 | sharp left | 9 | arrive |
| 4 | slight right | 10 | depart |
| 5 | right | | |

`distanceToTurn_m` saturates at 65535. `eta_unix` is UTC; the display converts it with the
offset from `TIME_SYNC`.

## Messages ESP32 → phone (`STATUS` notify)

| Type | Name | Payload | Meaning |
|---|---|---|---|
| `0x81` | `READY` | `u8 battery_pct`, `u16 battery_mV`, `u8 protocolVersion` (=1) | sent on subscribe and every 30 s |
| `0x82` | `ROUTE_OK` | `u16 routeId`, `u16 pointCount` | route received and CRC matched |
| `0x83` | `RESEND` | `u16 routeId`, `u8 reason` (1 = CRC mismatch, 2 = gap/count mismatch, 3 = out of memory) | phone should resend the whole route |

On `RESEND` the phone sends `REROUTE` with the same `routeId`, then the full route again
(at most 3 times).

## Typical session

```
phone                                   ESP32
  |── connect, MTU, subscribe STATUS ──>|
  |<───────────── READY (battery) ──────|
  |── TIME_SYNC ───────────────────────>|
  |── ROUTE_BEGIN (id 7, 812 pts) ─────>|
  |── ROUTE_CHUNK × n ─────────────────>|
  |── ROUTE_END (crc) ─────────────────>|
  |<───────────── ROUTE_OK (id 7) ──────|
  |── POSITION ~4-5 Hz, MANEUVER ~1 Hz ─>|   (PING if idle)
  |── REROUTE (id 8) + new route ───────>|   (when off-route)
  |── CLEAR ───────────────────────────>|   (arrived / stopped)
```
