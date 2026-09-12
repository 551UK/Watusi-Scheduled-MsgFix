#include <assert.h>
#include "../DeliveryPolicy.h"
int main(void) {
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
