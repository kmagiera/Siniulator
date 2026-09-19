#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

NS_ASSUME_NONNULL_BEGIN

// Returns an empty list on timeout. Late completions must not race the reader.
FOUNDATION_EXPORT NSArray *SIEnumerateScreens(id adapter, NSTimeInterval timeout);

// Only the dynamic private-API and NSException boundary lives in Objective-C.
// No private framework is linked at build time.
@interface SICoreSimulator : NSObject
- (nullable instancetype)initWithDeveloperDirectory:(NSString *)path error:(NSError **)error;
- (nullable id)deviceWithUDID:(NSString *)udid error:(NSError **)error;
- (uint32_t)lookupService:(NSString *)service device:(id)device error:(NSError **)error;
- (BOOL)postNotification:(NSString *)name device:(id)device error:(NSError **)error;
- (nullable NSNumber *)notificationState:(NSString *)name device:(id)device error:(NSError **)error;
- (BOOL)setNotificationState:(uint64_t)state name:(NSString *)name device:(id)device error:(NSError **)error;
- (BOOL)setHardwareKeyboardEnabled:(BOOL)enabled device:(id)device error:(NSError **)error;
@end

// Owns a separate service context so invalidation handling cannot affect display clients.
@interface SIDeviceMonitor : NSObject
- (nullable instancetype)initWithDeveloperDirectory:(NSString *)path
                                     changeHandler:(void (NS_SWIFT_SENDABLE ^)(void))changeHandler
                               invalidationHandler:(void (NS_SWIFT_SENDABLE ^)(NSString *))invalidationHandler
                                             error:(NSError **)error;
- (void)stop;
@end

@interface SIDisplay : NSObject
@property (nullable, readonly) id surface;
- (nullable instancetype)initWithDevice:(id)device error:(NSError **)error;
- (nullable instancetype)initWithDevice:(id)device screenID:(uint32_t)screenID width:(uint32_t)width height:(uint32_t)height error:(NSError **)error;
// Frame delivery occurs on the display queue, not the caller's actor.
- (BOOL)startWithFrameHandler:(void (NS_SWIFT_SENDABLE ^)(void))handler error:(NSError **)error;
- (void)stop;
@end

@interface SILegacyInput : NSObject
- (nullable instancetype)initWithDevice:(id)device error:(NSError **)error;
- (void)sendButton:(int32_t)source down:(BOOL)down completion:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))completion;
- (void)sendKey:(uint32_t)usage down:(BOOL)down completion:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))completion;
- (void)sendConsumerUsage:(uint32_t)usage down:(BOOL)down completion:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))completion;
- (void)sendTouch:(CGPoint)point phase:(NSUInteger)phase edge:(uint32_t)edge secondPoint:(nullable NSValue *)second completion:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))completion;
@end

NS_ASSUME_NONNULL_END
