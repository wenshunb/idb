/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation
@preconcurrency import CoreDevice
@preconcurrency import UniversalHID

private let universalHIDFeature = "com.apple.coredevice.feature.remote.universalhidservice"
private let keyboardFeature = "com.apple.coredevice.feature.remote.hid.keyboard"
private let touchServiceID: UInt64 = 0x101
private let keyboardServiceID: UInt64 = 0x200

@main
struct FBCoreDeviceHIDHelper {

  static func main() async {
    do {
      try await run(arguments: Array(CommandLine.arguments.dropFirst()))
      exit(0)
    } catch {
      fputs("CoreDevice UniversalHID helper error: \(error)\n", stderr)
      exit(1)
    }
  }

  private static func run(arguments: [String]) async throws {
    guard let command = arguments.first else {
      throw HelperError("missing command; expected touch or keyboard")
    }
    let options = try Options(arguments: Array(arguments.dropFirst()))

    switch command {
    case "touch":
      try await sendTouch(options: options)
    case "keyboard":
      try await sendKeyboard(options: options)
    default:
      throw HelperError("unknown command \(command); expected touch or keyboard")
    }
  }

  private static func sendTouch(options: Options) async throws {
    let udid = try options.requiredString("udid")
    let directionString = try options.requiredString("direction")
    guard let direction = TouchDirection(rawValue: directionString) else {
      throw HelperError("unsupported touch direction \(directionString); expected down or up")
    }
    let x = try options.requiredDouble("x")
    let y = try options.requiredDouble("y")
    let screenWidth = try options.requiredDouble("screen-width")
    let screenHeight = try options.requiredDouble("screen-height")
    let screenScale = try options.requiredDouble("screen-scale")
    let serviceID = try options.optionalUInt64("service-id") ?? touchServiceID
    let shouldResetGestureState = options.hasFlag("reset-gesture-state")

    let context = try await HIDContext.load(udid: udid)
    try context.requireService(rawServiceID: serviceID, purpose: "main touchscreen")

    if shouldResetGestureState {
      try sendCoreDeviceOperation(operation: "reset touch gesture state", udid: udid) {
        try context.service.resetGestureState(service: serviceID)
      }
    }

    let point = normalizedTouchPoint(
      x: x,
      y: y,
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      screenScale: screenScale
    )

    switch direction {
    case .down:
      try sendCoreDeviceOperation(operation: "send touch down", udid: udid) {
        try context.service.send(
          report: makeDigitizerReport(point: point, range: true, touch: true, contactCount: 1),
          to: serviceID
        )
        context.service.sendBarrier()
      }
      try await Task.sleep(nanoseconds: 100_000_000)

    case .up:
      try sendCoreDeviceOperation(operation: "send touch up", udid: udid) {
        try context.service.send(
          report: makeDigitizerReport(point: point, range: true, touch: false, contactCount: 1),
          to: serviceID
        )
        context.service.sendBarrier()
      }
      try await Task.sleep(nanoseconds: 40_000_000)
      try sendCoreDeviceOperation(operation: "send touch out of range", udid: udid) {
        try context.service.send(
          report: makeDigitizerReport(point: point, range: false, touch: false, contactCount: 0),
          to: serviceID
        )
        context.service.sendBarrier()
      }
      try await Task.sleep(nanoseconds: 150_000_000)
    }
  }

