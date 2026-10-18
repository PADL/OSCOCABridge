//
// Copyright (c) 2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an 'AS IS' BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import OSCOCABridge
import SocketAddress
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice
import SwiftOSCCore
import XCTest

final class OSCAddressTests: XCTestCase {
  func testDottedLeafIsAlwaysAMethodID() {
    XCTAssertEqual(OSCOCAAddressLeaf("4.2"), .methodID(OcaMethodID("4.2")))
    // a dotted property ID is not a thing: it is the method with that ID
    XCTAssertEqual(OSCOCAAddressLeaf("4.1"), .methodID(OcaMethodID("4.1")))
  }

  func testAES70NotationLeaves() {
    XCTAssertEqual(OSCOCAAddressLeaf("4m2"), .methodID(OcaMethodID("4.2")))
    XCTAssertEqual(OSCOCAAddressLeaf("4p1"), .propertyID(OcaPropertyID("4.1")))
    XCTAssertEqual(OSCOCAAddressLeaf("04p01"), .propertyID(OcaPropertyID("4.1")))
    XCTAssertEqual(OSCOCAAddressLeaf("03m02"), .methodID(OcaMethodID("3.2")))
  }

  func testNamesAreNotIDs() {
    for name in [
      "gain",
      "mute",
      "pan",
      "setGain",
      "p",
      "m",
      "4",
      "4p",
      "p1",
      "4.x",
      "4m2m",
      "Gain",
    ] {
      XCTAssertEqual(OSCOCAAddressLeaf(name), .name(name), name)
    }
  }

  func testRequests() throws {
    guard case let .member(rolePath, leaf) = try OSCOCARequest(OSCMessage("/Block/Gain/gain"))
    else { return XCTFail() }
    XCTAssertEqual(rolePath, ["Block", "Gain"])
    XCTAssertEqual(leaf, .name("gain"))

    guard case let .subscribe(patterns, port) = try OSCOCARequest(OSCMessage(
      "/subscribe",
      values: ["/Block/Gain/gain", "/Block/*/state", Int32(9001)]
    )) else { return XCTFail() }
    XCTAssertEqual(patterns, ["/Block/Gain/gain", "/Block/*/state"])
    XCTAssertEqual(port, 9001)

    guard case let .unsubscribe(patterns, port) = try OSCOCARequest(OSCMessage("/unsubscribe"))
    else { return XCTFail() }
    XCTAssertEqual(patterns, [])
    XCTAssertNil(port)

    XCTAssertThrowsError(try OSCOCARequest(OSCMessage("/gain")))
    XCTAssertThrowsError(try OSCOCARequest(OSCMessage("/subscribe", values: [Float(1)])))
  }
}

final class OSCValueBridgeTests: XCTestCase {
  func testOCAToOSC() throws {
    XCTAssertEqual(try OSCValueBridge.oscValues(from: Float(-6)) as? [Float], [-6])
    XCTAssertEqual(try OSCValueBridge.oscValues(from: true) as? [Bool], [true])
    XCTAssertEqual(try OSCValueBridge.oscValues(from: UInt8(7)) as? [Int32], [7])
    XCTAssertEqual(try OSCValueBridge.oscValues(from: UInt32.max) as? [Int64], [Int64(UInt32.max)])
    XCTAssertEqual(try OSCValueBridge.oscValues(from: OcaMuteState.unmuted) as? [Int32], [2])
    XCTAssertEqual(try OSCValueBridge.oscValues(from: "label") as? [String], ["label"])
    XCTAssertEqual(
      try OSCValueBridge.oscValues(from: OcaVector2D<OcaInt32>(x: 1, y: 2)) as? [Int32],
      [1, 2]
    )
  }

