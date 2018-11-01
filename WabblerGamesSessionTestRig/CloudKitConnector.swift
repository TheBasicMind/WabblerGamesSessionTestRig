//
//  CloudKitConnector.swift
//  OverWord
//
//  Created by Paul Lancefield on 28/09/2018.
//  Copyright © 2018 Paul Lancefield. All rights reserved.
//

import Foundation
import CloudKit
import UIKit


protocol AssuredValues { } // All values on conforming type must be non-optional for conforming types
protocol AssuredState {
    associatedtype AssuredValueType: AssuredValues
    var stateError: ((Error?)->Void)? { get set }
    func assuredFromOptional()->AssuredValueType? // Ensure implementation calls stateError if assurance cannot be provided
}

struct AssuredConnectionValues: AssuredValues {
    let container: CKContainer
    let privateSubscription: CKSubscription
    let privateDatabase: CKDatabase
    let sharedDatabase: CKDatabase
    let privateZone: CKRecordZone
}

enum CloudKitConnectorStrings {
    static let privateSubName                   = "wabbler-private-games"
    static let sharedSubName                    = "wabbler-shared-games"
}

/**
 Connector specific errors are only raised when
 connecting and / or if there is a problem getting
 assured values.
 */
enum CloudKitConnectorError: Error {
    case signInRequired
    case accountRestricted
    case couldNotDetermineAccountStatus
    case badState // For this one, check the failure states
    case badICloudContainer // Either the container is bad or something is bad with cloud kit
    case appUpdateRequired
    case badConnectorConfiguration // For when something structural is wrong relating to our cloudkit container
    case tryAgainLater
    case unknown
}

enum DatabaseVisibility {
    case privateDB
    case publicDB
}

/**
 The cloud kit connector
 provides a simplified interface
 for Wabbler interaction with CloudKit
 working in a single named zone and
 assuming the default container is
 used.
 */
class CloudKitConnector: AssuredState {
    typealias OptionalValueType = CloudKitConnector
    typealias AssuredValueType = AssuredConnectionValues
    static let sharedConnector = CloudKitConnector()
    private init() { }
    var stateError: ((Error?)->Void)?
    // Assured optionals
    var signedInToICloud: Bool = false
    var container: CKContainer?
    var privateSubscription: CKSubscription?
    var sharedSubscription: CKSubscription?
    var privateDatabase: CKDatabase?
    var sharedDatabase: CKDatabase?
    var privateZone: CKRecordZone?
    var sharedZones: [CKRecordZone]?
    // End Assured properties
    private var privateDBChangeToken: CKServerChangeToken? {
        didSet {
            print("private db change token: \(privateDBChangeToken?.description ?? "Nil")")
        }
    }
    private var sharedDBChangeToken: CKServerChangeToken? {
        didSet {
            print("shared db change token: \(sharedDBChangeToken?.description ?? "Nil")")
        }
    }
    private var zoneChangeTokens: [CKRecordZone.ID: CKServerChangeToken] = [:]
    //var databaseZoneUpdatedCompletion: (([(CKRecord,CKDatabase.Scope)],[(CKRecord.ID,CKDatabase.Scope)],Error?)->Void)?
    
    func assuredFromOptional() -> AssuredConnectionValues? {
        if let container = container,
           let privateSubscription = privateSubscription,
           let privateDatabase = privateDatabase,
           let sharedDatabase = sharedDatabase,
           let privateZone = privateZone {
           return AssuredConnectionValues(container: container, privateSubscription: privateSubscription, privateDatabase: privateDatabase, sharedDatabase: sharedDatabase, privateZone: privateZone)
        } else {
            stateError?(nil)
            return nil
        }
    }

