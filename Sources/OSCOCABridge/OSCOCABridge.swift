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
import OrderedCollections
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
import Synchronization

let MaxMessageSize = 1500

/// Bridges OSC to an OCA device. The OSC address space is the device's object tree: an
/// object is addressed by its role path, and the last component names one of its
/// members, a method by ID (`4.2` or `4m2`) or name (`setGain`), or a property by ID
/// (`4p1`) or name (`gain`). A property is read with no arguments and written with them.
/// `/subscribe` and `/unsubscribe` manage which property changes are sent to a peer.
///
/// The bridge is isolated to the device, `OcaDevice.shared`, so that it can keep its
/// subscriptions in step with the device's without awaiting it.
@OcaDevice
public final class OSCOCABridge {
  let address: any SocketAddress
  let subscriptionLifetime: Duration?
  var task: Task<(), Never>?

  /// Sends a datagram from the bridge's socket, once the event loop has bound it.
  typealias Sender = @Sendable (Data, AnySocketAddress) async throws -> ()

  /// Messages waiting for the socket; nil while the bridge is stopped.
  private var outbound: OSCOCAOutboundQueue?
  /// Removes peers not heard from within `subscriptionLifetime`; none without one.
  private var leaseExpiryTask: Task<(), Never>?

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

  /// A property of an object, which a change event names.
  struct PropertyKey: Hashable, Sendable {
    let oNo: OcaONo
    let propertyID: OcaPropertyID
  }

  /// A peer and one of its subscriptions, as a change event finds them.
  struct Recipient: Hashable, Sendable {
    let destination: AnySocketAddress
    let subscription: Subscription
  }

  /// Peers by host, then by the address property changes are sent to: `/unsubscribe` and
  /// renewal go by the host, as a peer need not send from the port it receives on. A host
  /// is its address with no port; see `host(of:)`.
  private var peers = [AnySocketAddress: [AnySocketAddress: Peer]]()
  /// A property and who is sent its changes.
  struct PropertyRecipients {
    let descriptor: OcaDevicePropertyDescriptor
    var recipients = Set<Recipient>()
  }

  /// The index a change event is answered from. A vector property is entered under both of
  /// its component IDs.
  private var recipients = [PropertyKey: PropertyRecipients]()
  /// How many subscriptions there are to each emitter's events, over all peers; the bridge
  /// holds one OCA subscription for each emitter with any.
  private var emitterSubscriptionCounts = [OcaONo: Int]()

  /// `subscriptionLifetime` is how long a peer's subscriptions last after the last datagram
  /// from its host; nil, the default, keeps them until it unsubscribes or the bridge stops.
  /// The device is `OcaDevice.shared`, the only device there is outside SwiftOCA.
  public nonisolated init(address: any SocketAddress, subscriptionLifetime: Duration? = nil) {
    self.address = address
    self.subscriptionLifetime = subscriptionLifetime
  }

  @available(*, deprecated, message: "the device is OcaDevice.shared")
  public convenience nonisolated init(
    address: any SocketAddress,
    device: OcaDevice,
    subscriptionLifetime: Duration? = nil
  ) {
    self.init(address: address, subscriptionLifetime: subscriptionLifetime)
  }

  private var device: OcaDevice { OcaDevice.shared }

  // The device actor's own state. Code isolated to the global actor runs on the shared
  // instance's executor, so it is read at once; the compiler only needs telling.

  private var rootBlock: SwiftOCADevice.OcaBlock<SwiftOCADevice.OcaRoot>? {
    device.assumeIsolated { $0.rootBlock }
  }

  private var subscriptionManager: SwiftOCADevice.OcaSubscriptionManager? {
    device.assumeIsolated { $0.subscriptionManager }
  }

  private func object(_ oNo: OcaONo) -> SwiftOCADevice.OcaRoot? {
    device.assumeIsolated { $0.resolve(objectNumber: oNo) }
  }

