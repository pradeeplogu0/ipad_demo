#pragma once
#include <Arduino.h>

// NavLink protocol v1 — see docs/PROTOCOL.md
enum MsgType : uint8_t {
    MSG_ROUTE_BEGIN = 0x01, MSG_ROUTE_CHUNK = 0x02, MSG_ROUTE_END = 0x03,
    MSG_POSITION = 0x10, MSG_MANEUVER = 0x20, MSG_REROUTE = 0x30,
    MSG_CLEAR = 0x40, MSG_TIME_SYNC = 0x50, MSG_PING = 0x7F,
};
enum StatusType : uint8_t { ST_READY = 0x81, ST_ROUTE_OK = 0x82, ST_RESEND = 0x83 };
enum Turn : uint8_t {
    TURN_STRAIGHT = 0, TURN_SLIGHT_LEFT, TURN_LEFT, TURN_SHARP_LEFT, TURN_SLIGHT_RIGHT,
    TURN_RIGHT, TURN_SHARP_RIGHT, TURN_UTURN, TURN_ROUNDABOUT, TURN_ARRIVE, TURN_DEPART,
    TURN_COUNT
};

struct Route {
    int32_t  *lat = nullptr, *lon = nullptr;   // micro-degrees, PSRAM
    uint16_t  id = 0, expected = 0, received = 0;
    uint32_t  total_m = 0, eta_unix = 0;
    bool      receiving = false, valid = false, gap = false;
    int32_t   prev_lat = 0, prev_lon = 0;      // delta decoder state
};

struct Maneuver {
    uint8_t  turn = TURN_STRAIGHT, exit = 0;
    uint16_t to_turn_m = 0;
    uint32_t remaining_m = 0, eta_unix = 0;
    char     street[33] = "";
    bool     valid = false;
};

struct Position {
    int32_t  lat = 0, lon = 0;
    float    heading = 0, speed_kmh = 0;
    bool     valid = false;
};

uint16_t crc16_ccitt(const uint8_t *data, size_t len, uint16_t crc = 0xFFFF);
uint16_t route_crc(const Route &r);

bool route_alloc(Route &r);                         // PSRAM buffers (once)
void route_begin(Route &r, const uint8_t *m, size_t n);
bool route_chunk(Route &r, const uint8_t *m, size_t n);   // false on gap / bad data
// Returns 0 = OK, else RESEND reason (1 CRC, 2 gap/count, 3 memory).
uint8_t route_end(Route &r, const uint8_t *m, size_t n);

bool parse_position(Position &p, const uint8_t *m, size_t n);
bool parse_maneuver(Maneuver &v, const uint8_t *m, size_t n);

static inline uint16_t rd16(const uint8_t *p) { return p[0] | (p[1] << 8); }
static inline uint32_t rd32(const uint8_t *p) {
    return p[0] | (p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
