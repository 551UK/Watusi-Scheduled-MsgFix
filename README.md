# Watusi Scheduled Message Fix

Rootless companion tweak for Watusi 3 on iOS 16.

## v1.0.2

This version no longer relies on the iOS notification-dispatch path. SpringBoard reads Watusi's saved schedule store, watches each schedule ID and date, and at the due time calls Watusi's own scheduler helper directly. If that helper is unavailable, the tweak falls back to Watusi's existing running-schedule plist and Darwin notification bridge.

The callservicesd launch safeguard from earlier builds is also retained.

Diagnostics are written to:

`/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist`

No message text or recipient names are logged.

## Target setup

- iOS 16.2
- Dopamine rootless
- WhatsApp 26.32.75
- Watusi 3 1.3.23
- WatusiTools 2.8.4
