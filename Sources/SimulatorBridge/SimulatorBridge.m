#import "SimulatorBridge.h"
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach.h>

@protocol SIContext <NSObject>
+ (id)sharedServiceContextForDeveloperDir:(NSString *)path error:(NSError **)error;
- (id)initWithDeveloperDir:(NSString *)path connectionType:(NSInteger)type error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
- (void)setConnectionInvalidationHandler:(void (^ _Nullable)(NSString *))handler;
- (BOOL)valid;
@end
@protocol SIDeviceSet <NSObject>
- (NSDictionary *)devicesByUDID;
- (NSUInteger)registerNotificationHandlerOnQueue:(dispatch_queue_t)queue handler:(void (^)(NSDictionary *))handler;
- (BOOL)unregisterNotificationHandler:(NSUInteger)registrationID error:(NSError **)error;
@end
@protocol SIDevice <NSObject>
- (id)io;
- (mach_port_t)lookup:(NSString *)name error:(NSError **)error;
- (BOOL)postDarwinNotification:(NSString *)name error:(NSError **)error;
- (BOOL)darwinNotificationGetState:(uint64_t *)state name:(NSString *)name error:(NSError **)error;
- (BOOL)darwinNotificationSetState:(uint64_t)state name:(NSString *)name error:(NSError **)error;
- (BOOL)setHardwareKeyboardEnabled:(BOOL)enabled keyboardType:(unsigned char)keyboardType error:(NSError **)error;
@end
@protocol SIIO <NSObject>
- (NSArray *)ioPorts;
- (id)descriptor;
- (id)state;
- (unsigned int)displayClass;
- (unsigned int)defaultWidthForDisplay;
- (unsigned int)defaultHeightForDisplay;
@end
@protocol SIScreen <NSObject>
- (unsigned int)screenID;
- (id)framebufferSurface;
- (id)ioSurface;
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid callbackQueue:(dispatch_queue_t)queue frameCallback:(void (^)(void))frame surfacesChangedCallback:(void (^)(id, id))surfaces propertiesChangedCallback:(void (^)(id))properties;
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;
- (void)registerCallbackWithUUID:(NSUUID *)uuid ioSurfacesChangeCallback:(void (^)(id))block;
- (void)registerCallbackWithUUID:(NSUUID *)uuid ioSurfaceChangeCallback:(void (^)(id))block;
- (void)registerCallbackWithUUID:(NSUUID *)uuid damageRectanglesCallback:(void (^)(id))block;
- (void)unregisterIOSurfacesChangeCallbackWithUUID:(NSUUID *)uuid;
- (void)unregisterIOSurfaceChangeCallbackWithUUID:(NSUUID *)uuid;
- (void)unregisterDamageRectanglesCallbackWithUUID:(NSUUID *)uuid;
@end
@protocol SIScreenAdapter <NSObject>
- (void)enumerateScreensWithCompletionQueue:(dispatch_queue_t)queue completionHandler:(void (^)(NSArray *))handler;
@end
@protocol SIHIDClient <NSObject>
- (id)initWithDevice:(id)device error:(NSError **)error;
- (void)sendWithMessage:(void *)message freeWhenDone:(BOOL)freeWhenDone completionQueue:(dispatch_queue_t)queue completion:(void (^)(NSError *))completion;
@end

static NSError *SIError(NSString *message) {
    return [NSError errorWithDomain:@"Siniulator.PrivateAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}
static void SIException(NSError **error, NSException *exception) {
    if (error) *error = SIError([NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]);
}
static void *SIKit;

NSArray *SIEnumerateScreens(id adapter, NSTimeInterval timeout) {
    __block NSArray *screens = nil;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    [(id<SIScreenAdapter>)adapter enumerateScreensWithCompletionQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0) completionHandler:^(NSArray *value) {
        screens = value;
        dispatch_semaphore_signal(ready);
    }];
    // Only a successful wait establishes ordering with the callback's write.
    // On timeout the block owns the remaining storage; do not read it here.
    if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) return @[];
    return screens ?: @[];
}

