// Original GPL-3.0-or-later implementation. Private SPI names documented by Chromium;
// see ../README.md. No proprietary binary/code reuse.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <math.h>
#import <string.h>

static BOOL has(Class cls, NSString *selector) {
    return cls && [cls instancesRespondToSelector:NSSelectorFromString(selector)];
}
BOOL ODVirtualDisplayAvailable(void) {
    NSDictionary *requirements = @{
        @"CGVirtualDisplayDescriptor": @[@"init", @"setQueue:", @"setName:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:", @"setSizeInMillimeters:", @"setWhitePoint:", @"setRedPrimary:", @"setGreenPrimary:", @"setBluePrimary:", @"setSerialNum:", @"setVendorID:", @"setProductID:"],
        @"CGVirtualDisplaySettings": @[@"init", @"setHiDPI:", @"setModes:"],
        @"CGVirtualDisplayMode": @[@"initWithWidth:height:refreshRate:"],
        @"CGVirtualDisplay": @[@"initWithDescriptor:", @"applySettings:", @"displayID"]
    };
    for (NSString *name in requirements) {
        for (NSString *selector in requirements[name]) {
            if (!has(NSClassFromString(name), selector)) return NO;
        }
    }
    return YES;
}
// Returns a retained runtime object; its lifetime owns the virtual endpoint.
CFTypeRef ODVirtualDisplayCreate(const char *name, uint32_t width, uint32_t height,
                                double refresh, uint32_t serial, BOOL hidpi) {
    // Refuse corrupt direct bridge calls before touching WindowServer.
    if (!name || !name[0] || strlen(name) > 128 || width < 640 || width > 8192 || height < 480 || height > 8192 ||
        !isfinite(refresh) || refresh < 24 || refresh > 120 || serial == 0 ||
        (hidpi && ((width % 2) || (height % 2)))) return NULL;
    NSString *displayName = [NSString stringWithUTF8String:name];
    if (!displayName || [[displayName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length] == 0) return NULL;
    if (!ODVirtualDisplayAvailable()) return NULL;
    @try {
        id descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        [descriptor setValue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0) forKey:@"queue"];
        [descriptor setValue:displayName forKey:@"name"];
        // Standard sRGB chromaticities and D65 white, independent of any physical display.
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.3127, 0.3290)] forKey:@"whitePoint"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.64, 0.33)] forKey:@"redPrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.30, 0.60)] forKey:@"greenPrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.15, 0.06)] forKey:@"bluePrimary"];
        [descriptor setValue:@(width) forKey:@"maxPixelsWide"];
        [descriptor setValue:@(height) forKey:@"maxPixelsHigh"];
        [descriptor setValue:[NSValue valueWithSize:NSMakeSize(width * 25.4 / 110, height * 25.4 / 110)] forKey:@"sizeInMillimeters"];
        [descriptor setValue:@(serial) forKey:@"serialNum"];
        if (has([descriptor class], @"setSerialNumber:")) [descriptor setValue:@(serial) forKey:@"serialNumber"];
        [descriptor setValue:@(0x4f44) forKey:@"vendorID"];
        [descriptor setValue:@(1) forKey:@"productID"];
        id display = ((id (*)(id, SEL, id))objc_msgSend)([NSClassFromString(@"CGVirtualDisplay") alloc], NSSelectorFromString(@"initWithDescriptor:"), descriptor);
        if (!display) return NULL;
        id mode = ((id (*)(id, SEL, unsigned int, unsigned int, double))objc_msgSend)([NSClassFromString(@"CGVirtualDisplayMode") alloc], NSSelectorFromString(@"initWithWidth:height:refreshRate:"), hidpi ? width / 2 : width, hidpi ? height / 2 : height, refresh);
        if (!mode) return NULL;
        id settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        [settings setValue:@(hidpi ? 1 : 0) forKey:@"hiDPI"];
        [settings setValue:@[mode] forKey:@"modes"];
        if (!((BOOL (*)(id, SEL, id))objc_msgSend)(display, NSSelectorFromString(@"applySettings:"), settings)) return NULL;
        return CFBridgingRetain(display);
    } @catch (NSException *exception) { return NULL; }
}
uint32_t ODVirtualDisplayID(CFTypeRef handle) {
    if (!handle) return 0;
    return ((unsigned int (*)(id, SEL))objc_msgSend)((__bridge id)handle, NSSelectorFromString(@"displayID"));
}
void ODVirtualDisplayRelease(CFTypeRef handle) { if (handle) CFRelease(handle); }
