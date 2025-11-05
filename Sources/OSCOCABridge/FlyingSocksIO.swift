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

#if !os(Linux)

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import FlyingSocks
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

private func _defaultPool(logger: Logging = .disabled) -> AsyncSocketPool {
  #if canImport(Darwin)
  return .kQueue(logger: logger)
  #elseif canImport(CSystemLinux)
  return .ePoll(logger: logger)
  #else
  return .poll(logger: logger)
  #endif
}

private extension Socket {
  func setIPv6Only() throws {
    try setValue(1, for: Int32SocketOption(name: IPV6_V6ONLY), level: IPPROTO_IPV6)
  }
}

private func _makeUdpSocket(address: sockaddr_storage) async throws -> Socket {
  let socket = try Socket(domain: address.family, type: .datagram)

  try socket.setValue(true, for: .localAddressReuse)
  if address.family == sa_family_t(AF_INET6) { try socket.setIPv6Only() }
  try socket.bind(to: address)

  return socket
}

func udpEventLoop(address: sockaddr_storage, with bridge: OSCOCABridge) async throws {
  let socket = try await _makeUdpSocket(address: address)
  let pool = _defaultPool()
  try await pool.prepare()

  let poolTask = Task { try await pool.run() }
  let asyncSocket = try AsyncSocket(socket: socket, pool: pool)

  for try await pdu in asyncSocket.messages(maxMessageLength: MaxMessageSize) {
    try? await bridge._handle(message: Data(pdu.payload), from: pdu.peerAddress.makeStorage())
  }

  poolTask.cancel()
}

#endif
