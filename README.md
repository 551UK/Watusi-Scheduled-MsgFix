# Watusi Scheduled Message Fix

For iOS 16 rootless, Watusi 1.3.23 and WatusiTools 2.8.4.

1.0.15 restores Watusi's original first-send routine and delays overdue processing during startup. It adds exception handling and an interrupted-attempt guard to prevent repeated launch failures.

New one-off schedules stay pending until sending is confirmed. Repeating schedules use Watusi's original behaviour. Missing message identity leaves a schedule pending to avoid duplicate sends.

Install, let Sileo finish, then reboot and re-jailbreak. Open WhatsApp and create a fresh schedule at least a minute ahead. Do not reuse a failed 1.0.14 schedule: its sending state may be uncertain. This build still needs phone testing.

If a schedule stays pending, the tweak now keeps its own recent diagnostic events in WhatsApp's Library/Caches/com.551.watusischeduledmsgfix-send.plist. No message text is logged.
