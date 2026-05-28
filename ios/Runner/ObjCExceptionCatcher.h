#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps AVCaptureDevice.setExposureModeCustom in @try/@catch so that
/// NSExceptions thrown by iOS 26 virtual-device sessions are caught safely
/// instead of crashing the app (Swift do-catch does not catch NSExceptions).
@interface ObjCExceptionCatcher : NSObject

/// Calls [device setExposureModeCustomWithDuration:ISO:completionHandler:]
/// inside @try/@catch.
/// Returns YES if the call succeeded (no exception); NO if an exception was raised.
/// On NO the completionHandler will never fire — caller must handle that case.
+ (BOOL)setExposureModeCustom:(AVCaptureDevice *)device
                     duration:(CMTime)duration
                          iso:(float)iso
            completionHandler:(nullable void (^)(CMTime syncTime))handler;

@end

NS_ASSUME_NONNULL_END
