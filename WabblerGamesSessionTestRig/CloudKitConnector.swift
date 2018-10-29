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


enum CloudKitConnectorStrings {
    static let privateSubName                   = "wabbler-private-games"
    static let sharedSubName                    = "wabbler-shared-games"
}

enum CloudKitConnectorError: Error {
    case signInRequired
    case accountRestricted
    case couldNotDetermineAccountStatus
    case badState // For this one, check the failure states
}

/**
 State verification so we have some formal
 structure around forced optionals that are
 configured asyncronously
 */
struct FailureSet: OptionSet {
    let rawValue: Int
    static let notSignedInToICloud          = FailureSet(rawValue: 1 << 0)
    static let noPrivateDBSub               = FailureSet(rawValue: 1 << 1)
    static let noSharedDBSub                = FailureSet(rawValue: 1 << 2)
    static let noPrivateZone                = FailureSet(rawValue: 1 << 3)
    static let noPrivateDB                  = FailureSet(rawValue: 1 << 4)
    static let noSharedDB                   = FailureSet(rawValue: 1 << 5)
}

protocol Assurable {
    func assuredForOptional()->AssuredValues?
}

struct AssuredValues {
    let container: CKContainer
    let privateSubscription: CKSubscription
    let privateDatabase: CKDatabase
    let privateZone: CKRecordZone
    let sharedDatabase: CKDatabase
}

protocol OptionalValues: Assurable {
    var container: CKContainer? { get set }
    var privateSubscription: CKSubscription? { get set }
    var privateDatabase: CKDatabase? { get set }
    var sharedDatabase: CKDatabase? { get set }
    var privateZone: CKRecordZone? { get set }
}

extension OptionalValues {
    func assuredForOptional()->AssuredValues? {
        if let c = container,
        let ps = privateSubscription,
        let pd = privateDatabase,
        let pz = privateZone,
        let sd = sharedDatabase {
            return AssuredValues(container: c, privateSubscription: ps, privateDatabase: pd, privateZone: pz, sharedDatabase: sd)
        } else {
            return nil
        }
    }
}

protocol AssuredState: OptionalValues {
    var stateError: ((CloudKitConnectorError)->Void)? { get set }
    var failureStates: FailureSet { get set }
    var assuredValues: AssuredValues? { get }// use in a guard let statement ensures all values are available
}

