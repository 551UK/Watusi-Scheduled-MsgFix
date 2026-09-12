# Watusi Scheduled Message Fix

For iOS 16 rootless, Watusi 1.3.23 and WatusiTools 2.8.4.

1.0.17 goes back to the proven 1.0.10 scheduler/send path. It calls Watusi's own scheduler helper so Watusi performs its normal rootless handoff, then blocks only a second identical final handoff for a few seconds to prevent the double message.

It does not inject into WhatsApp.

Install the deb, let Sileo finish, then userspace reboot or reboot/re-jailbreak. Open WhatsApp once and create a fresh schedule at least a minute ahead.
