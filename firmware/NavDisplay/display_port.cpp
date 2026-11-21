#include "display_port.h"
#include "config.h"
#include <TFT_eSPI.h>
#include <Wire.h>

static TFT_eSPI tft = TFT_eSPI(SCREEN_W, SCREEN_H);

static void flush_cb(lv_disp_drv_t *drv, const lv_area_t *a, lv_color_t *px) {
    uint32_t w = a->x2 - a->x1 + 1, h = a->y2 - a->y1 + 1;
    tft.startWrite();
    tft.setAddrWindow(a->x1, a->y1, w, h);
    tft.pushColors((uint16_t *)&px->full, w * h, true);
    tft.endWrite();
    lv_disp_flush_ready(drv);
}

// CHSC6X: 5-byte report, [0] = 1 when touched, [2] = x, [4] = y (portrait).
static void touch_cb(lv_indev_drv_t *, lv_indev_data_t *data) {
    static lv_coord_t lx = 0, ly = 0;
    if (digitalRead(PIN_TOUCH_INT) != LOW) { data->state = LV_INDEV_STATE_REL; return; }
    uint8_t d[5] = {0};
    if (Wire.requestFrom((uint8_t)TOUCH_I2C_ADDR, (uint8_t)5) == 5) {
        Wire.readBytes(d, 5);
        if (d[0] == 0x01) {
            int x = d[2], y = d[4];
            for (int i = 0; i < SCREEN_ROTATION; i++) {   // rotate like the panel
                int t = x;
                x = y;
                y = ((i % 2) ? SCREEN_H : SCREEN_W) - t;
            }
            lx = x; ly = y;
        }
    }
    data->point.x = lx;
    data->point.y = ly;
    data->state = LV_INDEV_STATE_PR;
}

void display_set_brightness(uint8_t pct) {
    ledcWrite(PIN_BACKLIGHT, pct == 0 ? 0 : map(constrain(pct, 1, 100), 1, 100, 10, 255));
}

void display_init() {
    tft.begin();
    tft.setRotation(SCREEN_ROTATION);
    tft.fillScreen(TFT_BLACK);
    ledcAttach(PIN_BACKLIGHT, 5000, 8);
    display_set_brightness(100);

    lv_init();
    static lv_disp_draw_buf_t draw_buf;
    size_t n = SCREEN_W * LVGL_BUF_LINES;
    lv_color_t *buf = (lv_color_t *)heap_caps_malloc(n * sizeof(lv_color_t),
                                                     MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!buf) buf = (lv_color_t *)malloc(n * sizeof(lv_color_t));   // no PSRAM fallback
    lv_disp_draw_buf_init(&draw_buf, buf, NULL, n);

    static lv_disp_drv_t disp;
    lv_disp_drv_init(&disp);
    disp.hor_res = SCREEN_W;
    disp.ver_res = SCREEN_H;
    disp.flush_cb = flush_cb;
    disp.draw_buf = &draw_buf;
    lv_disp_drv_register(&disp);

    pinMode(PIN_TOUCH_INT, INPUT_PULLUP);
    static lv_indev_drv_t indev;
    lv_indev_drv_init(&indev);
    indev.type = LV_INDEV_TYPE_POINTER;
    indev.read_cb = touch_cb;
    lv_indev_drv_register(&indev);
}
