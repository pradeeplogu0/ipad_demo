"""
NavLink protocol test driver for NavDisplay (Windows, Python 3 + bleak).

Sends a fake route, then "drives" along it sending POSITION (~5 Hz), MANEUVER
(1 Hz) and PING, exactly like the iPhone app. Use it to test the firmware
without the phone.

    pip install bleak
    python tools/sim_drive.py                 # drive the demo route at 40 km/h
    python tools/sim_drive.py --speed 80 --duration 60
    python tools/sim_drive.py --corrupt-crc   # expect a RESEND from the display
    python tools/sim_drive.py --selftest      # encoder tests only, no BLE
"""
import argparse
import asyncio
import math
import struct
import sys
import time

SERVICE = "872ad000-4757-4f7a-b4e4-dc3d400d7ff4"
NAV_RX = "872ad001-4757-4f7a-b4e4-dc3d400d7ff4"
STATUS = "872ad002-4757-4f7a-b4e4-dc3d400d7ff4"

TURN = dict(straight=0, slight_left=1, left=2, sharp_left=3, slight_right=4, right=5,
            sharp_right=6, uturn=7, roundabout=8, arrive=9, depart=10)


# ── protocol encoding (mirrors app/lib/protocol.dart) ────────────────────
def crc16_ccitt(data: bytes, crc: int = 0xFFFF) -> int:
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc


def zigzag_varint(v: int) -> bytes:
    z = ((v << 1) ^ (v >> 31)) & 0xFFFFFFFF
    out = bytearray()
    while True:
        b = z & 0x7F
        z >>= 7
        if z:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def route_messages(route_id, pts_e6, total_m, eta_unix, payload_max=180, corrupt=False):
    msgs = [struct.pack("<BHHII", 0x01, route_id, len(pts_e6), total_m, eta_unix)]
    prev = (0, 0)
    i = chunk = 0
    while i < len(pts_e6):
        head_len = 8
        body = bytearray()
        first = i
        while i < len(pts_e6):
            la, lo = pts_e6[i]
            enc = zigzag_varint(la - prev[0]) + zigzag_varint(lo - prev[1])
            if head_len + len(body) + len(enc) > payload_max or i - first >= 255:
                break
            body += enc
            prev = (la, lo)
            i += 1
        msgs.append(struct.pack("<BHHHB", 0x02, route_id, chunk, first, i - first) + bytes(body))
        chunk += 1
    crc = 0xFFFF
    for la, lo in pts_e6:
        crc = crc16_ccitt(struct.pack("<ii", la, lo), crc)
    if corrupt:
        crc ^= 0x5A5A
    msgs.append(struct.pack("<BHH", 0x03, route_id, crc))
    return msgs


def position_msg(lat, lon, heading, speed_kmh):
    return struct.pack("<BiiHH", 0x10, round(lat * 1e6), round(lon * 1e6),
                       round(heading * 10) % 3600, round(speed_kmh * 10))


def maneuver_msg(turn, to_turn, remaining, eta_unix, street, exit_no=0):
    name = street.encode("utf-8")[:32]
    return struct.pack("<BBBHIIB", 0x20, turn, exit_no, min(int(to_turn), 65535),
                       int(remaining), int(eta_unix), len(name)) + name


