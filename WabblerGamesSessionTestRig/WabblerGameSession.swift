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

public enum WabblerGameSessionError: Error {
    case cloudKitConnectionInitialisationFailed
    case localPlayerNotSignedIn // CKError.Code.notAuthenticated
    case unknown
    case gameDataCouldNotBeEncoded
    case serverGameDataCouldNotBeDecoded
    case recordCouldNotBeDecoded
    case recordCouldNotBeCached
    case cacheFailure
    case cloudDriveDisabled // User not logged into iCloud or iCloud account restricted
}

public struct WabblerCloudPlayer: Codable, Hashable, Equatable {
    public var displayName: String?
    public var playerID: String?
    public var modificationDate: Date?
    
    /**
     Note uses the same container as
     was set up when the Wabbler game
     session was initialised.
     
     If the returned error is CKError.Code.notAuthenticated
     the user is not logged in, or his account is restricted.
    */
    public static func getCurrentSignedInPlayer(completionHandler handler: @escaping (WabblerCloudPlayer?, Error?) -> Void) {
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

public protocol WabblerGameSessionEventListener {
    /**
     When called, the session record has the local player added but has not yet been saved back to the server
    */
    func joinedSession(_ session: WabblerGameSession, withPlayer: WabblerCloudPlayer)
    func session(_ session: WabblerGameSession, player: WabblerCloudPlayer, didSave data: Data)
    func sessionWasDeleted(withIdentifier: WabblerGameSession.ID)
    func session(_ session: WabblerGameSession, didRemove player: WabblerCloudPlayer)
}

/**
 Wabbler Game Session specialises the
 CloudKitConnector for Wabber game sessions.
 It also acts as a universal persistent cache
 of all game sessions stored for the player.
 
 We cache at this level because caching whole
 CKRecords can be innefficient and is a per
 application decision.
 */

public class WabblerGameSession {
    public typealias ID = String
    public static func == (lhs: WabblerGameSession, rhs: WabblerGameSession) -> Bool { return true }
    public static var stateError: ((Error?) -> Void)?
    //public var stateError: ((Error) -> Void)?
    public static var localPlayer: WabblerCloudPlayer? {
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
    fileprivate static let keys = (players: "players", title : "title", cachedData: "cachedData", owner: "owner", opponent: "opponent")
    private static var eventListenerDelegate: WabblerGameSessionEventListener?
    private var record : CKRecord //
    public let scope: CKDatabase.Scope
    public var owner: WabblerCloudPlayer? {
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
    public var opponent: WabblerCloudPlayer? {
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
    public var identifier : String {
        get {
            return record.recordID.recordName
        }
    }
    public var creationDate: Date? {
        get {
            return record.creationDate
        }
    }
    public var lastModifiedDate : Date? {
        get {
            return record.modificationDate
        }
    }
    public var players: [WabblerCloudPlayer] {
        var players = [WabblerCloudPlayer]()
        if let owner = owner {
            players += [owner]
            if let opponent = opponent {
                players += [opponent]
            }
        }
        return players
    }
    public var title : String {
        get {
            return record[WabblerGameSession.keys.title] as! String
        }
        set {
            record[WabblerGameSession.keys.title] = newValue
        }
    }
    
    public static func acceptShare(shareMetaData:CKShare.Metadata) {
        CloudKitConnector.sharedConnector.acceptShare(shareMetaData: shareMetaData)
    }
    
    /**
     Returns nil if game session is not assured
     The cloud kit connector also needs to be assured.
     Returns the CloudKitConnector assured values if
     successful.
    */
    public static func assuredFromOptional()-> AssuredConnectionValues? {
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
    public static func initialiseCloudKitConnection(localPlayerName: String) {
        do {
            _ = try Storage.getURL(for: Storage.Directory.documentsNoBackup, fileName: nil)
        } catch {
            WabblerGameSession.stateError?(error)
        }
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
    
    /**
     Returns the WabblerGameSession as stored on the server
    */
    public static func createSession(withTitle title: String, completionHandler: @escaping (WabblerGameSession?, Error?) -> Void) {
        guard WabblerGameSession.assuredFromOptional() != nil else { return }
        var newSession: WabblerGameSession?
        do {
            newSession = try WabblerGameSession(scope:.private)
        } catch {
            completionHandler(nil, error)
        }
        newSession!.title = title
        newSession?.owner = WabblerGameSession.localPlayer!
        
        CloudKitConnector.sharedConnector.save(record: newSession!.record, scope: .private) { (records, error) in
            if let error = error {
                DispatchQueue.main.async {
                    completionHandler(newSession, error)
                }
            } else if let record = records?.first {
                newSession?.record = record
                do {
                    try WabblerGameSession.cacheRecord(record, scope: .private)
                } catch (let anError) {
                    DispatchQueue.main.async {
                        completionHandler(newSession, anError)
                    }
                }
                DispatchQueue.main.async {
                    completionHandler(newSession, error)
                }
            } else {
                DispatchQueue.main.async {
                    completionHandler(nil, WabblerGameSessionError.unknown)
                }
            }
        }
    }
    
    public static func cachedSessions() -> [WabblerGameSession] {
        var sessions = [WabblerGameSession]()
        if let records = WabblerGameSession.cachedRecords() {
            for record in records {
                sessions += [WabblerGameSession(record: record.0, scope: record.1)]
            }
        }
        return sessions
    }
    
    /**
     Whenever this call is made we should also
     check for any session deletions by comparing
     with any existing array / list of sessions.
     */
    public static func loadSessions(completionHandler: @escaping ([WabblerGameSession]?, Error?) -> Void) {
        guard CloudKitConnector.sharedConnector.assuredFromOptional() != nil else { return }
        CloudKitConnector.sharedConnector.fetchRecords() {
            records, error in
            
            // NOTE: IT IS POSSIBLE PRIVATE DATABASE RECORDS WILL BE RETURNED
            // WHILE THE SHARED DATABASE REQUEST RAISES AN ERROR. IN THIS CASE
            // THE GAMES WHERE MULTIPLE PLAYERS HAVE JOINED COULD BE LOST FROM
            // THE CACHE UNTIL THE USER REFRESHES, OR RESTARTS THE GAME.
            var sessions = [WabblerGameSession]()

            if let error = error {
                DispatchQueue.main.async {
                    completionHandler(nil, error)
                }
            } else {
                do {
                    try Storage.clear(.documentsNoBackup)
                } catch {
                    completionHandler(nil,WabblerGameSessionError.cacheFailure)
                    return
                }
                for (ckRecord,scope) in records {
                    if ckRecord.recordType == WabblerGameSession.recordType {
                        sessions += [WabblerGameSession(record: ckRecord, scope: scope)]
                        do {
                            try WabblerGameSession.cacheRecord(ckRecord, scope: scope)
                        } catch {
                            DispatchQueue.main.async {
                                completionHandler(nil, WabblerGameSessionError.cacheFailure)
                            }
                            return
                        }
                    }
                    sessions.sort { s1,s2 in s1.lastModifiedDate!.timeIntervalSince1970 > s2.lastModifiedDate!.timeIntervalSince1970 }
                }
                DispatchQueue.main.async {
                    completionHandler(sessions, error)
                }
            }

        }
    }
    
    /**
     Save data to the session record.
     The completion handler returns the data we attempted to save
     or an error. This method is kept private because for efficiency
     the completion handler does not return on the main thread.
     If the save is successful this method caches the newly saved record locally.
     - parameter data: The data we are saving to the record.
     - parameter completionHandler: A completion handler closure.
        - data: The data now saved on the server
        - error: A passthrough CloudKit error object if an error was raised.
    */
    ///TODO: Retry after seconds
    public func save(_ data: Data, completionHandler:((Data?, Error?) -> Void)?) {
        record[WabblerGameSession.keys.cachedData] = data
        save { (session, error) in
            let saveData = session?.record[WabblerGameSession.keys.cachedData] as? Data
            completionHandler?(saveData,error)
        }
    }
    
    /**
     Save data to the session record.
     The completion handler returns the data we attempted to save
     or an error. This method is kept private because for efficiency
     the completion handler does not return on the main thread.
     If the save is successful this method caches the newly saved record locally.
     - parameter data: The data we are saving to the record.
     - parameter completionHandler: A completion handler closure.
     - data: The data now saved on the server
     - error: A passthrough CloudKit error object if an error was raised.
     */
    ///TODO: Retry after seconds
    public func save(completionHandler:((WabblerGameSession?, Error?) -> Void)?) {
        let scope = self.scope
        CloudKitConnector.sharedConnector.save(record: record, scope: scope) { (records, error) in
            
            // If there is an error we extract
            // the data as saved on the server
            if let ckError = error as? CKError {
                switch ckError.code {
                default:
                    if let updatedRecord = ckError.serverRecord {
                        let serverSession = WabblerGameSession(record: updatedRecord, scope: scope)
                        completionHandler?(serverSession, error)
                    } else {
                        completionHandler?(nil, error)
                    }
                    return
                }
            } else if let error = error {
                // Some other error we weren't expecting
                // to return data will break the API so
                // we return nil
                completionHandler?(nil,error)
                return
            } else if let savedRecord = records?.first {
                let savedSession = WabblerGameSession(record: savedRecord, scope: scope)
                do {
                    try WabblerGameSession.cacheRecord(savedRecord, scope: scope)
                } catch {
                    completionHandler?(nil, error)
                    return
                }
                completionHandler?(savedSession, error)
            } else {
                // Should not ever be encountered
                completionHandler?(nil, nil)
            }
        }
    }
    
    /**
     Load game data from the local cache
     record locally.
     */
    public func loadCachedData(completion: ((Data?, Error?) -> Void)? ) {
        let record = WabblerGameSession.cachedRecord(fileName: self.record.recordID.recordName)
        completion?(record?.0[WabblerGameSession.keys.cachedData] as? Data, nil)
        //        CloudKitConnector.sharedConnector.loadRecord(record.recordID, scope: scope) { record, error in
        //            var data: Data? = nil
        //            if let record = record, error == nil {
        //                self.record = record
        //                do {
        //                    try WabblerGameSession.cacheRecord(record, scope: scope)
        //                } catch {
        //                    completion?(nil, WabblerGameSessionError.cacheFailure)
        //                    return
        //                }
        //            }
        //            data = record?[WabblerGameSession.keys.cachedData] as? Data
        //            DispatchQueue.main.async {
        //                completion?(data, error)
        //            }
        //        }
    }
    
    
    /*
    static func loadPrivateSessions(completionHandler: @escaping ([WabblerGameSession]?, Error?) -> Void) {
        guard let av = CloudKitConnector.sharedConnector.assuredFromOptional() else { return }
        WabblerGameSession.loadSessions(databaseScope: av.privateDatabase.databaseScope, completionHandler: completionHandler)
    }
    
    static func loadSharedSessions(completionHandler: @escaping ([WabblerGameSession]?, Error?) -> Void) {
        guard let av = CloudKitConnector.sharedConnector.assuredFromOptional() else { return }
        WabblerGameSession.loadSessions(databaseScope: av.sharedDatabase.databaseScope, completionHandler: completionHandler)
    }
    
    /**
     Load all sessions in the given database scope
     WARNING: DOES NOT YET CACHE THE RESULTS
     */
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
     */
    
    public static func add(listener: WabblerGameSessionEventListener) {
        WabblerGameSession.eventListenerDelegate = listener
    }
    
    /**
     Call when a CKDatabaseSubscription based push notication
     has been received.
    */
    public static func updateForChanges(databaseScope:CKDatabase.Scope, completion: ((Bool)->Void )? ) {
        guard let delegate = WabblerGameSession.eventListenerDelegate else { return }
        guard WabblerGameSession.assuredFromOptional() != nil else { return }
        CloudKitConnector.sharedConnector.fetchLatestChanges(databaseScope: databaseScope) { (records, deletions, all, error) in
            if let error = error {
                print("Errors:")
                print(error)
                completion?(false)
            } else {
                for record in records {
                    if record.0.recordType == WabblerGameSession.recordType {
                        
                        do {
                            try WabblerGameSession.cacheRecord(record.0, scope: record.1)
                        } catch {
                            completion?(false)
                            return
                        }
                        
                        let gameSession = WabblerGameSession(record: record.0, scope: record.1)
                        var player: WabblerCloudPlayer? = nil
                        if record.0.lastModifiedUserRecordID == WabblerGameSession.localPlayerRecord!.recordID {
                            player = WabblerGameSession.localPlayer!
                        } else {
                            player = gameSession.remotePlayer
                            if gameSession.opponent == nil, record.1 == .shared {
                                gameSession.opponent = localPlayer
                                DispatchQueue.main.async {
                                    if let player = player {
                                        delegate.joinedSession(gameSession, withPlayer: player)
                                    } else {
                                        print("Error: Player for record was nil")
                                        print(record.0)
                                    }
                                }
                                completion?(true)
                                return
                            }
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
                    WabblerGameSession.removeCachedRecord(fileName: sessionID)
                    DispatchQueue.main.async {
                        WabblerGameSession.eventListenerDelegate?.sessionWasDeleted(withIdentifier: sessionID)
                    }
                }
            }
            completion?(true)
        }
    }
    
    public func remove(completionHandler: @escaping (Error?) -> Void) {
        CloudKitConnector.sharedConnector.delete(recordID: record.recordID) { (recordID, error) in
            if error == nil, let recordID = recordID {
                WabblerGameSession.removeCachedRecord(fileName: recordID.recordName)
            }
            DispatchQueue.main.async {
                completionHandler(error)
            }
        }
    }
    
    public func shareSession()->UICloudSharingController? {
        return CloudKitConnector.sharedConnector.shareRecord(record)
    }
    
    public func removeParticipant(completion: ((Bool,Error?)->())?) {
        if record.share != nil {
            CloudKitConnector.sharedConnector.removeParticipant(record: record, scope: scope) { (records, error) in
                completion?(records != nil && error == nil, error)
            }
        }
    }
    
    /**
     If the opponent field has been updated
     this will return true. The opponent field
     is updated when the opponent adds player
     details to the session. This method provides
     a means to check if the session should be
     resaved, so the opponent is informed the
     player has joined the game.
    */
    public func shouldSaveForPlayerJoined()->Bool {
        return record.changedKeys().contains(WabblerGameSession.keys.opponent)
    }
}

extension WabblerGameSession: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(record.recordID)
    }
}

@objc(WabblerGameSessionArch)
class WabblerGameSessionArch: NSObject, NSSecureCoding {
    var record: CKRecord?
    var database: String?
    static var supportsSecureCoding: Bool {
        return false
    }
    
    func encode(with aCoder: NSCoder) {
        aCoder.encode(record, forKey: "record")
        aCoder.encode(database, forKey:"database")
    }
    
    required init?(coder aDecoder: NSCoder) {
        guard let record = aDecoder.decodeObject(forKey: "record") as? CKRecord else { return nil }
        guard let database = aDecoder.decodeObject(forKey: "database") as? String else { return nil }
        self.record = record
        self.database = database
    }
    
    override init() {
        super.init()
    }
}

// Local Caching

public extension WabblerGameSession {
    static func cacheRecord(_ record: CKRecord, scope: CKDatabase.Scope) throws {
        let cachable = WabblerGameSessionArch()
        var database: String
        switch scope {
        case .private:
            database = "private"
        case .shared:
            database = "shared"
        default:
            throw WabblerGameSessionError.cacheFailure
        }
        cachable.record = record
        cachable.database = database
        try Storage.storeNSObj(cachable, to: .documentsNoBackup, as: record.recordID.recordName)
    }
    
    static func cachedRecord(fileName: String) -> (CKRecord,CKDatabase.Scope)? {
        do {
            let arch = try Storage.retrieveNSObj(fileName, from: .documentsNoBackup, as: WabblerGameSessionArch.self)
            var scope: CKDatabase.Scope
            switch arch.database {
            case "private":
                scope = .private
            case "shared":
                scope = .shared
            default:
                return nil
            }
            return (arch.record!, scope)
        } catch {
            return nil
        }
    }
    
    static func cachedRecords() -> [(CKRecord, CKDatabase.Scope)]? {
        let arch: [WabblerGameSessionArch]
        do {
            arch = try Storage.retreiveAllNSObjOfType(WabblerGameSessionArch.self)
        } catch {
            return nil
        }
        var records = [(CKRecord, CKDatabase.Scope)]()
        for record in arch {
            var scope: CKDatabase.Scope
            switch record.database {
            case "private":
                scope = .private
            case "shared":
                scope = .shared
            default:
                return nil
            }
            records += [(record.record!, scope)]
        }
        return records
    }
    
    
    @discardableResult static func removeCachedRecord(fileName: String) -> Bool? {
        do {
            let success = try Storage.remove(fileName, from: .documentsNoBackup)
            return success
        } catch {
            return nil
        }
    }
}