  private static func sendKeyboard(options: Options) async throws {
    let udid = try options.requiredString("udid")
    let directionString = try options.requiredString("direction")
    guard let direction = KeyboardDirection(rawValue: directionString) else {
      throw HelperError("unsupported keyboard direction \(directionString); expected down or up")
    }
    let keyCode = try options.requiredUInt16("key-code")
    let pressedUsages = try keyboardUsageValues(from: options.optionalString("pressed-usages") ?? "")
    let serviceID = try options.optionalUInt64("service-id") ?? keyboardServiceID
    let context = try await HIDContext.load(udid: udid)
    try context.requireService(rawServiceID: serviceID, purpose: "main keyboard")
    guard context.device.supportsFeature(identifiedBy: keyboardFeature) else {
      throw HelperError("CoreDevice HID Keyboard capability \(keyboardFeature) is absent for simulator \(udid)")
    }

    let keyboard: any HIDKeyboard
    do {
      keyboard = try await context.device.getImplementation(
        for: CapabilityStaticMember<HIDDeviceCapability>.keyboard
      )
    } catch {
      throw HelperError("CoreDevice HID Keyboard could not connect to simulator \(udid): \(error)")
    }

    try sendCoreDeviceOperation(operation: "send keyboard \(directionString) \(keyCode)", udid: udid) {
      let replayedChordModifiers = pressedUsages.filter(isReplayableChordModifier).sorted()
      if !isReplayableChordModifier(keyCode) {
        // The helper is launched per event, so each base-key event must carry its active chord modifiers.
        for modifier in replayedChordModifiers {
          try keyboard.send(key: HIDKeyboardUsageCode(Int(modifier)), state: .down)
        }
      }
      try keyboard.send(key: HIDKeyboardUsageCode(Int(keyCode)), state: direction.buttonState)
      if direction == .up && !isReplayableChordModifier(keyCode) {
        for modifier in replayedChordModifiers.reversed() {
          try keyboard.send(key: HIDKeyboardUsageCode(Int(modifier)), state: .up)
        }
      }
      keyboard.sendBarrier()
    }
    try await Task.sleep(nanoseconds: 35_000_000)
  }
}

private struct HIDContext {
  let device: RemoteDevice
  let service: any UniversalHIDService
  let connectedServiceIDs: [HIDServiceID]

  static func load(udid: String) async throws -> HIDContext {
    guard let uuid = UUID(uuidString: udid) else {
      throw HelperError("CoreDevice UniversalHID requires a simulator UUID, got \(udid)")
    }

    let manager = DeviceManager(
      serviceConnection: CoreDeviceService.sharedConnection,
      allowedDeviceVisibilityClasses: [.default, .simulators]
    )
    await manager.awaitFullInitialization()

    guard let device = manager.allDevices().first(where: { $0.deviceIdentifier == uuid }) else {
      throw HelperError("CoreDevice UniversalHID could not find simulator \(udid)")
    }

    guard device.supportsFeature(identifiedBy: universalHIDFeature) else {
      throw HelperError("CoreDevice UniversalHID capability \(universalHIDFeature) is absent for simulator \(udid)")
    }

    do {
      let service: any UniversalHIDService = try await device.getImplementation(
        for: CapabilityStaticMember<UniversalHIDServiceCapability>.universalHidService
      )
      return HIDContext(
        device: device,
        service: service,
        connectedServiceIDs: try await service.connectedServiceIDs()
      )
    } catch {
      throw HelperError("CoreDevice UniversalHID could not connect to simulator \(udid): \(error)")
    }
  }

  func requireService(rawServiceID: UInt64, purpose: String) throws {
    if connectedServiceIDs.contains(where: { Self.rawValue(for: $0) == rawServiceID }) {
      return
    }
    throw HelperError(
      "CoreDevice UniversalHID service 0x\(String(rawServiceID, radix: 16)) (\(purpose)) is absent; connected services: [\(connectedServiceDescription)]"
    )
  }

  private var connectedServiceDescription: String {
    connectedServiceIDs
      .map(Self.serviceDescription)
      .joined(separator: ", ")
  }

  private static func serviceDescription(for serviceID: HIDServiceID) -> String {
    let rawValue = rawValue(for: serviceID)
    let name: String
    switch rawValue {
    case 0x101:
      name = "mainTouchscreen"
    case 0x104:
      name = "touchscreen"
    case 0x200:
      name = "mainKeyboard"
    case 0x402:
      name = "mainScreenButtons"
    case 0x500:
      name = "avpCustom"
    case 0x501:
      name = "touchscreenGesture"
    default:
      name = "unknown"
    }
    return "\(name)(0x\(String(rawValue, radix: 16)))"
  }

  private static func rawValue(for serviceID: HIDServiceID) -> UInt64 {
    precondition(MemoryLayout<HIDServiceID>.size == MemoryLayout<UInt64>.size)
    return withUnsafeBytes(of: serviceID) { bytes in
      bytes.load(as: UInt64.self)
    }
  }
}

