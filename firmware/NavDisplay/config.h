#pragma once
// ─────────────────────────────────────────────────────────────────────────────
// NavDisplay hardware configuration — change the display / pins here.
//
// Default: Seeed Studio XIAO ESP32-S3 (8 MB flash, 8 MB OPI PSRAM)
//          + Seeed Round Display for XIAO: GC9A01 240x240, CHSC6X touch,
//          PCF8563 RTC, battery divider on D0.
//
// The SPI display pins (MOSI/SCLK/CS/DC/BL) and the GC9A01 driver are chosen in
// TFT_eSPI's User_Setup.h (a copy for CI lives in ../ci/TFT_eSPI_User_Setup.h):
//   MOSI = GPIO9 (D10), SCLK = GPIO7 (D8), CS = GPIO2 (D1), DC = GPIO4 (D3),
//   RST = not connected, BL = GPIO43 (D6).
// ─────────────────────────────────────────────────────────────────────────────

#define SCREEN_W          240
#define SCREEN_H          240
#define SCREEN_ROUND      1        // 1 = round panel: keep UI inside the circle
#define SCREEN_ROTATION   0        // 0-3 (x 90 degrees)

#define PIN_BACKLIGHT     D6       // PWM brightness
#define PIN_TOUCH_INT     D7       // CHSC6X interrupt (LOW while touched)
#define TOUCH_I2C_ADDR    0x2E     // CHSC6X
#define PIN_BAT_ADC       D0       // battery through a 1:2 divider
#define BAT_DIVIDER       2

#define LVGL_BUF_LINES    40       // partial draw buffer height (PSRAM)
#define MAX_ROUTE_POINTS  4000     // stored in PSRAM (8 bytes each)

#define BLE_DEVICE_NAME   "NavDisplay"
#define SIGNAL_LOST_MS    5000     // "Signal lost" after this long without a message
