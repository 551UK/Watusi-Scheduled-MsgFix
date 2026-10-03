# Watusi Scheduled Message Fix

Built on Watusi 3 1.3.22 but should work from this version and upwards.

Fixes Watusi scheduled messages on iOS 16 rootless for both WhatsApp and WhatsApp Business.

Messages send with either app closed, and overdue messages wait for internet then send automatically.

WhatsApp Business schedules are resolved against the Business schedule store so they use the same immediate send path as normal WhatsApp.
