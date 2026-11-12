# choclift (macOS + iOS / iPadOS + watchOS Replica)

Turn your **iPhone**, **iPad**, and **Apple Watch** into tactile, customizable **Chocolate Touch Bar** companions ("Workflow Sweetener") for your Mac.

---

## Core Replicated Features (v2.3.6 Feature Set + Native watchOS Companion)

### 1. Customizable Chocolate Bar (`Apps`, `Apple Shortcuts`, `Websites`, `Quick Actions`)
- **8 Pages × 8 Molded Chocolate Squares (2×4 Grid)**: Organize workflows across 8 switchable pages (`Daily`, `Workspace`, `Quick Actions`, `Web & Docs`, `Shortcuts`, `Creative`, `Media`, `Focus`).
- **One-Tap Mac Apps & Drag & Drop 2.0**: Launch or switch to any Mac app in a single haptic tap — including **Drag & Drop 2.0** (grab a file with your Mac mouse and tap the destination app on your companion device to bring its window forward mid-drag).
- **Apple Shortcuts Integration**: Discover and trigger real macOS Apple Shortcuts (`/usr/bin/shortcuts`) topped with custom emojis and vibrant tile colors.
- **Smart Website Bookmarks**: Launch URLs or **automatically switch to an already-open matching browser tab** in Safari, Google Chrome, Arc, Brave, or Microsoft Edge.
- **Redesigned App Picker**: Instant search with `↑` / `↓` arrow-key navigation + `Return` to select, plus direct `.app` and URL drag-and-drop from Finder/Safari onto any slot.

### 2. App Time Travel (Smart Dynamic Dock)
- Real-time chronological timeline of recently opened & switched Mac applications via `NSWorkspace` notifications.
- **Pin Favorites**: Pin essential apps to stay anchored at the front of Time Travel; manage pins or switch windows from iPhone, iPad, or Apple Watch.

### 3. Cursor-Aware Emoji Bar ("Pick emojis right where you type")
- **8 Customizable Emoji Slides** (64 favorite slots + full categorized Emoji picker on iOS/macOS).
- **Smart Mac Text-Field Focus Detection**: Automatically detects via macOS Accessibility (`AXUIElement`) when your cursor enters an editable text input on Mac and surfaces the Emoji Bar on your connected iPhone, iPad, or Apple Watch, injecting emojis right at your cursor while preserving your Mac clipboard.

### 4. Multi-Touch Finger Gestures (iOS / iPadOS) & Wrist Quick Actions (watchOS)
- Global pass-through multi-touch gesture recognizer on iPhone & iPad (plus dedicated Gesture Pad mode):
  - **2-Finger Swipe Up / Down**: Maximize / Minimize active Mac window
  - **2-Finger Swipe Left / Right**: Snap window to Left / Right half of screen
  - **3-Finger Pinch In ("Grab") / Spread Out ("Drop")**: Copy (`⌘C`) / Paste (`⌘V`)
  - **2-Finger Double Tap**: Undo (`⌘Z`)
  - **3-Finger Swipe Up / Down**: Mission Control / Show Desktop
  - Every gesture is remappable to 22 Window, Clipboard, Media, Volume, and System actions.
- **Apple Watch Companion (`ChocliftWatch`)**:
  - Pairs directly with the same `ChocliftMac` session over **both** Wi-Fi TCP (`Network.framework`) and **Bluetooth LE** (`CoreBluetooth` `CBCentralManager`), sharing the exact same length-prefixed `ClientMessage` / `ServerMessage` wire protocol, 6-digit PIN, and persistent `authToken`.
  - Persistent top-bar pairing & live connection status pill showing the active link icon (`wifi` or `BLE` wave icon) alongside `<MacName>`.
  - Watch-sized 2×4 **Chocolate Bar** grid across all 8 synced pages (with Digital Crown scroll and quick slot assignment for empty tiles), dedicated **Quick Actions** remote (Media & Volume strips, Window Snap/Maximize/Minimize/Center/Fullscreen, Spaces/Desktop, Copy/Paste/Undo/Screenshot/Lock), **App Time Travel** switcher, and **Emoji Bar** slides.

### 5. Dual-Transport Wi-Fi TCP + Bluetooth LE Pairing & Roaming
- **Two Links, One Shared Protocol & PIN**:
  - **Wi-Fi (TCP)**: Bonjour (`_choclift._tcp`) + length-prefixed TCP on port `54821` (plus `127.0.0.1:54821` for iOS/watchOS Simulators and manual IP connect).
  - **Bluetooth LE (GATT)**: CoreBluetooth peripheral service (`C40C11F7-0001-4A11-9B2E-43484F434C49`) on `ChocliftMac` with GATT metadata characteristic (`macID`, `macName`, `protocolVersion`) and ATT MTU-aware streaming frame characteristic (`20`–`180` byte chunks, partial-header reassembly, notify backpressure flow control, and per-icon BLE streaming).
