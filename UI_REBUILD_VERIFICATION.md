# Companion UI interaction rebuild

Base: `2e10ff4` (Choclift 1.0.14 / build 67). Changes are confined to this worktree.

## Surfaces changed

- **iPhone / iPad main workspace:** source-initial now-playing hero, title/artist/source, previous/play-pause/next targets, native seek slider with one release commit, labeled volume and brightness with live percentages, audio-output/reconnect/More row, and pairing/retry card when disconnected. Portrait, landscape and iPad share the new hierarchy. App tiles remain a separate region below the controls; only the tile pager owns page swipes. Empty slots show Add and retain tap-to-add and hold-to-edit.
- **More:** calendar/capture, power/security, desktop/windows, cleanup/disks, display/microphone/window undo, and editing/recents sections. Existing pinned controls and status details remain reachable. Secondary pill targets and sliders were enlarged to at least 44 points.
- **Pairing:** iPhone/iPad and Watch use one PIN field and an explicit Connect action. Link status stays visible; iOS advanced connection options and haptics are disclosures. Discovery and existing connection policies remain intact.
- **Slot editor:** selecting an action opens name/icon review before saving. Shortcut execution names and reference identities stay protected. Clear requires a second tap within three seconds.
- **Flows on iOS:** explicit 44-point Run action, larger list rows and More target, and two-tap flow deletion. Existing creation/templates, placement, editing and step ordering remain reachable.
- **Search:** one field, a scope-choice picker menu, and existing result rows that execute only on tap. The clear target is 44 points.
- **Soundboard, Emoji, snippets and clipboard on iOS:** existing separate surfaces remain reachable through the mode dock and Emoji segments; secondary controls, snippet creation and segment targets were enlarged. Their existing libraries, search, editing and execution paths remain intact.
- **Mac Bar:** compact player and release-committed volume above the canvas, one quiet keep-awake/audio/battery/Wi-Fi row, selected tile outline, double-click/context edit, existing drag reorder, and two-tap slot/page clearing.
- **Mac navigation / Settings:** five sidebar destinations: Bar, Flows, Soundboard, Emoji and Settings. Recents and gesture configuration remain accessible from Settings. Settings retains pairing, devices, audio-output selection and software updates, with no duplicate player.
- **Mac Flows:** larger vertical step rows and confirmation gates for flow and step deletion.
- **Mac Soundboard:** larger Play targets and release-committed volume with a live percentage; sound removal confirms on a second tap.
- **Mac Emoji:** search above larger insertion targets; assignment to the selected slot remains available through the context action and custom input.
- **Mac menu bar:** current page name, five large media/volume actions and a Studio link.
- **Mac notch:** current page tiles plus a single-line now-playing title, with no slider copy.
- **Watch current page / player / quick actions:** current page and crown volume retained, tappable track row opens a dedicated transport/seek player, and secondary remote actions are full-width rows on a separate navigation screen. Crown volume is throttled to 400 ms. Audio output remains a list.
- **Shared feedback:** existing button style now provides immediate press scaling. Hold repeat is restricted to volume and media next with a 400 ms initial hold and repeat interval. Level drags on the rebuilt surfaces and seek sliders commit on release.

## Verification

All commands used `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

| Check | Result |
| --- | --- |
| `swift test --disable-sandbox --package-path Packages/ChocliftCore` | 138 tests passed, zero failures |
| `xcodebuild -project Choclift.xcodeproj -scheme ChocliftMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | Passed |
| `xcodebuild -project Choclift.xcodeproj -scheme ChocliftIOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` | Passed |
| `xcodebuild -project Choclift.xcodeproj -scheme ChocliftWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build` | Passed |
| `git diff --check` | Passed |

Build logs are `/tmp/choclift-{ios,mac,watch}-build.log`; test log is `/tmp/choclift-core-tests.log`. Build commands used isolated derived-data directories under `/tmp/choclift-mobbin-*`.

## Visual verification limitation

The desktop session reported `CGSSessionScreenIsLocked=Yes`. Simulator observation returned `window_not_found`, including one restore attempt. Connected hero, disconnected card, tile-page and More screenshots were therefore **not captured**, and no visual/runtime interaction proof is claimed. An iPhone simulator briefly booted during availability checks was returned to its original shutdown state. On-device layout, pairing and drag/tap behavior still need an unlocked interactive review.

No Mobbin images, external artwork, new palette hex colors, new fonts, protocol changes, pairing-crypto changes, Bluetooth-policy changes or Sparkle-feed changes were introduced. No push, PR, tag or merge was performed.

## Content height and typography follow-up (1.0.15 base)

- Removed the portrait/wide workspace's 310/300-point minimum. The tile pager owns its drag gesture and derives its height from the visible tile rows (84-point tiles, 12-point row spacing, 10-point top/bottom padding). Trailing unused rows are omitted while one Add slot remains available; a fully empty page is one full-width 44-point Add button. The mode dock remains the next element in the existing 16-point stack.
- Removed the Mac Bar preview's vertical expansion and its side rail's empty spacer. The notch card wraps its controls inside the existing native window/shadow bounds, aligned to the top. Watch crown volume follows the tile grid inside its scroll content instead of sitting in a bottom safe-area inset. Remaining surface spacers separate actual horizontal controls or position tile overlays.
- Added `ChocType.title` (17 semibold), `body` (15 regular), `caption` (13 medium), and `micro` (11 medium), all system rounded. Companion surfaces and their editors, pairing, search, flow and auxiliary sheets use these roles. Primary body buttons may use semibold. Shared tile labels use micro, allowing 9–11 points only when the tile side is below 44 points. Removed text scale-down modifiers that could violate these floors. Proportional tile icon/emoji drawing and ChocPalette remain intact.
- Core: 138 tests passed, zero failures. Unsigned macOS, iOS Simulator, and watchOS Simulator builds passed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; logs are `/tmp/choclift-type-gap-{mac,ios,watch}.log` and `/tmp/choclift-type-gap-tests.log`. `git diff --check` passed.
- Visual verification remains blocked by `CGSSessionScreenIsLocked=Yes`. No iPhone screenshot or runtime layout confirmation is claimed; an unlocked-device visual check remains outstanding.
