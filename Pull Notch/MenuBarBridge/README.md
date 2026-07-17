# MenuBarBridge

MenuBarBridge is the first Pull Notch integration point for an Ice/Bartender style menu bar experience.

## Goal

Pull Notch should show menu bar extras inside the notch panel without trying to move another app's `NSStatusItem` into our view hierarchy. macOS does not provide a public API for re-parenting third-party status items, so this bridge mirrors visible menu bar items and forwards activation back to the original Accessibility element.

## Initial shape

- `AXMenuBarScanner` reads menu bar-like Accessibility elements from `SystemUIServer` and accessory apps.
- `MenuBarItemSnapshot` converts those elements into a stable UI model for Pull Notch.
- `MenuBarBridgeController` owns refresh, permission state, and activation forwarding.
- `NotchMenuBarView` renders the mirrored items in a notch-friendly horizontal strip.

## Ice relationship

Ice remains the best reference implementation for menu bar hiding and layout behavior. This PR intentionally starts with a small bridge layer rather than vendoring Ice directly, so Pull Notch can keep its own UI and adopt Ice-like behavior gradually.

Future work can port the hiding/layout pieces after this bridge is wired into the expanded notch page.

## Follow-up wiring

1. Add a `menuBar` built-in expanded page.
2. Keep a `MenuBarBridgeController` on `NotchOverlayModel` or `AppDelegate`.
3. Start auto-refresh while the page is visible.
4. Render `NotchMenuBarView` from `ContentView`.
5. Add a settings toggle for MenuBarBridge.
