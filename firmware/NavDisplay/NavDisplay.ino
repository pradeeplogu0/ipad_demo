/*
 * NavDisplay — BLE navigation display for the NavLink iPhone app.
 * XIAO ESP32-S3 + GC9A01 240x240 round display (see config.h).
 * Protocol: docs/PROTOCOL.md
 *
 * Flow: BLE callbacks push raw messages into a FreeRTOS queue (ble_link.cpp);
 * this loop (the UI task) decodes them (nav_proto.cpp) and redraws (nav_ui.cpp).
 */
#include <Arduino.h>
#include <Wire.h>
#include <math.h>
#include <sys/time.h>
#include "config.h"
#include "display_port.h"
#include "nav_proto.h"
#include "ble_link.h"
#include "nav_ui.h"

static Route    g_route;
static Position g_pos;
static Maneuver g_man;
static UiState  g_ui;
static uint32_t g_last_msg_ms = 0;
static uint32_t g_arrived_ms = 0;
static int      g_snap = 0;
static uint16_t g_bat_mv = 0;

// ── battery (1:2 divider, LiPo curve) ─────────────────────────────────
static const int16_t LIPO_MV[]  = {4200, 4100, 4000, 3900, 3800, 3750, 3700, 3650, 3600, 3500, 3300};
static const int8_t  LIPO_PCT[] = { 100,   90,   78,   65,   50,   40,   30,   20,   12,    5,    0};

static void battery_sample() {
    int32_t sum = 0;
    for (int i = 0; i < 16; i++) sum += analogReadMilliVolts(PIN_BAT_ADC);
    int mv = (int)(sum / 16) * BAT_DIVIDER;
    g_bat_mv = mv;
    int pct = 0;
    if (mv >= LIPO_MV[0]) pct = 100;
    else for (int i = 1; i < 11; i++)
        if (mv >= LIPO_MV[i]) {
            pct = LIPO_PCT[i] + (mv - LIPO_MV[i]) * (LIPO_PCT[i - 1] - LIPO_PCT[i]) /
                                (LIPO_MV[i - 1] - LIPO_MV[i]);
            break;
        }
    g_ui.battery_pct = pct;
}

static void send_ready() {
    uint8_t m[5] = {ST_READY, (uint8_t)max(0, g_ui.battery_pct),
                    (uint8_t)(g_bat_mv & 0xFF), (uint8_t)(g_bat_mv >> 8), 1};
    ble_status(m, sizeof m);
}

// ── snap the position to the nearest route point (windowed search) ────
static void update_snap() {
    if (!g_route.valid || !g_pos.valid) return;
    double lat0 = g_pos.lat / 1e6;
    float kx = (float)(cos(lat0 * M_PI / 180.0) * 111320.0), ky = 110540.0f;
    int from = max(0, g_snap - 30), to = min((int)g_route.received, g_snap + 400);
    if (g_snap == 0) { from = 0; to = g_route.received; }
    float best = 1e30f;
    int bi = g_snap;
    for (int i = from; i < to; i++) {
        float x = (g_route.lon[i] - g_pos.lon) / 1e6f * kx;
        float y = (g_route.lat[i] - g_pos.lat) / 1e6f * ky;
        float d = x * x + y * y;
        if (d < best) { best = d; bi = i; }
    }
    g_snap = bi;
    g_ui.snap_idx = bi;
}

