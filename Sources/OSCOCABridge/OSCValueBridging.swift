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
import SwiftOCA
import SwiftOSCCore

// MARK: - OCP.1 encoding of OSC values, as method invocation sends them

extension Encodable {
  var _ocp1Encoded: Data {
    get throws {
      try Ocp1Encoder().encode(self)
    }
  }
}

extension [any Encodable] {
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

extension OSCValues {
  var _ocp1Encoded: Data {
    get throws {
      let values = try map {
        guard let value = $0 as? Encodable else { throw Ocp1Error.status(.invalidRequest) }
        return value
      }
      return try values._ocp1Encoded
    }
  }
}

// MARK: - property values

/// Converts property values between their OCA types and OSC arguments.
enum OSCValueBridge {
  /// The OSC arguments for an OCA value: OSC scalars as they are, other integers as
  /// `Int32` (or `Int64` if they do not fit), enumerations as their raw values, and
  /// collections and records as their elements, in order. Anything else is sent as a
  /// blob holding its OCP.1 encoding.
  static func oscValues(from value: Any) throws -> OSCValues {
    if let values = scalarOSCValue(from: value) {
      return [values]
    } else if let value = value as? any RawRepresentable {
      return try oscValues(from: rawValue(of: value))
    } else if let elements = value as? [Any] {
      return try elements.flatMap { try oscValues(from: $0) }
    }

    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .struct, !mirror.children.isEmpty,
       let values = try? mirror.children.flatMap({ try oscValues(from: $0.value) })
    {
      return values
    } else if let value = value as? Encodable {
      return try [value._ocp1Encoded]
    }

    throw Ocp1Error.status(.badFormat)
  }

  private static func scalarOSCValue(from value: Any) -> (any OSCValue)? {
    switch value {
    case let value as Bool: value
    case let value as Float: value
    case let value as Double: value
    case let value as String: value
    case let value as Data: value
    case let value as Int32: value
    case let value as Int64: value
    case let value as any FixedWidthInteger: oscInteger(value)
    default: nil
    }
  }

  private static func oscInteger(_ value: some FixedWidthInteger) -> any OSCValue {
    if let value = Int32(exactly: value) {
      value
    } else if let value = Int64(exactly: value) {
      value
    } else {
      Int64.max // only a UInt64 above Int64.max
    }
  }

  private static func rawValue(of value: some RawRepresentable) -> Any {
    value.rawValue
  }

  /// The OCA value of `type` that OSC arguments set. A single argument is converted:
  /// numbers to any numeric type that holds them exactly (floating-point values are
  /// rounded for integer types), Booleans to and from numbers, enumerations from their
  /// raw values. Otherwise the arguments are encoded as OCP.1 in order and decoded as
  /// `type`, as for a record of several fields such as a vector.
  static func value<T: Decodable>(_ type: T.Type, from values: OSCValues) throws -> T {
    if values.count == 1, let value = try scalarValue(type, from: values[0]) {
      return value
    }
    return try Ocp1Decoder().decode(type, from: values._ocp1Encoded)
  }

  private static func scalarValue<T>(_ type: T.Type, from value: any OSCValue) throws -> T? {
    let result: Any? = if T.self == Bool.self {
      try boolValue(from: value)
    } else if T.self == String.self {
      value as? String
    } else if let type = T.self as? any BinaryFloatingPoint.Type {
      try floatingPointValue(type, from: value)
    } else if let type = T.self as? any FixedWidthInteger.Type {
      try integerValue(type, from: value)
    } else if let type = T.self as? any RawRepresentable.Type {
      try enumerationValue(type, from: value)
    } else {
      nil
    }
    return result as? T
  }

  private static func boolValue(from value: any OSCValue) throws -> Bool {
    switch value {
    case let value as Bool: value
    case let value as Int32: value != 0
    case let value as Int64: value != 0
    case let value as Float: value != 0
    case let value as Double: value != 0
    default: throw Ocp1Error.status(.badFormat)
    }
  }

  private static func floatingPointValue<F: BinaryFloatingPoint>(
    _ type: F.Type,
    from value: any OSCValue
  ) throws -> F {
    switch value {
    case let value as Float: F(value)
    case let value as Double: F(value)
    case let value as Int32: F(value)
    case let value as Int64: F(value)
    case let value as Bool: value ? 1 : 0
    default: throw Ocp1Error.status(.badFormat)
    }
  }

  private static func integerValue<I: FixedWidthInteger>(
    _ type: I.Type,
    from value: any OSCValue
  ) throws -> I {
    let result: I? = switch value {
    case let value as Int32: I(exactly: value)
    case let value as Int64: I(exactly: value)
    case let value as Float: value.isFinite ? I(exactly: value.rounded()) : nil
    case let value as Double: value.isFinite ? I(exactly: value.rounded()) : nil
    case let value as Bool: value ? 1 : 0
    default: throw Ocp1Error.status(.badFormat)
    }
    guard let result else { throw Ocp1Error.status(.parameterOutOfRange) }
    return result
  }

  private static func enumerationValue<R: RawRepresentable>(
    _ type: R.Type,
    from value: any OSCValue
  ) throws -> R {
    guard let rawValue = try scalarValue(R.RawValue.self, from: value) else {
      throw Ocp1Error.status(.badFormat)
    }
    guard let value = R(rawValue: rawValue) else {
      throw Ocp1Error.status(.parameterOutOfRange)
    }
    return value
  }
}
