#pragma once
#include <Arduino.h>
#include "nav_proto.h"

enum UiMode { UI_WAITING, UI_IDLE, UI_NAV, UI_ARRIVED };

struct UiState {
    bool      connected = false;
    bool      signal_lost = false;
    int       battery_pct = -1;
    bool      time_valid = false;
    int32_t   utc_offset_s = 0;
    const Route    *route = nullptr;
    const Position *pos = nullptr;
    const Maneuver *man = nullptr;
    int       snap_idx = 0;            // nearest route point to the position
};

void ui_init();
void ui_set_mode(UiMode m);
UiMode ui_mode();
void ui_refresh(const UiState &s);    // call ~10 Hz