    func connect(containerIdentifier: String?, zoneName:String) {
        var container: CKContainer
        if let containerIdentifier = containerIdentifier {
            container = CKContainer(identifier: containerIdentifier)
        } else {
            container = CKContainer.default()
        }
        self.container = container
        
        CKContainer.default().accountStatus {
            status, error in
            if let error = error {
                if let ckError = error as? CKError {
                    switch ckError.code {
                    case .badContainer:
                        self.stateError?(CloudKitConnectorError.badICloudContainer)
                    case .incompatibleVersion:
                        self.stateError?(CloudKitConnectorError.appUpdateRequired)
                    case .badDatabase:
                        self.stateError?(CloudKitConnectorError.badConnectorConfiguration)
                    case .internalError:
                        self.stateError?(CloudKitConnectorError.tryAgainLater)
                    default:
                        self.stateError?(CloudKitConnectorError.unknown)
                    }
                }
            } else {
                switch status {
                case .available:
                    self.signedInToICloud = true
                    self.privateDatabase = container.privateCloudDatabase
                    self.sharedDatabase = container.sharedCloudDatabase
                    self.continueConnection(zoneName: zoneName)
                case .noAccount:
                    // User not logged in to iCloud
                    self.stateError?(CloudKitConnectorError.signInRequired)
                case .couldNotDetermine:
                    self.stateError?(CloudKitConnectorError.couldNotDetermineAccountStatus)
                case .restricted:
                    self.stateError?(CloudKitConnectorError.accountRestricted)
                }
            }
        }
    }
    
    /**
     By the time initialisation is finalised
     we should have
     */
    private func continueConnection(zoneName: String) {
        let recordZone = CKRecordZone(zoneName: zoneName)
        privateDatabase?.fetch(withRecordZoneID: recordZone.zoneID) { (retreivedZone, error) in
            if let error = error {
                print(error)
                print(error.localizedDescription)
                let ckError = error as NSError
                if ckError.code == CKError.zoneNotFound.rawValue || ckError.code == CKError.userDeletedZone.rawValue {
                    CloudKitConnector.sharedConnector.privateDatabase?.save(recordZone) { (newZone, error) in
                        if let error = error {
                            print(error.localizedDescription)
                        } else {
                            CloudKitConnector.sharedConnector.privateZone = newZone
                        }
                    }
                }
            } else {
                CloudKitConnector.sharedConnector.privateZone = retreivedZone
            }
        }
        
        // Setup private subscription if one hasn't been set up already
        if privateSubscription != nil { return }
        let privateOp = createDatabaseSubscriptionOperation(subscriptionId: CloudKitConnectorStrings.privateSubName)
        privateOp.modifySubscriptionsCompletionBlock = { [weak self] (subscriptions, strings, error) in
            if error == nil {
                if let sub = subscriptions?.first {
                    self?.privateSubscription = sub
                    print("Subscription created: \(sub)")
                }
            } else {
                print(error!)
            }
        }
        privateDatabase?.add(privateOp)
        
        sharedDatabase?.fetchAllRecordZones { (retreivedZones, error) in
            if let error = error {
                print(error)
                print(error.localizedDescription)
            } else {
                CloudKitConnector.sharedConnector.sharedZones = retreivedZones
            }
        }
        
        if sharedSubscription != nil { return }
        let sharedOp = createDatabaseSubscriptionOperation(subscriptionId: CloudKitConnectorStrings.sharedSubName)
        sharedOp.modifySubscriptionsCompletionBlock = { [weak self] (subscriptions, strings, error) in
            if error == nil {
                if let sub = subscriptions?.first {
                    self?.sharedSubscription = sub
                    print("Subscription created: \(sub)")
                }
            } else {
                print(error!)
            }
        }
        sharedDatabase?.add(sharedOp)
    }
    
