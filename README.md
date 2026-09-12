# Watusi Scheduled Message Fix

For iOS 16 rootless, Watusi 1.3.23 and WatusiTools 2.8.4.

1.0.16 removes the direct WhatsApp injection that stopped the app opening in 1.0.15. It restores the proven SpringBoard schedule scan and routes both Watusi's native trigger and the fallback through one shared handoff so the same schedule is only posted once.

Install the deb, let Sileo finish, then userspace reboot or reboot/re-jailbreak. Open WhatsApp once and create a fresh schedule at least a minute ahead.
