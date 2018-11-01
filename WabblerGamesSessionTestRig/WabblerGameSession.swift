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
    case cloudKitConnectionInitialisationFailed
    case localPlayerNotSignedIn // CKError.Code.notAuthenticated
    case unknown
    case gameDataCouldNotBeEncoded
    case serverGameDataCouldNotBeDecoded
    case cloudDriveDisabled // User not logged into iCloud or iCloud account restricted
}

struct WabblerCloudPlayer: Codable, Hashable, Equatable {
    var displayName: String?
    var playerID: String?
    var modificationDate: Date?
    
    /**
     Note uses the same container as
     was set up when the Wabbler game
     session was initialised.
     
     If the returned error is CKError.Code.notAuthenticated
     the user is not logged in, or his account is restricted.
    */
    static func getCurrentSignedInPlayer(completionHandler handler: @escaping (WabblerCloudPlayer?, Error?) -> Void) {
        if let localPlayer = WabblerGameSession.localPlayer {
            handler(localPlayer, nil)
        } else {
            CloudKitConnector.sharedConnector.fetchUserRecord(containerIdentifier: nil) {
                record, error in
                if let record = record  {
                    print(record.description)
                    DispatchQueue.main.async {
                        let player = WabblerCloudPlayer(displayName: record[WabblerCloudPlayerStrings.displayName] ?? WabblerGameSession.localPlayerDisplayName ?? "Name not defined", playerID: record.recordID.recordName, modificationDate: record.modificationDate)
                        WabblerGameSession.localPlayerRecord = record
                        handler(player, error)
                    }
                } else if let error = error {
                    DispatchQueue.main.async {
                        handler(nil, error)
                    }
                    return
                }
            }
        }
    }
}

protocol WabblerGameSessionEventListener {
    /**
     When called, the session record has the local player added but has not yet been saved back to the server
    */
    func session(_ session: WabblerGameSession, didAdd player: WabblerCloudPlayer)
    func sessionWasDeleted(withIdentifier: WabblerGameSession.ID)
    func session(_ session: WabblerGameSession, didReceiveMessage message: String, with data: Data, from player: WabblerCloudPlayer)
    func session(_ session: WabblerGameSession, player: WabblerCloudPlayer, didSave data: Data)
}