    private func createDatabaseSubscriptionOperation(subscriptionId: String) -> CKModifySubscriptionsOperation {
        let subscription = CKDatabaseSubscription(subscriptionID: subscriptionId)
        
        let notificationInfo = CKSubscription.NotificationInfo()
        //notificationInfo.shouldSendContentAvailable = true
        notificationInfo.alertBody = "This is the alert body text."
        subscription.notificationInfo = notificationInfo
        
        subscription.recordType = "WabblerGameSession"
        let operation = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: [])
        operation.qualityOfService = .utility
        return operation
    }

    
    /**
     Note if containerIdentifier is nil
     then the default container is used.
     */
    func fetchUserRecord(containerIdentifier: String?, completion: @escaping (CKRecord?, Error?)->Void) {
        var container: CKContainer
        if let containerIdentifier = containerIdentifier {
            container = CKContainer(identifier: containerIdentifier)
        } else {
            container = CKContainer.default()
        }
        container.fetchUserRecordID {
            recordID, error in
            if let error = error {
                completion(nil,error)
            } else {
                container.privateCloudDatabase.fetch(withRecordID: recordID!) {
                    record, error in
                    completion(record, error)
                }
            }
        }
    }
    
    /**
     fetch all records accross both private
     and shared databases. Only updates that
     are a delta from the point this request
     is made will be received after this
     request is made.
     */
    func fetchRecords(allRecords: @escaping ([(CKRecord,CKDatabase.Scope)], Error?)->Void) {
        guard let av = assuredFromOptional() else { return }
        fetchChanges(database: av.privateDatabase,changeToken: nil) { [weak self](records, deletions, error) in
            var zippedRecords:[(CKRecord,CKDatabase.Scope)] = records.map { ($0.0, .private) }
            if let error = error {
                allRecords(zippedRecords,error)
            } else {
                self?.fetchChanges(database: av.sharedDatabase, changeToken: nil) { (records, deletions, error) in
                    zippedRecords += records.map { ($0.0, .shared) }
                    allRecords(zippedRecords,error)
                }
            }
        }
    }
    
    /**
     Fetch changes since the last request
     Note if ANY errors are returned to allChanges, then
     server change tokens will not have been cached
     and making the request again will result in all
     changes since the previous tokens to be retreived.
    */
    func fetchLatestChanges(databaseScope: CKDatabase.Scope, allChanges: @escaping ([(CKRecord,CKDatabase.Scope)],[(CKRecord.ID,CKRecord.RecordType,CKDatabase.Scope)], Error?)->Void) {
        var changeToken: CKServerChangeToken? = nil
        switch databaseScope {
        case .private:
            changeToken = privateDBChangeToken
        case .shared:
            changeToken = sharedDBChangeToken
        default:
            return
        }
        fetchChanges(databaseScope: databaseScope, changeToken: changeToken, allChanges: allChanges)
    }
    
    /**
     Fetch changes since supplied change token
     or all changes if no change token is supplied
     */
    func fetchChanges(databaseScope: CKDatabase.Scope, changeToken: CKServerChangeToken?, allChanges: @escaping ([(CKRecord,CKDatabase.Scope)],[(CKRecord.ID,CKRecord.RecordType,CKDatabase.Scope)], Error?)->Void) {
        guard let av = assuredFromOptional() else { return }
        let database: CKDatabase
        switch databaseScope {
        case .private:
            database = av.privateDatabase
        case .shared:
            database = av.sharedDatabase
        default:
            return
        }
        
        fetchChanges(database: database, changeToken: changeToken, allChanges: allChanges)
    }

    
    /**
     Generally abstracted method for fetching
     all changed records from a database. If
     nil is passed for the change token, fetches
     all records.
     */
    private func fetchChanges(database: CKDatabase, changeToken: CKServerChangeToken?, allChanges: @escaping ([(CKRecord,CKDatabase.Scope)],[(CKRecord.ID,CKRecord.RecordType,CKDatabase.Scope)], Error?)->Void) {
        
        let changesOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: changeToken) // Nil simply fetches all zones
        changesOperation.fetchAllChanges = true
        changesOperation.qualityOfService = .userInitiated
        var changedZones = [CKRecordZone.ID]()
        changesOperation.recordZoneWithIDChangedBlock = { rzid in
            // This is the information for the zones that
            // have changed records (note it doesn't justify
            // a database change token udate yet)
            changedZones += [rzid]
        }
        
        changesOperation.recordZoneWithIDWasDeletedBlock = { rzid in
            // Deal with zone deletion. Since we are dealing
            // with these on the local client, we need a new
            // server change token once we are finished - which
            // is given in the next block.
            
        }
        
        changesOperation.changeTokenUpdatedBlock = { [weak self] newToken in
            // This is the new database change token
            // for the database after zone deletions have
            // been processed.
            switch database.databaseScope {
            case .private:
                self?.privateDBChangeToken = newToken
            case .shared:
                self?.sharedDBChangeToken = newToken
            default:
                // Do nothing
                break
            }
        }
        // must update changeTokenUpdatedBlock
        // because single operation may result in
        // multiple
        changesOperation.fetchDatabaseChangesCompletionBlock = {
            [weak self] newToken, more, error in
            if let error = error {
                allChanges([],[],error)
            } else if changedZones.count == 0 {
                switch database.databaseScope {
                case .private:
                    self?.privateDBChangeToken = newToken
                case .shared:
                    self?.sharedDBChangeToken = newToken
                default:
                    // Do nothing
                    break
                }
                allChanges([],[],nil)
            } else {
                self?.fetchZoneChanges(database: database, serverChangeToken: changeToken, zones: changedZones, allChanges: allChanges) // using CKFetchRecordZoneChangesOperation
            }
        }
        
        database.add(changesOperation)
    }
    
    /**
     Note: On this initial implemention if ANY error is returned to allChanges, database and zone change tokens will not be updated.
    */
    func fetchZoneChanges(database: CKDatabase, serverChangeToken: CKServerChangeToken?, zones: [CKRecordZone.ID], allChanges: @escaping ([(CKRecord,CKDatabase.Scope)],[(CKRecord.ID,CKRecord.RecordType,CKDatabase.Scope)], Error?)->Void) {
        var configurationsByRecordZoneID = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]()
        for zoneID in zones {
            let configs = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            configs.previousServerChangeToken = zoneChangeTokens[zoneID]
                configurationsByRecordZoneID[zoneID] = configs
        }
        let recordsOperation = CKFetchRecordZoneChangesOperation(recordZoneIDs: zones, configurationsByRecordZoneID: configurationsByRecordZoneID)
        recordsOperation.fetchAllChanges = true
        var records = [(CKRecord,CKDatabase.Scope)]()
        var deletedRecords = [(CKRecord.ID,CKRecord.RecordType,CKDatabase.Scope)]()
        recordsOperation.recordChangedBlock = { record in
            records += [(record,database.databaseScope)]
        }
        recordsOperation.recordWithIDWasDeletedBlock = { recordID, recordType in
            deletedRecords += [(recordID,recordType,database.databaseScope)]
        }
        
        var tempZoneChangeTokens: [CKRecordZone.ID: CKServerChangeToken] = [:]
        
        recordsOperation.recordZoneChangeTokensUpdatedBlock = { zoneID, zoneChangeToken, _ in
            // We use this for noting change tokens due for the deletions
            // we have processed.
            tempZoneChangeTokens[zoneID] = zoneChangeToken
        }
        recordsOperation.recordZoneFetchCompletionBlock = { (zoneID, zoneChangeToken, _, moreComing, error) in
            // We use this for noting change tokens due for the
            // new records we have retreived
            tempZoneChangeTokens[zoneID] = zoneChangeToken
        }
        recordsOperation.fetchRecordZoneChangesCompletionBlock = {
            [weak self]  error in
            if error != nil {
                allChanges([],[],error)
            } else {
                if let serverChangeToken = serverChangeToken {
                    switch database.databaseScope {
                    case .private:
                        self?.privateDBChangeToken = serverChangeToken
                    case .shared:
                        self?.sharedDBChangeToken = serverChangeToken
                    default:
                        break
                    }
                }
                for (key, value) in tempZoneChangeTokens {
                    self?.zoneChangeTokens[key] = value
                }
                allChanges(records,deletedRecords,error)
            }
        }
        database.add(recordsOperation)
    }
    
    /**
     More targetted API for fetching all records in a database matching
     a given type. The callback will be called twice. Once for results
     from the privateDB and again with results from the publicDB
     */
    func fetchPrivateRecords(recordType: String, callback: @escaping ([CKRecord], Error?)->Void) {
        guard let av = assuredFromOptional() else { return }
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: recordType, predicate: predicate)
        var records = [CKRecord]()
        let queryOp = CKQueryOperation(query: query)
        queryOp.zoneID = av.privateZone.zoneID
        queryOp.recordFetchedBlock = {
            ckRecord in
            // Do we get here
            records += [ckRecord]
        }
        queryOp.queryCompletionBlock = {
            cursor, error in
            callback(records, error)
        }
        av.privateDatabase.add(queryOp)
    }

    /**
     A method for saving a single CKRecord.
     - parameter record: The record we attempted to save
     - parameter completion: The completion handler for once the record has saved. Returns an error if the record is not saved.
        -  record: The record we attempted to save
        -  error: If there was an error saving it is returned here
    */
    func save(record: CKRecord, scope: CKDatabase.Scope, completion:((CKRecord?, Error?)->Void)?) {
        modify(record: record, recordID: nil, scope: scope, saveCompletion: completion, deleteCompletion: nil)
    }
    
    func delete(recordID: CKRecord.ID, completion:((CKRecord.ID?, Error?)->Void)?) {
        modify(record: nil, recordID: recordID, scope:.private ,saveCompletion: nil, deleteCompletion: completion)
    }

    /**
     Modify a single cloud kit record.
     If modifying a record, supply record and save a completion handler
     If deleting a record, supply a record and delete completion handler.
     
     If there is an error modifying the record, the save completion handler will return
     the original record we attempted to save. Do not immediately exexute a query for the
     saved record in the save completion block because server indexing of the records
     will probably not have completed and the record may not be found.
     
     - parameter saveCompletion: The completion handler for once the record has saved. Returns an error if the record is not saved.
     -  record1: The record we attempted to save
     -  record2: The record as saved to the server
     -  error: If there was an error saving it is returned here
    */
    func modify(record: CKRecord?, recordID: CKRecord.ID?, scope: CKDatabase.Scope, saveCompletion:((CKRecord?, Error?)->Void)?, deleteCompletion: ((CKRecord.ID?, Error?)->Void)?) {
        guard let av = assuredFromOptional() else { return }
        var recordsToSave: [CKRecord]? = nil
        var recordsToDelete: [CKRecord.ID]? = nil
        if let record = record {
            recordsToSave = [record]
        }
        if let recordID = recordID {
            recordsToDelete = [recordID]
        }
        let modOp = CKModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: recordsToDelete)
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        modOp.configuration = configuration

        modOp.perRecordCompletionBlock = {
            record, error in
            saveCompletion?(record,error)
            modOp.modifyRecordsCompletionBlock = nil
        }
        
        modOp.modifyRecordsCompletionBlock = {
            records, recordIDs, error in
            
            if let ckError = error as? CKError {
                let userInf = ckError.userInfo
                guard let errorDict = userInf[CKPartialErrorsByItemIDKey] as? NSDictionary else { return }
                
                if let record = records?.first {
                    let saveError = errorDict[record.recordID] as? Error
                    saveCompletion?(record,saveError)
                } else if let recordID = recordIDs?.first {
                    let saveError = errorDict[recordID] as? Error
                    deleteCompletion?(recordID,saveError)
                } else {
                    if let saveCompletion = saveCompletion {
                        saveCompletion(record, CloudKitConnectorError.unknown)
                    }
                    if let deleteCompletion = deleteCompletion {
                        deleteCompletion(recordID, CloudKitConnectorError.unknown)
                    }
                }
            } else {
                if let saveCompletion = saveCompletion {
                    // Even though no error, still an unknown error has occured because
                    // otherwise we would have nulified this completion block in the previous
                    // block
                    saveCompletion(record,  CloudKitConnectorError.unknown)
                }
                if let deleteCompletion = deleteCompletion {
                    if let recordID = recordIDs?.first {
                        deleteCompletion(recordID, nil)
                    }
                }
            }
        }
        
        switch scope {
        case .private:
            av.privateDatabase.add(modOp)
        case .shared:
            sharedDatabase?.add(modOp)
        default:
            print("Wrong db scope")
        }
    }
    
    func loadRecord(_ recordID: CKRecord.ID, scope: CKDatabase.Scope, completion:((CKRecord?, Error?)->Void)?) {
        guard let av = assuredFromOptional() else { return }
        let fetchOp = CKFetchRecordsOperation(recordIDs: [recordID])
        fetchOp.perRecordCompletionBlock = {
            record, _, error in
            completion?(record, error)
        }
        switch scope {
        case .private:
            av.privateDatabase.add(fetchOp)
        case .shared:
            sharedDatabase?.add(fetchOp)
        default:
            print("Wrong db scope")
        }
    }
    
    /**
     Get the sharing controller which
     can be used to share a record.
     If the record has already been
     shared, this method returns nil.
    */
    func shareRecord(_ record: CKRecord)->UICloudSharingController? {
        guard let av = assuredFromOptional() else { return nil }
        if record.share != nil {
            // Already shared
            return nil
        }
        let controller = UICloudSharingController {
            controller, preparationCompletionHandler in
            let share = CKShare(rootRecord: record)
            let saveOperation = CKModifyRecordsOperation(recordsToSave: [record, share], recordIDsToDelete: nil)
            saveOperation.modifyRecordsCompletionBlock = {
                records, recordIDs, error in
                if error == nil {
                    preparationCompletionHandler(share, CKContainer.default(), error)
                }
            }
            av.privateDatabase.add(saveOperation)
        }
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        return controller
    }
    
    func acceptShare(shareMetaData:CKShare.Metadata) {
        let accept = CKAcceptSharesOperation(shareMetadatas: [shareMetaData])
        accept.perShareCompletionBlock = {
            metaData, share, error in
            print(error)
        }
        CKContainer(identifier: shareMetaData.containerIdentifier).add(accept)
    }
}
