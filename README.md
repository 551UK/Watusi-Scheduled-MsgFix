# Watusi Scheduled Message Fix

For iOS 16 rootless with Watusi 1.3.23.

2.0.0 is a clean rewrite. It does not scan schedule dates or send messages itself. It passes iOS 16 scheduled WhatsApp notifications back into Watusi's own scheduler and only fixes the system launch block needed when WhatsApp is closed or locked.

No WhatsApp injection and no custom outbox.
