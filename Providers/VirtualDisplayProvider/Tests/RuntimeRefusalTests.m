// No valid creation request is issued: all calls must fail before WindowServer SPI.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <assert.h>
#import <math.h>
extern CFTypeRef ODVirtualDisplayCreate(const char *, uint32_t, uint32_t, double, uint32_t, BOOL);
extern BOOL ODVirtualDisplayAvailable(void);
extern uint32_t ODVirtualDisplayID(CFTypeRef);
extern void ODVirtualDisplayRelease(CFTypeRef);
@interface ODTestEndpoint : NSObject
- (unsigned int)displayID;
@end
@implementation ODTestEndpoint
- (unsigned int)displayID { return 42; }
@end
int main(void) {
    @autoreleasepool {
        assert(ODVirtualDisplayAvailable() == ODVirtualDisplayAvailable());
        assert(ODVirtualDisplayID(NULL) == 0);
        CFTypeRef fake = CFBridgingRetain([ODTestEndpoint new]);
        assert(ODVirtualDisplayID(fake) == 42);
        ODVirtualDisplayRelease(fake);
        ODVirtualDisplayRelease(NULL);
        assert(ODVirtualDisplayCreate(NULL, 1920, 1080, 60, 1, NO) == NULL);
        assert(ODVirtualDisplayCreate("", 1920, 1080, 60, 1, NO) == NULL);
        assert(ODVirtualDisplayCreate("   ", 1920, 1080, 60, 1, NO) == NULL);
        char longName[130]; memset(longName, 'A', 129); longName[129] = 0;
        assert(ODVirtualDisplayCreate(longName, 1920, 1080, 60, 1, NO) == NULL);
        assert(ODVirtualDisplayCreate("Invalid", 0, 1080, 60, 1, NO) == NULL);
        assert(ODVirtualDisplayCreate("Invalid", 1920, 9000, 60, 1, NO) == NULL);
        assert(ODVirtualDisplayCreate("Invalid", 1920, 1080, NAN, 1, NO) == NULL);
        assert(ODVirtualDisplayCreate("Invalid", 1920, 1080, INFINITY, 1, NO) == NULL);
        assert(ODVirtualDisplayCreate("Invalid", 1920, 1080, 23, 1, NO) == NULL);
        assert(ODVirtualDisplayCreate("Invalid", 1920, 1080, 121, 1, NO) == NULL);
        assert(ODVirtualDisplayCreate("Invalid", 1920, 1080, 60, 0, NO) == NULL);
        assert(ODVirtualDisplayCreate("Invalid", 1921, 1080, 60, 1, YES) == NULL);
        assert(ODVirtualDisplayCreate("Invalid", 1920, 1081, 60, 1, YES) == NULL);
    }
    puts("16 virtual bridge probe/ID/refusal checks passed; no valid display creation requested.");
    return 0;
}
