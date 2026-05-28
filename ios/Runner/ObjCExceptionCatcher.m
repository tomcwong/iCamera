#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)setExposureModeCustom:(AVCaptureDevice *)device
                     duration:(CMTime)duration
                          iso:(float)iso
            completionHandler:(nullable void (^)(CMTime syncTime))handler {
    @try {
        [device setExposureModeCustomWithDuration:duration ISO:iso completionHandler:handler];
        return YES;
    }
    @catch (NSException *exception) {
        NSLog(@"[iCamera] setExposureModeCustom NSException: %@ — %@",
              exception.name, exception.reason);
        return NO;
    }
}

@end