static id SISurface(id<SIScreen> screen) {
    id surface = nil;
    @try { surface = [screen framebufferSurface]; } @catch (NSException *e) {}
    if (!surface) { @try { surface = [screen ioSurface]; } @catch (NSException *e) {} }
    return surface;
}

static uint64_t SISurfaceArea(id surface) {
    if (!surface || CFGetTypeID((__bridge CFTypeRef)surface) != IOSurfaceGetTypeID()) return 0;
    return (uint64_t)IOSurfaceGetWidth((__bridge IOSurfaceRef)surface)
        * (uint64_t)IOSurfaceGetHeight((__bridge IOSurfaceRef)surface);
}

static id<SIScreen> SIPreferredScreen(NSArray *screens, uint32_t desiredScreenID,
                                      uint32_t desiredWidth, uint32_t desiredHeight, id *selectedSurface) {
    id<SIScreen> selected = nil;
    uint64_t selectedArea = 0;
    for (id<SIScreen> screen in screens) {
        if (![screen conformsToProtocol:NSProtocolFromString(@"SimDisplayIOSurfaceRenderable")]) continue;
        id<SIIO> state = [(id<SIIO>)screen state];
        if ([state displayClass] != 0) continue;
        id surface = SISurface(screen);
        if (desiredScreenID != 0) {
            uint32_t screenID = 0;
            BOOL exposesScreenID = [screen respondsToSelector:@selector(screenID)];
            if (exposesScreenID) {
                @try { screenID = [screen screenID]; } @catch (NSException *e) { exposesScreenID = NO; }
            }
            BOOL matches = exposesScreenID && screenID == desiredScreenID;
            if (!matches && desiredWidth != 0 && desiredHeight != 0) {
                uint32_t width = 0, height = 0;
                @try {
                    width = [state defaultWidthForDisplay];
                    height = [state defaultHeightForDisplay];
                } @catch (NSException *e) {}
                matches = (width == desiredWidth && height == desiredHeight)
                    || (width == desiredHeight && height == desiredWidth);
                if (!matches && surface && CFGetTypeID((__bridge CFTypeRef)surface) == IOSurfaceGetTypeID()) {
                    size_t surfaceWidth = IOSurfaceGetWidth((__bridge IOSurfaceRef)surface);
                    size_t surfaceHeight = IOSurfaceGetHeight((__bridge IOSurfaceRef)surface);
                    matches = (surfaceWidth == desiredWidth && surfaceHeight == desiredHeight)
                        || (surfaceWidth == desiredHeight && surfaceHeight == desiredWidth);
                }
            }
            if (!matches) continue;
        }
        uint64_t area = SISurfaceArea(surface);
        if (!selected || area > selectedArea) {
            selected = screen;
            selectedArea = area;
            if (selectedSurface) *selectedSurface = surface;
        }
    }
    return selected;
}

