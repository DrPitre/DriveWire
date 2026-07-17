//
//  DriveWireHost+Logging.swift
//  DriveWireSwift
//

import Foundation

extension DriveWireHost {
    static func trimmedLog(from value: String) -> String {
        guard value.count > maximumLogCharacters else {
            return value
        }

        let retainedCount = maximumLogCharacters - trimmedLogPrefix.count
        guard retainedCount > 0 else {
            return String(value.suffix(maximumLogCharacters))
        }

        return trimmedLogPrefix + value.suffix(retainedCount)
    }

    func reportActivity(_ message: String, isFrequent: Bool = false, isError: Bool = false) {
        let shouldRecord = isError || !isFrequent || detailedOpcodeLogging
        if shouldRecord {
            logStorage = Self.trimmedLog(from: logStorage + message + "\n")
        }

        if isError || (Self.emitConsoleOutput && shouldRecord) {
            print(message)
        }
    }
}

extension Data {
    func dump() {
        dump(prefix: "")
    }

    func dump(prefix : String) {
        let prefix : String = prefix
        var line : String = ""
        var asciiLine : String = ""
        var asciiByte : String
        var count = 0
        let c = {
            print("\(prefix)\(line)", terminator: "")
            let s = String.init(repeating: " ", count: 40 - line.count)
            print(s, terminator: "")
            print(asciiLine, terminator: "\n")
            line = ""
            asciiLine = ""
        }
        for byte in self {
            line.append(String(format: "%02x", byte))
            if byte > 0x1f && byte < 0x7f {
                asciiByte = String(format: "%c", byte)
            } else {
                asciiByte = "."
            }
            asciiLine.append(asciiByte)
            if count % 2 == 1 {
                line.append(" ")
            }
            count = count + 1
            if count % 16 == 0 {
                c()
            }
        }

        if line != "" {
            c()
        }
    }
}
