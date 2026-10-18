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

import SwiftOCA
import SwiftOSCCore

/// The last component of an object address: the member of the object it names. A method
/// ID is written dotted (`4.2`) or in AES70 notation (`4m2`), a property ID only in AES70
/// notation (`4p1`); anything else is a property or method name.
enum OSCOCAAddressLeaf: Equatable, Sendable {
  case methodID(OcaMethodID)
  case propertyID(OcaPropertyID)
  case name(String)

  init(_ string: some StringProtocol) {
    let string = String(string)
    // both parsers accept the dotted form, so the method ID's goes first and takes it
    if let methodID = try? OcaMethodID(unsafeString: string) {
      self = .methodID(methodID)
    } else if let propertyID = try? OcaPropertyID(unsafeString: string) {
      self = .propertyID(propertyID)
    } else {
      self = .name(string)
    }
  }
}

/// What an incoming OSC message asks of the bridge.
enum OSCOCARequest: Sendable {
  /// `/subscribe ,s <address>… [,i port]`; no addresses means every property.
  case subscribe(patterns: [String], port: UInt16?)
  /// `/unsubscribe ,s <address>… [,i port]`; no addresses means every subscription.
  case unsubscribe(patterns: [String], port: UInt16?)
  /// `/<rolePath>/<leaf>`: a method to invoke, or a property to get or set.
  case member(rolePath: OcaNamePath, leaf: OSCOCAAddressLeaf)

  static let subscribeAddress = "subscribe"
  static let unsubscribeAddress = "unsubscribe"

  init(_ message: OSCMessage) throws {
    let pathComponents = message.addressPattern.pathComponents

    if pathComponents.count == 1,
       pathComponents[0] == Self.subscribeAddress || pathComponents[0] == Self.unsubscribeAddress
    {
      let (patterns, port) = try Self.patternsAndPort(message.values)
      self = pathComponents[0] == Self.subscribeAddress
        ? .subscribe(patterns: patterns, port: port)
        : .unsubscribe(patterns: patterns, port: port)
    } else {
      let (rolePath, leaf) = try Self.member(pathComponents)
      self = .member(rolePath: rolePath, leaf: leaf)
    }
  }

  /// An object address's role path and leaf.
  static func member(_ pathComponents: [Substring]) throws -> (OcaNamePath, OSCOCAAddressLeaf) {
    guard pathComponents.count > 1, let leaf = pathComponents.last else {
      throw Ocp1Error.status(.badMethod)
    }
    return (pathComponents.dropLast().map { String($0) }, OSCOCAAddressLeaf(leaf))
  }

  private static func patternsAndPort(_ values: OSCValues) throws -> ([String], UInt16?) {
    var patterns = [String]()
    var port: UInt16?

    for (index, value) in values.enumerated() {
      switch value {
      case let pattern as String:
        patterns.append(pattern)
      case let value as Int32 where index == values.count - 1:
        guard let value = UInt16(exactly: value), value != 0 else {
          throw Ocp1Error.status(.parameterOutOfRange)
        }
        port = value
      default:
        throw Ocp1Error.status(.badFormat)
      }
    }

    return (patterns, port)
  }
}

extension OcaPropertyID {
  /// The AES70 notation for the ID, as an address leaf: `4p1`.
  var oscLeaf: String { "\(defLevel)p\(propertyIndex)" }
}

extension String {
  /// Whether the string uses OSC address pattern matching characters.
  var isOSCAddressPattern: Bool {
    contains { "*?[]{}".contains($0) }
  }

  /// `GetGain` → `getGain`: model method names, as the leaf names them.
  var lowerCamelCased: String {
    guard let first else { return self }
    return first.lowercased() + dropFirst()
  }

  /// `gain` → `Gain`.
  var upperCamelCased: String {
    guard let first else { return self }
    return first.uppercased() + dropFirst()
  }
}
