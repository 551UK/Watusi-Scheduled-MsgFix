# Watusi Scheduled Message Fix

Fixes Watusi scheduled messages on iOS 16 rootless.

Watusi stays as the scheduler. Due direct messages are sent through iOS Shortcuts' WhatsApp background messaging path. If there is no internet, the send stays pending and retries when the connection comes back instead of being lost or queued inside WhatsApp.
