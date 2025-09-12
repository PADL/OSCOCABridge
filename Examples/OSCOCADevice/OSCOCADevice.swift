//
// Copyright (c) 2023-2025 PADL Software Pty Ltd
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

import Foundation
import SwiftOCA
import SwiftOCADevice
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
import OSCOCABridge

@main
public enum OSCOCADevice {
  static var testActuator: SwiftOCADevice.OcaBooleanActuator?
  static let port: UInt16 = 65000
  static let oscPort: UInt16 = 8000

  public static func main() async throws {
    var listenAddress = sockaddr_in()
    listenAddress.sin_family = sa_family_t(AF_INET)
    listenAddress.sin_port = port.bigEndian
    #if canImport(Darwin)
    listenAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif

    var listenAddressData = Data()
    withUnsafeBytes(of: &listenAddress) { bytes in
      listenAddressData = Data(bytes: bytes.baseAddress!, count: bytes.count)
    }

    let device = OcaDevice.shared
    try await device.initializeDefaultObjects()
    let deviceManager = await device.deviceManager!
    Task { @OcaDevice in
      deviceManager.deviceName = "OCA Test"
      deviceManager.modelGUID = OcaModelGUID(mfrCode: .init((0, 0, 0)), modelCode: (1, 2, 3, 4))
    }
    #if os(Linux)
    let streamEndpoint = try await Ocp1IORingStreamDeviceEndpoint(address: listenAddressData)
    let datagramEndpoint = try await Ocp1IORingDatagramDeviceEndpoint(address: listenAddressData)
    #elseif canImport(FlyingSocks)
    let streamEndpoint = try await Ocp1FlyingSocksStreamDeviceEndpoint(address: listenAddressData)
    let datagramEndpoint =
      try await Ocp1FlyingSocksDatagramDeviceEndpoint(address: listenAddressData)
    #else
    let streamEndpoint = try await Ocp1StreamDeviceEndpoint(address: listenAddressData)
    #endif

    listenAddress = sockaddr_in()
    listenAddress.sin_family = sa_family_t(AF_INET)
    listenAddress.sin_port = oscPort.bigEndian
    #if canImport(Darwin)
    listenAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    let bridge = OSCOCABridge(address: listenAddress, device: device)
    await bridge.run()

    class MyBooleanActuator: SwiftOCADevice.OcaBooleanActuator {
      override open class var classID: OcaClassID { OcaClassID(parent: super.classID, 65280) }
    }

    let matrix = try await SwiftOCADevice
      .OcaMatrix<MyBooleanActuator>(
        rows: 4,
        columns: 2,
        deviceDelegate: device
      )

    let block = try await SwiftOCADevice
      .OcaBlock<SwiftOCADevice.OcaWorker>(role: "Block", deviceDelegate: device)

    let members = await matrix.members
    for x in 0..<members.nX {
      for y in 0..<members.nY {
        let coordinate = OcaVector2D(x: OcaMatrixCoordinate(x), y: OcaMatrixCoordinate(y))
        let actuator = try await MyBooleanActuator(
          role: "Actuator(\(x),\(y))",
          deviceDelegate: device,
          addToRootBlock: false
        )
        try await block.add(actionObject: actuator)
        try await matrix.add(member: actuator, at: coordinate)
      }
    }

    let gain = try await SwiftOCADevice.OcaGain(
      role: "Gain",
      deviceDelegate: device,
      addToRootBlock: false
    )
    try await block.add(actionObject: gain)

    let controlNetwork = try await SwiftOCADevice.OcaControlNetwork(deviceDelegate: device)
    Task { @OcaDevice in controlNetwork.state = .running }

    signal(SIGPIPE, SIG_IGN)

    try await withThrowingTaskGroup(of: Void.self) { taskGroup in
      taskGroup.addTask {
        print("Starting OCP.1 stream endpoint \(streamEndpoint)...")
        try await streamEndpoint.run()
      }
      #if os(Linux) || canImport(FlyingSocks)
      taskGroup.addTask {
        print("Starting OCP.1 datagram endpoint \(datagramEndpoint)...")
        try await datagramEndpoint.run()
      }
      #endif
      taskGroup.addTask {
        for try await value in await gain.$gain {
          print("gain set to \(value)!")
        }
      }
      try await taskGroup.next()
    }
  }
}
