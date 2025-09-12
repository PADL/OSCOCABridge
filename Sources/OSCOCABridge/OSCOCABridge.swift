//
// Copyright (c) 2025 PADL Software Pty Ltd
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
import OSCKitCore
import SocketAddress
import SwiftOCA
import SwiftOCADevice
import SystemPackage
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(Linux)
import IORing
import IORingUtils
#else
typealias Socket = CFSocketWrapper
#endif

public actor OSCOCABridge {
  let address: any SocketAddress
  let device: OcaDevice
  var task: Task<(), Error>?

  public init(address: any SocketAddress, device: OcaDevice) {
    self.address = address
    self.device = device
  }

  deinit {
    task?.cancel()
  }

  private func _makeSocket() async throws -> Socket {
    let socket: Socket

    #if os(Linux)
    socket = try Socket(ring: IORing.shared, domain: address.family, type: SOCK_DGRAM, protocol: 0)
    try socket.bind(to: address)
    #else
    socket = try await CFSocketWrapper(address: address, type: SOCK_DGRAM, options: .server)
    #endif
    return socket
  }

  private func _run() async throws {
    let socket = try await _makeSocket()
    repeat {
      #if os(Linux)
      do {
        for try await pdu in try await socket.receiveMessages(count: 1500) {
          try? await _handle(message: Data(pdu.buffer), from: AnySocketAddress(bytes: pdu.name))
        }
      } catch Errno.canceled {}
      #else
      for try await pdu in socket.receivedMessages {
        try? await _handle(message: pdu.1, from: pdu.0)
      }
      #endif
    } while !Task.isCancelled
  }

  public func run() {
    task?.cancel()
    task = Task {
      try await _run()
    }
  }

  public func stop() {
    task?.cancel()
    task = nil
  }

  private func _handle(message: OSCMessage, from address: any SocketAddress) async throws {
    let command = try await device._bridgeOscMessage(message)
    _ = await device.handleCommand(command, from: self)
  }

  private func _handle(message: any OSCObject, from address: any SocketAddress) async throws {
    switch message {
    case let bundle as OSCBundle:
      for element in bundle.elements {
        try await _handle(message: element, from: address)
      }
    case let message as OSCMessage:
      try await _handle(message: message, from: address)
    default:
      break
    }
  }

  private func _handle(message: Data, from address: any SocketAddress) async throws {
    guard let message = try message.parseOSC() else {
      throw Ocp1Error.status(.invalidRequest)
    }

    try await _handle(message: message, from: address)
  }
}

private extension OcaDevice {
  // walk root block
  func _resolve(namePath: OcaNamePath) async throws -> OcaONo? {
    try await rootBlock.find(actionObjectsByRolePath: namePath, resultFlags: .oNo).first?.oNo
  }

  func _bridgeOscMessage(_ message: OSCMessage) async throws -> Ocp1Command {
    let (ocaNamePath, ocaMethodID) = try message.addressPattern._bridgeToOcaPathAndMethodID()
    guard let oNo = try await _resolve(namePath: ocaNamePath) else {
      throw Ocp1Error.status(.processingFailed)
    }

    let encodedValues = try message.values.map { value in
      guard let value = value as? Encodable else { throw Ocp1Error.status(.invalidRequest) }
      let encoded: Data = try Ocp1Encoder().encode(value)
      return encoded
    }
    let flattenedValues = encodedValues.reduce(Data()) {
      var data = $0
      data.append($1)
      return data
    }
    let parameters = Ocp1Parameters(
      parameterCount: OcaUint8(message.values.count),
      parameterData: flattenedValues
    )

    return Ocp1Command(handle: 0, targetONo: oNo, methodID: ocaMethodID, parameters: parameters)
  }
}

private extension OSCAddressPattern {
  func _bridgeToOcaPathAndMethodID() throws -> (OcaNamePath, OcaMethodID) {
    guard pathComponents.count > 1 else {
      throw Ocp1Error.status(.badMethod)
    }

    let ocaNamePath = pathComponents[0..<(pathComponents.count - 1)].map { String($0) }
    let ocaMethodID = try OcaMethodID(unsafeString: String(pathComponents.last!))

    return (ocaNamePath, ocaMethodID)
  }
}

extension OSCOCABridge: OcaController {
  public nonisolated var flags: OcaControllerFlags { [] }

  public func addSubscription(
    _ subscription: SwiftOCADevice
      .OcaSubscriptionManagerSubscription
  ) async throws {}

  public func removeSubscription(
    _ subscription: SwiftOCADevice
      .OcaSubscriptionManagerSubscription
  ) async throws {}

  public func removeSubscription(
    _ event: SwiftOCA.OcaEvent,
    property: SwiftOCA.OcaPropertyID?,
    subscriber: SwiftOCA.OcaMethod
  ) async throws {}

  public func sendMessage(
    _ message: any SwiftOCA.Ocp1Message,
    type messageType: SwiftOCA.OcaMessageType
  ) async throws {}
}