- **Cross-Link Token Roaming & Preference**:
  - Pairing once over **either** Wi-Fi or Bluetooth LE issues a persistent `authToken` valid on **both** links — no second PIN or separate pairing format is ever needed.
  - When both links are reachable, companions prefer low-latency **Wi-Fi (TCP)** and automatically fall back to **Bluetooth LE** when off the same Wi-Fi (or if Wi-Fi drops).
  - Active link badges (`Wi-Fi` vs `BLE`) are shown live in the Mac pairing popover & device manager, iPhone Touch Bar rail & connection sheet, iPad header pill, and Apple Watch toolbar pill & pairing screen.
- **Multi-Device Simultaneous Sync**: Connect an iPhone, an iPad, and an Apple Watch to your Mac at the same time (even mixing Wi-Fi and Bluetooth LE companions) with live bidirectional profile synchronization.
- **Native Resizable iPad Workspace**: Dedicated multi-panel layout on iPad displaying the Chocolate Bar, persistent App Time Travel dock strip, Emoji Bar, and Gesture Pad together.

---

## Project Structure

```text
choclift/
├── project.yml                         # XcodeGen multi-platform spec (macOS 14+, iOS 17+, watchOS 10+)
├── Choclift.xcodeproj                  # Generated Xcode project (ChocliftMac, ChocliftIOS, ChocliftWatch)
├── Packages/
│   └── ChocliftCore/                   # Shared models, length-prefixed TCP wire protocol, networking & theme
├── Apps/
│   ├── ChocliftMac/                    # macOS Studio + MenuBarExtra + AX Window/Emoji/Shortcuts/Browser services
│   ├── ChocliftIOS/                    # iPhone Touch Bar + Resizable iPad Dashboard + Multi-Touch Gesture Engine (embeds ChocliftWatch)
│   └── ChocliftWatch/                  # Native watchOS companion (Chocolate Bar pages, Quick Actions, Time Travel & Emoji Bar)
└── Scripts/
    └── generate_icons.swift            # Programmatic CoreGraphics/CoreText brand AppIcon generator
```

---

## How to Pair Over Wi-Fi vs. Bluetooth LE

### Pairing Over Wi-Fi (Same Local Network or Simulator)
1. Launch **`ChocliftMac`** on your Mac. Click the top-right **Pair PIN** pill (or menu bar icon) to confirm **`Wi-Fi Ready`** and view the 6-digit PIN.
2. Open **`ChocliftIOS`** (iPhone/iPad) or **`ChocliftWatch`** (Apple Watch) on the same Wi-Fi network:
   - **Physical Device on Same Wi-Fi**: Tap your Mac under **Macs on Local Wi-Fi** (Bonjour `_choclift._tcp`) or enter `<Mac-LAN-IP>:54821` under **Direct IP**.
   - **iOS / watchOS Simulator on Same Mac**: Tap **Connect 127.0.0.1** (`127.0.0.1:54821`).
3. Enter the 6-digit PIN shown on your Mac once. The connection header displays **`Wi-Fi`** (`Wi-Fi (TCP)`), and future launches reconnect automatically.

### Pairing & Reconnecting Over Bluetooth LE (Off Wi-Fi)
1. Ensure Bluetooth is turned **On** on both your Mac and your physical iPhone, iPad, or Apple Watch, and grant Bluetooth permission when prompted (`ChocliftMac` shows **`Bluetooth Ready`** in the PIN popover).
2. When the companion device is **not** on the same Wi-Fi network as your Mac:
   - **Already paired previously (over Wi-Fi or Bluetooth)**: Simply open `choclift` — after checking Wi-Fi, it discovers your Mac over Bluetooth LE and **reconnects automatically** using the saved `authToken` (no PIN prompt).
   - **First-time pairing off Wi-Fi**: Open the Connection sheet (`Connect to Mac` / `Link Mac`), tap your Mac under **Macs over Bluetooth LE**, and enter the **same 6-digit PIN** shown on `ChocliftMac`.
3. Once connected, both the Mac device manager and the companion UI display **`BLE`** (`Bluetooth LE`) as the active link. You can also switch between discovered Wi-Fi and Bluetooth links manually from the connection sheet at any time.

