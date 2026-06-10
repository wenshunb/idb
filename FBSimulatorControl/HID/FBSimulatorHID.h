/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <mach/mach.h>

#import <Foundation/Foundation.h>

#import <FBControlCore/FBControlCore.h>
#import <FBSimulatorControl/FBSimulatorIndigoHID.h>
#import <FBSimulatorControl/FBSimulatorPurpleHID.h>

@class FBSimulator;

/**
 The HID abstraction layer for a Simulator, providing two transport paths:

 1. Indigo (IndigoHIDRegistrationPort) — for older-Xcode touch/keyboard events
    and HID events that are not yet covered by the CoreDevice helper transport.
    Payloads are constructed by FBSimulatorIndigoHID and sent via SimDeviceLegacyHIDClient
    when that legacy client is present.
    Guest-side: SimHIDVirtualServiceManager dispatches on eventKind + target.

 2. PurpleWorkspacePort — for GSEvent-based events (e.g., device orientation changes).
    Payloads are constructed by FBSimulatorPurpleHID and sent via raw mach_msg_send.
    Guest-side: GraphicsServices._PurpleEventCallback → backboardd.

 See Indigo.h and GSEvent.h for wire format documentation.

 ## Touch delivery: the two CoreSimulator HID paths (as of Xcode 27)

 A tap reaches UIKit through one of two parallel host→guest injection paths. Both are
 implemented by CoreSimulator and both bottom out in the guest's HID system (backboardd);
 they differ only in how the event crosses the host/guest boundary:

 1. Legacy "Indigo" path — used for older Xcodes and non-v1 HID events.
      FBSimulatorIndigoHID builds an `IndigoMessage`
        → -[SimDeviceLegacyHIDClient sendWithMessage:freeWhenDone:completionQueue:completion:]  (SimulatorKit, host-side)
        → SimDeviceIO Indigo port  (CoreSimulator host↔guest IO channel)
        → guest SimHIDVirtualServiceManager → backboardd → UIKit touch
    Host-side, ObjC/C-callable, requires no entitlement. This is the reachable, stable
    path that FBSimulatorControl uses today.

 2. CoreDevice/UniversalHID helper path — Xcode 27+ touch/keyboard transport.
      FBSimulatorControl launches the bundled/private helper
        → CoreDevice.DeviceManager finds the simulator
        → com.apple.coredevice.feature.remote.universalhidservice
        → UniversalHID service 0x101 (touchscreen) or 0x200 (keyboard)
        → dtuhidd posts IOHID reports to com.apple.iohideventsystem
        → guest backboardd → UIKit touch
    This is what Xcode's DeviceHub-era simulator stack drives. In this fork,
    FBSimulatorControl keeps the semantic API but does not import or link CoreDevice
    directly. The helper is built separately with the Xcode 27 toolchain so the main
    frameworks can keep the macOS 11 deployment target.

 Both paths represent the same semantic touch/keyboard actions and bottom out in
 CoreSimulator — notably, `dtuhidd` is itself a CoreSimulator binary, so the
 "CoreDevice" digitizer for a simulator is still CoreSimulator functionality.
 The CoreDevice path is the direction Apple is converging on. The intent for this
 layer is to expose both as alternative transports while preserving the public HID
 event API and keeping non-v1 HID behavior on Indigo/Purple.
 */
@interface FBSimulatorHID : NSObject

#pragma mark Initializers

/**
 Creates and returns a FBSimulatorHID Instance for the provided Simulator.
 Will fail if a HID Port could not be registered for the provided Simulator.
 Registration may need to occur prior to booting.

 @param simulator the Simulator to create a IndigoHIDRegistrationPort for.
 @return a FBSimulatorHID if successful, nil otherwise.
 */
+ (nonnull FBFuture<FBSimulatorHID *> *)hidForSimulator:(nonnull FBSimulator *)simulator;

#pragma mark Lifecycle

/**
 Obtains the Reply Port for the Simulator.
 This must be obtained in order to send IndigoHID events to the Simulator.
 This should be obtained after the Simulator is booted.

 @return A future that resolves when connected.
 */
- (nonnull FBFuture<NSNull *> *)connect;

/**
 Disconnects from the remote HID.

 @return A future that resolves when disconnected
 */
- (nonnull FBFuture<NSNull *> *)disconnect;

#pragma mark HID Manipulation

/**
 Sends the event payload

 @param data the payload data
 @return A future that resolves when the event has been sent.
 */
- (nonnull FBFuture<NSNull *> *)sendEvent:(nonnull NSData *)data;

/**
 Sends a semantic single-touch event.

 @param direction the touch direction.
 @param x the x coordinate in IDB simulator coordinates.
 @param y the y coordinate in IDB simulator coordinates.
 @return A future that resolves when the event has been sent.
 */
