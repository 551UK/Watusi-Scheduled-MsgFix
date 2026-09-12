# Watusi Scheduled Message Fix

Fixes Watusi scheduled messages on iOS 16 rootless.

Watusi stays as the scheduler. Due direct messages are sent through iOS Shortcuts' WhatsApp background messaging path, with pending sends kept and retried instead of being dropped after the scheduled minute.
