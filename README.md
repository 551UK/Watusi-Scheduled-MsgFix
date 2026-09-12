# Watusi Scheduled Message Fix

Helps Watusi trigger scheduled messages while WhatsApp is closed or your phone is locked. For iOS 16 rootless jailbreaks.

Version 1.0.14 fixes the wake-up file path and prevents two simultaneous triggers from creating two messages. Watusi's normal message retries remain enabled.

Install the deb, let Sileo finish, then reboot and re-jailbreak so WhatsApp, SpringBoard and callservicesd all load the new version. Open WhatsApp once and create a new schedule a few minutes ahead. Test with the phone locked.

Built against Watusi 1.3.23 / WatusiTools 2.8.4. Actual sending still needs testing on the phone. An “Inactive” schedule only means its scheduled date has passed; it is not a delivery confirmation.