@implementation SICoreSimulator {
    id _context;
    id _deviceSet;
}
- (instancetype)initWithDeveloperDirectory:(NSString *)path error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    @try {
        if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW | RTLD_GLOBAL)) {
            if (error) *error = SIError(@"Could not load CoreSimulator. Install and select Xcode.");
            return nil;
        }
        NSString *contents = [path stringByDeletingLastPathComponent];
        NSArray *candidates = @[
            [path stringByAppendingPathComponent:@"Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"],
            [contents stringByAppendingPathComponent:@"SharedFrameworks/SimulatorKit.framework/SimulatorKit"]
        ];
        for (NSString *candidate in candidates) {
            SIKit = dlopen(candidate.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
            if (SIKit) break;
        }
        Class contextClass = NSClassFromString(@"SimServiceContext");
        if (!contextClass) {
            if (error) *error = SIError(@"SimServiceContext is unavailable in this Xcode version.");
            return nil;
        }
        _context = [(id<SIContext>)contextClass sharedServiceContextForDeveloperDir:path error:error];
        _deviceSet = [(id<SIContext>)_context defaultDeviceSetWithError:error];
        if (!_deviceSet) return nil;
    } @catch (NSException *exception) { SIException(error, exception); return nil; }
    return self;
}
- (id)deviceWithUDID:(NSString *)udid error:(NSError **)error {
    @try {
        id device = [(id<SIDeviceSet>)_deviceSet devicesByUDID][[[NSUUID alloc] initWithUUIDString:udid]];
        if (!device && error) *error = SIError(@"The simulator no longer exists. Refresh the device list.");
        return device;
    } @catch (NSException *exception) { SIException(error, exception); return nil; }
}
- (uint32_t)lookupService:(NSString *)service device:(id)device error:(NSError **)error {
    @try { return [(id<SIDevice>)device lookup:service error:error]; }
    @catch (NSException *exception) { SIException(error, exception); return 0; }
}
- (BOOL)postNotification:(NSString *)name device:(id)device error:(NSError **)error {
    @try { return [(id<SIDevice>)device postDarwinNotification:name error:error]; }
    @catch (NSException *exception) { SIException(error, exception); return NO; }
}
- (BOOL)setHardwareKeyboardEnabled:(BOOL)enabled device:(id)device error:(NSError **)error {
    @try {
        if (![device respondsToSelector:@selector(setHardwareKeyboardEnabled:keyboardType:error:)]) {
            if (error) *error = SIError(@"This Xcode version cannot change the hardware keyboard connection.");
            return NO;
        }
        // Resolve the current Mac keyboard type when SimulatorKit provides it.
        uint32_t (*getKeyboardType)(void) = SIKit ? dlsym(SIKit, "IndigoHIDGetKeyboardType") : NULL;
        uint32_t type = getKeyboardType ? getKeyboardType() : 0;
        return [(id<SIDevice>)device setHardwareKeyboardEnabled:enabled keyboardType:(unsigned char)MIN(type, UINT8_MAX) error:error];
    } @catch (NSException *exception) { SIException(error, exception); return NO; }
}
- (NSNumber *)notificationState:(NSString *)name device:(id)device error:(NSError **)error {
    @try {
        if (![device respondsToSelector:@selector(darwinNotificationGetState:name:error:)]) {
            if (error) *error = SIError(@"This Xcode version cannot read simulator notification state.");
            return nil;
        }
        uint64_t state = 0;
        if (![(id<SIDevice>)device darwinNotificationGetState:&state name:name error:error]) return nil;
        return @(state);
    } @catch (NSException *exception) { SIException(error, exception); return nil; }
}
- (BOOL)setNotificationState:(uint64_t)state name:(NSString *)name device:(id)device error:(NSError **)error {
    @try {
        if (![device respondsToSelector:@selector(darwinNotificationSetState:name:error:)]) {
            if (error) *error = SIError(@"This Xcode version cannot set simulator notification state.");
            return NO;
        }
        return [(id<SIDevice>)device darwinNotificationSetState:state name:name error:error];
    } @catch (NSException *exception) { SIException(error, exception); return NO; }
}
@end