  func testOSCToOCA() throws {
    XCTAssertEqual(try OSCValueBridge.value(Float.self, from: [Int32(-6)]), -6)
    XCTAssertEqual(try OSCValueBridge.value(UInt8.self, from: [Float(3)]), 3)
    XCTAssertEqual(try OSCValueBridge.value(Bool.self, from: [Int32(1)]), true)
    XCTAssertEqual(try OSCValueBridge.value(OcaMuteState.self, from: [Int32(1)]), .muted)
    XCTAssertEqual(
      try OSCValueBridge.value(OcaVector2D<OcaInt32>.self, from: [Int32(1), Int32(2)]),
      OcaVector2D(x: 1, y: 2)
    )
  }

  func testOutOfRange() {
    XCTAssertThrowsError(try OSCValueBridge.value(UInt8.self, from: [Int32(256)]))
    XCTAssertThrowsError(try OSCValueBridge.value(UInt8.self, from: [Int32(-1)]))
    XCTAssertThrowsError(try OSCValueBridge.value(OcaMuteState.self, from: [Int32(3)]))
    XCTAssertThrowsError(try OSCValueBridge.value(UInt8.self, from: [Float.nan]))
  }
}

/// What the bridge sends, as it would go out of its socket.
private actor Outbox {
  private(set) var messages = [(destination: String, message: OSCMessage)]()

  func append(_ data: Data, to destination: AnySocketAddress) {
    guard let packet = try? OSCPacket(from: data), case let .message(message) = packet else {
      return
    }
    messages.append(((try? destination.presentationAddress) ?? "?", message))
  }

  func messages(
    count: Int,
    timeout: Duration = .seconds(2)
  ) async -> [(destination: String, message: OSCMessage)] {
    let deadline = ContinuousClock.now + timeout
    while messages.count < count, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return messages
  }

  func messages(
    until isComplete: ([(destination: String, message: OSCMessage)]) -> Bool,
    timeout: Duration = .seconds(2)
  ) async -> [(destination: String, message: OSCMessage)] {
    let deadline = ContinuousClock.now + timeout
    while !isComplete(messages), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return messages
  }

  func removeAll() { messages.removeAll() }
}

/// An actuator with a settable vector property, which the library's classes lack.
@OcaDeviceClass
private final class XYActuator: SwiftOCADevice.OcaActuator {
  override class var classID: OcaClassID { OcaClassID(parent: super.classID, 65001) }

  @OcaVectorDeviceProperty(
    xPropertyID: OcaPropertyID("5.1"),
    yPropertyID: OcaPropertyID("5.2"),
    getMethodID: OcaMethodID("5.1"),
    setMethodID: OcaMethodID("5.2")
  )
  var position = OcaVector2D<OcaInt32>(x: 0, y: 0)
}

/// The device's objects, made once: the shared device is the only one there is.
private enum TestDevice {
  static let objects = Task { @OcaDevice in
    let device = OcaDevice.shared
    try await device.initializeDefaultObjects()
    let block = try await SwiftOCADevice.OcaBlock<SwiftOCADevice.OcaWorker>(
      role: "Block",
      deviceDelegate: device
    )
    let gain = try await SwiftOCADevice.OcaGain(
      role: "Gain",
      deviceDelegate: device,
      addToRootBlock: false
    )
    try await block.add(actionObject: gain)
    let mute = try await SwiftOCADevice.OcaMute(
      role: "Mute",
      deviceDelegate: device,
      addToRootBlock: false
    )
    try await block.add(actionObject: mute)
    let xy = try await XYActuator(role: "XY", deviceDelegate: device, addToRootBlock: false)
    try await block.add(actionObject: xy)
  }
}

final class OSCOCABridgeDeviceTests: XCTestCase {
  private var device: OcaDevice!
  private var bridge: OSCOCABridge!
  private var outbox: Outbox!

  private let client = try! AnySocketAddress(
    family: sa_family_t(AF_INET),
    presentationAddress: "127.0.0.1:9000"
  )
  private let otherClient = try! AnySocketAddress(
    family: sa_family_t(AF_INET),
    presentationAddress: "127.0.0.1:9100"
  )