// ── message handling ──────────────────────────────────────────────────
static void handle(const BleMsg &m) {
    const uint8_t *d = m.data;
    size_t n = m.len;
    g_last_msg_ms = millis();
    switch (d[0]) {
    case MSG_ROUTE_BEGIN:
        route_begin(g_route, d, n);
        g_snap = 0;
        Serial.printf("[NAV] route %u begin, %u points, %lu m\n", g_route.id, g_route.expected,
                      (unsigned long)g_route.total_m);
        break;
    case MSG_ROUTE_CHUNK:
        route_chunk(g_route, d, n);
        break;
    case MSG_ROUTE_END: {
        uint8_t reason = route_end(g_route, d, n);
        if (reason == 0) {
            uint8_t ok[5] = {ST_ROUTE_OK, (uint8_t)g_route.id, (uint8_t)(g_route.id >> 8),
                             (uint8_t)g_route.received, (uint8_t)(g_route.received >> 8)};
            ble_status(ok, sizeof ok);
            ui_set_mode(UI_NAV);
            update_snap();
            Serial.printf("[NAV] route %u OK (%u points, crc ok)\n", g_route.id, g_route.received);
        } else {
            uint8_t rs[4] = {ST_RESEND, (uint8_t)g_route.id, (uint8_t)(g_route.id >> 8), reason};
            ble_status(rs, sizeof rs);
            Serial.printf("[NAV] route %u rejected, reason %u (got %u/%u)\n", g_route.id, reason,
                          g_route.received, g_route.expected);
        }
        break;
    }
    case MSG_POSITION:
        if (parse_position(g_pos, d, n)) update_snap();
        break;
    case MSG_MANEUVER:
        if (parse_maneuver(g_man, d, n)) {
            if (ui_mode() != UI_NAV && ui_mode() != UI_ARRIVED) ui_set_mode(UI_NAV);
            if (g_man.turn == TURN_ARRIVE && g_man.to_turn_m < 25) {
                ui_set_mode(UI_ARRIVED);
                g_arrived_ms = millis();
            }
        }
        break;
    case MSG_REROUTE:
        g_route.valid = false;
        g_route.receiving = false;
        g_snap = 0;
        Serial.println("[NAV] reroute");
        break;
    case MSG_CLEAR:
        g_route.valid = false;
        g_man.valid = false;
        if (ui_mode() != UI_ARRIVED) ui_set_mode(UI_IDLE);
        Serial.println("[NAV] cleared");
        break;
    case MSG_TIME_SYNC:
        if (n >= 7) {
            struct timeval tv = {(time_t)rd32(d + 1), 0};
            settimeofday(&tv, nullptr);
            g_ui.utc_offset_s = (int16_t)rd16(d + 5) * 60;
            g_ui.time_valid = true;
        }
        break;
    case MSG_PING:
    default:
        break;
    }
}

void setup() {
    Serial.begin(115200);
    delay(1200);                              // let USB CDC enumerate so boot logs show
    Serial.println("[SYS] boot");
    Wire.begin();
    analogReadResolution(12);
    display_init();
    Serial.println("[SYS] display ok");
    ui_init();
    Serial.println("[SYS] ui ok");
    if (!route_alloc(g_route)) Serial.println("[SYS] route buffer alloc failed");
    ble_link_init();
    Serial.println("[SYS] ble ok");
    battery_sample();
    g_ui.route = &g_route;
    g_ui.pos = &g_pos;
    g_ui.man = &g_man;
    Serial.printf("[SYS] NavDisplay ready, advertising as '%s'\n", BLE_DEVICE_NAME);
}

void loop() {
    lv_timer_handler();

    BleMsg msg;
    int budget = 24;                         // drain the queue without starving the UI
    while (budget-- && ble_receive(&msg)) handle(msg);

    uint32_t now = millis();
    bool conn = ble_connected();
    if (conn != g_ui.connected) {
        g_ui.connected = conn;
        Serial.printf("[BLE] %s\n", conn ? "connected" : "disconnected");
        if (conn && ui_mode() == UI_WAITING) ui_set_mode(UI_IDLE);
        if (!conn && ui_mode() == UI_IDLE) ui_set_mode(UI_WAITING);
    }
    if (ble_take_subscribed_event()) send_ready();

    g_ui.signal_lost = ui_mode() == UI_NAV && now - g_last_msg_ms > SIGNAL_LOST_MS;
    if (ui_mode() == UI_ARRIVED && now - g_arrived_ms > 8000) {
        ui_set_mode(conn ? UI_IDLE : UI_WAITING);
    }

    static uint32_t ui_last = 0, bat_last = 0;
    if (now - ui_last >= 100) { ui_last = now; ui_refresh(g_ui); }
    if (now - bat_last >= 30000) { bat_last = now; battery_sample(); if (conn) send_ready(); }
    delay(2);
}
