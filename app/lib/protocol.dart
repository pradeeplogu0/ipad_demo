/// NavLink BLE protocol v1 encoder — see docs/PROTOCOL.md.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

const serviceUuid = '872ad000-4757-4f7a-b4e4-dc3d400d7ff4';
const navRxUuid = '872ad001-4757-4f7a-b4e4-dc3d400d7ff4';
const statusUuid = '872ad002-4757-4f7a-b4e4-dc3d400d7ff4';
const deviceName = 'NavDisplay';

/// Turn types on the wire (MANEUVER.turn).
enum Turn {
  straight,
  slightLeft,
  left,
  sharpLeft,
  slightRight,
  right,
  sharpRight,
  uturn,
  roundabout,
  arrive,
  depart,
}

class Msg {
  static const routeBegin = 0x01, routeChunk = 0x02, routeEnd = 0x03;
  static const position = 0x10, maneuver = 0x20, reroute = 0x30;
  static const clear = 0x40, timeSync = 0x50, ping = 0x7F;
  static const statusReady = 0x81, statusRouteOk = 0x82, statusResend = 0x83;
}

/// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF).
int crc16(List<int> data, [int crc = 0xFFFF]) {
  for (final b in data) {
    crc ^= (b & 0xFF) << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
      crc &= 0xFFFF;
    }
  }
  return crc;
}

/// Zig-zag + varint encoding of a 32-bit signed integer.
List<int> zigzagVarint(int v) {
  var z = ((v << 1) ^ (v >> 31)) & 0xFFFFFFFF;
  final out = <int>[];
  while (true) {
    final b = z & 0x7F;
    z >>= 7;
    if (z != 0) {
      out.add(b | 0x80);
    } else {
      out.add(b);
      return out;
    }
  }
}

int toE6(double deg) => (deg * 1e6).round();

/// CRC over all points as absolute int32 lat/lon (LE), per the protocol.
int routeCrc(List<(int, int)> e6) {
  var crc = 0xFFFF;
  final bd = ByteData(8);
  for (final (la, lo) in e6) {
    bd.setInt32(0, la, Endian.little);
    bd.setInt32(4, lo, Endian.little);
    crc = crc16(bd.buffer.asUint8List(), crc);
  }
  return crc;
}

/// ROUTE_BEGIN, ROUTE_CHUNK×n, ROUTE_END for [points], each ≤ [maxPayload] bytes.
List<Uint8List> encodeRoute(
  int routeId,
  List<LatLng> points,
  int totalMeters,
  DateTime eta, {
  int maxPayload = 180,
}) {
  final e6 = [for (final p in points) (toE6(p.latitude), toE6(p.longitude))];
  final out = <Uint8List>[];
  final begin = ByteData(13)
    ..setUint8(0, Msg.routeBegin)
    ..setUint16(1, routeId, Endian.little)
    ..setUint16(3, e6.length, Endian.little)
    ..setUint32(5, totalMeters.clamp(0, 0xFFFFFFFF), Endian.little)
    ..setUint32(9, eta.toUtc().millisecondsSinceEpoch ~/ 1000, Endian.little);
  out.add(begin.buffer.asUint8List());

  var prev = (0, 0);
  var i = 0, chunk = 0;
  while (i < e6.length) {
    final first = i;
    final body = <int>[];
    while (i < e6.length && i - first < 255) {
      final (la, lo) = e6[i];
      final enc = [
        ...zigzagVarint(la - prev.$1),
        ...zigzagVarint(lo - prev.$2),
      ];
      if (8 + body.length + enc.length > maxPayload) break;
      body.addAll(enc);
      prev = (la, lo);
      i++;
    }
    final head = ByteData(8)
      ..setUint8(0, Msg.routeChunk)
      ..setUint16(1, routeId, Endian.little)
      ..setUint16(3, chunk, Endian.little)
      ..setUint16(5, first, Endian.little)
      ..setUint8(7, i - first);
    out.add(Uint8List.fromList([...head.buffer.asUint8List(), ...body]));
    chunk++;
  }
  final end = ByteData(5)
    ..setUint8(0, Msg.routeEnd)
    ..setUint16(1, routeId, Endian.little)
    ..setUint16(3, routeCrc(e6), Endian.little);
  out.add(end.buffer.asUint8List());
  return out;
}

Uint8List encodePosition(LatLng p, double headingDeg, double speedKmh) {
  final b = ByteData(13)
    ..setUint8(0, Msg.position)
    ..setInt32(1, toE6(p.latitude), Endian.little)
    ..setInt32(5, toE6(p.longitude), Endian.little)
    ..setUint16(9, ((headingDeg % 360) * 10).round() % 3600, Endian.little)
    ..setUint16(11, (speedKmh * 10).round().clamp(0, 65535), Endian.little);
  return b.buffer.asUint8List();
}

/// Street names are cut to 32 bytes without splitting a UTF-8 character.
List<int> streetBytes(String s) {
  final b = utf8.encode(s);
  if (b.length <= 32) return b;
  var n = 32;
  while (n > 0 && (b[n] & 0xC0) == 0x80) {
    n--;
  }
  return b.sublist(0, n);
}

Uint8List encodeManeuver(
  Turn turn,
  int exit,
  double toTurnM,
  double remainingM,
  DateTime eta,
  String street,
) {
  final name = streetBytes(street);
  final b = ByteData(14)
    ..setUint8(0, Msg.maneuver)
    ..setUint8(1, turn.index)
    ..setUint8(2, exit.clamp(0, 255))
    ..setUint16(3, toTurnM.round().clamp(0, 65535), Endian.little)
    ..setUint32(5, remainingM.round().clamp(0, 0xFFFFFFFF), Endian.little)
    ..setUint32(9, eta.toUtc().millisecondsSinceEpoch ~/ 1000, Endian.little)
    ..setUint8(13, name.length);
  return Uint8List.fromList([...b.buffer.asUint8List(), ...name]);
}

Uint8List encodeReroute(int newRouteId) {
  final b = ByteData(3)
    ..setUint8(0, Msg.reroute)
    ..setUint16(1, newRouteId, Endian.little);
  return b.buffer.asUint8List();
}

Uint8List encodeTimeSync(DateTime now) {
  final b = ByteData(7)
    ..setUint8(0, Msg.timeSync)
    ..setUint32(1, now.toUtc().millisecondsSinceEpoch ~/ 1000, Endian.little)
    ..setInt16(5, now.timeZoneOffset.inMinutes, Endian.little);
  return b.buffer.asUint8List();
}

Uint8List encodeClear() => Uint8List.fromList([Msg.clear]);
Uint8List encodePing() => Uint8List.fromList([Msg.ping]);

/// STATUS notifications from the display.
sealed class DisplayStatus {}

class StatusReady extends DisplayStatus {
  StatusReady(this.batteryPct, this.batteryMv);
  final int batteryPct, batteryMv;
}

class StatusRouteOk extends DisplayStatus {
  StatusRouteOk(this.routeId, this.points);
  final int routeId, points;
}

class StatusResend extends DisplayStatus {
  StatusResend(this.routeId, this.reason);
  final int routeId, reason;
}

DisplayStatus? decodeStatus(List<int> v) {
  if (v.isEmpty) return null;
  int u16(int i) => v[i] | (v[i + 1] << 8);
  switch (v[0]) {
    case Msg.statusReady when v.length >= 4:
      return StatusReady(v[1], u16(2));
    case Msg.statusRouteOk when v.length >= 5:
      return StatusRouteOk(u16(1), u16(3));
    case Msg.statusResend when v.length >= 4:
      return StatusResend(u16(1), v[3]);
  }
  return null;
}