  /// The device's managers, which are outside the root block, each with its role as its
  /// role path: `/DeviceManager/deviceName`.
  private var managers: [(rolePath: OcaNamePath, object: SwiftOCADevice.OcaRoot)] {
    get async {
      await device.managers.map { (rolePath: [$0.role], object: $0) }
    }
  }

  public func run() {
    task?.cancel()
    startExpiringLeases()
    let address = address
    task = Task {
      await startOutbound()
      try? await udpEventLoop(address: address, with: self)
    }
  }

  /// Stops the bridge. Its peers' subscriptions are removed; destinations added with
  /// `addDestination(_:patterns:)` are kept, and are sent their current values and then
  /// changes again once it runs.
  public func stop() {
    task?.cancel()
    task = nil
    leaseExpiryTask?.cancel()
    leaseExpiryTask = nil
    for (host, destinations) in peers {
      for (destination, peer) in destinations where !peer.isStatic {
        removePeer(destination, on: host)
      }
    }
    // a message waiting for the socket is dropped with the queue
    outbound?.close()
    outbound = nil
  }

  /// Sends the changes of every property matching `patterns`, or of every property if there
  /// are none, to `destination`, until it is removed. The current values are sent once the
  /// bridge runs, if it is not running yet.
  public func addDestination(
    _ destination: any SocketAddress,
    patterns: [String] = []
  ) async throws {
    try await subscribe(AnySocketAddress(destination), to: patterns, isStatic: true)
  }

  public func removeDestination(_ destination: any SocketAddress) {
    let destination = AnySocketAddress(destination)
    guard let host = try? host(of: destination) else { return }
    removePeer(destination, on: host)
  }

  // MARK: - inbound

