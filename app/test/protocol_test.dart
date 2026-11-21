import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navlink/protocol.dart';

/// Mirror of the firmware decoder (firmware/NavDisplay/nav_proto.cpp).
class DecodedRoute {
  int id = 0, expected = 0, total = 0, eta = 0, crc = -1;
  final pts = <(int, int)>[];
  bool gap = false;
}

DecodedRoute decodeRoute(List<Uint8List> msgs) {
  final d = DecodedRoute();
  var prevLa = 0, prevLo = 0;
  int u16(List<int> m, int i) => m[i] | (m[i + 1] << 8);
  int u32(List<int> m, int i) => u16(m, i) | (u16(m, i + 2) << 16);
  for (final m in msgs) {
    switch (m[0]) {
      case 0x01:
        d.id = u16(m, 1);
        d.expected = u16(m, 3);
        d.total = u32(m, 5);
        d.eta = u32(m, 9);
      case 0x02:
        if (u16(m, 5) != d.pts.length) d.gap = true;
        var p = 8;
        int varint() {
          var v = 0, shift = 0;
          while (true) {
            final b = m[p++];
            v |= (b & 0x7F) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
          }
          return (v >> 1) ^ -(v & 1);
        }
        for (var i = 0; i < m[7]; i++) {
          prevLa += varint();
          prevLo += varint();
          d.pts.add((prevLa, prevLo));
        }
      case 0x03:
        d.crc = u16(m, 3);
    }
  }
  return d;
}

void main() {
  test('CRC-16/CCITT-FALSE test vector', () {
    expect(crc16(ascii.encode('123456789')), 0x29B1);
  });

  test('zig-zag varint', () {
    expect(zigzagVarint(0), [0]);
    expect(zigzagVarint(-1), [1]);
    expect(zigzagVarint(1), [2]);
    expect(zigzagVarint(64), [0x80, 0x01]);
    expect(zigzagVarint(77594600).length, 4);
  });

  test('route round-trips through the firmware decoder, every chunk fits', () {
    final pts = [
      for (var i = 0; i < 500; i++)
        LatLng(
          12.9716 + i * 0.00031 * (i.isEven ? 1 : 0.7),
          77.5946 - i * 0.00017,
        ),
    ];
    for (final payload in [20, 182, 240]) {
      final msgs = encodeRoute(
        42,
        pts,
        12345,
        DateTime.utc(2026, 11, 22, 10),
        maxPayload: payload,
      );
      expect(
        msgs.every((m) => m.length <= payload),
        isTrue,
        reason: 'payload $payload',
      );
      final d = decodeRoute(msgs);
      expect(d.id, 42);
      expect(d.expected, 500);
      expect(d.total, 12345);
      expect(
        d.eta,
        DateTime.utc(2026, 11, 22, 10).millisecondsSinceEpoch ~/ 1000,
      );
      expect(d.gap, isFalse);
      expect(d.pts.length, 500);
      expect(d.pts.first, (
        toE6(pts.first.latitude),
        toE6(pts.first.longitude),
      ));
      expect(d.pts.last, (toE6(pts.last.latitude), toE6(pts.last.longitude)));
      expect(d.crc, routeCrc(d.pts));
    }
  });

  test('position and maneuver layouts', () {
    final p = encodePosition(const LatLng(12.5, -77.25), 359.96, 42.34);
    final bd = ByteData.sublistView(p);
    expect(p.length, 13);
    expect(bd.getInt32(1, Endian.little), 12500000);
    expect(bd.getInt32(5, Endian.little), -77250000);
    expect(bd.getUint16(9, Endian.little), 0); // 360.0 wraps to 0
    expect(bd.getUint16(11, Endian.little), 423);

    final m = encodeManeuver(
      Turn.roundabout,
      2,
      250.4,
      3150,
      DateTime.utc(2026),
      'MG Road',
    );
    final mb = ByteData.sublistView(m);
    expect(m[0], 0x20);
    expect(m[1], 8);
    expect(m[2], 2);
    expect(mb.getUint16(3, Endian.little), 250);
    expect(mb.getUint32(5, Endian.little), 3150);
    expect(m[13], 7);
    expect(utf8.decode(m.sublist(14)), 'MG Road');
  });

  test('street names are cut to 32 bytes on a UTF-8 boundary', () {
    final s = streetBytes('ಮಹಾತ್ಮ ಗಾಂಧಿ ರಸ್ತೆ ಬೆಂಗಳೂರು');
    expect(s.length, lessThanOrEqualTo(32));
    expect(() => utf8.decode(s), returnsNormally);
    expect(streetBytes('Short').length, 5);
  });

  test('status decoding', () {
    final r = decodeStatus([0x81, 86, 0xE4, 0x0F, 1]) as StatusReady;
    expect([r.batteryPct, r.batteryMv], [86, 4068]);
    final ok = decodeStatus([0x82, 7, 0, 112, 0]) as StatusRouteOk;
    expect([ok.routeId, ok.points], [7, 112]);
    final rs = decodeStatus([0x83, 7, 0, 1]) as StatusResend;
    expect([rs.routeId, rs.reason], [7, 1]);
  });
}
