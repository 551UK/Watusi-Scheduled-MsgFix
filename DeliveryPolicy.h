#ifndef WSMF_DELIVERY_POLICY_H
#define WSMF_DELIVERY_POLICY_H
// Shared by the device outbox and the host regression tests.
typedef enum { WSMFWait, WSMFCreate, WSMFRetry, WSMFConfirm } WSMFAction;
static inline WSMFAction WSMFDeliveryAction(int submitted, int knownMessage, int sent) {
    if (knownMessage && sent) return WSMFConfirm;
    if (knownMessage) return WSMFRetry;
    // A crash between submission and capturing identity is ambiguous.
    // Keep pending rather than creating another message.
    if (submitted) return WSMFWait;
    return WSMFCreate;
}
static inline int WSMFCanStart(int initialAttempt, int notBlocked, int startupReady) {
    return initialAttempt && notBlocked && startupReady;
}
#endif
