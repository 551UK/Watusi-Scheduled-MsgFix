#include <assert.h>
#include "../DeliveryPolicy.h"
int main(void) {
    assert(!WSMFCanStart(1,1,0)); /* due during startup: defer */
    assert(WSMFCanStart(1,1,1));
    assert(!WSMFCanStart(0,1,1)); /* retry must not create a new message */
    assert(!WSMFCanStart(1,0,1)); /* interrupted attempt cannot loop */
    assert(WSMFDeliveryAction(0,0,0)==WSMFCreate);
    assert(WSMFDeliveryAction(1,0,0)==WSMFWait);
    assert(WSMFDeliveryAction(1,1,0)==WSMFRetry);
    assert(WSMFDeliveryAction(1,1,1)==WSMFConfirm);
    // Losing internet, elapsed time and reboot never authorize a new send
    // after submission. Only a known message can be retried or confirmed.
    for (int elapsed=0; elapsed<100000; elapsed++) {
        assert(WSMFDeliveryAction(1,1,0)==WSMFRetry);
        assert(WSMFDeliveryAction(1,0,0)==WSMFWait);
    }
    return 0;
}
