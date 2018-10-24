//
//  WabblerGameSession.swift
//  OverWord
//
//  Created by Paul Lancefield on 11/10/2018.
//  Copyright © 2018 Paul Lancefield. All rights reserved.
//

import Foundation
import UIKit
import CloudKit

enum WabblerGameSessionStrings {
    static let gamesZoneName                    = "Games"
}

enum WabblerCloudPlayerStrings {
    static let displayName                    = "displayName"
}

enum WabblerGameSessionError: Error {
    case noCloudKitConnection
    case localPlayerNotSignedIn
    case unknownError
    case gameDataCouldNotBeEncoded
    case serverGameDataCouldNotBeDecoded
}

struct WabblerSessionFailureSet: OptionSet, Hashable {
    let rawValue: Int
    static let noAssuredCloudKitConnection  = WabblerSessionFailureSet(rawValue: 1 << 0)
    static let localPlayerNotSignedIn       = WabblerSessionFailureSet(rawValue: 1 << 1)
}

protocol WabblerAssuredState {
    //var stateError: ((WabblerGameSessionError)->Void)? { get set }
    //var failureStates: WabblerSessionFailureSet { get set }
    var isAssured: Bool { get }
}

struct WabblerCloudPlayer: Codable, Hashable {
    var displayName: String?
    var playerID: String?
    var modificationDate: Date?
    
    /**
     Note uses the same container as
     was set up when the Wabbler game
     session was initialised.
    */
    static func getCurrentSignedInPlayer(completionHandler handler: @escaping (WabblerCloudPlayer?, Error?) -> Void) {
        if let localPlayer = WabblerGameSession.localPlayer {
            handler(localPlayer, nil)
        } else {
            CloudKitConnector.sharedConnector.fetchUserRecord(containerIdentifier: nil) {
                record, error in
                if let record = record  {
                    print(record)
                    DispatchQueue.main.async {
                        let player = WabblerCloudPlayer(displayName: record[WabblerCloudPlayerStrings.displayName] ?? WabblerGameSession.localPlayerName ?? "Name not defined", playerID: record.recordID.recordName, modificationDate: record.modificationDate)
                        WabblerGameSession.localPlayer = player
                        WabblerGameSession.localPlayerRecord = record
                        handler(player, error)
                    }
                }
            }
        }
    }
}

protocol WabblerGameSessionEventListener {
    func sessionConnectionStateError(error:Error)
    func session(_ session: WabblerGameSession, didAdd player: WabblerCloudPlayer)
    func session(_ session: WabblerGameSession, didRemove player: WabblerCloudPlayer)
    func session(_ session: WabblerGameSession, didReceiveMessage message: String, with data: Data, from player: WabblerCloudPlayer)
    func session(_ session: WabblerGameSession, player: WabblerCloudPlayer, didSave data: Data)
}

class WabblerGameSession: WabblerAssuredState {
    var isAssured: Bool {
        let connectorInitialised = CloudKitConnector.sharedConnector.failureStates.isEmpty
        if WabblerGameSession.localPlayer != nil, connectorInitialised {
            return true
        } else {
            if connectorInitialised == false {
                let error = WabblerGameSessionError.noCloudKitConnection
                WabblerGameSession.stateError?(error)
            } else {
                let error = WabblerGameSessionError.localPlayerNotSignedIn
                WabblerGameSession.stateError?(error)
            }
            return false
        }
    }
    static func == (lhs: WabblerGameSession, rhs: WabblerGameSession) -> Bool { return true }
    static var stateError: ((Error) -> Void)?
    static var localPlayer: WabblerCloudPlayer?
    static var localPlayerName: String?
    fileprivate static var localPlayerRecord: CKRecord?
    fileprivate static let recordType = "WabblerGameSession"
    fileprivate static let keys = (identifier : "name", lastModifiedDate : "lastModifiedDate", players: "players", title : "title", cachedData: "cachedData")
    private static var eventListenerDelegate: WabblerGameSessionEventListener?
    private var record : CKRecord //
    let scope: CKDatabase.Scope
    var owner: WabblerCloudPlayer? {
        if players.count > 0 {
            return players[0]
        } else {
            return nil
        }
    }
    var opponent: WabblerCloudPlayer?
    
    var identifier : String {
        get {
            return record.recordID.recordName
        }
    }
    
    var creationDate: Date? {
        get {
            return record.creationDate
        }
    }
    
    var lastModifiedDate : Date? {
        get {
            return record.modificationDate
        }
    }
    
