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
@_spi(SwiftOCAPrivate)
import SwiftOCADevice

/// The member of an object that an address names.
enum OSCOCAMember: Sendable {
  case method(OcaMethodID)
  case property(OcaDevicePropertyDescriptor)
}

extension SwiftOCADevice.OcaRoot {
  /// The properties introspection shows, which a wildcard subscription is matched against.
  /// A hidden property is still there to be named: hidden means not advertised.
  var oscVisibleProperties: [OcaDevicePropertyDescriptor] {
    devicePropertyDescriptors.filter { !$0.flags.contains(.hidden) }
  }

  /// Resolves an address leaf against this object: a method ID, a property ID, a
  /// property name, then a method name, which may be a property accessor's. Names are
  /// matched exactly, in lower camel case: `gain`, `setGain`.
  func oscMember(for leaf: OSCOCALeaf) -> OSCOCAMember? {
    switch leaf {
    case let .methodID(methodID):
      return .method(methodID)
    case let .propertyID(propertyID):
      return devicePropertyDescriptors
        .first { $0.propertyID == propertyID || $0.yPropertyID == propertyID }
        .map { .property($0) }
    case let .name(name):
      let properties = devicePropertyDescriptors
      if let property = properties.first(where: { $0.name == name }) {
        return .property(property)
      }
      if let method = deviceMethodDescriptors.first(where: { $0.name.lowerCamelCased == name }) {
        return .method(method.methodID)
      }
      for property in properties {
        let stem = property.name.upperCamelCased
        if let getMethodID = property.getMethodID,
           (property.accessorNames.get ?? "Get\(stem)").lowerCamelCased == name
        {
          return .method(getMethodID)
        }
        if let setMethodID = property.setMethodID,
           (property.accessorNames.set ?? "Set\(stem)").lowerCamelCased == name
        {
          return .method(setMethodID)
        }
      }
      return nil
    }
  }
}

/// Every object in `container` and the blocks within it, with its role path.
@OcaDevice
func oscObjects(
  in container: any OcaBlockContainer,
  rolePath: OcaNamePath = []
) -> [(rolePath: OcaNamePath, object: SwiftOCADevice.OcaRoot)] {
  var objects = [(rolePath: OcaNamePath, object: SwiftOCADevice.OcaRoot)]()
  for member in container.actionObjects {
    let memberRolePath = rolePath + [member.role]
    objects.append((memberRolePath, member))
    if let member = member as? any OcaBlockContainer {
      objects += oscObjects(in: member, rolePath: memberRolePath)
    }
  }
  return objects
}

/// The address of a role path and leaf: `/Block/Gain/gain`.
func oscAddress(rolePath: OcaNamePath, leaf: String) -> String {
  "/" + (rolePath + [leaf]).joined(separator: "/")
}