@implementation SIDeviceMonitor {
    id<SIContext> _context;
    id<SIDeviceSet> _deviceSet;
    NSUInteger _registrationID;
    BOOL _registered;
    void (^_changeHandler)(void);
    void (^_invalidationHandler)(NSString *);
}
- (instancetype)initWithDeveloperDirectory:(NSString *)path
                            changeHandler:(void (NS_SWIFT_SENDABLE ^)(void))changeHandler
                      invalidationHandler:(void (NS_SWIFT_SENDABLE ^)(NSString *))invalidationHandler
                                    error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    @try {
        if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW | RTLD_GLOBAL)) {
            if (error) *error = SIError(@"Could not load CoreSimulator. Install and select Xcode.");
            return nil;
        }
        Class contextClass = NSClassFromString(@"SimServiceContext");
        if (![contextClass instancesRespondToSelector:@selector(initWithDeveloperDir:connectionType:error:)] ||
            ![contextClass instancesRespondToSelector:@selector(setConnectionInvalidationHandler:)]) {
            if (error) *error = SIError(@"This Xcode version cannot observe simulator changes.");
            return nil;
        }
        // Connection type 0 is the client connection used by sharedServiceContextForDeveloperDir:.
        _context = [(id<SIContext>)[contextClass alloc] initWithDeveloperDir:path connectionType:0 error:error];
        if (!_context) return nil;
        _changeHandler = [changeHandler copy];
        _invalidationHandler = [invalidationHandler copy];
        __weak SIDeviceMonitor *weakSelf = self;
        [_context setConnectionInvalidationHandler:^(NSString *reason) {
            SIDeviceMonitor *monitor = weakSelf;
            if (!monitor) return;
            void (^handler)(NSString *);
            @synchronized (monitor) { handler = monitor->_invalidationHandler; }
            if (handler) handler(reason);
        }];
        _deviceSet = [_context defaultDeviceSetWithError:error];
        if (!_deviceSet) return nil;
        if (![_deviceSet respondsToSelector:@selector(registerNotificationHandlerOnQueue:handler:)] ||
            ![_deviceSet respondsToSelector:@selector(unregisterNotificationHandler:error:)]) {
            if (error) *error = SIError(@"This Xcode version cannot observe simulator changes.");
            return nil;
        }
        dispatch_queue_t queue = dispatch_queue_create("Siniulator.devices", DISPATCH_QUEUE_SERIAL);
        _registrationID = [_deviceSet registerNotificationHandlerOnQueue:queue handler:^(NSDictionary *notification) {
            SIDeviceMonitor *monitor = weakSelf;
            if (!monitor) return;
            void (^handler)(void);
            @synchronized (monitor) { handler = monitor->_changeHandler; }
            if (handler) handler();
        }];
        _registered = YES;
        // CoreSimulator resubscribes and replays initial device notifications after an XPC
        // interruption. A permanently invalid context instead triggers the handler above.
        if (![_context valid]) {
            if (error) *error = SIError(@"The CoreSimulator connection became invalid while subscribing.");
            return nil;
        }
    } @catch (NSException *exception) { SIException(error, exception); return nil; }
    return self;
}
- (void)stop {
    @synchronized (self) {
        _changeHandler = nil;
        _invalidationHandler = nil;
    }
    @try { [_context setConnectionInvalidationHandler:nil]; } @catch (NSException *ignored) {}
    if (_registered) {
        _registered = NO;
        @try { [_deviceSet unregisterNotificationHandler:_registrationID error:NULL]; } @catch (NSException *ignored) {}
    }
}
- (void)dealloc { [self stop]; }
@end

