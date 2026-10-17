//
// Copyright (c) 2025-2026 PADL Software Pty Ltd
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
import SwiftOSCCore
@_spi(SwiftOCAPrivate)
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import SocketAddress

let MaxMessageSize = 1500

/// Bridges OSC to an OCA device. The OSC address space is the device's object tree: an
/// object is addressed by its role path, and the last component names one of its
/// members, a method by ID (`4.2` or `4m2`) or name (`setGain`), or a property by ID
/// (`4p1`) or name (`gain`). A property is read with no arguments and written with them.
/// `/subscribe` and `/unsubscribe` manage which property changes are sent to a peer.
public actor OSCOCABridge {
  let address: any SocketAddress
  let device: OcaDevice
  let subscriptionLifetime: Duration?
  var task: Task<(), Error>?

  /// Sends a datagram from the bridge's socket, once the event loop has bound it.
  typealias Sender = @Sendable (Data, AnySocketAddress) async throws -> ()

  private var sender: Sender?
  private var outbound: AsyncStream<(Data, AnySocketAddress)>.Continuation?
  private var outboundTask: Task<(), Never>?
  private var sweepTask: Task<(), Never>?

  /// A property change a peer is sent, on the address it subscribed with.
  struct Subscription: Hashable, Sendable {
    let oNo: OcaONo
    let propertyID: OcaPropertyID
    let address: String
  }

  struct Peer {
    var subscriptions = [Subscription: OcaDevicePropertyDescriptor]()
    var lastSeen = ContinuousClock.now
    /// Added with `addDestination(_:patterns:)`; never expires.
    var isStatic = false
  }

  /// Peers by the address property changes are sent to.
  private var peers = [AnySocketAddress: Peer]()
  /// How many subscriptions there are to each emitter's events, over all peers; the bridge
  /// holds one OCA subscription for each emitter with any.
  private var emitterSubscriptionCounts = [OcaONo: Int]()

  /// `subscriptionLifetime` is how long a peer's subscriptions last after the last datagram
  /// from its host; nil, the default, keeps them until it unsubscribes or the bridge stops.
  public init(
    address: any SocketAddress,
    device: OcaDevice,
    subscriptionLifetime: Duration? = nil
  ) {
    self.address = address
    self.device = device
    self.subscriptionLifetime = subscriptionLifetime
  }

  deinit {
    task?.cancel()
    outboundTask?.cancel()
    sweepTask?.cancel()
    outbound?.finish()
  }

  public func run() {
    task?.cancel()
    startOutbound()
    startSweeping()
    task = Task {
      try await udpEventLoop(address: address, with: self)
    }
  }

  public func stop() async {
    task?.cancel()
    task = nil
    sweepTask?.cancel()
    sweepTask = nil
    for destination in Array(peers.keys) {
      await removePeer(destination)
    }
    outbound?.finish()
    outbound = nil
    outboundTask = nil
    sender = nil
  }

  /// Sends the changes of every property matching `patterns`, or of every property if there
  /// are none, to `destination`, until it is removed.
  public func addDestination(
    _ destination: any SocketAddress,
    patterns: [String] = []
  ) async throws {
    let destination = AnySocketAddress(destination)
    try await subscribe(destination, to: patterns)
    peers[destination]?.isStatic = true
  }

  public func removeDestination(_ destination: any SocketAddress) async {
    await removePeer(AnySocketAddress(destination))
  }

  // MARK: - inbound

  func _set(sender: @escaping Sender) {
    self.sender = sender
  }

  private func _handle(message: OSCMessage, from source: AnySocketAddress) async {
    do {
      switch try OSCOCARequest(message) {
      case let .subscribe(patterns, port):
        try await subscribe(destination(for: source, port: port), to: patterns)
      case let .unsubscribe(patterns, port):
        try await unsubscribe(destination(for: source, port: port), from: patterns)
      case let .member(rolePath, leaf):
        try await handle(message, rolePath: rolePath, leaf: leaf, from: source)
      }
    } catch {
      let reason = if case let Ocp1Error.status(status) = error {
        String(describing: status)
      } else {
        String(describing: error)
      }
      send(OSCMessage("/error", values: [message.addressPattern.stringValue, reason]), to: source)
    }
  }

  private func _handle(message: OSCPacket, from source: AnySocketAddress) async {
    switch message {
    case let .bundle(bundle):
      for element in bundle.elements {
        await _handle(message: element, from: source)
      }
    case let .message(message):
      await _handle(message: message, from: source)
    }
  }

  func _handle(message: Data, from source: any SocketAddress) async throws {
    guard let message = try OSCPacket(from: message) else {
      throw Ocp1Error.status(.invalidRequest)
    }

    let source = AnySocketAddress(source)
    renew(host: source)
    await _handle(message: message, from: source)
  }

  #if !os(Linux)
  func _handle(message: Data, from source: sockaddr_storage) async throws {
    try await _handle(message: message, from: AnySocketAddress(source))
  }

  func _set(sender: @escaping @Sendable (Data, sockaddr_storage) async throws -> ()) {
    self.sender = { data, destination in try await sender(data, destination.asStorage()) }
  }
  #endif

  private func handle(
    _ message: OSCMessage,
    rolePath: OcaNamePath,
    leaf: OSCOCALeaf,
    from source: AnySocketAddress
  ) async throws {
    let (oNo, member) = try await resolve(rolePath: rolePath, leaf: leaf)

    switch member {
    case let .method(methodID):
      try await invoke(methodID, on: oNo, with: message)
    case let .property(descriptor):
      if message.values.isEmpty {
        let values = try await get(descriptor, of: oNo)
        send(OSCMessage(message.addressPattern, values: values), to: source)
      } else {
        try await set(descriptor, of: oNo, from: message)
      }
    }
  }

  private func resolve(
    rolePath: OcaNamePath,
    leaf: OSCOCALeaf
  ) async throws -> (OcaONo, OSCOCAMember) {
    guard let rootBlock = await device.rootBlock else {
      throw Ocp1Error.status(.deviceError)
    }
    guard let oNo = try await rootBlock.findActionObjectsByRolePath(
      searchPath: rolePath,
      resultFlags: .oNo,
      from: self
    ).first?.oNo,
      let object = await device.resolve(objectNumber: oNo)
    else {
      throw Ocp1Error.status(.badONo)
    }
    guard let member = await object.oscMember(for: leaf) else {
      throw Ocp1Error.status(.badMethod)
    }
    return (oNo, member)
  }

  // MARK: - methods and properties

  private func perform(
    _ methodID: OcaMethodID,
    on oNo: OcaONo,
    parameterCount: Int,
    parameterData: Data
  ) async throws -> Ocp1Response {
    guard let parameterCount = OcaUint8(exactly: parameterCount) else {
      throw Ocp1Error.status(.parameterOutOfRange)
    }
    let command = Ocp1Command(
      handle: 0,
      targetONo: oNo,
      methodID: methodID,
      parameters: OcaParameters(parameterCount: parameterCount, parameterData: parameterData)
    )
    let response = await device.handleCommand(command, from: self)
    guard response.statusCode == .ok else {
      throw Ocp1Error.status(response.statusCode)
    }
    return response
  }

  /// Invokes a method with the message's arguments encoded as OCP.1 in order, unless the
  /// object bridges them itself.
  private func invoke(
    _ methodID: OcaMethodID,
    on oNo: OcaONo,
    with message: OSCMessage
  ) async throws {
    var parameters: (count: Int, data: Data)?

    if let object = await device.resolve(objectNumber: oNo) as? OSCOCACustomBridgeable {
      do {
        let values = try await object.bridgeValues(from: message, for: methodID)
        parameters = try (values.count, values.map { $0 as any Encodable }._ocp1Encoded)
      } catch OSCOCACustomBridgeableError.methodNotBridged {}
    }

    let (count, data) = try parameters ?? (message.values.count, message.values._ocp1Encoded)
    _ = try await perform(methodID, on: oNo, parameterCount: count, parameterData: data)
  }

  /// The property's value as OSC arguments. A bounded property's getter answers with its
  /// range after the value, which is left out.
  private func get(
    _ descriptor: OcaDevicePropertyDescriptor,
    of oNo: OcaONo
  ) async throws -> OSCValues {
    guard let getMethodID = descriptor.getMethodID else {
      throw Ocp1Error.status(.notImplemented)
    }
    let response = try await perform(getMethodID, on: oNo, parameterCount: 0, parameterData: Data())
    let value = try Ocp1Decoder().decode(
      descriptor.valueType,
      from: response.parameters.parameterData
    )
    return try await oscValues(from: value, of: descriptor, on: oNo)
  }

  private func set(
    _ descriptor: OcaDevicePropertyDescriptor,
    of oNo: OcaONo,
    from message: OSCMessage
  ) async throws {
    guard let setMethodID = descriptor.setMethodID else {
      throw Ocp1Error.status(.notImplemented)
    }

    var value: (any Encodable & Sendable)?
    if let object = await device.resolve(objectNumber: oNo) as? OSCOCACustomBridgeable {
      do {
        value = try await object.bridgeValue(from: message, for: descriptor.propertyID)
      } catch OSCOCACustomBridgeableError.propertyNotBridged {}
    }
    let encoded = try (value ?? OSCValueBridge.value(descriptor.valueType, from: message.values))
      ._ocp1Encoded

    // a vector property's setter takes its components as two parameters
    let parameterCount = descriptor.yPropertyID == nil ? 1 : 2
    _ = try await perform(
      setMethodID,
      on: oNo,
      parameterCount: parameterCount,
      parameterData: encoded
    )
  }

  private func oscValues(
    from value: any Sendable,
    of descriptor: OcaDevicePropertyDescriptor,
    on oNo: OcaONo
  ) async throws -> OSCValues {
    if let object = await device.resolve(objectNumber: oNo) as? OSCOCACustomBridgeable {
      do {
        return try await object.bridgeOSCValues(from: value, for: descriptor.propertyID)
      } catch OSCOCACustomBridgeableError.propertyNotBridged {}
    }
    return try OSCValueBridge.oscValues(from: value)
  }

  // MARK: - subscriptions

  /// Where a peer is sent property changes: its host, at `port` if it names one, else at
  /// the port it sent from.
  private func destination(for source: AnySocketAddress, port: UInt16?) throws -> AnySocketAddress {
    guard let port else { return source }
    let host = try source.presentationAddressNoPort
    let presentationAddress = source.family == sa_family_t(AF_INET6)
      ? "[\(host)]:\(port)"
      : "\(host):\(port)"
    return try AnySocketAddress(family: source.family, presentationAddress: presentationAddress)
  }

  /// The properties `patterns` name, each with the address its changes are sent on. A
  /// pattern without wildcards is resolved as an address; one with them is matched against
  /// every property's address by name and by ID. No patterns names every property.
  private func resolve(
    patterns: [String]
  ) async throws -> [Subscription: OcaDevicePropertyDescriptor] {
    var resolved = [Subscription: OcaDevicePropertyDescriptor]()
    var objects: [(rolePath: OcaNamePath, object: SwiftOCADevice.OcaRoot)]?

    func allObjects() async throws -> [(rolePath: OcaNamePath, object: SwiftOCADevice.OcaRoot)] {
      if let objects { return objects }
      guard let rootBlock = await device.rootBlock else {
        throw Ocp1Error.status(.deviceError)
      }
      let all = await oscObjects(in: rootBlock)
      objects = all
      return all
    }

    for pattern in patterns where !pattern.isOSCAddressPattern {
      guard case let .member(rolePath, leaf) = try OSCOCARequest
        .member(OSCAddressPattern(pattern).pathComponents)
      else { continue }
      let (oNo, member) = try await resolve(rolePath: rolePath, leaf: leaf)
      guard case let .property(descriptor) = member else {
        throw Ocp1Error.status(.badMethod)
      }
      resolved[Subscription(oNo: oNo, propertyID: descriptor.propertyID, address: pattern)] =
        descriptor
    }

    let wildcards = patterns.filter(\.isOSCAddressPattern).map { OSCAddressPattern($0) }
    if patterns.isEmpty || !wildcards.isEmpty {
      for (rolePath, object) in try await allObjects() {
        for descriptor in await object.oscVisibleProperties where descriptor.getMethodID != nil {
          let byName = oscAddress(rolePath: rolePath, leaf: descriptor.name)
          let byID = oscAddress(rolePath: rolePath, leaf: descriptor.propertyID.oscLeaf)
          let address: String? = if patterns.isEmpty {
            byName
          } else if wildcards.contains(where: { $0.matches(localAddress: byName) }) {
            byName
          } else if wildcards.contains(where: { $0.matches(localAddress: byID) }) {
            byID
          } else {
            nil
          }
          guard let address else { continue }
          resolved[Subscription(
            oNo: object.objectNumber,
            propertyID: descriptor.propertyID,
            address: address
          )] = descriptor
        }
      }
    }

    return resolved
  }

  private func subscribe(_ destination: AnySocketAddress, to patterns: [String]) async throws {
    let resolved = try await resolve(patterns: patterns)
    var peer = peers[destination] ?? Peer()
    peer.lastSeen = .now

    var added = [(Subscription, OcaDevicePropertyDescriptor)]()
    for (subscription, descriptor) in resolved where peer.subscriptions[subscription] == nil {
      peer.subscriptions[subscription] = descriptor
      added.append((subscription, descriptor))
    }
    peers[destination] = peer

    for (subscription, _) in added {
      try await retainEmitter(subscription.oNo)
    }

    // the current values, which a newly subscribed peer would otherwise not have
    for (subscription, descriptor) in resolved {
      if let values = try? await get(descriptor, of: subscription.oNo) {
        send(OSCMessage(subscription.address, values: values), to: destination)
      }
    }
  }

  private func unsubscribe(_ destination: AnySocketAddress, from patterns: [String]) async throws {
    guard let peer = peers[destination] else { return }
    guard !patterns.isEmpty else {
      await removePeer(destination)
      return
    }

    let patterns = patterns.map { OSCAddressPattern($0) }
    let removed = peer.subscriptions.keys.filter { subscription in
      patterns.contains { $0.stringValue == subscription.address ||
        $0.matches(localAddress: subscription.address)
      }
    }
    for subscription in removed {
      peers[destination]?.subscriptions[subscription] = nil
      await releaseEmitter(subscription.oNo)
    }
    if peers[destination]?.subscriptions.isEmpty == true, peers[destination]?.isStatic == false {
      peers[destination] = nil
    }
  }

  private func removePeer(_ destination: AnySocketAddress) async {
    guard let peer = peers.removeValue(forKey: destination) else { return }
    for subscription in peer.subscriptions.keys {
      await releaseEmitter(subscription.oNo)
    }
  }

  private func emitterSubscription(_ oNo: OcaONo) -> OcaSubscriptionManagerSubscription {
    .subscription2(OcaSubscription2(
      event: OcaEvent(emitterONo: oNo, eventID: OcaPropertyChangedEventID),
      notificationDeliveryMode: .normal,
      destinationInformation: OcaNetworkAddress()
    ))
  }

  private func retainEmitter(_ oNo: OcaONo) async throws {
    let count = emitterSubscriptionCounts[oNo, default: 0]
    if count == 0 {
      try await device.subscriptionManager.addSubscription(emitterSubscription(oNo), for: self)
    }
    emitterSubscriptionCounts[oNo] = count + 1
  }

  private func releaseEmitter(_ oNo: OcaONo) async {
    guard let count = emitterSubscriptionCounts[oNo] else { return }
    if count > 1 {
      emitterSubscriptionCounts[oNo] = count - 1
    } else {
      emitterSubscriptionCounts[oNo] = nil
      await device.subscriptionManager.removeSubscription(emitterSubscription(oNo), for: self)
    }
  }

  /// Any datagram from a host renews its peers' subscriptions.
  private func renew(host source: AnySocketAddress) {
    guard subscriptionLifetime != nil, let host = try? source.presentationAddressNoPort else {
      return
    }
    let now = ContinuousClock.now
    for destination in peers.keys where (try? destination.presentationAddressNoPort) == host {
      peers[destination]?.lastSeen = now
    }
  }

  private func startSweeping() {
    sweepTask?.cancel()
    guard let subscriptionLifetime else { return }
    sweepTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: subscriptionLifetime / 2)
        await self?.sweep(lifetime: subscriptionLifetime)
      }
    }
  }

  private func sweep(lifetime: Duration) async {
    let now = ContinuousClock.now
    let expired = peers.filter { !$0.value.isStatic && now - $0.value.lastSeen > lifetime }
    for destination in expired.keys {
      await removePeer(destination)
    }
  }

  // MARK: - outbound

  func startOutbound() {
    outbound?.finish()
    let (stream, continuation) = AsyncStream<(Data, AnySocketAddress)>
      .makeStream(bufferingPolicy: .bufferingNewest(4096))
    outbound = continuation
    outboundTask = Task { [weak self] in
      for await (data, destination) in stream {
        guard let sender = await self?.sender else { continue }
        try? await sender(data, destination)
      }
    }
  }

  /// Queues a message for a peer; the device never waits on the socket.
  private func send(_ message: OSCMessage, to destination: AnySocketAddress) {
    guard let outbound, let data = try? message.rawData() else { return }
    outbound.yield((data, destination))
  }

  /// Sends a property change to each peer subscribed to it.
  private func handle(_ notification: Ocp1Notification2) async {
    guard notification.event.eventID == OcaPropertyChangedEventID,
          case let .ocp1(data) = notification.eventData,
          let propertyID = try? OcaEventDataCoding.propertyID(from: data, format: .ocp1)
    else { return }
    let oNo = notification.event.emitterONo

    var recipients = [(AnySocketAddress, Subscription)]()
    var descriptor: OcaDevicePropertyDescriptor?
    for (destination, peer) in peers {
      for (subscription, subscribed) in peer.subscriptions
        where subscription.oNo == oNo &&
        (subscribed.propertyID == propertyID || subscribed.yPropertyID == propertyID)
      {
        recipients.append((destination, subscription))
        descriptor = subscribed
      }
    }
    guard let descriptor, !recipients.isEmpty else { return }

    let values: OSCValues
    do {
      if descriptor.yPropertyID != nil {
        // each component changes on its own; send both, as the property is set
        values = try await get(descriptor, of: oNo)
      } else {
        let (value, changeType) = try Self.decodePropertyChanged(descriptor.valueType, from: data)
        guard changeType == .currentChanged else { return }
        values = try await oscValues(from: value, of: descriptor, on: oNo)
      }
    } catch {
      return
    }

    for (destination, subscription) in recipients {
      send(OSCMessage(subscription.address, values: values), to: destination)
    }
  }

  private static func decodePropertyChanged<T: Codable & Sendable>(
    _ type: T.Type,
    from data: Data
  ) throws -> (any Sendable, OcaPropertyChangeType) {
    let eventData = try Ocp1Decoder().decode(OcaPropertyChangedEventData<T>.self, from: data)
    return (eventData.propertyValue, eventData.changeType)
  }
}

