#include "nav_proto.h"
#include "config.h"

uint16_t crc16_ccitt(const uint8_t *d, size_t len, uint16_t crc) {
    for (size_t i = 0; i < len; i++) {
        crc ^= (uint16_t)d[i] << 8;
        for (int b = 0; b < 8; b++) crc = (crc & 0x8000) ? (crc << 1) ^ 0x1021 : crc << 1;
    }
    return crc;
}

uint16_t route_crc(const Route &r) {
    uint16_t crc = 0xFFFF;
    for (uint16_t i = 0; i < r.received; i++) {
        uint8_t b[8];
        uint32_t la = (uint32_t)r.lat[i], lo = (uint32_t)r.lon[i];
        for (int k = 0; k < 4; k++) { b[k] = la >> (8 * k); b[4 + k] = lo >> (8 * k); }
        crc = crc16_ccitt(b, 8, crc);
    }
    return crc;
}

bool route_alloc(Route &r) {
    if (r.lat) return true;
    r.lat = (int32_t *)heap_caps_malloc(MAX_ROUTE_POINTS * 4, MALLOC_CAP_SPIRAM);
    r.lon = (int32_t *)heap_caps_malloc(MAX_ROUTE_POINTS * 4, MALLOC_CAP_SPIRAM);
    return r.lat && r.lon;
}

void route_begin(Route &r, const uint8_t *m, size_t n) {
    r.valid = false;
    r.receiving = n >= 13;
    if (!r.receiving) return;
    r.id = rd16(m + 1);
    r.expected = rd16(m + 3);
    r.total_m = rd32(m + 5);
    r.eta_unix = rd32(m + 9);
    r.received = 0;
    r.gap = r.expected > MAX_ROUTE_POINTS;
    r.prev_lat = r.prev_lon = 0;
}

// zig-zag varint (32-bit)
static bool read_varint(const uint8_t *&p, const uint8_t *end, int32_t &out) {
    uint32_t v = 0;
    for (int shift = 0; shift < 35; shift += 7) {
        if (p >= end) return false;
        uint8_t b = *p++;
        v |= (uint32_t)(b & 0x7F) << shift;
        if (!(b & 0x80)) { out = (int32_t)((v >> 1) ^ (~(v & 1) + 1)); return true; }
    }
    return false;
}

bool route_chunk(Route &r, const uint8_t *m, size_t n) {
    if (!r.receiving || n < 8 || rd16(m + 1) != r.id) return false;
    uint16_t first = rd16(m + 5);
    uint8_t  count = m[7];
    if (first != r.received) { r.gap = true; return false; }
    const uint8_t *p = m + 8, *end = m + n;
    for (uint8_t i = 0; i < count; i++) {
        int32_t dl, dn;
        if (!read_varint(p, end, dl) || !read_varint(p, end, dn)) { r.gap = true; return false; }
        r.prev_lat += dl;
        r.prev_lon += dn;
        if (r.received >= MAX_ROUTE_POINTS) { r.gap = true; return false; }
        r.lat[r.received] = r.prev_lat;
        r.lon[r.received] = r.prev_lon;
        r.received++;
    }
    return true;
}

uint8_t route_end(Route &r, const uint8_t *m, size_t n) {
    r.receiving = false;
    if (!r.lat) return 3;
    if (n < 5 || rd16(m + 1) != r.id) return 2;
    if (r.gap || r.received != r.expected || r.received < 2) return 2;
    if (route_crc(r) != rd16(m + 3)) return 1;
    r.valid = true;
    return 0;
}

bool parse_position(Position &p, const uint8_t *m, size_t n) {
    if (n < 13) return false;
    p.lat = (int32_t)rd32(m + 1);
    p.lon = (int32_t)rd32(m + 5);
    p.heading = rd16(m + 9) / 10.0f;
    p.speed_kmh = rd16(m + 11) / 10.0f;
    p.valid = true;
    return true;
}

bool parse_maneuver(Maneuver &v, const uint8_t *m, size_t n) {
    if (n < 14) return false;
    v.turn = m[1] < TURN_COUNT ? m[1] : TURN_STRAIGHT;
    v.exit = m[2];
    v.to_turn_m = rd16(m + 3);
    v.remaining_m = rd32(m + 5);
    v.eta_unix = rd32(m + 9);
    uint8_t len = m[13];
    if (len > 32) len = 32;
    if (14 + len > n) len = n - 14;
    // Keep printable ASCII only (watch fonts); multi-byte UTF-8 becomes '?' once.
    size_t k = 0;
    for (uint8_t i = 0; i < len && k < 32; i++) {
        uint8_t c = m[14 + i];
        if (c >= 32 && c < 127) v.street[k++] = (char)c;
        else if ((c & 0xC0) != 0x80 && c >= 0x80) v.street[k++] = '?';
    }
    v.street[k] = 0;
    v.valid = true;
    return true;
}
