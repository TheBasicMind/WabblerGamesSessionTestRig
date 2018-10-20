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

struct WabblerGameSession: Hashable, WabblerAssuredState {
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
    private var record : CKRecord
    var owner: WabblerCloudPlayer?
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
            if let data = self.record[WabblerGameSession.keys.players] as? Data {
                let decoder = JSONDecoder()
                do {
                    players = try decoder.decodeApiVersion(Array<WabblerCloudPlayer>.self, from: data)
                } catch {
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
            record[WabblerGameSession.keys.players] = NSData(data: data)
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
    
    private init() throws {
        let recordZone = CKRecordZone(zoneName: WabblerGameSessionStrings.gamesZoneName)
        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: recordZone.zoneID)
        let myRecord = CKRecord(recordType: WabblerGameSession.recordType, recordID:recordID)
        self.record = myRecord
        self.title = ""
        guard let player = WabblerGameSession.localPlayer else {
            throw WabblerGameSessionError.localPlayerNotSignedIn
        }
        self.players = [player]
    }
    
    private init(record : CKRecord) {
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
            newSession = try WabblerGameSession()
        } catch {
            completionHandler(nil, error)
        }
        newSession!.title = title
        
        CloudKitConnector.sharedConnector.save(record: newSession!.record) { (record, error) in
            var modSession = record != nil ? newSession : nil
            if let record = record {
                modSession?.record = record
            }
            DispatchQueue.main.async {
                completionHandler(modSession, error)
            }
        }
    }
    
    mutating func save(_ data: Data, completionHandler:((Data?, Error?) -> Void)?) {
        record[WabblerGameSession.keys.cachedData] = data
        
        CloudKitConnector.sharedConnector.save(record: record) { (savedRecord, error) in
            DispatchQueue.main.async {
                if let error = error {
                    completionHandler?(savedRecord?[WabblerGameSession.keys.cachedData] as? Data, error)
                } else {
                    completionHandler?(savedRecord?[WabblerGameSession.keys.cachedData] as? Data, error)
                }
            }
        }
    }
    
    mutating func loadData(completion: ((Data?, Error?) -> Void)? ) {
        var scope: CKDatabase.Scope = .private

        if record.share != nil {
            scope = .shared
        }
        CloudKitConnector.sharedConnector.loadRecord(record.recordID, scope: scope) {
            record, error in
            
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
        guard let av = CloudKitConnector.sharedConnector.assuredValues else { return }
        guard let sharedDB = CloudKitConnector.sharedConnector.sharedDatabase else { return }
        WabblerGameSession.loadSessions(database: sharedDB, completionHandler: completionHandler)
    }
    
    static private func loadSessions(database: CKDatabase, completionHandler: @escaping ([WabblerGameSession]?, Error?) -> Void) {
        var sessions = [WabblerGameSession]()
        CloudKitConnector.sharedConnector.fetchRecords(database: database, recordType: WabblerGameSession.recordType) {
            ckRecords, error in
            for record in ckRecords {
                sessions += [WabblerGameSession(record: record)]
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
