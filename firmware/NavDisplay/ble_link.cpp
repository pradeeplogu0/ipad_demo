// BLE peripheral. The ESP32 Arduino core 3.3+ BLE library runs on the NimBLE
// host (lower RAM than Bluedroid) — no extra library needed. The stack creates
// the CCCD for NOTIFY characteristics itself and only notifies subscribers.
#include "ble_link.h"
#include "config.h"
#include <BLEDevice.h>
#include <BLEServer.h>

#define SERVICE_UUID "872ad000-4757-4f7a-b4e4-dc3d400d7ff4"
#define NAV_RX_UUID  "872ad001-4757-4f7a-b4e4-dc3d400d7ff4"
#define STATUS_UUID  "872ad002-4757-4f7a-b4e4-dc3d400d7ff4"

static QueueHandle_t      s_queue;
static BLECharacteristic *s_status;
static volatile bool      s_connected = false;
static volatile bool      s_subscribed_evt = false;

class ServerCB : public BLEServerCallbacks {
    void onConnect(BLEServer *) override { s_connected = true; }
    void onDisconnect(BLEServer *) override {
        s_connected = false;
        BLEDevice::startAdvertising();
    }
};

class RxCB : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *c) override {
        static BleMsg m;                      // callback runs on the BLE task only
        size_t n = c->getLength();
        if (n == 0 || n > BLE_MSG_MAX) return;
        memcpy(m.data, c->getData(), n);
        m.len = n;
        xQueueSend(s_queue, &m, 0);           // drop if the UI is badly behind
    }
};

class StatusCB : public BLECharacteristicCallbacks {
    void onSubscribe(BLECharacteristic *, ble_gap_conn_desc *, uint16_t sub) override {
        if (sub) s_subscribed_evt = true;
    }
};

void ble_link_init() {
    s_queue = xQueueCreate(48, sizeof(BleMsg));
    BLEDevice::init(BLE_DEVICE_NAME);
    BLEDevice::setMTU(247);
    BLEServer *server = BLEDevice::createServer();
    server->setCallbacks(new ServerCB());
    BLEService *svc = server->createService(BLEUUID(SERVICE_UUID));

    BLECharacteristic *rx = svc->createCharacteristic(NAV_RX_UUID,
        BLECharacteristic::PROPERTY_WRITE_NR | BLECharacteristic::PROPERTY_WRITE);
    rx->setCallbacks(new RxCB());

    s_status = svc->createCharacteristic(STATUS_UUID,
        BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
    s_status->setCallbacks(new StatusCB());
    uint8_t zero[5] = {0x81, 0, 0, 0, 1};   // READY, battery unknown, protocol v1
    s_status->setValue(zero, 5);

    svc->start();
    BLEAdvertising *adv = BLEDevice::getAdvertising();
    adv->addServiceUUID(SERVICE_UUID);
    adv->setScanResponse(true);
    BLEDevice::startAdvertising();
}

bool ble_receive(BleMsg *out) { return xQueueReceive(s_queue, out, 0) == pdTRUE; }
bool ble_connected() { return s_connected; }

bool ble_take_subscribed_event() {
    if (!s_subscribed_evt) return false;
    s_subscribed_evt = false;
    return true;
}

void ble_status(const uint8_t *data, size_t len) {
    s_status->setValue((uint8_t *)data, len);
    if (s_connected) s_status->notify();
}
