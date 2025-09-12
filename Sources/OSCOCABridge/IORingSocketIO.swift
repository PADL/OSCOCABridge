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

#if os(Linux)

import IORing
import IORingUtils
import SocketAddress
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Glibc
import SystemPackage

func udpEventLoop(address: any SocketAddress, with bridge: OSCOCABridge) async throws {
  let socket: Socket

  socket = try Socket(ring: IORing.shared, domain: address.family, type: SOCK_DGRAM, protocol: 0)
  try socket.bind(to: address)

  repeat {
    do {
      for try await pdu in try await socket.receiveMessages(count: MaxMessageSize) {
        try? await bridge._handle(message: Data(pdu.buffer), from: AnySocketAddress(bytes: pdu.name))
      }
    } catch Errno.canceled {}
  } while !Task.isCancelled
}

#endif
