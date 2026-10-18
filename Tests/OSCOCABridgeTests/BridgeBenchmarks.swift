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
import Synchronization
import XCTest

/// Run with `OSCOCA_BENCH=<objects> swift test -c release -Xswiftc -enable-testing --filter
/// BridgeBenchmarks`, where `<objects>` is the size of the block of gains the device is given
/// (10 by default). They add a block of their own to the shared device.
final class BridgeBenchmarks: XCTestCase {
  /// The device has one block of this many gains, so that each run measures one size.
  private static let treeSize = Int(ProcessInfo.processInfo.environment["OSCOCA_BENCH"] ?? "") ?? 10
  private static let treeSizes = [treeSize]
  private static let subscriberCounts = [0, 1, 10, 100]

  /// The objects, made once: a block of each tree size, each of that many gains.
  private static let objects = Task { @OcaDevice in
    let device = OcaDevice.shared
    try await SharedDevice.initialized.value
    for size in treeSizes {
      let block = try await SwiftOCADevice.OcaBlock<SwiftOCADevice.OcaWorker>(
        role: "Bench\(size)",
        deviceDelegate: device
      )
      for index in 0..<size {
        let gain = try await SwiftOCADevice.OcaGain(
          role: "Gain\(index)",
          deviceDelegate: device,
          addToRootBlock: false
        )
        try await block.add(actionObject: gain)
      }
    }
  }

  private static let client = try! AnySocketAddress(
    family: sa_family_t(AF_INET),
    presentationAddress: "127.0.0.1:9000"
  )

  override func setUp() async throws {
    guard ProcessInfo.processInfo.environment["OSCOCA_BENCH"] != nil else {
      throw XCTSkip("set OSCOCA_BENCH to run")
    }
    try await Self.objects.value
  }

  // MARK: - helpers

  private struct Result {
    let name: String
    let nanosecondsPerOperation: Double
  }

  private static func time(
    _ iterations: Int,
    _ body: (Int) async throws -> ()
  ) async rethrows -> Double {
    // warm up: caches, first-use allocations
    for i in 0..<min(iterations / 10, 200) {
      try await body(i)
    }
    let start = ContinuousClock.now
    for i in 0..<iterations {
      try await body(i)
    }
    let elapsed = ContinuousClock.now - start
    let (seconds, attoseconds) = elapsed.components
    return (Double(seconds) * 1e9 + Double(attoseconds) / 1e9) / Double(iterations)
  }

  private func report(_ results: [Result]) {
    for result in results {
      let ns = result.nanosecondsPerOperation
      print(String(
        format: "BENCH %-58@ %10.0f ns/op %10.0f op/s",
        result.name as NSString,
        ns,
        1e9 / ns
      ))
    }
  }

  private final class Counter: Sendable {
    private let count = Atomic<Int>(0)
    func increment() { count.add(1, ordering: .relaxed) }
    var value: Int { count.load(ordering: .relaxed) }
  }

  /// A bridge whose sender counts what it is handed.
  private func makeBridge() async -> (OSCOCABridge, Counter) {
    let sent = Counter()
    let bridge = OSCOCABridge(address: Self.client)
    let sender: OSCOCABridge.Sender = { _, _ in sent.increment() }
    await bridge.startOutbound()
    await bridge._startDraining(with: sender)
    return (bridge, sent)
  }

  private func packet(_ address: String, _ values: OSCValues) throws -> Data {
    try OSCMessage(address, values: values).rawData()
  }

  private func gainONo(_ path: OcaNamePath, from bridge: OSCOCABridge) async throws -> OcaONo {
    let rootBlock = await OcaDevice.shared.rootBlock!
    let oNo = try await rootBlock.findActionObjectsByRolePath(
      searchPath: path,
      resultFlags: .oNo,
      from: bridge
    ).first?.oNo
    return try XCTUnwrap(oNo)
  }

  // MARK: - benchmarks

  func testCommandPaths() async throws {
    let (bridge, _) = await makeBridge()
    let iterations = 20000
    let oNo = try await gainONo(["Bench\(Self.treeSize)", "Gain0"], from: bridge)
    // alternate values so that every set is a change
    let values: [Float] = [-6, -12]

    let ocp1 = try values.map { value in
      try Ocp1Command(
        handle: 0,
        targetONo: oNo,
        methodID: OcaMethodID("4.2"),
        parameters: OcaParameters(parameterCount: 1, parameterData: Ocp1Encoder().encode(value))
      )
    }
    let byName = try values.map { try packet("/Bench\(Self.treeSize)/Gain0/gain", [$0]) }
    let byMethodID = try values.map { try packet("/Bench\(Self.treeSize)/Gain0/4.2", [$0]) }
    let byMethodName = try values.map { try packet("/Bench\(Self.treeSize)/Gain0/setGain", [$0]) }
    let get = try packet("/Bench\(Self.treeSize)/Gain0/gain", [])

    var results = [Result]()
    await results.append(Result(
      name: "OCP.1 SetGain, straight to handleCommand (baseline)",
      nanosecondsPerOperation: Self.time(iterations) { i in
        _ = await OcaDevice.shared.handleCommand(ocp1[i & 1], from: bridge)
      }
    ))
    try await results.append(Result(
      name: "OSC set by property name   /Bench\(Self.treeSize)/Gain0/gain",
      nanosecondsPerOperation: Self.time(iterations) { i in
        try await bridge._handle(message: byName[i & 1], from: Self.client)
      }
    ))
    try await results.append(Result(
      name: "OSC set by method ID       /Bench\(Self.treeSize)/Gain0/4.2",
      nanosecondsPerOperation: Self.time(iterations) { i in
        try await bridge._handle(message: byMethodID[i & 1], from: Self.client)
      }
    ))
    try await results.append(Result(
      name: "OSC set by method name     /Bench\(Self.treeSize)/Gain0/setGain",
      nanosecondsPerOperation: Self.time(iterations) { i in
        try await bridge._handle(message: byMethodName[i & 1], from: Self.client)
      }
    ))
    try await results.append(Result(
      name: "OSC get, reply encoded and queued",
      nanosecondsPerOperation: Self.time(iterations) { _ in
        try await bridge._handle(message: get, from: Self.client)
      }
    ))
    report(results)
    await bridge.stop()
  }