    var players: [WabblerCloudPlayer] {
        get {
            let players: [WabblerCloudPlayer]
            if let data = self.record[WabblerGameSession.keys.players] as? NSData {
                let decoder = JSONDecoder()
                do {
                    players = try decoder.decode(Array<WabblerCloudPlayer>.self, from: data as Data)
                } catch {
                    print(error.localizedDescription)
                    players = []
                }
            } else {
                players = []
            }
            return players
        }
        set {
            let encoder = JSONEncoder()
            let data: Data
            do {
                data = try encoder.encode(newValue)
            } catch {
                return
            }
            record[WabblerGameSession.keys.players] = data as NSData
        }
    }
    
    var title : String {
        get {
            return record[WabblerGameSession.keys.title] as! String
        }
        set {
            record[WabblerGameSession.keys.title] = newValue
        }
    }
    
    private init(scope: CKDatabase.Scope) throws {
        let recordZone = CKRecordZone(zoneName: WabblerGameSessionStrings.gamesZoneName)
        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: recordZone.zoneID)
        let myRecord = CKRecord(recordType: WabblerGameSession.recordType, recordID:recordID)
        self.scope = scope
        self.record = myRecord
        guard let player = WabblerGameSession.localPlayer else {
            throw WabblerGameSessionError.localPlayerNotSignedIn
        }
        self.players = [player]
        self.title = ""
    }
    
    private init(record : CKRecord, scope: CKDatabase.Scope) {
        self.scope = scope
        self.record = record
    }
    
    /**
     The local player name should
     be set before cloudkit is initialised
    */
    static func initialiseCloudKitConnection(localPlayerName: String) {
        WabblerGameSession.localPlayerName = localPlayerName
        CloudKitConnector.sharedConnector.stateError = {
            error in
            WabblerGameSession.stateError?(error)
        }
        CloudKitConnector.sharedConnector.connect(containerIdentifier: nil, zoneName: WabblerGameSessionStrings.gamesZoneName)
        WabblerCloudPlayer.getCurrentSignedInPlayer { (player, error) in
            WabblerGameSession.localPlayer = player
            if let error = error {
                print(error.localizedDescription)
            }
        }
        CloudKitConnector.sharedConnector.remoteRecordDeletedCompletion = { recordID, error in
            DispatchQueue.main.async {
                if let error = error {
                    
                } else {
                    // If the record is not owned by
                    // the current player, call player
                    // removed from share.
                    
                    //WabblerGameSession.eventListenerDelegate.
                }
            }
        }
        CloudKitConnector.sharedConnector.remoteRecordUpdatedCompletion = { record, recordID, error in
            DispatchQueue.main.async {
                if let error = error {
                    // If the record is not owned by
                    // the current player, call player
                    // removed from share.
                } else {
                    
                }
            }
        }
    }
    
    static func createSession(withTitle title: String, completionHandler: @escaping (WabblerGameSession?, Error?) -> Void) {
        var newSession: WabblerGameSession?
        do {
            newSession = try WabblerGameSession(scope:.private)
        } catch {
            completionHandler(nil, error)
        }
        newSession!.title = title
        guard let player = WabblerGameSession.localPlayer else {
            WabblerGameSession.stateError?(WabblerGameSessionError.localPlayerNotSignedIn)
            return
        }
        newSession?.players = [player]
        
        CloudKitConnector.sharedConnector.save(record: newSession!.record, scope: .private) { (record, error) in
            let modSession = record != nil ? newSession : nil
            if let record = record {
                modSession?.record = record
            }
            DispatchQueue.main.async {
                completionHandler(modSession, error)
            }
        }
    }
    
    /**
     Save data to the session record.
     The completion handler returns the data we attempted to save
     or an error. This method is kept private because for efficiency
     the completion handler does not return on the main thread.
     - parameter data: The data we are saving to the record.
     - parameter completionHandler: A completion handler closure.
        - data: The data now saved on the server
        - error: A passthrough CloudKit error object if an error was raised.
    */
    ///TODO: Retry after seconds
    private func save(_ data: Data, completionHandler:((Data?, Error?) -> Void)?) {
        let modifiedRecord = record.copy() as! CKRecord // We make a copy and avoid modifying this session un
        modifiedRecord[WabblerGameSession.keys.cachedData] = data
        
        CloudKitConnector.sharedConnector.save(record: modifiedRecord, scope: scope) { (savedRecord, error) in
            var dataToBeReturned: Data? = nil
            if let savedRecord = savedRecord {
                self.record = savedRecord
            }
            // If there is an error we extract
            // the data as saved on the server
            if let ckError = error as? CKError {
                switch ckError.code {
                default:
                    if let updatedRecord = ckError.serverRecord {
                        self.record = updatedRecord
                        dataToBeReturned = updatedRecord[WabblerGameSession.keys.cachedData] as? Data
                        completionHandler?(dataToBeReturned, error)
                        return
                    }
                }
            }
            if let error = error {
                // Some other error we weren't expecting
                // to return data will break the API so
                // we return nil
                completionHandler?(nil,error)
                return
            }
            completionHandler?(data, error)
        }
    }
    
    /**
     Version and save game data to the session record.
     The completion handler returns the data we attempted to save
     or an error.
     - parameter data: The data we are saving to the record.
     - parameter completionHandler: A completion handler closure.
     - gameData: The game data now stored on the server after this save call has been made
     - error: The error object if an error was raised.
     */
    func saveGameData(_ gameData: GameData, completionHandler: @escaping (GameData?, Error?) -> Void) {
        let encoder = JSONEncoder()
        let data: Data
        do {
            data = try encoder.encodeApiVersion(gameData)
        } catch {
            myDebugPrint("error saving API data")
            completionHandler(gameData, WabblerGameSessionError.gameDataCouldNotBeEncoded)
            return
        }
        
        save(data) { (savedData, error) in
            var gameData: GameData? = nil
            let decoder = JSONDecoder()
            
            if savedData != nil {
                do {
                    gameData = try decoder.decodeApiVersion(GameData.self, from: savedData!)
                } catch {
                    myDebugPrint("******** Error decoding data saved by other player.")
                    DispatchQueue.main.async {
                        completionHandler(gameData, WabblerGameSessionError.serverGameDataCouldNotBeDecoded)
                    }
                    return
                }
            }
            DispatchQueue.main.async {
                completionHandler(gameData, error)
            }
        }
    }
    
    func loadData(completion: ((Data?, Error?) -> Void)? ) {
        CloudKitConnector.sharedConnector.loadRecord(record.recordID, scope: scope) {
            record, error in
            var data: Data? = nil
            if let record = record {
                self.record = record
            }
            data = record?[WabblerGameSession.keys.cachedData] as? Data
            DispatchQueue.main.async {
                completion?(data, error)
            }
        }
    }
    
    func loadGameData(completionHandler: @escaping (GameData?, Error?) -> Void) {
        loadData { (data, anError) in
            var anError = anError
            let decoder = JSONDecoder()
            var gameData: GameData? = nil
            if let data = data {
                do {
                    gameData = try decoder.decodeApiVersion(GameData.self, from: data)
                } catch {
                    myDebugPrint("Error: Could not decode gamedata when loading data")
                    anError = WabblerGameSessionError.serverGameDataCouldNotBeDecoded
                    return
                }
            }
            DispatchQueue.main.async {
                completionHandler(gameData, anError)
            }
        }
    }
    
    static func add(listener: WabblerGameSessionEventListener) {
        WabblerGameSession.eventListenerDelegate = listener
    }
    
    static func loadPrivateSessions(completionHandler: @escaping ([WabblerGameSession]?, Error?) -> Void) {
        guard let av = CloudKitConnector.sharedConnector.assuredValues else { return }
        WabblerGameSession.loadSessions(database: av.privateDatabase, completionHandler: completionHandler)
    }
    
    static func loadSharedSessions(completionHandler: @escaping ([WabblerGameSession]?, Error?) -> Void) {
        guard CloudKitConnector.sharedConnector.assuredValues != nil else { return }
        guard let sharedDB = CloudKitConnector.sharedConnector.sharedDatabase else { return }
        WabblerGameSession.loadSessions(database: sharedDB, completionHandler: completionHandler)
    }
    
    static private func loadSessions(database: CKDatabase, completionHandler: @escaping ([WabblerGameSession]?, Error?) -> Void) {
        var sessions = [WabblerGameSession]()
        CloudKitConnector.sharedConnector.fetchRecords(database: database, recordType: WabblerGameSession.recordType) {
            ckRecords, error in
            for record in ckRecords {
                sessions += [WabblerGameSession(record: record, scope: database.databaseScope)]
            }
            DispatchQueue.main.async {
                completionHandler(sessions, error)
            }
        }
    }
    
    static func loadSessions(completionHandler: @escaping ([WabblerGameSession]?, Error?) -> Void) {
        guard CloudKitConnector.sharedConnector.assuredValues != nil else { return }
        var sessions = [WabblerGameSession]()
        CloudKitConnector.sharedConnector.fetchRecords(recordType: WabblerGameSession.recordType) {
            ckRecords, error in
            for record in ckRecords {
                sessions += [WabblerGameSession(record: record.0, scope: record.1)]
            }
            DispatchQueue.main.async {
                completionHandler(sessions, error)
            }
        }
    }
    
    func remove(completionHandler: @escaping (Error?) -> Void) {
        CloudKitConnector.sharedConnector.delete(recordID: record.recordID) { (recordID, error) in
            DispatchQueue.main.async {
                completionHandler(error)
            }
        }
    }
    
    func shareSession()->UICloudSharingController? {
        return CloudKitConnector.sharedConnector.shareRecord(record)
    }
}

extension WabblerGameSession: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(record)
        hasher.combine(players)
    }
}
