/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSimulatorHID.h"

#import <mach/mach.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>

#import <CoreGraphics/CoreGraphics.h>

#import <CoreSimulator/SimDevice.h>
#import <CoreSimulator/SimDeviceType.h>
#import <SimulatorApp/Indigo.h>
#import <SimulatorKit/SimDeviceLegacyClient.h>

#import "FBSimulator.h"
#import "FBSimulatorControl-Swift.h"

@interface FBSimulatorHID ()

@property (nonatomic, readonly, strong, nullable) SimDeviceLegacyClient *client;
@property (nonatomic, readonly, weak) FBSimulator *simulator;

- (instancetype)initWithIndigo:(nullable FBSimulatorIndigoHID *)indigo purple:(FBSimulatorPurpleHID *)purple client:(nullable SimDeviceLegacyClient *)client simulator:(FBSimulator *)simulator mainScreenSize:(CGSize)mainScreenSize mainScreenScale:(float)mainScreenScale queue:(dispatch_queue_t)queue;
- (BOOL)shouldUseCoreDeviceHID;

@end

@implementation FBSimulatorHID

#pragma mark Initializers

static const char *SimulatorHIDClientClassName = "SimulatorKit.SimDeviceLegacyHIDClient";

+ (dispatch_queue_t)workQueue
{
  return dispatch_queue_create("com.facebook.fbsimulatorcontrol.hid", DISPATCH_QUEUE_SERIAL);
}

+ (FBFuture<FBSimulatorHID *> *)hidForSimulator:(FBSimulator *)simulator
{
  BOOL shouldUseCoreDeviceHID = FBCoreDeviceHID.shouldHandleCurrentXcode;

  Class clientClass = objc_lookUpClass(SimulatorHIDClientClassName);
  if (!clientClass && !shouldUseCoreDeviceHID) {
    return (FBFuture *)[[FBSimulatorError
                         describe:[NSString stringWithFormat:@"Could not find %@", @(SimulatorHIDClientClassName)]]
                        failFuture];
  }

  NSError *error = nil;
  SimDeviceLegacyClient *client = clientClass ? [[clientClass alloc] initWithDevice:simulator.device error:&error] : nil;
  if (!client && !shouldUseCoreDeviceHID) {
    return (FBFuture *)[[[FBSimulatorError
                          describe:[NSString stringWithFormat:@"Could not create instance of %@", NSStringFromClass(clientClass)]]
                         causedBy:error]
                        failFuture];
  }
  if (!client) {
    error = nil;
  }

  FBSimulatorIndigoHID *indigo = nil;
  if (!shouldUseCoreDeviceHID) {
    indigo = [FBSimulatorIndigoHID simulatorKitHIDWithError:&error];
    if (!indigo) {
      return nil;
    }
  }

  CGSize mainScreenSize = simulator.device.deviceType.mainScreenSize;
  float scale = simulator.device.deviceType.mainScreenScale;
  FBSimulatorPurpleHID *purple = [FBSimulatorPurpleHID purple];
  FBSimulatorHID *hid = [[self alloc] initWithIndigo:indigo purple:purple client:client simulator:simulator mainScreenSize:mainScreenSize mainScreenScale:scale queue:self.workQueue];
  return [FBFuture futureWithResult:hid];
}

- (instancetype)initWithIndigo:(nullable FBSimulatorIndigoHID *)indigo purple:(FBSimulatorPurpleHID *)purple client:(nullable SimDeviceLegacyClient *)client simulator:(FBSimulator *)simulator mainScreenSize:(CGSize)mainScreenSize mainScreenScale:(float)mainScreenScale queue:(dispatch_queue_t)queue
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _indigo = indigo;
  _purple = purple;
  _client = client;
  _simulator = simulator;
  _mainScreenSize = mainScreenSize;
  _queue = queue;
  _mainScreenScale = mainScreenScale;

  return self;
}

#pragma mark HID Manipulation

- (FBFuture<NSNull *> *)sendEvent:(NSData *)data
{
  if (!self.indigo || !self.client) {
    return (FBFuture *)[[FBSimulatorError
                         describe:@"Indigo HID is unavailable for this simulator connection; this HID event is not supported by the Xcode 27 CoreDevice helper transport"]
                        failFuture];
  }

  return [FBFuture onQueue:self.queue
                   resolve:^{
                     FBMutableFuture<NSNull *> *future = FBMutableFuture.future;
                     [self sendIndigoMessageData:data
                                 completionQueue:self.queue
                                      completion:^(NSError *error) {
                               if (error) {
                                 [future resolveWithError:error];
                               } else {
                                 [future resolveWithResult:NSNull.null];
                               }
                             }];
                     return future;
                   }];
}

- (FBFuture<NSNull *> *)sendTouchWithDirection:(FBSimulatorHIDDirection)direction x:(double)x y:(double)y
{
  if ([self shouldUseCoreDeviceHID]) {
    FBSimulator *simulator = self.simulator;
    if (!simulator) {
      return (FBFuture *)[[FBSimulatorError describe:@"Cannot send CoreDevice touch, simulator reference is nil"] failFuture];
    }
    return [FBCoreDeviceHID
      sendTouchWithUDID:simulator.udid
      direction:direction
      x:x
      y:y
      screenSize:self.mainScreenSize
      screenScale:self.mainScreenScale
    ];
  }

  return [self sendEvent:[self.indigo touchScreenSize:self.mainScreenSize screenScale:self.mainScreenScale direction:direction x:x y:y]];
}