extension AssuredState {
    var assuredValues: AssuredValues? {
        get {
            if let assured = assuredForOptional() {
                return assured
            } else {
                stateError?(.badState)
                return nil
            }
        }
    }
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
    static let sharedConnector = CloudKitConnector()
    private init() { }
    var stateError: ((CloudKitConnectorError)->Void)?
    var failureStates: FailureSet = [.notSignedInToICloud,.noPrivateDBSub,.noSharedDBSub,.noPrivateZone,.noPrivateDB,.noSharedDB]
    // Assured properties
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
    var remoteRecordUpdatedCompletion: ((CKRecord?, CKRecord.ID?, Error?)->Void)?
    var remoteRecordDeletedCompletion: ((CKRecord.ID?, Error?)->Void)?
    
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
            switch status {
            case .available:
                self.failureStates.remove(.notSignedInToICloud)
                self.privateDatabase = container.privateCloudDatabase
                self.sharedDatabase = container.sharedCloudDatabase
                self.failureStates.remove(.noPrivateDB)
                self.failureStates.remove(.noSharedDB)
                self.continueConnection(zoneName: zoneName)
            case .noAccount:
                // User not logged in to iCloud
                self.stateError?(.signInRequired)
            case .couldNotDetermine:
                self.stateError?(.couldNotDetermineAccountStatus)
            case .restricted:
                self.stateError?(.accountRestricted)
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
                if ckError.code == CKError.zoneNotFound.rawValue {
                    CloudKitConnector.sharedConnector.privateDatabase?.save(recordZone) { (newZone, error) in
                        if let error = error {
                            print(error.localizedDescription)
                        } else {
                            CloudKitConnector.sharedConnector.privateZone = newZone
                            self.failureStates.remove(.noPrivateZone)
                        }
                    }
                }
            } else {
                CloudKitConnector.sharedConnector.privateZone = retreivedZone
                self.failureStates.remove(.noPrivateZone)
            }
        }
        
        // Setup private subscription if one hasn't been set up already
        if privateSubscription != nil { return }
        let privateOp = createDatabaseSubscriptionOperation(subscriptionId: CloudKitConnectorStrings.privateSubName)
        privateOp.modifySubscriptionsCompletionBlock = { [weak self] (subscriptions, strings, error) in
            if error == nil {
                if let sub = subscriptions?.first {
                    self?.privateSubscription = sub
                    self?.failureStates.remove(.noPrivateDBSub)
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
                    self?.failureStates.remove(.noSharedDBSub)
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
        
        //let notificationInfo = CKSubscription.NotificationInfo()
        //notificationInfo.shouldSendContentAvailable = true
        //subscription.notificationInfo = notificationInfo
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
        guard let av = assuredValues else { return }
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
        guard let av = assuredValues else { return }
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
            if changedZones.count == 0 {
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
                self?.fetchZoneChanges(database: database, previousChangeToken: changeToken, zones: changedZones, allChanges: allChanges) // using CKFetchRecordZoneChangesOperation
            }
        }
        
        database.add(changesOperation)
    }
    
    func fetchZoneChanges(database: CKDatabase, previousChangeToken: CKServerChangeToken?,zones: [CKRecordZone.ID], allChanges: @escaping ([(CKRecord,CKDatabase.Scope)],[(CKRecord.ID,CKRecord.RecordType,CKDatabase.Scope)], Error?)->Void) {
        var configurationsByRecordZoneID = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]()
        for zoneID in zones {
            let configs = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            configs.previousServerChangeToken = previousChangeToken
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
        recordsOperation.recordZoneChangeTokensUpdatedBlock = { [weak self] _, serverChangeToken, _ in
            // We use this for noting change tokens due for the deletions
            // we have processed.
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
        }
        recordsOperation.recordZoneFetchCompletionBlock = { [weak self](_,serverChangeToken,_,moreComing,error) in
            // We use this for noting change tokens due for the
            // new records we have retreived
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
        }
        recordsOperation.fetchRecordZoneChangesCompletionBlock = {
            error in
            allChanges(records,deletedRecords,error)
        }
        database.add(recordsOperation)
    }
    
    /**
     More targetted API for fetching all records in a database matching
     a given type. The callback will be called twice. Once for results
     from the privateDB and again with results from the publicDB
     */
    func fetchPrivateRecords(recordType: String, callback: @escaping ([CKRecord], Error?)->Void) {
        guard let av = assuredValues else { return }
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
        guard let av = assuredValues else { return }
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
                        saveCompletion(record, WabblerGameSessionError.unknownError)
                    }
                    if let deleteCompletion = deleteCompletion {
                        deleteCompletion(recordID, WabblerGameSessionError.unknownError)
                    }
                }
            } else {
                if let saveCompletion = saveCompletion {
                    // Even though no error, still an unknown error has occured because
                    // otherwise we would have nulified this completion block in the previous
                    // block
                    saveCompletion(record,  WabblerGameSessionError.unknownError)
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
        guard let av = assuredValues else { return }
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
        guard let av = assuredValues else { return nil }
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
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let dict = userInfo as! [String:NSObject]
        let notification = CKQueryNotification(fromRemoteNotificationDictionary: dict)
        guard let recordID = notification.recordID else { return }
        
        if notification.subscriptionID == CloudKitConnectorStrings.privateSubName || notification.subscriptionID == CloudKitConnectorStrings.sharedSubName {
            switch notification.queryNotificationReason {
            case .recordUpdated:
                loadRecord(recordID, scope:notification.databaseScope, completion: nil)
            case .recordDeleted:
                remoteRecordDeleted(recordID, scope:notification.databaseScope)
            default:
                print("do nothing")
            }
        }
    }
    
    func remoteRecordDeleted(_ recordID: CKRecord.ID, scope: CKDatabase.Scope) {
        remoteRecordDeletedCompletion?(recordID, nil)
    }
    
    func acceptShare(shareMetaData:CKShare.Metadata) {
        let accept = CKAcceptSharesOperation(shareMetadatas: [shareMetaData])
        accept.perShareCompletionBlock = {
            metaData, share, error in
            
        }
        CKContainer(identifier: shareMetaData.containerIdentifier).add(accept)
    }
}
