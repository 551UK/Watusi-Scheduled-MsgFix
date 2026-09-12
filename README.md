# Watusi Scheduled Message Fix

For iOS 16 rootless with Watusi 1.3.23.

3.0.0 is a fresh rewrite. It repairs Watusi's old SpringBoard scheduled-notification trigger on iOS 16 and then leaves Watusi's own wake, send, retry and delivery logic alone.

No custom sender, no schedule polling, no outbox, no callservicesd override and no WhatsApp injection.