  private func _handle(message: OSCMessage, from source: AnySocketAddress) async {
    do {
      switch try OSCOCARequest(message) {
      case let .subscribe(patterns, port):
        try await subscribe(destination(for: source, port: port), to: patterns)
      case let .unsubscribe(patterns, port):
        let host = try host(of: source)
        if let port {
          try unsubscribe(destination(for: source, port: port), on: host, from: patterns)
        } else {
          // the sender's subscriptions, whichever port it had them sent to
          for destination in peers[host].map({ Array($0.keys) }) ?? [] {
            unsubscribe(destination, on: host, from: patterns)
          }
        }
      case let .member(rolePath, leaf):
        try await handle(message, rolePath: rolePath, leaf: leaf, from: source)
      }
    } catch {
      // an /error is not answered, lest two bridges answer each other's forever
      guard message.addressPattern.stringValue != "/error" else { return }
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
    if subscriptionLifetime != nil, let host = try? host(of: source) {
      renew(host: host)
    }
    await _handle(message: message, from: source)
  }

  #if !os(Linux)
  func _handle(message: Data, from source: sockaddr_storage) async throws {
    try await _handle(message: message, from: AnySocketAddress(source))
  }

  @discardableResult
  func _startDraining(
    with sender: @escaping @Sendable (Data, sockaddr_storage) async throws -> ()
  ) -> Task<(), Never> {
    let sender: Sender = { data, destination in try await sender(data, destination.asStorage()) }
    return _startDraining(with: sender)
  }
  #endif

  private func handle(
    _ message: OSCMessage,
    rolePath: OcaNamePath,
    leaf: OSCOCAAddressLeaf,
    from source: AnySocketAddress
  ) async throws {
    let (object, member) = try await resolve(rolePath: rolePath, leaf: leaf)

    switch member {
    case let .method(methodID):
      try await invoke(methodID, on: object, with: message)
    case let .property(descriptor):
      if message.values.isEmpty {
        let values = try await get(descriptor, of: object)
        send(OSCMessage(message.addressPattern, values: values), to: source)
      } else {
        try await set(descriptor, of: object, from: message)
      }
    }
  }

  private func resolve(
    rolePath: OcaNamePath,
    leaf: OSCOCAAddressLeaf
  ) async throws -> (SwiftOCADevice.OcaRoot, OSCOCAMember) {
    guard let rootBlock else {
      throw Ocp1Error.status(.deviceError)
    }
    var oNo = try await rootBlock.findActionObjectsByRolePath(
      searchPath: rolePath,
      resultFlags: .oNo,
      from: self
    ).first?.oNo
    if oNo == nil, rolePath.count == 1 {
      oNo = await managers.first { $0.rolePath == rolePath }?.object.objectNumber
    }
    guard let oNo, let object = object(oNo)
    else {
      throw Ocp1Error.status(.badONo)
    }
    guard let member = object.oscMember(for: leaf) else {
      throw Ocp1Error.status(.badMethod)
    }
    return (object, member)
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
    on object: SwiftOCADevice.OcaRoot,
    with message: OSCMessage
  ) async throws {
    var parameters: (count: Int, data: Data)?

    if let object = object as? OSCOCACustomBridgeable {
      do {
        let values = try object.ocaParameters(for: methodID, from: message)
        parameters = try (values.count, values.map { $0 as any Encodable }._ocp1Encoded)
      } catch OSCOCACustomBridgeableError.methodNotBridged {}
    }

    let (count, data) = try parameters ?? (message.values.count, message.values._ocp1Encoded)
    _ = try await perform(
      methodID,
      on: object.objectNumber,
      parameterCount: count,
      parameterData: data
    )
  }

  /// The property's value as OSC arguments. A bounded property's getter answers with its
  /// range after the value, which is left out.
  private func get(
    _ descriptor: OcaDevicePropertyDescriptor,
    of object: SwiftOCADevice.OcaRoot
  ) async throws -> OSCValues {
    guard let getMethodID = descriptor.getMethodID else {
      throw Ocp1Error.status(.notImplemented)
    }
    let response = try await perform(
      getMethodID,
      on: object.objectNumber,
      parameterCount: 0,
      parameterData: Data()
    )
    let value = try Ocp1Decoder().decode(
      descriptor.valueType,
      from: response.parameters.parameterData
    )
    return try await oscValues(from: value, of: descriptor, on: object)
  }

  private func set(
    _ descriptor: OcaDevicePropertyDescriptor,
    of object: SwiftOCADevice.OcaRoot,
    from message: OSCMessage
  ) async throws {
    guard let setMethodID = descriptor.setMethodID else {
      throw Ocp1Error.status(.notImplemented)
    }

    var value: (any Encodable & Sendable)?
    if let object = object as? OSCOCACustomBridgeable {
      do {
        value = try object.ocaValue(for: descriptor.propertyID, from: message)
      } catch OSCOCACustomBridgeableError.propertyNotBridged {}
    }
    let encoded: Data
    let parameterCount: Int
    if let value {
      encoded = try value._ocp1Encoded
      parameterCount = descriptor.componentType == nil ? 1 : 2
    } else if let componentType = descriptor.componentType {
      // a vector property's setter takes its components as two parameters, each converted
      guard message.values.count == 2 else { throw Ocp1Error.status(.badFormat) }
      encoded = try OSCValueBridge.value(componentType, from: [message.values[0]])._ocp1Encoded +
        OSCValueBridge.value(componentType, from: [message.values[1]])._ocp1Encoded
      parameterCount = 2
    } else {
      encoded = try OSCValueBridge.value(descriptor.valueType, from: message.values)._ocp1Encoded
      parameterCount = 1
    }
    _ = try await perform(
      setMethodID,
      on: object.objectNumber,
      parameterCount: parameterCount,
      parameterData: encoded
    )
  }

  private func oscValues(
    from value: any Sendable,
    of descriptor: OcaDevicePropertyDescriptor,
    on object: SwiftOCADevice.OcaRoot
  ) async throws -> OSCValues {
    if let object = object as? OSCOCACustomBridgeable {
      do {
        return try object.oscValues(for: descriptor.propertyID, from: value)
      } catch OSCOCACustomBridgeableError.propertyNotBridged {}
    }
    return try OSCValueBridge.oscValues(from: value)
  }

  // MARK: - subscriptions

  /// Where a peer is sent property changes: its host, at `port` if it names one, else at
  /// the port it sent from.
  private func destination(for source: AnySocketAddress, port: UInt16?) throws -> AnySocketAddress {
    guard let port else { return source }
    return try address(source, port: port)
  }

  /// A peer's host: its address with no port, which keeps an IPv6 scope.
  private func host(of address: AnySocketAddress) throws -> AnySocketAddress {
    try self.address(address, port: 0)
  }

  /// `address` with its port replaced, copied so that the rest of it is kept.
  private func address(_ address: AnySocketAddress, port: UInt16) throws -> AnySocketAddress {
    var destination = address
    try destination.withMutableSockAddr { sa, _ in
      switch Int32(sa.pointee.sa_family) {
      case AF_INET:
        sa
          .withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            $0.pointee.sin_port = port.bigEndian
          }
      case AF_INET6:
        sa
          .withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
            $0.pointee.sin6_port = port.bigEndian
          }
      default:
        throw Ocp1Error.status(.parameterError)
      }
    }
    return destination
  }

  /// The properties `patterns` name, each with the address its changes are sent on. A
  /// pattern without wildcards is resolved as an address, so it may name a hidden property;
  /// one with them is matched against the address of every property introspection shows,
  /// by name and by ID. No patterns names every such property.
  private func resolve(
    patterns: [String]
  ) async throws -> [Subscription: (
    object: SwiftOCADevice.OcaRoot,
    descriptor: OcaDevicePropertyDescriptor
  )] {
    var resolved = [Subscription: (
      object: SwiftOCADevice.OcaRoot,
      descriptor: OcaDevicePropertyDescriptor
    )]()

    for pattern in patterns where !pattern.isOSCAddressPattern {
      let (rolePath, leaf) = try OSCOCARequest.member(OSCAddressPattern(pattern).pathComponents)
      let (object, member) = try await resolve(rolePath: rolePath, leaf: leaf)
      guard case let .property(descriptor) = member else {
        throw Ocp1Error.status(.badMethod)
      }
      resolved[Subscription(
        oNo: object.objectNumber,
        propertyID: descriptor.propertyID,
        address: pattern
      )] = (object, descriptor)
    }

    let wildcards = patterns.filter(\.isOSCAddressPattern).map { OSCAddressPattern($0) }
    if patterns.isEmpty || !wildcards.isEmpty {
      guard let rootBlock else {
        throw Ocp1Error.status(.deviceError)
      }
      let objects = await oscObjects(in: rootBlock) + managers
      for (rolePath, object) in objects {
        for descriptor in object.oscVisibleProperties where descriptor.getMethodID != nil {
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
          )] = (object, descriptor)
        }
      }
    }

    return resolved
  }

  /// The peer is changed and the device subscribed to with nothing awaited, so another
  /// call cannot run in between and see them out of step.
  private func subscribe(
    _ destination: AnySocketAddress,
    to patterns: [String],
    isStatic: Bool = false
  ) async throws {
    let resolved = try await resolve(patterns: patterns)
    guard !resolved.isEmpty else { throw Ocp1Error.status(.badONo) }
    let host = try host(of: destination)

    var peer = peers[host]?[destination] ?? Peer()
    let added = resolved.filter { peer.subscriptions[$0.key] == nil }
    var retained = [OcaONo]()
    do {
      for subscription in added.keys {
        try retainEmitter(subscription.oNo)
        retained.append(subscription.oNo)
      }
    } catch {
      for oNo in retained {
        releaseEmitter(oNo)
      }
      throw error
    }

    peer.lastSeen = .now
    peer.isStatic = peer.isStatic || isStatic
    for (subscription, (_, descriptor)) in added {
      peer.subscriptions[subscription] = descriptor
      let recipient = Recipient(destination: destination, subscription: subscription)
      for propertyID in [descriptor.propertyID, descriptor.yPropertyID].compactMap({ $0 }) {
        recipients[
          PropertyKey(oNo: subscription.oNo, propertyID: propertyID),
          default: PropertyRecipients(descriptor: descriptor)
        ].recipients.insert(recipient)
      }
    }
    peers[host, default: [:]][destination] = peer

    // the current values, which a newly subscribed peer would otherwise not have
    for (subscription, (object, descriptor)) in resolved {
      if let values = try? await get(descriptor, of: object) {
        send(OSCMessage(subscription.address, values: values), to: destination)
      }
    }
  }

  /// A destination added with `addDestination(_:patterns:)` is only removed by
  /// `removeDestination(_:)`, not by a peer's `/unsubscribe`.
  private func unsubscribe(
    _ destination: AnySocketAddress,
    on host: AnySocketAddress,
    from patterns: [String]
  ) {
    guard let peer = peers[host]?[destination], !peer.isStatic else { return }
    guard !patterns.isEmpty else {
      removePeer(destination, on: host)
      return
    }

    let patterns = patterns.map { OSCAddressPattern($0) }
    let removed = peer.subscriptions.keys.filter { subscription in
      patterns.contains { $0.matches(localAddress: subscription.address) }
    }
    for subscription in removed {
      remove(subscription, of: destination, on: host)
    }
    if peers[host]?[destination]?.subscriptions.isEmpty == true {
      removePeer(destination, on: host)
    }
  }

  private func remove(
    _ subscription: Subscription,
    of destination: AnySocketAddress,
    on host: AnySocketAddress
  ) {
    guard let descriptor = peers[host]?[destination]?.subscriptions
      .removeValue(forKey: subscription)
    else { return }
    let recipient = Recipient(destination: destination, subscription: subscription)
    for propertyID in [descriptor.propertyID, descriptor.yPropertyID].compactMap({ $0 }) {
      let key = PropertyKey(oNo: subscription.oNo, propertyID: propertyID)
      recipients[key]?.recipients.remove(recipient)
      if recipients[key]?.recipients.isEmpty == true { recipients[key] = nil }
    }
    releaseEmitter(subscription.oNo)
  }

  private func removePeer(_ destination: AnySocketAddress, on host: AnySocketAddress) {
    guard let peer = peers[host]?[destination] else { return }
    for subscription in peer.subscriptions.keys {
      remove(subscription, of: destination, on: host)
    }
    peers[host]?[destination] = nil
    if peers[host]?.isEmpty == true { peers[host] = nil }
  }

  private func emitterSubscription(_ oNo: OcaONo) -> OcaSubscriptionManagerSubscription {
    .subscription2(OcaSubscription2(
      event: OcaEvent(emitterONo: oNo, eventID: OcaPropertyChangedEventID),
      notificationDeliveryMode: .normal,
      destinationInformation: OcaNetworkAddress()
    ))
  }

  private func retainEmitter(_ oNo: OcaONo) throws {
    let count = emitterSubscriptionCounts[oNo, default: 0]
    if count == 0 {
      guard let subscriptionManager else {
        throw Ocp1Error.status(.deviceError)
      }
      try subscriptionManager.addSubscription(emitterSubscription(oNo), for: self)
    }
    emitterSubscriptionCounts[oNo] = count + 1
  }

  private func releaseEmitter(_ oNo: OcaONo) {
    guard let count = emitterSubscriptionCounts[oNo] else { return }
    if count > 1 {
      emitterSubscriptionCounts[oNo] = count - 1
    } else {
      emitterSubscriptionCounts[oNo] = nil
      subscriptionManager?.removeSubscription(emitterSubscription(oNo), for: self)
    }
  }

  /// Any datagram from a host renews its peers' subscriptions.
  private func renew(host: AnySocketAddress) {
    guard let destinations = peers[host]?.keys else { return }
    let now = ContinuousClock.now
    for destination in destinations {
      peers[host]?[destination]?.lastSeen = now
    }
  }

  /// Checks for lapsed leases twice a lifetime, so that none outlives it by more than half.
  private func startExpiringLeases() {
    leaseExpiryTask?.cancel()
    guard let subscriptionLifetime else { return }
    leaseExpiryTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: subscriptionLifetime / 2)
        self?.expireLeases(olderThan: subscriptionLifetime)
      }
    }
  }

  /// Removes the peers not heard from within `lifetime`, other than fixed destinations.
  private func expireLeases(olderThan lifetime: Duration) {
    let now = ContinuousClock.now
    let expired = peers.flatMap { host, destinations in
      destinations.filter { !$0.value.isStatic && now - $0.value.lastSeen > lifetime }
        .map { (host: host, destination: $0.key) }
    }
    for (host, destination) in expired {
      removePeer(destination, on: host)
    }
  }

  // MARK: - outbound

  /// Starts queueing outbound messages, as the bridge runs, if that is not under way. A
  /// message queued before the socket is bound waits for it. A stopped bridge queues
  /// nothing, so the destinations, which it kept, are first queued their current values.
  func startOutbound() async {
    guard outbound == nil else { return }
    outbound = OSCOCAOutboundQueue()
    for destinations in peers.values {
      for (destination, peer) in destinations where peer.isStatic {
        for (subscription, descriptor) in peer.subscriptions {
          if let object = object(subscription.oNo),
             let values = try? await get(descriptor, of: object)
          {
            send(OSCMessage(subscription.address, values: values), to: destination)
          }
        }
      }
    }
  }

  /// Sends the queued messages with `sender`, until the task is cancelled or the bridge
  /// stops. The event loop starts this once it has bound its socket, and cancels it when the
  /// socket goes; a newer drain takes over from an older one.
  @discardableResult
  func _startDraining(with sender: @escaping Sender) -> Task<(), Never> {
    // the bridge has stopped since the event loop started
    guard let outbound else { return Task {} }
    // detached, so as not to drain on the device's executor and wait behind the work
    // that is raising what it drains
    return Task.detached {
      for await _ in outbound.wakeups() {
        while !Task.isCancelled, let (data, destination) = outbound.popFirst() {
          try? await sender(data, destination)
        }
      }
    }
  }

  /// Queues a message for a peer; the device never waits on the socket. A value still
  /// queued for the same address and peer is replaced, so that a peer that is not keeping
  /// up is sent the latest value rather than every one; an `/error` is never replaced.
  private func send(_ message: OSCMessage, to destination: AnySocketAddress) {
    guard let outbound, let data = try? message.rawData() else { return }
    let address = message.addressPattern.stringValue
    outbound.push(
      data,
      to: destination,
      replacing: address == "/error" ? nil : address
    )
  }

  /// Sends a property change to each peer subscribed to it. A vector property raises an
  /// event for each component, and a set from within the device notifies from a task of
  /// its own, so the events of two sets can interleave: the x event is ignored and the y
  /// event reads the property, which is what it is by then.
  private func handle(_ notification: Ocp1Notification2) async {
    guard notification.event.eventID == OcaPropertyChangedEventID,
          case let .ocp1(data) = notification.eventData,
          let propertyID = try? OcaEventDataCoding.propertyID(from: data, format: .ocp1),
          let property = recipients[PropertyKey(
            oNo: notification.event.emitterONo,
            propertyID: propertyID
          )]
    else { return }
    let key = PropertyKey(oNo: notification.event.emitterONo, propertyID: propertyID)
    let descriptor = property.descriptor

    let values: OSCValues
    do {
      guard let object = object(key.oNo) else { return }
      if descriptor.componentType != nil {
        guard propertyID == descriptor.yPropertyID else { return }
        values = try await get(descriptor, of: object)
      } else {
        let (value, changeType) = try Self.decodePropertyChanged(descriptor.valueType, from: data)
        guard changeType == .currentChanged else { return }
        values = try await oscValues(from: value, of: descriptor, on: object)
      }
    } catch {
      return
    }

    // read again: a peer may have gone while the value was read
    for recipient in recipients[key]?.recipients ?? [] {
      send(OSCMessage(recipient.subscription.address, values: values), to: recipient.destination)
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
  /// The OCA parameters of a method, from the OSC arguments invoking it.
  func ocaParameters(
    for methodID: OcaMethodID,
    from message: OSCMessage
  ) throws -> [any Encodable & Sendable]

  /// The OCA value a property is set to, from the OSC arguments setting it.
  func ocaValue(
    for propertyID: OcaPropertyID,
    from message: OSCMessage
  ) throws -> any Encodable & Sendable

  /// The OSC arguments for a property's OCA value.
  func oscValues(
    for propertyID: OcaPropertyID,
    from value: any Sendable
  ) throws -> OSCValues
}

public extension OSCOCACustomBridgeable {
  func ocaParameters(
    for methodID: OcaMethodID,
    from message: OSCMessage
  ) throws -> [any Encodable & Sendable] {
    throw OSCOCACustomBridgeableError.methodNotBridged
  }

  func ocaValue(
    for propertyID: OcaPropertyID,
    from message: OSCMessage
  ) throws -> any Encodable & Sendable {
    throw OSCOCACustomBridgeableError.propertyNotBridged
  }

  func oscValues(
    for propertyID: OcaPropertyID,
    from value: any Sendable
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

  public func ocaParameters(
    for methodID: OcaMethodID,
    from message: OSCMessage
  ) throws -> [any Encodable & Sendable] {
    guard methodID == Self.setStateMethodID else {
      throw OSCOCACustomBridgeableError.methodNotBridged
    }
    return try [muteState(from: message)]
  }

  public func ocaValue(
    for propertyID: OcaPropertyID,
    from message: OSCMessage
  ) throws -> any Encodable & Sendable {
    guard propertyID == Self.statePropertyID else {
      throw OSCOCACustomBridgeableError.propertyNotBridged
    }
    return try muteState(from: message)
  }

  public func oscValues(
    for propertyID: OcaPropertyID,
    from value: any Sendable
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

/// Messages for peers, in the order they were queued, where a newer value for an address
/// and peer replaces the one queued, keeping its place. Its size is bounded: past
/// `capacity`, the oldest message is dropped.
final class OSCOCAOutboundQueue: Sendable {
  static let capacity = 4096

  private struct Key: Hashable {
    let destination: AnySocketAddress
    /// The address a newer value replaces; nil, with `serial`, for one never replaced.
    let address: String?
    let serial: Int
  }

  private struct State {
    var messages = OrderedDictionary<Key, Data>()
    var serial = 0
    var wakeup: AsyncStream<()>.Continuation?
  }

  private let state = Mutex(State())

  func push(_ data: Data, to destination: AnySocketAddress, replacing address: String?) {
    let wakeup = state.withLock { state in
      let key: Key
      if let address {
        key = Key(destination: destination, address: address, serial: 0)
      } else {
        state.serial += 1
        key = Key(destination: destination, address: nil, serial: state.serial)
      }
      state.messages[key] = data
      if state.messages.count > Self.capacity {
        state.messages.removeFirst()
      }
      return state.wakeup
    }
    wakeup?.yield()
  }

  func popFirst() -> (Data, AnySocketAddress)? {
    state.withLock { state in
      guard !state.messages.isEmpty else { return nil }
      let (key, data) = state.messages.removeFirst()
      return (data, key.destination)
    }
  }

  /// Yields when there may be messages, starting now, for the one drain; a newer call ends
  /// the stream of an older one, as does closing the queue.
  func wakeups() -> AsyncStream<()> {
    let (stream, wakeup) = AsyncStream<()>.makeStream(bufferingPolicy: .bufferingNewest(1))
    wakeup.yield()
    state.withLock { state in
      state.wakeup?.finish()
      state.wakeup = wakeup
    }
    return stream
  }

  /// Drops what is queued and ends the drain's wakeups: the bridge has stopped.
  func close() {
    let wakeup = state.withLock { state in
      state.messages.removeAll()
      defer { state.wakeup = nil }
      return state.wakeup
    }
    wakeup?.finish()
  }
}
