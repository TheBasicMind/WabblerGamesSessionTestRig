//
//  File.swift
//  OverWord
//
//  Created by Paul Lancefield on 08/05/2018.
//  Copyright © 2018 Mr Lancefield Software Limited. All rights reserved.
//

import Foundation



public class Storage {
    
    fileprivate init() { }
    
    enum StorageError: Error {
        case couldNotSaveFile
        case couldNotReadFile
        case couldNotCompleteOperation
    }
    
    enum Directory {
        // Only documents and other data that is user-generated, or that cannot otherwise be recreated by your application, should be stored in the <Application_Home>/Documents directory and will be automatically backed up by iCloud.
        case documents
        // To persist data to the documents directory but ensure it is not backed up by iCloud
        case documentsNoBackup
        // Data that can be downloaded again or regenerated should be stored in the <Application_Home>/Library/Caches directory. Examples of files you should put in the Caches directory include database cache files and downloadable content, such as that used by magazine, newspaper, and map applications.
        case caches
    }
    
    static func retreiveAllDataObjects(for directory: Directory) throws -> [Data] {
        let url = try getURL(for: directory, fileName: nil)
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
        var datas = [Data]()
        for fileUrl in contents {
            let data = try Data(contentsOf:fileUrl, options:[])
            datas += [data]
        }
        return datas
    }
    
    /// Returns URL constructed from specified directory
    static func getURL(for directory: Directory, fileName: String?) throws -> URL {
        var searchPathDirectory: FileManager.SearchPathDirectory
        
        switch directory {
        case .documents, .documentsNoBackup:
            searchPathDirectory = .documentDirectory
        case .caches:
            searchPathDirectory = .cachesDirectory
        }
        
        if var url = FileManager.default.urls(for: searchPathDirectory, in: .userDomainMask).first {
            if directory == .documentsNoBackup {
                url = url.appendingPathComponent("cache", isDirectory: true)
                if fileName == nil {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
                }
            }
            if let fileName = fileName {
                url = url.appendingPathComponent(fileName, isDirectory: false)
            }

            return url
        } else {
            throw StorageError.couldNotReadFile
        }
    }
    
    
    /// Store an encodable struct to the specified directory on disk
    ///
    /// - Parameters:
    ///   - object: the encodable struct to store
    ///   - directory: where to store the struct
    ///   - fileName: what to name the file where the struct data will be stored
    static func store<T: Encodable>(_ object: T, to directory: Directory, as fileName: String) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(object)
        
        try Storage.storeData(data, to: directory, as: fileName)
    }
    
    static func storeData(_ data: Data, to directory: Directory, as fileName: String) throws {
        var url = try getURL(for: directory, fileName: fileName)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        do {
            try data.write(to: url, options: [NSData.WritingOptions.atomic])
        } catch {
            throw error
        }
    }
    
    /// Retrieve and convert a struct from a file on disk
    ///
    /// - Parameters:
    ///   - fileName: name of the file where struct data is stored
    ///   - directory: directory where struct data is stored
    ///   - type: struct type (i.e. Message.self)
    /// - Returns: decoded struct model(s) of data
    static func retrieve<T: Decodable>(_ fileName: String, from directory: Directory, as type: T.Type) throws -> T {
        let data = try retrieveData(fileName, from: directory)
        let decoder = JSONDecoder()
        let model = try decoder.decode(type, from: data)
        return model
    }
    
    static func retrieveData(_ fileName: String, from directory: Directory) throws -> Data {
        let url = try getURL(for: directory, fileName: fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            throw StorageError.couldNotReadFile
        }
        
        let data = try Data(contentsOf:url, options:[])

        return data
    }
    
    /// Remove all files at specified directory
    static func clear(_ directory: Directory) throws {
        let url = try getURL(for: directory, fileName: nil)
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
        for fileUrl in contents {
            try FileManager.default.removeItem(at: fileUrl)
        }
    }
    
    /// Remove all files at specified directory
    static func clearMatchingObjectType<T: Decodable>(_ directory: Directory, type: T.Type) throws {
        let url = try getURL(for: directory, fileName: nil)
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
        for fileUrl in contents {
            do {
                let data = try Data(contentsOf:fileUrl, options:[])
                let decoder = JSONDecoder()
                do {
                    _ = try decoder.decode(type, from: data)
                    do {
                        // If we get here we have successfully decoded
                        try FileManager.default.removeItem(at: fileUrl)
                    } catch {
                        continue
                    }
                } catch {
                    continue
                }
            } catch {
                continue
            }
        }
    }
    
    /// Remove all files at specified directory
    static func clearMatchingObject<T: Decodable>(_ directory: Directory, type: T.Type, matchingObject: (T)->Bool ) throws {
        let url = try getURL(for: directory, fileName: nil)
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
        for fileUrl in contents {
            let data: Data
            let decoder: JSONDecoder
            do {
                data = try Data(contentsOf:fileUrl, options:[])
                decoder = JSONDecoder()
            } catch {
                throw StorageError.couldNotReadFile
            }
            do {
                let obj = try decoder.decode(type, from: data)
                if matchingObject(obj) {
                    do {
                        // If we get here we have successfully decoded
                        try FileManager.default.removeItem(at: fileUrl)
                    } catch {
                        print("Error: cached object could not be removed")
                        continue
                    }
                }
            } catch {
                continue
            }
        }
    }
    
    /// Remove specified file from specified directory
    static func remove(_ fileName: String, from directory: Directory) throws ->Bool {
        let url = try getURL(for: directory, fileName: fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            return true
        } else {
            return false
        }
    }
    
    /// Returns BOOL indicating whether file exists at specified directory with specified file name
    static func fileExists(_ fileName: String, in directory: Directory) throws -> Bool {
        let url = try getURL(for: directory, fileName: fileName)
        return FileManager.default.fileExists(atPath: url.path)
    }
}
