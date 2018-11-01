//
//  MiscExtensionsFunctionsConstants.swift
//  GKGameSessionTestRig
//
//  Created by Paul Lancefield on 20/12/2017.
//  Copyright © 2017 Paul Lancefield. All rights reserved.
//

import UIKit
import GameKit
import CloudKit


func myDebugPrint(_ string: String) {
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
    var newString = appDelegate.debugString
    newString.append("\n\(string)")
    appDelegate.debugString = newString
    appDelegate.updateDebugTextView(newString)
    print(string)
}

enum GKGameSessionRigStrings {
    static let cloudKitContainer                  = "iCloud.radicalfraction.GKGameSessionTestRig"
    static let openWabbleForPlayerChallenge        = "newOWTestGameRequest://?token="
}
enum GKGameSessionAPI {
    static let versionNo                        = 1
}
enum GKGameSessionRigBools {
    static let joinAtStartUp                       = true
    static let shortIDs                            = true
}

enum APIError: Error {
    case doesNotMatchVersion(currentVersion: Int, storedVersion: Int)
}

struct APIData<T: Codable>: Codable {
    let apiVersion: Int
    let apiData: T
    
    enum CodingKeys: String, CodingKey {
        case apiVersion = "apiVersion"
        case apiData = "apiData"
    }
    
    init(versionNumber: Int, apiData: T) {
        self.apiVersion = versionNumber
        self.apiData = apiData
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let apiVersion = try container.decode(Int.self, forKey: .apiVersion)
        if apiVersion != GKGameSessionAPI.versionNo { throw APIError.doesNotMatchVersion(currentVersion: apiVersion, storedVersion: apiVersion) }
        let apiData = try container.decode(T.self, forKey: .apiData)
        self.apiVersion = apiVersion
        self.apiData = apiData
    }
}

extension JSONEncoder {
    open func encodeApiVersion<T>(_ value: T) throws -> Data where T : Codable {
        let wrappedData = APIData(versionNumber: GKGameSessionAPI.versionNo, apiData: value)
        let data = try self.encode(wrappedData)
        return data
    }
}

extension JSONDecoder {
    open func decodeApiVersion<T>(_ type: T.Type, from data: Data) throws -> T where T : Codable {
        let wrappedData: APIData = try decode(APIData<T>.self, from: data)
        let data = wrappedData.apiData
        return data
    }
}

struct GameData: Codable {
    let someString: String
}

extension String {
    // Compare short easier to read values when debugging
    func strHash() -> String {
        var result = UInt64 (5381)
        let buf = [UInt8](self.utf8)
        for b in buf {
            result = 127 * (result & 0x00ffffffffffffff) + UInt64(b)
        }
        let resultString = "\(result)"
        return String(resultString.prefix(8))
    }
}

extension CKError {
    // check: https://developer.apple.com/documentation/cloudkit/ckerrorcode
    public func isRecordNotFound() -> Bool {
        return isZoneNotFound() || isUnknownItem()
    }
    public func isZoneNotFound() -> Bool {
        return isSpecificErrorCode(code: .zoneNotFound)
    }
    public func isUnknownItem() -> Bool {
        return isSpecificErrorCode(code: .unknownItem)
    }
    public func isConflict() -> Bool {
        return isSpecificErrorCode(code: .serverRecordChanged)
    }
    public func isSpecificErrorCode(code: CKError.Code) -> Bool {
        var match = false
        if self.code == code {
            match = true
        }
        else if self.code == .partialFailure {
            // This is a multiple-issue error. Check the underlying array
            // of errors to see if it contains a match for the error in question.
            guard let errors = partialErrorsByItemID else {
                return false
            }
            for (_, error) in errors {
                if let cke = error as? CKError {
                    if cke.code == code {
                        match = true
                        break
                    }
                }
            }
        }
        return match
    }
    // ServerRecordChanged errors contain the CKRecord information
    // for the change that failed, allowing the client to decide
    // upon the best course of action in performing a merge.
    public func getMergeRecords() -> (CKRecord?, CKRecord?) {
        if code == .serverRecordChanged {
            // This is the direct case of a simple serverRecordChanged Error.
            return (clientRecord, serverRecord)
        }
        guard code == .partialFailure else {
            return (nil, nil)
        }
        guard let errors = partialErrorsByItemID else {
            return (nil, nil)
        }
        for (_, error) in errors {
            if let cke = error as? CKError {
                if cke.code == .serverRecordChanged {
                    // This is the case of a serverRecordChanged Error
                    // contained within a multi-error PartialFailure Error.
                    return cke.getMergeRecords()
                }
            }
        }
        return (nil, nil)
    }
}