def time_sync_msg():
    off = -time.timezone if not time.localtime().tm_isdst else -time.altzone
    return struct.pack("<BIh", 0x50, int(time.time()), off // 60)


# ── demo route: ~2.2 km loop with a few turns (Bengaluru MG Road area) ──
def demo_route():
    legs = [  # (bearing deg, metres, maneuver at end of leg, street of next leg)
        (0, 500, "right", "MG Road"),
        (90, 400, "roundabout", "Residency Road"),
        (135, 350, "left", "Brigade Road"),
        (45, 300, "slight_right", "Church Street"),
        (90, 450, "sharp_left", "St Marks Road"),
        (300, 250, "arrive", "Destination"),
    ]
    lat, lon = 12.9716, 77.5946
    pts = [(lat, lon)]
    turns = []  # (point index, turn, street)
    for bearing, dist, turn, street in legs:
        steps = max(2, int(dist / 20))
        for _ in range(steps):
            d = dist / steps
            lat += d * math.cos(math.radians(bearing)) / 110540
            lon += d * math.sin(math.radians(bearing)) / (111320 * math.cos(math.radians(lat)))
            pts.append((lat, lon))
        turns.append((len(pts) - 1, turn, street))
    return pts, turns, "Brigade Road"


def haversine(a, b):
    r = 6371000
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.atan2(math.sqrt(h), math.sqrt(1 - h))


def bearing(a, b):
    y = math.sin(math.radians(b[1] - a[1])) * math.cos(math.radians(b[0]))
    x = math.cos(math.radians(a[0])) * math.sin(math.radians(b[0])) - \
        math.sin(math.radians(a[0])) * math.cos(math.radians(b[0])) * math.cos(math.radians(b[1] - a[1]))
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def selftest():
    assert crc16_ccitt(b"123456789") == 0x29B1, "CRC-16/CCITT-FALSE test vector"
    assert zigzag_varint(0) == b"\x00" and zigzag_varint(-1) == b"\x01" and zigzag_varint(1) == b"\x02"
    assert zigzag_varint(64) == b"\x80\x01"
    pts, _, _ = demo_route()
    e6 = [(round(a * 1e6), round(b * 1e6)) for a, b in pts]
    msgs = route_messages(1, e6, 2250, 0)
    assert all(len(m) <= 180 for m in msgs)
    print(f"selftest OK: {len(pts)} points -> {len(msgs) - 2} chunks")


# ── BLE session ──────────────────────────────────────────────────────────
async def run(args):
    from bleak import BleakClient, BleakScanner

    print("scanning for NavDisplay...")
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or "") == "NavDisplay" or SERVICE in ad.service_uuids, timeout=15)
    if not dev:
        sys.exit("NavDisplay not found - is it powered and not connected to the phone?")

    async with BleakClient(dev) as c:
        statuses = []

        def on_status(_, data: bytearray):
            data = bytes(data)
            statuses.append(data)
            if data[0] == 0x81:
                print(f"  STATUS READY battery={data[1]}% {struct.unpack('<H', data[2:4])[0]} mV")
            elif data[0] == 0x82:
                rid, n = struct.unpack("<HH", data[1:5])
                print(f"  STATUS ROUTE_OK route={rid} points={n}")
            elif data[0] == 0x83:
                print(f"  STATUS RESEND route={struct.unpack('<H', data[1:3])[0]} reason={data[3]}")

        await c.start_notify(STATUS, on_status)
        payload = max(20, min(c.mts if hasattr(c, "mts") else c.mtu_size - 3, 240))
        print(f"connected, MTU {c.mtu_size} -> payload {payload} bytes")
        send = lambda m: c.write_gatt_char(NAV_RX, m, response=False)

        await send(time_sync_msg())
        pts, turns, first_street = demo_route()
        e6 = [(round(a * 1e6), round(b * 1e6)) for a, b in pts]
        cum = [0.0]
        for i in range(1, len(pts)):
            cum.append(cum[-1] + haversine(pts[i - 1], pts[i]))
        total = cum[-1]
        speed_ms = args.speed / 3.6
        eta = int(time.time() + total / speed_ms)

        msgs = route_messages(7, e6, int(total), eta, payload, corrupt=args.corrupt_crc)
        for m in msgs:
            await send(m)
            await asyncio.sleep(0.01)
        print(f"sent route: {len(pts)} points, {len(msgs) - 2} chunks, {total:.0f} m")
        await asyncio.sleep(1.0)
        if args.corrupt_crc:
            ok = any(s[0] == 0x83 and s[3] == 1 for s in statuses)
            print("PASS: display rejected the bad CRC" if ok else "FAIL: no RESEND received")
            return
        if not any(s[0] == 0x82 for s in statuses):
            print("FAIL: no ROUTE_OK - route was not accepted")
            return

        t0 = time.time()
        last_man = 0.0
        while True:
            el = time.time() - t0
            along = min(total, el * speed_ms)
            i = next((k for k in range(1, len(cum)) if cum[k] >= along), len(cum) - 1)
            f = 0 if cum[i] == cum[i - 1] else (along - cum[i - 1]) / (cum[i] - cum[i - 1])
            here = (pts[i - 1][0] + (pts[i][0] - pts[i - 1][0]) * f,
                    pts[i - 1][1] + (pts[i][1] - pts[i - 1][1]) * f)
            await send(position_msg(here[0], here[1], bearing(pts[i - 1], pts[i]), args.speed))
            if el - last_man >= 1.0:
                last_man = el
                nxt = next(((k, t, s) for k, t, s in turns if cum[k] > along + 2), turns[-1])
                street = next((s for k, t, s in turns if cum[k] <= along), first_street)
                left = total - along
                exit_no = 2 if nxt[1] == "roundabout" else 0
                await send(maneuver_msg(TURN[nxt[1]], cum[nxt[0]] - along, left,
                                        time.time() + left / speed_ms, street if nxt[1] != "arrive" else nxt[2],
                                        exit_no))
                print(f"  t={el:5.1f}s  {nxt[1]:>12} in {cum[nxt[0]] - along:6.0f} m   left {left:6.0f} m")
            if along >= total or el > args.duration:
                break
            await asyncio.sleep(0.2)

        await asyncio.sleep(2)
        await send(bytes([0x40]))  # CLEAR
        print("sent CLEAR - done")
        print("PASS")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--speed", type=float, default=40, help="km/h")
    ap.add_argument("--duration", type=float, default=240, help="max seconds")
    ap.add_argument("--corrupt-crc", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    selftest()
    if not a.selftest:
        asyncio.run(run(a))