- (FBFuture<NSNull *> *)sendKeyboardWithDirection:(FBSimulatorHIDDirection)direction keyCode:(unsigned int)keyCode
{
  if ([self shouldUseCoreDeviceHID]) {
    FBSimulator *simulator = self.simulator;
    if (!simulator) {
      return (FBFuture *)[[FBSimulatorError describe:@"Cannot send CoreDevice keyboard event, simulator reference is nil"] failFuture];
    }
    return [FBCoreDeviceHID sendKeyboardWithUDID:simulator.udid direction:direction keyCode:keyCode];
  }

  return [self sendEvent:[self.indigo keyboardWithDirection:direction keyCode:keyCode]];
}

- (void)sendIndigoMessageData:(NSData *)data completionQueue:(dispatch_queue_t)completionQueue completion:(void (^)(NSError *))completion
{
  if (!self.client) {
    completion([FBSimulatorError describe:@"Cannot send Indigo HID message because SimDeviceLegacyHIDClient is unavailable"].build);
    return;
  }

  // Host-side "Indigo" injection: hand the IndigoMessage to SimulatorKit's
  // SimDeviceLegacyHIDClient, which writes it to the guest's SimDeviceIO port for
  // backboardd to consume. See FBSimulatorHID.h for the full host→guest chain and the
  // parallel CoreDevice/dtuhidd helper path used by semantic touch/key events on Xcode 27+.
  //
  // The event is delivered asynchronously.
  // Therefore copy the message and let the client manage the lifecycle of it.
  // The free of the buffer is performed by the client and the NSData will free when it falls out of scope.
  size_t size = (mach_msg_size_t) data.length;
  IndigoMessage *message = malloc(size);
  memcpy(message, data.bytes, size);
  [self.client sendWithMessage:message freeWhenDone:YES completionQueue:completionQueue completion:completion];
}

// Default Mach send timeout (in milliseconds) for the convenience wrapper.
// Healthy `sendPurpleEvent:` round-trips return in low single-digit milliseconds.
// 2000ms absorbs scheduler jitter while bounding the wedge condition where SpringBoard's
// PurpleWorkspacePort receive queue fills under sustained event flow with a stalled receiver.
static const mach_msg_timeout_t DefaultPurpleSendTimeoutMs = 2000;

- (BOOL)sendPurpleEvent:(NSData *)data error:(NSError **)error
{
  return [self sendPurpleEvent:data timeoutMs:DefaultPurpleSendTimeoutMs error:error];
}

- (BOOL)sendPurpleEvent:(NSData *)data timeoutMs:(mach_msg_timeout_t)timeoutMs error:(NSError **)error
{
  FBSimulator *simulator = self.simulator;
  if (!simulator) {
    return [[FBSimulatorError describe:@"Cannot send PurpleEvent, simulator reference is nil"] failBool:error];
  }

  mach_port_t purplePort = [simulator.device lookup:@"PurpleWorkspacePort" error:error];
  if (purplePort == 0) {
    return [[FBSimulatorError describe:@"Could not find PurpleWorkspacePort in simulator bootstrap namespace"] failBool:error];
  }

  // Copy the payload and patch msgh_remote_port with the looked-up port.
  NSMutableData *mutableData = [data mutableCopy];
  mach_msg_header_t *header = (mach_msg_header_t *)mutableData.mutableBytes;
  header->msgh_remote_port = purplePort;

  kern_return_t kr = mach_msg(
    header,
    MACH_SEND_MSG | MACH_SEND_TIMEOUT,
    header->msgh_size,
    0,
    MACH_PORT_NULL,
    timeoutMs,
    MACH_PORT_NULL
  );
  if (kr == KERN_SUCCESS) {
    return YES;
  }
  if (kr == MACH_SEND_TIMED_OUT) {
    return [[FBSimulatorError
             describe:[NSString stringWithFormat:@"mach_msg to PurpleWorkspacePort %u timed out after %u ms — receive queue full, SpringBoard is likely not draining HID events: %s",
                       purplePort, timeoutMs, mach_error_string(kr)]]
            failBool:error];
  }
  return [[FBSimulatorError
           describe:[NSString stringWithFormat:@"mach_msg to PurpleWorkspacePort %u failed: %s (kr=0x%x)",
                     purplePort, mach_error_string(kr), kr]]
          failBool:error];
}

- (BOOL)postDarwinNotification:(NSString *)notificationName error:(NSError **)error
{
  FBSimulator *simulator = self.simulator;
  if (!simulator) {
    return [[FBSimulatorError describe:@"Cannot post Darwin notification, simulator reference is nil"] failBool:error];
  }
  return [simulator.device postDarwinNotification:notificationName error:error];
}

#pragma mark NSObject

- (NSString *)description
{
  if ([self shouldUseCoreDeviceHID]) {
    return [NSString stringWithFormat:@"CoreDevice helper/SimulatorKit HID %@", self.client ?: @"(legacy unavailable)"];
  }
  return [NSString stringWithFormat:@"SimulatorKit HID %@", self.client];
}

#pragma mark Lifecycle

- (FBFuture<NSNull *> *)connect
{
  if (!self.client && ![self shouldUseCoreDeviceHID]) {
    return (FBFuture *)[[FBSimulatorError
                         describe:@"Cannot Connect, HID client has already been disposed of"]
                        failFuture];
  }
  return FBFuture.empty;
}

- (FBFuture<NSNull *> *)disconnect
{
  FBSimulator *simulator = self.simulator;
  if (simulator) {
    [FBCoreDeviceHID clearStateForUDID:simulator.udid];
  }
  _client = nil;
  return FBFuture.empty;
}

- (BOOL)shouldUseCoreDeviceHID
{
  return [FBCoreDeviceHID shouldHandleCurrentXcode];
}

@end
