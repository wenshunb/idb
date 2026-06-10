/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import Foundation

@objc(FBCoreDeviceHID)
public final class FBCoreDeviceHID: NSObject {

  private static let minimumXcodeVersion = NSDecimalNumber(string: "27.0")
  private static let helperExecutableName = "idb_coredevice_hid_helper"
  private static let helperOverrideEnvironmentVariable = "IDB_COREDEVICE_HID_HELPER"
  private static let helperQueue = DispatchQueue(label: "com.facebook.fbsimulatorcontrol.coredevicehid.helper")
  private static let state = FBCoreDeviceHIDState()

  @objc(shouldHandleCurrentXcode)
  public static func shouldHandleCurrentXcode() -> Bool {
    FBXcodeConfiguration.xcodeVersionNumber.compare(minimumXcodeVersion) != .orderedAscending
  }

  @objc(isAvailableForCurrentXcode)
  public static func isAvailableForCurrentXcode() -> Bool {
    shouldHandleCurrentXcode() && (try? helperExecutableURL()) != nil
  }

  @objc(sendTouchWithUDID:direction:x:y:screenSize:screenScale:)
  public static func sendTouch(
    udid: String,
    direction: FBSimulatorHIDDirection,
    x: Double,
    y: Double,
    screenSize: CGSize,
    screenScale: Float
  ) -> FBFuture<NSNull> {
    guard shouldHandleCurrentXcode() else {
      return failFuture("CoreDevice HID helper is only used for Xcode 27 or newer")
    }

    guard let directionArgument = directionString(from: direction) else {
      return failFuture("CoreDevice HID helper touch direction \(direction.rawValue) is not supported")
    }

    var arguments = [
      "touch",
      "--udid", udid,
      "--direction", directionArgument,
      "--x", "\(x)",
      "--y", "\(y)",
      "--screen-width", "\(Double(screenSize.width))",
      "--screen-height", "\(Double(screenSize.height))",
      "--screen-scale", "\(Double(screenScale))",
    ]

    if direction == .down && state.shouldResetTouch(for: udid) {
      arguments.append("--reset-gesture-state")
    }
    let future = runHelper(arguments: arguments, operation: "send CoreDevice touch \(directionArgument)", udid: udid)
    if direction == .down {
      return unsafeBitCast(
        future.onQueue(
          helperQueue,
          handleError: { error -> FBFuture<AnyObject> in
            state.endTouch(for: udid)
            return FBFuture<NSNull>(error: error) as! FBFuture<AnyObject>
          }
        ),
        to: FBFuture<NSNull>.self
      )
    }
    if direction == .up {
      state.endTouch(for: udid)
    }
    return future
  }

  @objc(sendKeyboardWithUDID:direction:keyCode:)
  public static func sendKeyboard(
    udid: String,
    direction: FBSimulatorHIDDirection,
    keyCode: UInt32
  ) -> FBFuture<NSNull> {
    guard shouldHandleCurrentXcode() else {
      return failFuture("CoreDevice HID helper is only used for Xcode 27 or newer")
    }

    guard let directionArgument = directionString(from: direction) else {
      return failFuture("CoreDevice HID helper keyboard direction \(direction.rawValue) is not supported")
    }

    let pressedUsages: [UInt8]
    do {
      pressedUsages = try state.keyboardUsages(for: udid, direction: direction, keyCode: keyCode)
    } catch {
      return FBFuture<NSNull>(error: error as NSError)
    }

    return runHelper(
      arguments: [
        "keyboard",
        "--udid", udid,
        "--direction", directionArgument,
        "--key-code", "\(keyCode)",
        "--pressed-usages", pressedUsages.map(String.init).joined(separator: ","),
      ],
      operation: "send CoreDevice keyboard \(directionArgument)",
      udid: udid
    )
  }

  @objc(clearStateForUDID:)
  public static func clearState(udid: String) {
    state.clear(for: udid)
  }

  private static func runHelper(arguments: [String], operation: String, udid: String) -> FBFuture<NSNull> {
    let future = FBFuture<AnyObject>.onQueue(
      helperQueue,
      resolve: {
        do {
          let executableURL = try helperExecutableURL()
          let result = try runProcess(executableURL: executableURL, arguments: arguments)
          guard result.exitCode == 0 else {
            return failFuture(
              "CoreDevice HID helper failed to \(operation) for simulator \(udid): exit \(result.exitCode)\(result.outputDescription)"
            ) as! FBFuture<AnyObject>
          }
          return FBFuture<NSNull>(result: NSNull()) as! FBFuture<AnyObject>
        } catch {
          return FBFuture<AnyObject>(error: error as NSError)
        }
      }
    )
    return unsafeBitCast(future, to: FBFuture<NSNull>.self)
  }

