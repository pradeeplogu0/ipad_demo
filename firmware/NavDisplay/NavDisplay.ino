// NavDisplay — display bring-up test (step 1 of the firmware)
#include <Arduino.h>
#include <Wire.h>
#include "config.h"
#include "display_port.h"

void setup() {
    Serial.begin(115200);
    Wire.begin();
    display_init();

    lv_obj_t *scr = lv_scr_act();
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x0B0F14), 0);
    lv_obj_t *ring = lv_arc_create(scr);
    lv_obj_set_size(ring, 228, 228);
    lv_obj_center(ring);
    lv_arc_set_bg_angles(ring, 0, 360);
    lv_arc_set_value(ring, 100);
    lv_obj_set_style_arc_color(ring, lv_color_hex(0x3D8BFD), LV_PART_INDICATOR);
    lv_obj_remove_style(ring, NULL, LV_PART_KNOB);
    lv_obj_t *l = lv_label_create(scr);
    lv_obj_set_style_text_font(l, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(0xFFFFFF), 0);
    lv_label_set_text(l, "NavDisplay\ndisplay OK");
    lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_center(l);
    Serial.printf("[SYS] display test up, PSRAM free %u\n", (unsigned)ESP.getFreePsram());
}

void loop() {
    lv_timer_handler();
    delay(5);
}