- (nonnull FBFuture<NSNull *> *)sendTouchWithDirection:(FBSimulatorHIDDirection)direction x:(double)x y:(double)y NS_SWIFT_NAME(sendTouch(direction:x:y:));

/**
 Sends a semantic keyboard event.

 @param direction the key direction.
 @param keyCode the USB HID keyboard usage code.
 @return A future that resolves when the event has been sent.
 */
- (nonnull FBFuture<NSNull *> *)sendKeyboardWithDirection:(FBSimulatorHIDDirection)direction keyCode:(unsigned int)keyCode NS_SWIFT_NAME(sendKeyboard(direction:keyCode:));

/**
 Sends the event payload, synchronously.
 This should only be used when the caller can guarantee that all calls to this API are performed from the same queue.

 @param data the payload data
 @param completionQueue the queue to call back on
 @param completion the completion block to invoke
 */
- (void)sendIndigoMessageData:(nonnull NSData *)data completionQueue:(nonnull dispatch_queue_t)completionQueue completion:(nonnull void (^)(NSError * _Nullable))completion;

/**
 Sends a raw mach message to the simulator's PurpleWorkspacePort.
 Convenience wrapper around `-sendPurpleEvent:timeoutMs:error:` that delegates with
 a default 2000ms timeout — generous enough to absorb scheduler jitter on a healthy
 simulator (round-trips return in low single-digit milliseconds) while bounded enough
 to surface a stalled SpringBoard receive thread instead of hanging the caller forever.
 Callers that need a different timeout (or the legacy unbounded behavior with `0`)
 should call `-sendPurpleEvent:timeoutMs:error:` directly.

 @param data the complete mach message to send.
 @param error an error out for any error that occurs.
 @return YES if the message was sent successfully, NO otherwise.
 */
- (BOOL)sendPurpleEvent:(nonnull NSData *)data error:(NSError * _Nullable * _Nullable)error;

/**
 Sends a raw mach message to the simulator's PurpleWorkspacePort, bounded by an
 explicit send-side timeout. Used for GSEvent-based HID events (e.g., orientation
 changes) that bypass the Indigo HID system. The data must contain a complete mach
 message including `mach_msg_header_t`. The `msgh_remote_port` field will be patched
 with the PurpleWorkspacePort looked up from the simulator's bootstrap namespace.

 The send always uses `mach_msg(MACH_SEND_TIMEOUT)` and returns a
 `MACH_SEND_TIMED_OUT`-tagged error if the queue does not drain in time. On
 `MACH_SEND_TIMED_OUT` the kernel guarantees the message is not enqueued (no
 partial-receive risk on the SpringBoard side). A `timeoutMs` of `0` is a
 non-blocking send: it succeeds only if the destination port queue has space
 immediately, otherwise returns `MACH_SEND_TIMED_OUT` straight away. There is no
 "wait forever" mode — the unbounded `mach_msg_send` path that previously hung the
 caller indefinitely on a stalled SpringBoard receive thread has been removed.

 This is synchronous — callers are responsible for dispatching to the appropriate
 queue and wrapping in a future if needed.

 @param data the complete mach message to send.
 @param timeoutMs the send-side timeout in milliseconds.
 @param error an error out for any error that occurs.
 @return YES if the message was sent successfully, NO otherwise.
 */
- (BOOL)sendPurpleEvent:(nonnull NSData *)data timeoutMs:(mach_msg_timeout_t)timeoutMs error:(NSError * _Nullable * _Nullable)error;

/**
 Posts a Darwin notification to the simulator.
 Used for features like shake that are triggered via Darwin notification
 rather than Indigo HID or PurpleWorkspacePort.

 This is synchronous — callers are responsible for dispatching to the appropriate
 queue and wrapping in a future if needed.

 @param notificationName the Darwin notification name to post (e.g. com.apple.UIKit.SimulatorShake).
 @param error an error out for any error that occurs.
 @return YES if the notification was posted successfully, NO otherwise.
 */
- (BOOL)postDarwinNotification:(nonnull NSString *)notificationName error:(NSError * _Nullable * _Nullable)error;

#pragma mark Properties

/**
 The Queue on which messages are sent to the HID Server.
 */
@property (nonnull, nonatomic, readonly, strong) dispatch_queue_t queue;

/**
 The Indigo payload builder (touch, button, keyboard), if SimulatorApp exposes it.
 This may be nil on Xcode 27+ CoreDevice-only HID connections.
 */
@property (nullable, nonatomic, readonly, strong) FBSimulatorIndigoHID *indigo;

/**
 The Purple/GSEvent payload builder (orientation, shake).
 */
@property (nonnull, nonatomic, readonly, strong) FBSimulatorPurpleHID *purple;

/**
 The dimensions of the main screen.
 */
@property (nonatomic, readonly, assign) CGSize mainScreenSize;

/**
 The scale of the main screen.
 */
@property (nonatomic, readonly, assign) float mainScreenScale;

@end
