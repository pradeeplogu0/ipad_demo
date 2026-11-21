# NavLink

Turn-by-turn navigation on an iPhone/iPad that streams live directions over Bluetooth LE to
an ESP32-S3 round display, **NavDisplay**, which draws the route, your position arrow, the next
turn, distance, street name and ETA.

```
/app            Flutter iOS app "NavLink" (OpenStreetMap map, Apple Maps search/routing)
/firmware       NavDisplay firmware (Arduino, ESP32-S3, LVGL 8, TFT_eSPI)
/tools          Python test driver (bleak) — test the display without the phone
/docs           PROTOCOL.md — the BLE protocol both sides implement
/.github        iOS build (unsigned .ipa) + firmware compile check
```

## Hardware

| | |
|---|---|
| Board | Seeed Studio **XIAO ESP32-S3** (8 MB flash, 8 MB OPI PSRAM) |
| Display | Seeed **Round Display for XIAO** — GC9A01 240×240, CHSC6X touch |
| Pins | MOSI GPIO9 (D10), SCLK GPIO7 (D8), CS GPIO2 (D1), DC GPIO4 (D3), BL GPIO43 (D6), touch INT D7 (I²C 0x2E), battery D0 (1:2 divider) |

Display size and pins: `firmware/NavDisplay/config.h` (SPI pins live in TFT_eSPI's
`User_Setup.h`; the copy used by CI is `firmware/ci/TFT_eSPI_User_Setup.h`).

## How it works

* The **phone** finds your position (GPS, or the simulator), follows the route
  (`app/lib/nav_engine.dart`: snapping, next maneuver, ETA, off-route > 40 m for > 5 s → reroute)
  and sends compact binary messages over BLE: the simplified route once (Douglas-Peucker,
  CRC-checked), then position 5×/s and the next maneuver 1×/s.
* The **display** stores the route in PSRAM and draws it heading-up around your position,
  auto-zooming by speed and when a turn is close. It shows *Signal lost* if the phone goes
  quiet for 5 s. See [`docs/PROTOCOL.md`](docs/PROTOCOL.md).
* **Maps:** the app's map view uses OpenStreetMap tiles; search and routing use **Apple Maps**
  on iPhone (free, best routes), and Nominatim + OSRM when testing on PC/Chrome.

## 1. Flash the display

Requirements (Windows): [arduino-cli](https://arduino.github.io/arduino-cli/) or Arduino IDE 2,
ESP32 core **3.3.x**, libraries **lvgl 8.3.11** and **TFT_eSPI** configured for the Round Display
(copy `firmware/ci/TFT_eSPI_User_Setup.h` over `TFT_eSPI/User_Setup.h`, and
`firmware/ci/lv_conf.h` to your `Arduino/libraries/` folder).

```powershell
arduino-cli compile -b "esp32:esp32:XIAO_ESP32S3:PSRAM=opi,PartitionScheme=default_8MB" firmware/NavDisplay
arduino-cli upload  -b "esp32:esp32:XIAO_ESP32S3:PSRAM=opi,PartitionScheme=default_8MB" -p COM17 firmware/NavDisplay
```

Your COM port is in Device Manager → Ports ("USB Serial Device"). If the upload can't connect,
hold **BOOT**, tap **RESET**, release BOOT and try again. The display shows
*Waiting for phone…* and advertises as **NavDisplay**.

## 2. Test the display from your PC (no phone needed)

```powershell
pip install bleak
python tools/sim_drive.py                 # sends a route and drives it at 40 km/h
python tools/sim_drive.py --speed 100     # faster
python tools/sim_drive.py --corrupt-crc   # display must reject it (RESEND)
python tools/sim_drive.py --selftest      # encoder self-test only
```

## 3. Build the iPhone app

This project lives on the **`navlink` branch** of `pradeeplogu0/ipad_demo` (`main` is the Watch Lab app).
Every push to `navlink` that changes `app/**` builds the app on a free macOS runner (public repo):
**Actions → "iOS build (NavLink unsigned IPA)"**. When it is green, open the run and download
the **navlink-ipa** artifact (a .zip containing `NavLink-unsigned.ipa`). You can also start a
build by hand with **Run workflow**.

Local development (Windows): `cd app`, `flutter pub get`, `flutter analyze`, `flutter test`,
`flutter run -d chrome` (map, search and routing work; Chrome can even connect to the
NavDisplay over Web Bluetooth; GPS is simulated).

Map tiles: set a free MapTiler key in `app/lib/config.dart` for dark vector-style tiles;
without a key the app uses openstreetmap.org tiles (light personal use only, per the
[OSM tile policy](https://operations.osmfoundation.org/policies/tiles/)).

## 4. Sideload onto your iPhone / iPad (Windows, free Apple ID)

1. Install **iTunes from apple.com** (not the Microsoft Store version) and
   [Sideloadly](https://sideloadly.io).
2. Plug in the phone, unlock it, tap **Trust** and enter your passcode.
3. In Sideloadly drag in `NavLink-unsigned.ipa`, enter your Apple ID, click **Start**.
4. iOS 16+: Settings → Privacy & Security → **Developer Mode** → on (the phone restarts).
   iOS 15 (e.g. iPhone 7) has no Developer Mode — skip.
5. Settings → General → **VPN & Device Management** → your Apple ID → **Trust**.
6. Free Apple IDs sign apps for **7 days** — re-sideload the same .ipa every week
   (or use Sideloadly's auto-refresh / AltStore).

## 5. Use it

1. Power the NavDisplay. Open **NavLink** and allow **Location** and **Bluetooth**. The chip
   next to the search bar turns green with the display's battery % when connected.
2. Search a place (or **long-press** the map), check the route, tap **Start**.
3. Lock the phone if you like — guidance keeps running (blue location pill) and the display
   updates live. Going off-route recalculates automatically.
4. To try it at your desk, switch on **Simulate drive** before Start and pick a speed.

Map data © OpenStreetMap contributors. Routes and search on iPhone by Apple Maps.