  private static func helperExecutableURL() throws -> URL {
    let fileManager = FileManager.default
    let environment = ProcessInfo.processInfo.environment

    if let overridePath = environment[helperOverrideEnvironmentVariable], !overridePath.isEmpty {
      guard fileManager.isExecutableFile(atPath: overridePath) else {
        throw simulatorError(
          "CoreDevice HID helper override \(helperOverrideEnvironmentVariable)=\(overridePath) is not executable"
        )
      }
      return URL(fileURLWithPath: overridePath)
    }

    let bundle = Bundle(for: FBCoreDeviceHID.self)
    let candidateURLs = [
      bundle.resourceURL?.appendingPathComponent(helperExecutableName),
      bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(helperExecutableName),
      Bundle.main.resourceURL?.appendingPathComponent(helperExecutableName),
    ].compactMap { $0 }

    if let executableURL = candidateURLs.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
      return executableURL
    }

    let searchedPaths = candidateURLs.map(\.path).joined(separator: ", ")
    throw simulatorError(
      "CoreDevice HID helper \(helperExecutableName) is required for Xcode 27 HID, but was not found or executable. Searched: \(searchedPaths). Set \(helperOverrideEnvironmentVariable) to a signed helper path or bundle it in FBSimulatorControl.framework/Resources."
    )
  }

  private static func runProcess(executableURL: URL, arguments: [String]) throws -> HelperResult {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr

    do {
      try process.run()
    } catch {
      throw simulatorError("Could not launch CoreDevice HID helper at \(executableURL.path): \(error)")
    }

    process.waitUntilExit()
    return HelperResult(
      exitCode: process.terminationStatus,
      stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
  }

  private static func directionString(from direction: FBSimulatorHIDDirection) -> String? {
    switch direction {
    case .down:
      return "down"
    case .up:
      return "up"
    @unknown default:
      return nil
    }
  }

  private static func failFuture(_ message: String) -> FBFuture<NSNull> {
    FBSimulatorError.describe(message).failFuture() as! FBFuture<NSNull>
  }

  private static func simulatorError(_ message: String) -> NSError {
    FBSimulatorError.describe(message).build()
  }
}

private struct HelperResult {
  let exitCode: Int32
  let stdout: String
  let stderr: String

  var outputDescription: String {
    let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    var parts: [String] = []
    if !trimmedStdout.isEmpty {
      parts.append("stdout: \(trimmedStdout)")
    }
    if !trimmedStderr.isEmpty {
      parts.append("stderr: \(trimmedStderr)")
    }
    return parts.isEmpty ? "" : " (\(parts.joined(separator: "; ")))"
  }
}

private final class FBCoreDeviceHIDState: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.facebook.fbsimulatorcontrol.coredevicehid.state")
  private var activeTouches = Set<String>()
  private var pressedKeysByUDID: [String: Set<UInt8>] = [:]

  func shouldResetTouch(for udid: String) -> Bool {
    queue.sync {
      let shouldReset = !activeTouches.contains(udid)
      activeTouches.insert(udid)
      return shouldReset
    }
  }

  func endTouch(for udid: String) {
    _ = queue.sync { activeTouches.remove(udid) }
  }

  func keyboardUsages(
    for udid: String,
    direction: FBSimulatorHIDDirection,
    keyCode: UInt32
  ) throws -> [UInt8] {
    try queue.sync {
      guard keyCode <= UInt8.max else {
        throw FBSimulatorError.describe("CoreDevice HID helper keyboard usage \(keyCode) is not supported").build()
      }

      var pressedKeys = pressedKeysByUDID[udid] ?? []
      switch direction {
      case .down:
        pressedKeys.insert(UInt8(keyCode))
      case .up:
        pressedKeys.remove(UInt8(keyCode))
      @unknown default:
        throw FBSimulatorError.describe("CoreDevice HID helper keyboard direction \(direction.rawValue) is not supported").build()
      }
      pressedKeysByUDID[udid] = pressedKeys
      return Array(pressedKeys).sorted()
    }
  }

  func clear(for udid: String) {
    queue.sync {
      activeTouches.remove(udid)
      pressedKeysByUDID.removeValue(forKey: udid)
    }
  }
}