private enum TouchDirection: String {
  case down
  case up
}

private enum KeyboardDirection: String {
  case down
  case up

  var buttonState: HIDButtonState {
    switch self {
    case .down:
      return .down
    case .up:
      return .up
    }
  }
}

private struct Options {
  private var values: [String: String] = [:]
  private var flags = Set<String>()

  init(arguments: [String]) throws {
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      guard argument.hasPrefix("--") else {
        throw HelperError("unexpected positional argument \(argument)")
      }

      let name = String(argument.dropFirst(2))
      if index + 1 >= arguments.count || arguments[index + 1].hasPrefix("--") {
        flags.insert(name)
        index += 1
      } else {
        values[name] = arguments[index + 1]
        index += 2
      }
    }
  }

  func requiredString(_ name: String) throws -> String {
    guard let value = values[name], !value.isEmpty else {
      throw HelperError("missing required option --\(name)")
    }
    return value
  }

  func optionalString(_ name: String) -> String? {
    values[name]
  }

  func requiredDouble(_ name: String) throws -> Double {
    let string = try requiredString(name)
    guard let value = Double(string) else {
      throw HelperError("option --\(name) must be a number, got \(string)")
    }
    return value
  }

  func requiredUInt16(_ name: String) throws -> UInt16 {
    let string = try requiredString(name)
    guard let value = UInt16(string) else {
      throw HelperError("option --\(name) must be a UInt16 decimal value, got \(string)")
    }
    return value
  }

  func optionalUInt64(_ name: String) throws -> UInt64? {
    guard let string = optionalString(name) else {
      return nil
    }
    let value: UInt64?
    if string.lowercased().hasPrefix("0x") {
      value = UInt64(String(string.dropFirst(2)), radix: 16)
    } else {
      value = UInt64(string, radix: 10)
    }
    guard let value else {
      throw HelperError("option --\(name) must be a UInt64 decimal or 0x-prefixed hex value, got \(string)")
    }
    return value
  }

  func hasFlag(_ name: String) -> Bool {
    flags.contains(name)
  }
}

private func keyboardUsageValues(from string: String) throws -> [UInt16] {
  if string.isEmpty {
    return []
  }

  return try string.split(separator: ",").map { part in
    guard let rawValue = UInt16(String(part)) else {
      throw HelperError("CoreDevice UniversalHID keyboard usage \(part) is not supported")
    }
    return rawValue
  }
}

private let keyboardTabUsage: UInt16 = 43
private let keyboardModifierUsageRange: ClosedRange<UInt16> = 224...231

private func isReplayableChordModifier(_ usage: UInt16) -> Bool {
  keyboardModifierUsageRange.contains(usage) || usage == keyboardTabUsage
}

private func normalizedTouchPoint(
  x: Double,
  y: Double,
  screenWidth: Double,
  screenHeight: Double,
  screenScale: Double
) -> HIDPoint {
  let width = max(screenWidth, 1)
  let height = max(screenHeight, 1)
  let scale = max(screenScale, 1)
  return HIDPoint(
    x: clamped((x * scale) / width),
    y: clamped((y * scale) / height),
    z: 0
  )
}

private func makeDigitizerReport(
  point: HIDPoint,
  range: Bool,
  touch: Bool,
  contactCount: UInt8
) -> HIDReport {
  var contact = DigitizerContact()
  contact.index = 0
  contact.point = point
  contact.range = range
  contact.touch = touch
  contact.resting = false

  var report = DigitizerReport(_report: HIDReport(bitCount: DigitizerReport.initialReportBitCount, id: DigitizerReport.reportID))
  report.contactCountMaximum = 1
  report.contactCount = contactCount
  report.setContact(contact, atIndex: 0)
  report.setContactIdentity(1, atIndex: 0)
  return report.report
}

private func sendCoreDeviceOperation(operation: String, udid: String, body: () throws -> Void) throws {
  do {
    try body()
  } catch {
    throw HelperError("CoreDevice UniversalHID failed to \(operation) for simulator \(udid): \(error)")
  }
}

private func clamped(_ value: Double) -> Double {
  min(max(value, 0), 1)
}

private struct HelperError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