  func testRolePathLookup() async throws {
    let (bridge, _) = await makeBridge()
    let rootBlock = await OcaDevice.shared.rootBlock!
    let size = Self.treeSize
    let path = ["Bench\(size)", "Gain\(size - 1)"]
    let nanoseconds = try await Self.time(2000) { _ in
      _ = try await rootBlock.findActionObjectsByRolePath(
        searchPath: path,
        resultFlags: .oNo,
        from: bridge
      )
    }
    report([Result(
      name: "findActionObjectsByRolePath alone, \(size + 1) objects",
      nanosecondsPerOperation: nanoseconds
    )])
    await bridge.stop()
  }

  func testTreeSize() async throws {
    let (bridge, _) = await makeBridge()
    var results = [Result]()
    for size in Self.treeSizes {
      // the last gain in the block, which a walk of the block comes to last
      let address = "/Bench\(size)/Gain\(size - 1)/gain"
      let packets = try [Float(-6), Float(-12)].map { try packet(address, [$0]) }
      let iterations = size >= 1000 ? 2000 : 10000
      try await results.append(Result(
        name: "OSC set, block of \(size) objects",
        nanosecondsPerOperation: Self.time(iterations) { i in
          try await bridge._handle(message: packets[i & 1], from: Self.client)
        }
      ))
    }
    report(results)
    await bridge.stop()
  }

  func testFanOut() async throws {
    var results = [Result]()
    for count in Self.subscriberCounts {
      let (bridge, sent) = await makeBridge()
      let address = "/Bench\(Self.treeSize)/Gain1/gain"
      for peer in 0..<count {
        let source = try AnySocketAddress(
          family: sa_family_t(AF_INET),
          presentationAddress: "127.0.0.1:\(20000 + peer)"
        )
        try await bridge._handle(message: packet("/subscribe", [address]), from: source)
      }
      let packets = try [Float(-6), Float(-12)].map { try packet(address, [$0]) }
      // the setter is not subscribed, so a set sends nothing but the notifications
      let setter = try AnySocketAddress(
        family: sa_family_t(AF_INET),
        presentationAddress: "127.0.0.2:9000"
      )
      let iterations = 5000
      let before = sent.value
      let start = ContinuousClock.now
      for i in 0..<iterations {
        try await bridge._handle(message: packets[i & 1], from: setter)
      }
      let setsDone = ContinuousClock.now
      // until the socket has been handed everything it will be, which it stops being
      // handed once the queue is drained
      var last = -1
      while sent.value != last {
        last = sent.value
        try await Task.sleep(for: .milliseconds(50))
      }
      let delivered = sent.value - before
      let expected = iterations * count
      func ns(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return (Double(seconds) * 1e9 + Double(attoseconds) / 1e9) / Double(iterations)
      }
      results.append(Result(
        name: "OSC set, \(count) subscriber(s): the set, notifications queued",
        nanosecondsPerOperation: ns(setsDone - start)
      ))
      print(
        "BENCH   \(count) subscriber(s): \(delivered) of \(expected) notifications reached the socket"
      )
      await bridge.stop()
    }
    report(results)
  }

  func testValueConversion() async throws {
    let iterations = 200_000
    var results = [Result]()
    try await results.append(Result(
      name: "OCA → OSC, Float",
      nanosecondsPerOperation: Self.time(iterations) { _ in
        _ = try OSCValueBridge.oscValues(from: Float(-6))
      }
    ))
    try await results.append(Result(
      name: "OCA → OSC, OcaMuteState (enumeration)",
      nanosecondsPerOperation: Self.time(iterations) { _ in
        _ = try OSCValueBridge.oscValues(from: OcaMuteState.muted)
      }
    ))
    try await results.append(Result(
      name: "OCA → OSC, OcaVector2D<OcaInt32> (record)",
      nanosecondsPerOperation: Self.time(iterations) { _ in
        _ = try OSCValueBridge.oscValues(from: OcaVector2D<OcaInt32>(x: 1, y: 2))
      }
    ))
    try await results.append(Result(
      name: "OSC → OCA, Float from Int32",
      nanosecondsPerOperation: Self.time(iterations) { _ in
        _ = try OSCValueBridge.value(Float.self, from: [Int32(-6)])
      }
    ))
    let message = try packet("/Bench\(Self.treeSize)/Gain0/gain", [Float(-6)])
    try await results.append(Result(
      name: "OSC message parse (/Bench\(Self.treeSize)/Gain0/gain ,f)",
      nanosecondsPerOperation: Self.time(iterations) { _ in
        _ = try OSCPacket(from: message)
      }
    ))
    report(results)
  }
}
