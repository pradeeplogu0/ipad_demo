#pragma once
#include <Arduino.h>

#define BLE_MSG_MAX 244

struct BleMsg {
    uint16_t len;
    uint8_t  data[BLE_MSG_MAX];
};

// GATT server per docs/PROTOCOL.md. Writes are pushed to a FreeRTOS queue
// from the BLE callback; the UI loop drains it with ble_receive().
void ble_link_init();
bool ble_receive(BleMsg *out);              // non-blocking
bool ble_connected();
bool ble_take_subscribed_event();           // true once after the phone subscribes
void ble_status(const uint8_t *data, size_t len);   // STATUS notify