class WabblerGameSession {
    typealias ID = String
    static func == (lhs: WabblerGameSession, rhs: WabblerGameSession) -> Bool { return true }
    static var stateError: ((Error?) -> Void)?
    var stateError: ((Error) -> Void)?
    static var localPlayer: WabblerCloudPlayer? {
        if let playerRecord = localPlayerRecord {
            return WabblerCloudPlayer(displayName: playerRecord[WabblerCloudPlayerStrings.displayName] ?? WabblerGameSession.localPlayerDisplayName ?? "Name not defined", playerID: playerRecord.recordID.recordName, modificationDate: playerRecord.modificationDate)
        }
        return nil
    }
    var remotePlayer: WabblerCloudPlayer? {
        if WabblerGameSession.localPlayerRecord?.recordID == record.creatorUserRecordID {
            return owner
        } else {
            return opponent
        }
    }
    static var localPlayerDisplayName: String?
    fileprivate static var localPlayerRecord: CKRecord?
    fileprivate static let recordType = "WabblerGameSession"
    fileprivate static let keys = (identifier : "name", lastModifiedDate : "lastModifiedDate", players: "players", title : "title", cachedData: "cachedData", owner: "owner", opponent: "opponent")
    private static var eventListenerDelegate: WabblerGameSessionEventListener?
    private var record : CKRecord //
    let scope: CKDatabase.Scope
    var owner: WabblerCloudPlayer? {
        get {
            var player: WabblerCloudPlayer? = nil
            if let data = self.record[WabblerGameSession.keys.owner] as? NSData {
                let decoder = JSONDecoder()
                do {
                    player = try decoder.decode(WabblerCloudPlayer.self, from: data as Data)
                } catch {
                    print(error.localizedDescription)
                }
            }
            return player
        }
        set {
            let encoder = JSONEncoder()
            let data: Data
            do {
                data = try encoder.encode(newValue)
            } catch {
                return
            }
            record[WabblerGameSession.keys.owner] = data as NSData
        }
    }
    var opponent: WabblerCloudPlayer? {
        get {
            var player: WabblerCloudPlayer? = nil
            if let data = self.record[WabblerGameSession.keys.opponent] as? NSData {
                let decoder = JSONDecoder()
                do {
                    player = try decoder.decode(WabblerCloudPlayer.self, from: data as Data)
                } catch {
                    print(error.localizedDescription)
                }
            }
            return player
        }
        set {
            let encoder = JSONEncoder()
            let data: Data
            do {
                data = try encoder.encode(newValue)
            } catch {
                return
            }
            record[WabblerGameSession.keys.opponent] = data as NSData
        }
    }
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
        var players = [WabblerCloudPlayer]()
        if let owner = owner {
            players += [owner]
            if let opponent = opponent {
                players += [opponent]
            }
        }
        return players
    }
    var title : String {
        get {
            return record[WabblerGameSession.keys.title] as! String
        }
        set {
            record[WabblerGameSession.keys.title] = newValue
        }
    }
    
    /**
     Returns nil if game session is not assured
     The cloud kit connector also needs to be assured.
     Returns the CloudKitConnector assured values if
     successful.
    */
    static func assuredFromOptional()-> AssuredConnectionValues? {
        let assuredValues = CloudKitConnector.sharedConnector.assuredFromOptional()
        if WabblerGameSession.localPlayer != nil, assuredValues != nil {
            return assuredValues
        } else {
            if assuredValues == nil {
                WabblerGameSession.stateError?(WabblerGameSessionError.cloudKitConnectionInitialisationFailed)
            } else {
                WabblerGameSession.stateError?(WabblerGameSessionError.localPlayerNotSignedIn)
            }
            return nil
        }
    }
    
    private init(scope: CKDatabase.Scope) throws {
        let recordZone = CKRecordZone(zoneName: WabblerGameSessionStrings.gamesZoneName)
        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: recordZone.zoneID)
        let myRecord = CKRecord(recordType: WabblerGameSession.recordType, recordID:recordID)
        self.scope = scope
        self.record = myRecord
        guard WabblerGameSession.localPlayer != nil else {
            throw WabblerGameSessionError.localPlayerNotSignedIn
        }
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
        WabblerGameSession.localPlayerDisplayName = localPlayerName
        CloudKitConnector.sharedConnector.stateError = {
            error in
            WabblerGameSession.stateError?(error)
        }
        CloudKitConnector.sharedConnector.connect(containerIdentifier: nil, zoneName: WabblerGameSessionStrings.gamesZoneName)
        WabblerCloudPlayer.getCurrentSignedInPlayer { (player, error) in
            if let error = error {
                print(error.localizedDescription)
            }
        }
    }
    
    static func createSession(withTitle title: String, completionHandler: @escaping (WabblerGameSession?, Error?) -> Void) {
        guard WabblerGameSession.assuredFromOptional() != nil else { return }
        var newSession: WabblerGameSession?
        do {
            newSession = try WabblerGameSession(scope:.private)
        } catch {
            completionHandler(nil, error)
        }
        newSession!.title = title
        newSession?.owner = WabblerGameSession.localPlayer!
        
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
        guard let av = CloudKitConnector.sharedConnector.assuredFromOptional() else { return }
        WabblerGameSession.loadSessions(databaseScope: av.privateDatabase.databaseScope, completionHandler: completionHandler)
    }
    
    static func loadSharedSessions(completionHandler: @escaping ([WabblerGameSession]?, Error?) -> Void) {
        guard let av = CloudKitConnector.sharedConnector.assuredFromOptional() else { return }
        WabblerGameSession.loadSessions(databaseScope: av.sharedDatabase.databaseScope, completionHandler: completionHandler)
    }
    
    static private func loadSessions(databaseScope: CKDatabase.Scope, completionHandler: @escaping ([WabblerGameSession]?, Error?) -> Void) {
        var sessions = [WabblerGameSession]()
        CloudKitConnector.sharedConnector.fetchChanges(databaseScope: databaseScope, changeToken: nil) {
            ckRecords, deletions, error in
            for record in ckRecords {
                if record.0.recordType == WabblerGameSession.recordType {
                    sessions += [WabblerGameSession(record: record.0, scope: record.1)]
                } else {
                    print("Non Wabbler Session record received")
                    print(record)
                }
            }
            DispatchQueue.main.async {
                completionHandler(sessions, error)
            }
        }
    }
    
    /**
     Call when a CKDatabaseSubscription based push notication
     has been received.
    */
    static func updateForChanges(databaseScope:CKDatabase.Scope, completion: ((Bool)->Void )? ) {
        guard let delegate = WabblerGameSession.eventListenerDelegate else { return }
        guard WabblerGameSession.assuredFromOptional() != nil else { return }
        CloudKitConnector.sharedConnector.fetchLatestChanges(databaseScope: databaseScope) { (records, deletions, error) in
            if let error = error {
                print("Errors:")
                print(error)
                completion?(false)
            } else {
                for record in records {
                    if record.0.recordType == WabblerGameSession.recordType {
                        let gameSession = WabblerGameSession(record: record.0, scope: record.1)
                        var player: WabblerCloudPlayer? = nil
                        if record.0.lastModifiedUserRecordID == WabblerGameSession.localPlayerRecord!.recordID {
                            player = WabblerGameSession.localPlayer!
                        } else {
                            if gameSession.opponent == nil, record.1 == .shared {
                                gameSession.opponent = localPlayer
                                DispatchQueue.main.async {
                                    WabblerGameSession.eventListenerDelegate?.session(gameSession, didAdd: localPlayer!)
                                }
                                return
                            }
                            player = gameSession.remotePlayer
                        }
                        guard let data = record.0[WabblerGameSession.keys.cachedData] as? Data else { return }
                        DispatchQueue.main.async {
                            if let player = player {
                                delegate.session(gameSession, player: player, didSave: data)
                            } else {
                                print("Error: Player for record was nil")
                                print(record.0)
                            }
                        }
                    } else if let ckShare = record.0 as? CKShare {
                        print("Non Game Session Record Update Received for database: \(record.1)")
                        print(ckShare)
                    }
                }
                for deletion in deletions {
                    let sessionID = deletion.0.recordName
                    DispatchQueue.main.async {
                        WabblerGameSession.eventListenerDelegate?.sessionWasDeleted(withIdentifier: sessionID)
                    }
                }
            }
            completion?(true)
        }
    }
    
    static func loadSessions(completionHandler: @escaping ([WabblerGameSession]?, Error?) -> Void) {
        guard CloudKitConnector.sharedConnector.assuredFromOptional() != nil else { return }
        var sessions = [WabblerGameSession]()
        CloudKitConnector.sharedConnector.fetchRecords() {
            records, error in
            for (ckRecord,scope) in records {
                if ckRecord.recordType == WabblerGameSession.recordType {
                    sessions += [WabblerGameSession(record: ckRecord, scope: scope)]
                }
                sessions.sort { s1,s2 in s1.lastModifiedDate!.timeIntervalSince1970 > s2.lastModifiedDate!.timeIntervalSince1970 }
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
        hasher.combine(record.recordID)
    }
}