  override func setUp() async throws {
    try await TestDevice.objects.value
    device = OcaDevice.shared

    let outbox = Outbox()
    self.outbox = outbox
    bridge = OSCOCABridge(address: client)
    await bridge._set(sender: { data, destination in await outbox.append(data, to: destination) })
    await bridge.startOutbound()
  }

  override func tearDown() async throws {
    await bridge.stop()
  }

  private func send(_ message: OSCMessage, from source: AnySocketAddress? = nil) async throws {
    try await bridge._handle(message: message.rawData(), from: source ?? client)
  }

  private func object(at rolePath: OcaNamePath) async throws -> SwiftOCADevice.OcaRoot {
    let oNo = try await device.rootBlock.findActionObjectsByRolePath(
      searchPath: rolePath,
      resultFlags: .oNo,
      from: bridge
    ).first?.oNo
    return try await XCTUnwrapAsync(device.resolve(objectNumber: XCTUnwrap(oNo)))
  }

  func testLeafResolutionOrder() async throws {
    let gain = try await object(at: ["Block", "Gain"])

    func member(_ leaf: String) async -> String? {
      switch await gain.oscMember(for: OSCOCAAddressLeaf(leaf)) {
      case let .method(methodID): "method \(methodID)"
      case let .property(descriptor): "property \(descriptor.name)"
      case nil: nil
      }
    }

    let gainMember = await member("gain")
    let gainByIDMember = await member("4p1")
    let setterByID = await member("4.2")
    let setterByAES70ID = await member("4m2")
    let setterByName = await member("setGain")
    let getterByName = await member("getGain")
    let wrongCase = await member("Gain")
    let unknown = await member("volume")
    XCTAssertEqual(gainMember, "property gain")
    XCTAssertEqual(gainByIDMember, "property gain")
    XCTAssertEqual(setterByID, "method 4.2")
    XCTAssertEqual(setterByAES70ID, "method 4.2")
    XCTAssertEqual(setterByName, "method 4.2")
    XCTAssertEqual(getterByName, "method 4.1")
    XCTAssertNil(wrongCase)
    XCTAssertNil(unknown)
  }

  func testGetAndSet() async throws {
    try await send(OSCMessage("/Block/Gain/gain", values: [Float(-6)]))
    try await send(OSCMessage("/Block/Gain/gain"))
    try await send(OSCMessage("/Block/Gain/4p1"))

    let messages = await outbox.messages(count: 2)
    XCTAssertEqual(messages.map(\.message.addressPattern.stringValue), [
      "/Block/Gain/gain",
      "/Block/Gain/4p1",
    ])
    XCTAssertEqual(messages.map { $0.message.values as? [Float] }, [[-6], [-6]])
    XCTAssertEqual(messages.first?.destination, "127.0.0.1:9000")
  }

  func testLegacyMethodInvocation() async throws {
    try await send(OSCMessage("/Block/Gain/4.2", values: [Float(-3)]))
    try await send(OSCMessage("/Block/Gain/setGain", values: [Float(-4)]))
    try await send(OSCMessage("/Block/Gain/gain"))

    let messages = await outbox.messages(count: 1)
    XCTAssertEqual(messages.map { $0.message.values as? [Float] }, [[-4]])
  }

  func testMuteIsBoolean() async throws {
    try await send(OSCMessage("/Block/Mute/state", values: [false]))
    try await send(OSCMessage("/Block/Mute/state"))
    try await send(OSCMessage("/Block/Mute/state", values: [true]))
    try await send(OSCMessage("/Block/Mute/state"))

    let messages = await outbox.messages(count: 2)
    XCTAssertEqual(messages.map { $0.message.values as? [Bool] }, [[false], [true]])
  }

