import Foundation

enum WindsurfProto {
    enum Field { case integer(UInt64), bytes(Data), fixed64(UInt64), fixed32(UInt32) }
    static func varint(_ value: UInt64) -> Data { var value = value; var data = Data(); repeat { let byte = UInt8(value & 127); value >>= 7; data.append(byte | (value == 0 ? 0 : 128)) } while value != 0; return data }
    static func bytes(_ field: UInt64, _ value: Data) -> Data { var result = varint(field << 3 | 2); result.append(varint(UInt64(value.count))); result.append(value); return result }
    static func decode(_ data: Data) throws -> [Int: Field] {
        guard data.count <= 2_097_152 else { throw UsageError.malformed }; let data = [UInt8](data); var index = 0; var fields: [Int: Field] = [:]
        func readVarint() throws -> UInt64 { var result: UInt64 = 0; for shift in stride(from: 0, through: 63, by: 7) { guard index < data.count else { throw UsageError.malformed }; let byte = data[index]; index += 1; if shift == 63 && byte > 1 { throw UsageError.malformed }; result |= UInt64(byte & 127) << shift; if byte & 128 == 0 { return result } }; throw UsageError.malformed }
        while index < data.count {
            let tag = try readVarint(); let number = tag >> 3; guard number > 0, number <= 536_870_911 else { throw UsageError.malformed }; let field: Field
            switch tag & 7 {
            case 0: field = .integer(try readVarint())
            case 2: let length = try readVarint(); guard length <= UInt64(data.count - index) else { throw UsageError.malformed }; field = .bytes(Data(data[index..<index + Int(length)])); index += Int(length)
            case 1: guard data.count - index >= 8 else { throw UsageError.malformed }; var value: UInt64 = 0; for offset in 0..<8 { value |= UInt64(data[index + offset]) << (offset * 8) }; index += 8; field = .fixed64(value)
            case 5: guard data.count - index >= 4 else { throw UsageError.malformed }; var value: UInt32 = 0; for offset in 0..<4 { value |= UInt32(data[index + offset]) << (offset * 8) }; index += 4; field = .fixed32(value)
            default: throw UsageError.malformed
            }; fields[Int(number)] = field
        }; return fields
    }
    static func integer(_ fields: [Int: Field], _ number: Int) throws -> UInt64? { guard let field = fields[number] else { return nil }; guard case .integer(let value) = field else { throw UsageError.malformed }; return value }
    static func payload(_ fields: [Int: Field], _ number: Int) throws -> Data? { guard let field = fields[number] else { return nil }; guard case .bytes(let value) = field else { throw UsageError.malformed }; return value }
    static func timestamp(_ data: Data?) throws -> Date? { guard let data else { return nil }; let fields = try decode(data); guard let seconds = try integer(fields, 1), seconds <= UInt64(Int64.max) else { return nil }; let nanos = try integer(fields, 2) ?? 0; guard nanos < 1_000_000_000 else { throw UsageError.malformed }; return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1e9) }
}
