enum PowerFlowSMCReader {
    struct Reading: Equatable, Sendable {
        var inputVoltageMillivolts: Double?
        var inputCurrentMilliamps: Double?
        var batteryVoltageMillivolts: Double?
        var batteryCurrentMilliamps: Double?
    }

    static func read() -> Reading {
        SMCSensorReader.withConnection { connection in
            read { key in
                SMCSensorReader.readKey(key, connection: connection)
            }
        } ?? Reading()
    }

    static func read(readKey: (String) -> SMCSensorReader.SMCReading?) -> Reading {
        let inputVoltageMillivolts = readKey("VD0R").flatMap { reading -> Double? in
            guard reading.dataType == "flt " else {
                return nil
            }
            return SMCSensorReader.decodeFloat(reading.bytes).map { $0 * 1_000 }
        }
        let inputCurrentMilliamps = readKey("ID0R").flatMap { reading -> Double? in
            guard reading.dataType == "flt " else {
                return nil
            }
            return SMCSensorReader.decodeFloat(reading.bytes).map { $0 * 1_000 }
        }
        let batteryVoltageMillivolts = readKey("B0AV").flatMap { reading -> Double? in
            guard reading.dataType == "ui16",
                  reading.bytes.count == 2 else {
                return nil
            }
            let raw = UInt16(reading.bytes[0]) | (UInt16(reading.bytes[1]) << 8)
            return Double(raw)
        }
        let batteryCurrentMilliamps = readKey("B0AC").flatMap { reading -> Double? in
            guard reading.dataType == "si16",
                  reading.bytes.count == 2 else {
                return nil
            }
            let raw = UInt16(reading.bytes[0]) | (UInt16(reading.bytes[1]) << 8)
            return Double(Int16(bitPattern: raw))
        }

        return Reading(
            inputVoltageMillivolts: inputVoltageMillivolts,
            inputCurrentMilliamps: inputCurrentMilliamps,
            batteryVoltageMillivolts: batteryVoltageMillivolts,
            batteryCurrentMilliamps: batteryCurrentMilliamps
        )
    }
}