@implementation SIDisplay {
    id<SIScreen> _screen;
    NSUUID *_token;
    id _surface;
    dispatch_queue_t _queue;
}
- (instancetype)initWithDevice:(id)device error:(NSError **)error {
    return [self initWithDevice:device screenID:0 width:0 height:0 error:error];
}
- (instancetype)initWithDevice:(id)device screenID:(uint32_t)screenID width:(uint32_t)width height:(uint32_t)height error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    @try {
        NSArray *ports = [(id<SIIO>)[(id<SIDevice>)device io] ioPorts];
        id<SIScreenAdapter> adapter = nil;
        for (id<SIIO> port in ports) {
            id descriptor = [port descriptor];
            if ([descriptor conformsToProtocol:NSProtocolFromString(@"SimScreenAdapter")]) { adapter = descriptor; break; }
        }
        if (adapter && [adapter respondsToSelector:@selector(enumerateScreensWithCompletionQueue:completionHandler:)]) {
            NSArray *screens = SIEnumerateScreens(adapter, 1);
            id surface = nil;
            _screen = SIPreferredScreen(screens ?: @[], screenID, width, height, &surface);
            _surface = surface;
        }
        if (!_screen) {
            NSMutableArray *screens = [NSMutableArray array];
            for (id<SIIO> port in ports) {
                id descriptor = [port descriptor];
                if ([descriptor conformsToProtocol:NSProtocolFromString(@"SimDisplayIOSurfaceRenderable")]) [screens addObject:descriptor];
            }
            id surface = nil;
            _screen = SIPreferredScreen(screens, screenID, width, height, &surface);
            _surface = surface;
        }
        if (!_screen) {
            if (error) *error = screenID == 0
                ? SIError(@"The simulator display is not ready yet.")
                : SIError([NSString stringWithFormat:@"Simulator screen %u is not ready yet.", screenID]);
            return nil;
        }
        if (!_surface) _surface = SISurface(_screen);
        _token = [NSUUID UUID];
        _queue = dispatch_queue_create("Siniulator.display", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    } @catch (NSException *exception) { SIException(error, exception); return nil; }
    return self;
}
- (id)surface { @synchronized (self) { return _surface; } }
- (BOOL)startWithFrameHandler:(void (NS_SWIFT_SENDABLE ^)(void))handler error:(NSError **)error {
    __weak SIDisplay *weakSelf = self;
    void (^surfaceChanged)(id) = ^(id surface) {
        SIDisplay *strongSelf = weakSelf;
        if (!strongSelf) return;
        @synchronized (strongSelf) { strongSelf->_surface = surface; }
        handler();
    };
    @try {
        if ([_screen conformsToProtocol:NSProtocolFromString(@"SimScreen")]) {
            [_screen registerScreenCallbacksWithUUID:_token callbackQueue:_queue frameCallback:handler surfacesChangedCallback:^(id surface, id masked) { surfaceChanged(surface); } propertiesChangedCallback:^(id properties) { handler(); }];
            return YES;
        }
    } @catch (NSException *e) { @try { [_screen unregisterScreenCallbacksWithUUID:_token]; } @catch (NSException *ignored) {} }
    BOOL registered = NO;
    @try { [_screen registerCallbackWithUUID:_token ioSurfacesChangeCallback:surfaceChanged]; registered = YES; } @catch (NSException *e) {}
    if (!registered) {
        @try { [_screen registerCallbackWithUUID:_token ioSurfaceChangeCallback:surfaceChanged]; registered = YES; } @catch (NSException *e) { SIException(error, e); }
    }
    if (!registered) return NO;
    @try { [_screen registerCallbackWithUUID:_token damageRectanglesCallback:^(id rectangles) { handler(); }]; }
    @catch (NSException *e) { SIException(error, e); [self stop]; return NO; }
    return YES;
}
- (void)stop {
    if (!_token) return;
    @try { [_screen unregisterScreenCallbacksWithUUID:_token]; } @catch (NSException *e) {}
    @try { [_screen unregisterIOSurfacesChangeCallbackWithUUID:_token]; } @catch (NSException *e) {}
    @try { [_screen unregisterIOSurfaceChangeCallbackWithUUID:_token]; } @catch (NSException *e) {}
    @try { [_screen unregisterDamageRectanglesCallbackWithUUID:_token]; } @catch (NSException *e) {}
    @synchronized (self) { _surface = nil; }
}
- (void)dealloc { [self stop]; }
@end