  func testErrors() async throws {
    try await send(OSCMessage("/Block/Gain/volume", values: [Float(0)]))
    try await send(OSCMessage("/Block/Nothing/gain"))
    try await send(OSCMessage("/Block/Gain/gain", values: [Float(100)]))

    let messages = await outbox.messages(count: 3)
    XCTAssertEqual(
      messages.map(\.message.addressPattern.stringValue),
      ["/error", "/error", "/error"]
    )
    XCTAssertEqual(messages.first?.message.values.first as? String, "/Block/Gain/volume")
  }

  func testSubscriptionSendsCurrentValueThenChanges() async throws {
    try await send(OSCMessage("/subscribe", values: ["/Block/Gain/gain", Int32(9001)]))
    var messages = await outbox.messages(count: 1)
    XCTAssertEqual(messages.map(\.destination), ["127.0.0.1:9001"])
    XCTAssertEqual(messages.map(\.message.addressPattern.stringValue), ["/Block/Gain/gain"])
    await outbox.removeAll()

    // a change made by another peer, by property ID, is sent as subscribed
    try await send(OSCMessage("/Block/Gain/4p1", values: [Float(-12)]), from: otherClient)
    messages = await outbox.messages(count: 1)
    XCTAssertEqual(messages.map(\.destination), ["127.0.0.1:9001"])
    XCTAssertEqual(messages.map(\.message.addressPattern.stringValue), ["/Block/Gain/gain"])
    XCTAssertEqual(messages.map { $0.message.values as? [Float] }, [[-12]])
    await outbox.removeAll()

    try await send(OSCMessage("/unsubscribe", values: [Int32(9001)]))
    try await send(OSCMessage("/Block/Gain/gain", values: [Float(-1)]), from: otherClient)
    messages = await outbox.messages(count: 1, timeout: .milliseconds(200))
    XCTAssertTrue(messages.isEmpty)
  }

  func testWildcardSubscription() async throws {
    try await send(OSCMessage("/subscribe", values: ["/Block/*/state", "/Block/Gain/4p*"]))
    let messages = await outbox.messages(count: 2)
    XCTAssertEqual(
      Set(messages.map(\.message.addressPattern.stringValue)),
      ["/Block/Mute/state", "/Block/Gain/4p1"]
    )
  }

  func testManagersAreAddressedByRole() async throws {
    try await send(OSCMessage("/DeviceManager/deviceName", values: ["OSC Test"]))
    try await send(OSCMessage("/DeviceManager/deviceName"))
    var messages = await outbox.messages(count: 1)
    XCTAssertEqual(messages.map { $0.message.values as? [String] }, [["OSC Test"]])
    await outbox.removeAll()

    // as are the properties a pattern matches
    try await send(OSCMessage("/subscribe", values: ["/Device*/device[N]ame", Int32(9001)]))
    messages = await outbox.messages(count: 1)
    XCTAssertEqual(
      messages.map(\.message.addressPattern.stringValue),
      ["/DeviceManager/deviceName"]
    )
    await outbox.removeAll()

    try await send(OSCMessage("/DeviceManager/deviceName", values: ["Renamed"]), from: otherClient)
    messages = await outbox.messages(count: 1)
    XCTAssertEqual(messages.map(\.destination), ["127.0.0.1:9001"])
    XCTAssertEqual(messages.map { $0.message.values as? [String] }, [["Renamed"]])
  }

  func testSubscribeToEverything() async throws {
    let expected: Set = ["/Block/Gain/gain", "/Block/Mute/state"]
    try await send(OSCMessage("/subscribe"))
    let messages = await outbox.messages(until: {
      expected.isSubset(of: $0.map(\.message.addressPattern.stringValue))
    })
    let addresses = Set(messages.map(\.message.addressPattern.stringValue))
    XCTAssertTrue(addresses.contains("/Block/Gain/gain"))
    XCTAssertTrue(addresses.contains("/Block/Mute/state"))
  }

