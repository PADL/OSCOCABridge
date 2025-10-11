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
import SwiftOCA
import SwiftOCADevice
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import SocketAddress

let MaxMessageSize = 1500

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

  public func run() {
    task?.cancel()
    task = Task {
      try await udpEventLoop(address: address, with: self)
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

  private func _handle(message: OSCPacket, from address: any SocketAddress) async throws {
    switch message {
    case let .bundle(bundle):
      for element in bundle.elements {
        try await _handle(message: element, from: address)
      }
    case let .message(message):
      try await _handle(message: message, from: address)
    }
  }

  func _handle(message: Data, from address: any SocketAddress) async throws {
    guard let message = try OSCPacket(from: message) else {
      throw Ocp1Error.status(.invalidRequest)
    }

    try await _handle(message: message, from: address)
  }

  #if !os(Linux)
  func _handle(message: Data, from address: sockaddr_storage) async throws {
    try await _handle(message: message, from: AnySocketAddress(address))
  }
  #endif
}

private extension Encodable {
  var _ocp1Encoded: Data {
    get throws {
      try Ocp1Encoder().encode(self)
    }
  }
}

private extension [any Encodable] {
  var _ocp1Encoded: Data {
    get throws {
      try reduce(Data()) {
        var data = $0
        try data.append($1._ocp1Encoded)
        return data
      }
    }
  }
}

private extension OSCValue {
  var _ocp1Encoded: Data {
    get throws {
      guard let value = self as? Encodable else { throw Ocp1Error.status(.invalidRequest) }
      return try value._ocp1Encoded
    }
  }
}

private extension OSCValues {
  var _ocp1Encoded: Data {
    get throws {
      try map {
        guard let value = $0 as? Encodable else { throw Ocp1Error.status(.invalidRequest) }
        return value
      }._ocp1Encoded
    }
  }
}

public enum OSCOCACustomBridgeableError: Error {
  case methodNotBridged
}

public protocol OSCOCACustomBridgeable: SwiftOCADevice.OcaRoot {
  func bridgeValues(from message: OSCMessage, for methodID: OcaMethodID) throws -> [any Encodable]
}

extension SwiftOCADevice.OcaMute: OSCOCACustomBridgeable {
  public func bridgeValues(
    from message: OSCMessage,
    for methodID: OcaMethodID
  ) throws -> [any Encodable] {
    guard methodID == OcaMethodID("4.2"), let boolValue = message.values.first as? Bool
    else { throw OSCOCACustomBridgeableError.methodNotBridged }
    return [boolValue ? OcaMuteState.muted : OcaMuteState.unmuted]
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

    var parameterCount: Int!
    var parameterData: Data!

    if let object = resolve(objectNumber: oNo) as? OSCOCACustomBridgeable {
      do {
        let bridgedValues = try object.bridgeValues(from: message, for: ocaMethodID)
        parameterCount = bridgedValues.count
        parameterData = try bridgedValues._ocp1Encoded
      } catch OSCOCACustomBridgeableError.methodNotBridged {}
    }

    if parameterData == nil {
      parameterCount = message.values.count
      parameterData = try message.values._ocp1Encoded
    }

    let parameters = Ocp1Parameters(
      parameterCount: OcaUint8(parameterCount),
      parameterData: parameterData
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

  public func sendMessages(
    _ message: [any SwiftOCA.Ocp1Message],
    type messageType: SwiftOCA.OcaMessageType
  ) async throws {}
}
