//
//  StorageExtensions.swift
//  OverWord
//
//  Created by Paul Lancefield on 03/11/2018.
//  Copyright © 2018 Paul Lancefield. All rights reserved.
//

import Foundation

extension Storage {
    
    /// Store an encodable struct to the specified directory on disk
    ///
    /// - Parameters:
    ///   - object: the NSCoder encodable object to store
    ///   - directory: where to store the struct
    ///   - fileName: what to name the file where the struct data will be stored
    static func storeNSObj<T: NSSecureCoding>(_ object: T, to directory: Directory, as fileName: String) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: false)
        try Storage.storeData(data, to: directory, as: fileName)
    }
    
    
    /// Retrieve and convert a struct from a file on disk
    ///
    /// - Parameters:
    ///   - fileName: name of the file where NSCodable object is stored
    ///   - directory: directory where object data is stored
    ///   - type: struct type (i.e. Message.self)
    /// - Returns: decoded struct model(s) of data
    static func retrieveNSObj<T: NSSecureCoding>(_ fileName: String, from directory: Directory, as type: T.Type) throws -> T {
        let data = try Storage.retrieveData(fileName, from: directory)
        if let obj = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? T  {
            return obj
        } else {
            throw StorageError.couldNotReadFile
        }
    }
    
    /// Remove all files at specified directory
    static func retreiveAllNSObjOfType<T: NSSecureCoding>(_ type: T.Type) throws -> [T] {
        let datas = try Storage.retreiveAllDataObjects(for: .documentsNoBackup)
        var objects = [T]()
        for data in datas {
            if let obj = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? T {
                objects += [obj]
            }
        }
        return objects
    }
    
//    /// Retrieve and convert a struct from a file on disk
//    ///
//    /// - Parameters:
//    ///   - fileName: name of the file where NSCodable object is stored
//    ///   - directory: directory where object data is stored
//    ///   - type: struct type (i.e. Message.self)
//    /// - Returns: decoded struct model(s) of data
//    static func retrieveAllNSObj<T: NSSecureCoding>(_ directory: Directory, of type: T.Type) throws -> [T] {
//        let allData = try Storage.retreiveAllOfType(Data.self, directory: .documentsNoBackup)
//        var allObj = [T]()
//        for data in allData {
//            if let anObj = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [type], from: data) as? T {
//                allObj += [anObj]
//            } else {
//                continue
//            }
//        }
//        return allObj
//    }
    
}
