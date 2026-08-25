import Foundation
import NIOCore
import XCTest
import MySQLNIO
@testable import DBDeckCore

/// Regressão do driver vendorizado: o scramble do handshake tem 20 bytes, e o NUL que
/// fecha a parte 2 NÃO faz parte dele. Com 21 bytes o full auth do caching_sha2
/// (XOR da senha com o seed repetido) desalinhava a partir do 21º caractere — senhas
/// com 20+ caracteres eram recusadas sem TLS.
final class MySQLHandshakeTests: XCTestCase {
    func testScrambleDoHandshakeTem20BytesSemONulFinal() throws {
        var payload = ByteBufferAllocator().buffer(capacity: 128)
        payload.writeInteger(UInt8(10))                                   // protocol version
        payload.writeNullTerminatedString("8.0.46")                      // server version
        payload.writeInteger(UInt32(42), endianness: .little)            // connection id
        payload.writeBytes(Array(1...8))                                  // auth-plugin-data-part-1
        payload.writeInteger(UInt8(0))                                    // filler
        payload.writeInteger(UInt16(0x8200), endianness: .little)        // caps low: PROTOCOL_41 | SECURE_CONNECTION
        payload.writeInteger(UInt8(0xFF))                                 // charset
        payload.writeInteger(UInt16(2), endianness: .little)             // status flags
        payload.writeInteger(UInt16(0x0008), endianness: .little)        // caps high: PLUGIN_AUTH
        payload.writeInteger(UInt8(21))                                   // auth plugin data length
        payload.writeBytes([UInt8](repeating: 0, count: 10))              // reserved
        payload.writeBytes(Array(9...20))                                  // auth-plugin-data-part-2 (12 bytes)
        payload.writeInteger(UInt8(0))                                    // ...e o NUL terminador
        payload.writeNullTerminatedString("caching_sha2_password")

        var packet = MySQLPacket(payload: payload)
        let handshake = try MySQLProtocol.HandshakeV10.decode(from: &packet, capabilities: [])
        XCTAssertEqual(handshake.authPluginData.readableBytes, 20)
        XCTAssertEqual(Array(handshake.authPluginData.readableBytesView), Array(1...20))
    }
}