public enum OSCOCACustomBridgeableError: Error {
  case methodNotBridged
  case propertyNotBridged
}

/// An object that converts between its OCA values and OSC arguments itself. Each method
/// throws `methodNotBridged` or `propertyNotBridged` for what it leaves to the bridge.
public protocol OSCOCACustomBridgeable: SwiftOCADevice.OcaRoot {
  /// The parameters of a method invoked by `message`.
  func bridgeValues(
    from message: OSCMessage,
    for methodID: OcaMethodID
  ) throws -> [any Encodable & Sendable]

  /// The value a property is set to by `message`.
  func bridgeValue(
    from message: OSCMessage,
    for propertyID: OcaPropertyID
  ) throws -> any Encodable & Sendable

  /// The OSC arguments for a property's value.
  func bridgeOSCValues(
    from value: any Sendable,
    for propertyID: OcaPropertyID
  ) throws -> OSCValues
}

public extension OSCOCACustomBridgeable {
  func bridgeValues(
    from message: OSCMessage,
    for methodID: OcaMethodID
  ) throws -> [any Encodable & Sendable] {
    throw OSCOCACustomBridgeableError.methodNotBridged
  }

  func bridgeValue(
    from message: OSCMessage,
    for propertyID: OcaPropertyID
  ) throws -> any Encodable & Sendable {
    throw OSCOCACustomBridgeableError.propertyNotBridged
  }