### watchOS Bluetooth Notes & Platform Limitations
- **Bonjour Does Not Cross the iPhone Network Proxy (Bluetooth LE Is the Normal Watch Path)**: When an Apple Watch is paired to a nearby iPhone, watchOS routes general network traffic through the iPhone companion proxy, and multicast DNS / Bonjour (`_choclift._tcp`) does **not** traverse that proxy. Consequently, **Bluetooth LE (`CoreBluetooth`) is the normal connection path on Apple Watch hardware** (while Wi-Fi TCP works when the Watch is directly associated with local Wi-Fi, via manual LAN IP, or via `127.0.0.1:54821` in watchOS Simulator).
- **Supported Direct BLE Central Path**: watchOS 10+ provides `CBCentralManager` and `CBPeripheral` (while `CBPeripheralManager` peripheral advertising is unavailable on watchOS). Because `ChocliftMac` advertises as the BLE Peripheral (including a 32-bit `macID` tag UUID in its primary advertisement plus a GATT metadata characteristic) and `ChocliftWatch` scans/connects as a BLE Central, Apple Watch pairs and controls the Mac directly over Bluetooth LE without needing an iPhone relay.
- **Foreground Scanning & Wrist-Down Suspension**: watchOS restricts `CBCentralManager` scanning to when the watch app is in the foreground, caps simultaneous app-managed BLE central connections (up to 2 peripherals), and suspends/closes custom GATT links shortly after the wrist is lowered or the app moves to the background. `ChocliftWatch` observes `scenePhase == .active` to automatically re-scan and token-reconnect as soon as you raise your wrist.
- **Simulator Hardware Limitation**: Neither iOS Simulator nor watchOS Simulator exposes a CoreBluetooth radio (`CBManagerState.unsupported`); use **Connect 127.0.0.1** in Simulator and physical hardware for Bluetooth LE radio sessions.

---

## How to Run Each Target

### Prerequisites
- macOS 14.0+ with **Xcode 16+** installed at `/Applications/Xcode.app`.
- If regenerating `Choclift.xcodeproj` after editing `project.yml`, run:
  ```bash
  xcodegen generate
  ```

### 1. Run `ChocliftMac` (macOS Host & Studio)
1. Open `Choclift.xcodeproj` in Xcode, select the **`ChocliftMac`** scheme and **My Mac** destination, and press **Run (`⌘R`)**.
2. Grant **System Settings → Privacy & Security → Accessibility** when prompted to enable window management gestures and direct cursor Emoji typing.
3. Click the top-right **PIN pill** (or the `choclift` menu bar icon) to view your 6-digit pairing PIN and local IP/port (`54821` by default).

CLI build check:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Choclift.xcodeproj -scheme ChocliftMac -destination 'platform=macOS' build
```

### 2. Run `ChocliftIOS` (iPhone & iPad Companion)
1. In Xcode, select the **`ChocliftIOS`** scheme and choose a physical **iPhone / iPad** (on the same Wi-Fi as your Mac) or an **iOS Simulator** (e.g. `iPhone 17 Pro` or `iPad Pro`).
2. Press **Run (`⌘R`)** (building `ChocliftIOS` also builds and embeds the paired `ChocliftWatch` app bundle).
3. Tap your Bonjour-discovered Mac (or tap **Connect 127.0.0.1** when running in iOS Simulator on the same Mac) and enter the 6-digit PIN once. Subsequent launches reconnect automatically via the saved device token.

CLI simulator build check:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Choclift.xcodeproj -scheme ChocliftIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

### 3. Run `ChocliftWatch` (Apple Watch Companion)
1. Ensure **`ChocliftMac`** is running on your Mac so its TCP/Bonjour session is active.
2. In Xcode, select the **`ChocliftWatch`** scheme and choose an **Apple Watch** (on the same local network) or **watchOS Simulator** (e.g. `Apple Watch Series 11 (46mm)`), then press **Run (`⌘R`)**.
   - `ChocliftWatch` is configured with `WKCompanionAppBundleIdentifier = com.choclift.ios` and `WKRunsIndependentlyOfCompanionApp = true`, so it can be installed alongside the iPhone app or launched directly on a watchOS Simulator.
3. On the watch, tap the top-left **Pair Mac** pill (or **Connect 127.0.0.1** in the watchOS Simulator / your discovered Wi-Fi Mac on hardware) and enter the 6-digit PIN displayed on `ChocliftMac` using the on-watch numeric keypad.
4. Swipe horizontally (or tap the top-right mode icon) to switch between **Chocolate Bar** (8 synced pages), **Quick Actions** (Media, Volume, Window Layout, Workspace & Clipboard), **Time Travel**, and **Emoji Bar**, and use the Digital Crown to scroll.

CLI simulator build check:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Choclift.xcodeproj -scheme ChocliftWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' build
```

---

## Running Shared Package & Loopback / BLE Chunking Tests

`ChocliftCore` includes unit and integration tests covering profile normalization, TCP stream framing, 20-byte BLE ATT MTU chunking, 1–3 byte partial header splits, BLE notify backpressure (`updateValue` pause/resume), live TCP loopback (`127.0.0.1`) multi-device pairing (`iPhone`, `iPad`, `Apple Watch`), BLE disconnect + saved-token auto-reconnect, and Wi-Fi ↔ Bluetooth LE cross-link roaming with a single PIN/token (note: automated tests use `SimulatedBLECompanionPipe` rather than physical Bluetooth hardware):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --disable-sandbox \
  --package-path Packages/ChocliftCore \
  --scratch-path /tmp/chocliftcore-build \
  --cache-path /tmp/swiftpm-cache
```