  func testVectorPropertyConvertsEachComponent() async throws {
    try await send(OSCMessage("/subscribe", values: ["/Block/XY/position", Int32(9001)]))
    _ = await outbox.messages(count: 1)
    await outbox.removeAll()

    // floats are converted to the integer components, not reinterpreted
    try await send(
      OSCMessage("/Block/XY/position", values: [Float(3), Float(4)]),
      from: otherClient
    )
    try await send(OSCMessage("/Block/XY/position"))
    let messages = await outbox.messages(count: 2)
    // one change message for the two component events, then the reply to the get
    XCTAssertEqual(messages.map(\.destination), ["127.0.0.1:9001", "127.0.0.1:9000"])
    XCTAssertEqual(messages.map { $0.message.values as? [Int32] }, [[3, 4], [3, 4]])
    let late = await outbox.messages(count: 3, timeout: .milliseconds(200))
    XCTAssertEqual(late.count, 2, "a vector change is sent once")

    try await send(OSCMessage("/Block/XY/position", values: [Float(1)]))
    let error = await outbox.messages(count: 3)
    XCTAssertEqual(error.last?.message.addressPattern.stringValue, "/error")
  }

  func testUnsubscribeWithoutPortCoversPortSubscriptions() async throws {
    try await send(OSCMessage("/subscribe", values: ["/Block/Gain/gain", Int32(9001)]))
    _ = await outbox.messages(count: 1)
    await outbox.removeAll()

    // as TouchOSC would on exit: no port, so every subscription from this host goes
    try await send(OSCMessage("/unsubscribe"))
    try await send(OSCMessage("/Block/Gain/gain", values: [Float(-20)]), from: otherClient)
    let messages = await outbox.messages(count: 1, timeout: .milliseconds(200))
    XCTAssertTrue(messages.isEmpty)
  }

  func testDestinationAddedBeforeRunningIsSentOnceRunning() async throws {
    let outbox = Outbox()
    let bridge = OSCOCABridge(address: client)
    let destination = try AnySocketAddress(
      family: sa_family_t(AF_INET),
      presentationAddress: "127.0.0.1:9300"
    )
    try await bridge.addDestination(destination, patterns: ["/Block/Gain/gain"])
    var messages = await outbox.messages(count: 1, timeout: .milliseconds(200))
    XCTAssertTrue(messages.isEmpty)

    // the socket arrives, as it does when the bridge runs; the initial value was waiting
    await bridge._set(sender: { data, destination in await outbox.append(data, to: destination) })
    messages = await outbox.messages(count: 1)
    XCTAssertEqual(messages.map(\.destination), ["127.0.0.1:9300"])
    XCTAssertEqual(messages.map(\.message.addressPattern.stringValue), ["/Block/Gain/gain"])
    await bridge.stop()
  }

  func testIPv6DestinationKeepsTheSourceAddress() async throws {
    let client6 = try AnySocketAddress(
      family: sa_family_t(AF_INET6),
      presentationAddress: "[::1]:9000"
    )
    try await send(
      OSCMessage("/subscribe", values: ["/Block/Gain/gain", Int32(9001)]),
      from: client6
    )
    let messages = await outbox.messages(count: 1)
    XCTAssertEqual(messages.map(\.destination), ["[::1]:9001"])
  }

  func testStaticDestinationSurvivesAPeerUnsubscribing() async throws {
    let destination = try AnySocketAddress(
      family: sa_family_t(AF_INET),
      presentationAddress: "127.0.0.1:9200"
    )
    try await send(OSCMessage("/Block/Mute/state", values: [false]))
    try await bridge.addDestination(destination, patterns: ["/Block/Mute/state"])
    _ = await outbox.messages(count: 1)
    await outbox.removeAll()

    // another client on the same host unsubscribing is not the app removing its destination
    try await send(OSCMessage("/unsubscribe"))
    try await send(OSCMessage("/unsubscribe", values: [Int32(9200)]))
    try await send(OSCMessage("/Block/Mute/state", values: [true]))
    let messages = await outbox.messages(count: 1)
    XCTAssertEqual(messages.map(\.destination), ["127.0.0.1:9200"])

    await bridge.removeDestination(destination)
    await outbox.removeAll()
    try await send(OSCMessage("/Block/Mute/state", values: [false]))
    let after = await outbox.messages(count: 1, timeout: .milliseconds(200))
    XCTAssertTrue(after.isEmpty)
  }

