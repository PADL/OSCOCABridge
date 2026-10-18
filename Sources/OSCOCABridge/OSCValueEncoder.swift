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
import SwiftOSCCore

/// Flattens a value into OSC arguments by encoding it: each scalar it encodes becomes an
/// argument, in order, so a record gives its fields, a collection its elements and an
/// enumeration its raw value. Integers that are not OSC types are sent as `Int32`, or as
/// `Int64` if they do not fit. A value with nothing OSC can carry, such as a nil or an
/// integer beyond `Int64`, is refused with `Unsupported`.
struct OSCValueEncoder {
  struct Unsupported: Error {}

  func encode(_ value: some Encodable) throws -> OSCValues {
    let encoder = _OSCValueEncoder()
    try encoder.encode(value)
    return encoder.values
  }
}

private final class _OSCValueEncoder: Encoder {
  var values = OSCValues()
  var codingPath = [any CodingKey]()
  var userInfo = [CodingUserInfoKey: Any]()

  func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    KeyedEncodingContainer(KeyedContainer(encoder: self))
  }

  func unkeyedContainer() -> any UnkeyedEncodingContainer {
    UnkeyedContainer(encoder: self)
  }

  func singleValueContainer() -> any SingleValueEncodingContainer {
    SingleValueContainer(encoder: self)
  }

  func append(_ value: any OSCValue) {
    values.append(value)
  }

  func appendInteger(_ value: some FixedWidthInteger) throws {
    if let value = Int32(exactly: value) {
      values.append(value)
    } else if let value = Int64(exactly: value) {
      values.append(value)
    } else {
      throw OSCValueEncoder.Unsupported()
    }
  }

  func encode(_ value: some Encodable) throws {
    switch value {
    // Data would otherwise encode as an array of bytes
    case let value as Data: append(value)
    default: try value.encode(to: self)
    }
  }
}

/// The containers all append to the one encoder: nesting only flattens.
private struct SingleValueContainer: SingleValueEncodingContainer {
  let encoder: _OSCValueEncoder
  var codingPath: [any CodingKey] { encoder.codingPath }

  func encodeNil() throws { throw OSCValueEncoder.Unsupported() }
  func encode(_ value: Bool) { encoder.append(value) }
  func encode(_ value: String) { encoder.append(value) }
  func encode(_ value: Double) { encoder.append(value) }
  func encode(_ value: Float) { encoder.append(value) }
  func encode(_ value: Int) throws { try encoder.appendInteger(value) }
  func encode(_ value: Int8) throws { try encoder.appendInteger(value) }
  func encode(_ value: Int16) throws { try encoder.appendInteger(value) }
  func encode(_ value: Int32) { encoder.append(value) }
  func encode(_ value: Int64) { encoder.append(value) }
  func encode(_ value: UInt) throws { try encoder.appendInteger(value) }
  func encode(_ value: UInt8) throws { try encoder.appendInteger(value) }
  func encode(_ value: UInt16) throws { try encoder.appendInteger(value) }
  func encode(_ value: UInt32) throws { try encoder.appendInteger(value) }
  func encode(_ value: UInt64) throws { try encoder.appendInteger(value) }
  func encode(_ value: some Encodable) throws { try encoder.encode(value) }
}

private struct UnkeyedContainer: UnkeyedEncodingContainer {
  let encoder: _OSCValueEncoder
  var codingPath: [any CodingKey] { encoder.codingPath }
  private(set) var count = 0

  init(encoder: _OSCValueEncoder) {
    self.encoder = encoder
  }

  mutating func encodeNil() throws { throw OSCValueEncoder.Unsupported() }

  mutating func encode(_ value: some Encodable) throws {
    try encoder.encode(value)
    count += 1
  }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type
  ) -> KeyedEncodingContainer<NestedKey> {
    count += 1
    return encoder.container(keyedBy: keyType)
  }

  mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
    count += 1
    return encoder.unkeyedContainer()
  }

  mutating func superEncoder() -> any Encoder { encoder }
}

private struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
  let encoder: _OSCValueEncoder
  var codingPath: [any CodingKey] { encoder.codingPath }

  mutating func encodeNil(forKey key: Key) throws { throw OSCValueEncoder.Unsupported() }

  mutating func encode(_ value: some Encodable, forKey key: Key) throws {
    try encoder.encode(value)
  }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type,
    forKey key: Key
  ) -> KeyedEncodingContainer<NestedKey> {
    encoder.container(keyedBy: keyType)
  }

  mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
    encoder.unkeyedContainer()
  }

  mutating func superEncoder() -> any Encoder { encoder }
  mutating func superEncoder(forKey key: Key) -> any Encoder { encoder }
}