@implementation SILegacyInput {
    id<SIHIDClient> _client;
    void *(*_button)(int32_t, int32_t, int32_t);
    void *(*_key)(int32_t, int32_t);
    void *(*_arbitrary)(int32_t, uint32_t, uint32_t, int32_t);
    void *(*_touch)(CGPoint *, CGPoint *, uint32_t, NSUInteger, CGSize, uint32_t);
    dispatch_queue_t _queue;
}
- (instancetype)initWithDevice:(id)device error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    @try {
        Class cls = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient") ?: NSClassFromString(@"SimDeviceLegacyHIDClient");
        _button = SIKit ? dlsym(SIKit, "IndigoHIDMessageForButton") : NULL;
        _key = SIKit ? dlsym(SIKit, "IndigoHIDMessageForKeyboardArbitrary") : NULL;
        _arbitrary = SIKit ? dlsym(SIKit, "IndigoHIDMessageForHIDArbitrary") : NULL;
        _touch = SIKit ? dlsym(SIKit, "IndigoHIDMessageForMouseNSEvent") : NULL;
        if (!cls || !_button || !_key || !_touch) {
            if (error) *error = SIError(@"Legacy HID is unavailable in this Xcode version.");
            return nil;
        }
        _client = [(id<SIHIDClient>)[cls alloc] initWithDevice:device error:error];
        if (!_client) return nil;
        _queue = dispatch_queue_create("Siniulator.legacyHID", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    } @catch (NSException *e) { SIException(error, e); return nil; }
    return self;
}
- (void)send:(void *)message completion:(void (NS_SWIFT_SENDABLE ^)(NSError *))completion {
    if (!message) { completion(SIError(@"Could not allocate a HID message.")); return; }
    dispatch_async(_queue, ^{
        @try { [self->_client sendWithMessage:message freeWhenDone:YES completionQueue:self->_queue completion:completion]; }
        @catch (NSException *e) { completion(SIError(e.reason)); }
    });
}
- (void)sendButton:(int32_t)source down:(BOOL)down completion:(void (NS_SWIFT_SENDABLE ^)(NSError *))completion {
    [self send:_button(source, down ? 1 : 2, 0x33) completion:completion];
}
- (void)sendKey:(uint32_t)usage down:(BOOL)down completion:(void (NS_SWIFT_SENDABLE ^)(NSError *))completion {
    [self send:_key(usage, down ? 1 : 2) completion:completion];
}
- (void)sendConsumerUsage:(uint32_t)usage down:(BOOL)down completion:(void (NS_SWIFT_SENDABLE ^)(NSError *))completion {
    if (!_arbitrary) { completion(SIError(@"Consumer HID controls are unavailable in this Xcode.")); return; }
    [self send:_arbitrary(0x32, 0x0c, usage, down ? 1 : 2) completion:completion];
}
- (void)sendTouch:(CGPoint)point phase:(NSUInteger)phase edge:(uint32_t)edge secondPoint:(NSValue *)second completion:(void (NS_SWIFT_SENDABLE ^)(NSError *))completion {
    CGPoint secondPoint = second.pointValue;
    void *source = _touch(&point, second ? &secondPoint : NULL, 0x32, phase, CGSizeMake(1, 1), edge);
    if (second) { [self send:source completion:completion]; return; }
    // idb's single-contact envelope avoids SimulatorKit's implicit second finger.
    // Wire layout is kept at this C boundary so Swift never accesses packed, unaligned fields.
    uint8_t *message = calloc(1, 320);
    if (!message || !source) { free(message); free(source); completion(SIError(@"Could not allocate a touch message.")); return; }
    uint32_t size = 144, kind = 11;
    uint64_t timestamp = mach_absolute_time();
    memcpy(message + 0x18, &size, 4);
    message[0x1c] = 2;
    memcpy(message + 0x20, &kind, 4);
    memcpy(message + 0x24, &timestamp, 8);
    memcpy(message + 0x30, (uint8_t *)source + 0x30, 112);
    free(source);
    memcpy(message + 0xb0, message + 0x20, 144);
    uint32_t one = 1, two = 2;
    memcpy(message + 0xc0, &one, 4);
    memcpy(message + 0xc4, &two, 4);
    [self send:message completion:completion];
}
@end