  func testSubscribingToNothingIsAnError() async throws {
    try await send(OSCMessage("/subscribe", values: ["/Nope/*"]))
    let messages = await outbox.messages(count: 1)
    XCTAssertEqual(messages.map(\.message.addressPattern.stringValue), ["/error"])
    XCTAssertEqual(messages.first?.message.values.first as? String, "/subscribe")
  }

  func testErrorIsNotAnswered() async throws {
    try await send(OSCMessage("/error", values: ["/Block/Gain/volume", "badMethod"]))
    let messages = await outbox.messages(count: 1, timeout: .milliseconds(200))
    XCTAssertTrue(messages.isEmpty)
  }

  func testResubscribingAfterUnsubscribing() async throws {
    // the bridge's subscription to the object is made and removed each time
    for value in [Float(-30), Float(-31), Float(-32)] {
      try await send(OSCMessage("/subscribe", values: ["/Block/Gain/gain", Int32(9001)]))
      _ = await outbox.messages(count: 1)
      await outbox.removeAll()
      try await send(OSCMessage("/Block/Gain/gain", values: [value]), from: otherClient)
      let messages = await outbox.messages(count: 1)
      XCTAssertEqual(messages.map { $0.message.values as? [Float] }, [[value]])
      await outbox.removeAll()
      try await send(OSCMessage("/unsubscribe", values: [Int32(9001)]))
    }
  }

  func testStopKeepsStaticDestinations() async throws {
    let destination = try AnySocketAddress(
      family: sa_family_t(AF_INET),
      presentationAddress: "127.0.0.1:9400"
    )
    try await send(OSCMessage("/Block/Mute/state", values: [false]))
    try await bridge.addDestination(destination, patterns: ["/Block/Mute/state"])
    try await send(OSCMessage("/subscribe", values: ["/Block/Mute/state", Int32(9001)]))
    _ = await outbox.messages(count: 2)

    await bridge.stop()
    await outbox.removeAll()
    // as run() would: drain again, with a new socket
    let outbox = outbox!
    await bridge.startOutbound()
    await bridge._set(sender: { data, destination in await outbox.append(data, to: destination) })

    try await send(OSCMessage("/Block/Mute/state", values: [true]))
    let messages = await outbox.messages(count: 1)
    // the destination was kept; the peer's subscription went with the stop
    let late = await outbox.messages(count: 2, timeout: .milliseconds(200))
    XCTAssertEqual(messages.map(\.destination), ["127.0.0.1:9400"])
    XCTAssertEqual(late.count, 1)
    await bridge.removeDestination(destination)
  }

  func testStaticDestination() async throws {
    let destination = try AnySocketAddress(
      family: sa_family_t(AF_INET),
      presentationAddress: "127.0.0.1:9200"
    )
    // an unchanged value raises no event, so start from a known one
    try await send(OSCMessage("/Block/Mute/state", values: [false]))
    try await bridge.addDestination(destination, patterns: ["/Block/Mute/state"])
    var messages = await outbox.messages(count: 1)
    XCTAssertEqual(messages.map { $0.message.values as? [Bool] }, [[false]])
    await outbox.removeAll()

    try await send(OSCMessage("/Block/Mute/state", values: [true]))
    messages = await outbox.messages(count: 1)
    XCTAssertEqual(messages.map(\.destination), ["127.0.0.1:9200"])
    XCTAssertEqual(messages.map { $0.message.values as? [Bool] }, [[true]])
  }
}

private func XCTUnwrapAsync<T>(_ value: T?) throws -> T {
  try XCTUnwrap(value)
}
