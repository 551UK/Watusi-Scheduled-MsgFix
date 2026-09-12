# 1.0.14 evidence and limits

Inspected the supplied Watusi 1.3.23 and WatusiTools 2.8.4 binaries.

- WatusiSB `sendCallKitNotificationWithUserInfo:bundleIdentifier:` at 0x712c writes a rootless-prefixed handoff and silently returns when writing fails. The receiver accepts the normal mobile preferences path.
- `WSSchedule isActive` at 0x5f4cc checks repetition or a future date, recipients and message content. It is not a delivery check.
- `WSScheduleHandler sendSchedule:retryJIDs:timesSent:completion:` at 0x5b3e0 creates messages only on the initial attempt, retries the chat's last message on later calls, and stops after its counter passes 100. Signature: v48@0:8@16@24q32@?40.
- `messageSent:` at 0x5ba4c accepts statuses 1, 6 and 8. This build calls Watusi's own predicate instead of redefining those values.
- FRWhatsApp's text helper dispatches actual message creation asynchronously to the main queue.

The new outbox registers future one-off schedules and stores state in WhatsApp's preferences container. SpringBoard reads pending IDs and asks for a wake once per minute until the row is confirmed. It never marks delivery based on a helper return or timer expiry. The WhatsApp-side isActive override is limited to registered occurrences.

Before the first send, submission intent is persisted. A Core Data save observer associates a newly inserted outgoing object by chat session and text and saves its permanent object URI. Retries resolve that exact object and call retrySendingMessage:. Every recipient must satisfy Watusi's send-status predicate before the schedule completes. The schedule manager save/delete hooks register new occurrences immediately and remove cancelled or rescheduled occurrences. Empty manager state during app startup never erases pending records.

Limitations: runtime compatibility of WhatsApp's managed message objects and chatSession relation has not been verified on the device. A missing/ambiguous identity or crash between submission and identity capture leaves the occurrence pending without blindly recreating it. Identical manually sent text during the same insertion interval can make matching ambiguous; this is not an exactly-once delivery guarantee. Existing overdue schedules are not imported, to avoid replaying already delivered messages. Repeating schedules remain on Watusi's native implementation.

Regression tests execute the shared delivery decision function. CI compiles all three rootless injection components. Required device validation: fresh one-off schedule, locked/app-closed delivery, offline over five minutes then reconnect, multiple recipients, respring while queued, deletion, identical-text concurrent messages, and normal foreground sending.
