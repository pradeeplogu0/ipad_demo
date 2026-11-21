#pragma once
#include <Arduino.h>
#include <lvgl.h>

// TFT_eSPI + LVGL 8 glue for the configured panel (see config.h), with the
// draw buffer in PSRAM and the CHSC6X touch as an LVGL pointer device.
void display_init();
void display_set_brightness(uint8_t pct);   // 0-100
