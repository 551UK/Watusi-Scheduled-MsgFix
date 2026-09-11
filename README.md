# Watusi Scheduled Message Fix

A rootless companion tweak for **Watusi 3** that targets scheduled messages failing to send when WhatsApp is closed or the device is locked.

## The iOS 16 problem

Watusi schedules a normal iOS local notification containing `WatusiMessageScheduleID`. On older notification paths, Watusi catches that notification in SpringBoard and converts it into its fake WhatsApp VoIP push, which wakes WhatsApp and processes the scheduled message.

On the iOS 16 notification path used by `CSNotificationDispatcher` / `SBDashBoardNotificationDispatcher`, Watusi handles notification images but does not run its scheduled-message bridge. The scheduled time therefore passes without the message being processed, and Watusi later shows **Schedule date has passed**.

## v1.0.1

- Adds the missing iOS 16 SpringBoard scheduled-notification bridge.
- Reads the Watusi schedule ID from the due notification.
- Reuses Watusi's existing `running-schedule-info.plist` + Darwin notification + `callservicesd` VoIP-push path.
- Keeps the v1.0.0 WhatsApp launch-prevention safeguard as a secondary fix.
- Prevents duplicate forwarding if both modern notification dispatchers see the same schedule.
- Writes a small diagnostics file at `/var/mobile/Library/Preferences/com.551.watusischeduledmsgfix-debug.plist` containing only hook/status information, not message text.

## Target setup

- iOS 16.2
- Dopamine rootless
- WhatsApp 26.32.75
- Watusi 3 1.3.23
- WatusiTools 2.8.4

Install the package and test a scheduled message with WhatsApp fully closed and the phone locked. The package reloads SpringBoard and `callservicesd` after installation.
