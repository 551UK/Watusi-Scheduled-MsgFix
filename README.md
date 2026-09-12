# Watusi Scheduled Message Fix

For iOS 16 rootless jailbreaks, Watusi 1.3.23 and WatusiTools 2.8.4.

New one-off schedules stay active and pending until Watusi confirms sending for every recipient. Missing the scheduled time does not expire them. Once an outgoing message has been identified, retries reuse that message instead of creating another copy.

Install the deb, let Sileo finish, then reboot and re-jailbreak. Open WhatsApp once and create a new schedule at least a minute ahead. Existing overdue schedules must be rescheduled because their past delivery is unknown. Repeating schedules continue using Watusi's original behaviour.

This is a test build. If WhatsApp does not expose the outgoing message identity, the schedule stays pending rather than risking a duplicate. Internet access and a running jailbreak are still required; confirmed sending is not a read receipt.