  func bridgeOSCValues(
    from value: any Sendable,
    for propertyID: OcaPropertyID
  ) throws -> OSCValues {
    throw OSCOCACustomBridgeableError.propertyNotBridged
  }
}

/// A mute is a Boolean in OSC: true is muted.
extension SwiftOCADevice.OcaMute: OSCOCACustomBridgeable {
  private static let statePropertyID = OcaPropertyID("4.1")
  private static let setStateMethodID = OcaMethodID("4.2")

  private func muteState(from message: OSCMessage) throws -> OcaMuteState {
    guard message.values.count == 1 else { throw Ocp1Error.status(.badFormat) }
    switch message.values[0] {
    case let value as Bool: return value ? .muted : .unmuted
    case let value as Int32: return value != 0 ? .muted : .unmuted
    case let value as Float: return value != 0 ? .muted : .unmuted
    default: throw Ocp1Error.status(.badFormat)
    }
  }

  public func bridgeValues(
    from message: OSCMessage,
    for methodID: OcaMethodID
  ) throws -> [any Encodable & Sendable] {
    guard methodID == Self.setStateMethodID else {
      throw OSCOCACustomBridgeableError.methodNotBridged
    }
    return try [muteState(from: message)]
  }

  public func bridgeValue(
    from message: OSCMessage,
    for propertyID: OcaPropertyID
  ) throws -> any Encodable & Sendable {
    guard propertyID == Self.statePropertyID else {
      throw OSCOCACustomBridgeableError.propertyNotBridged
    }
    return try muteState(from: message)
  }

  public func bridgeOSCValues(
    from value: any Sendable,
    for propertyID: OcaPropertyID
  ) throws -> OSCValues {
    guard propertyID == Self.statePropertyID, let state = value as? OcaMuteState else {
      throw OSCOCACustomBridgeableError.propertyNotBridged
    }
    return [state == .muted]
  }
}

extension OSCOCABridge: OcaController {
  public nonisolated var flags: OcaControllerFlags { [] }

  /// Property changes the bridge subscribed to on its peers' behalf.
  public func sendMessages(
    _ messages: [any SwiftOCA.Ocp1Message],
    type messageType: SwiftOCA.OcaMessageType
  ) async throws {
    for case let notification as Ocp1Notification2 in messages {
      await handle(notification)
    }
  }
}
