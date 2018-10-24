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
    static let noSharedZone                 = FailureSet(rawValue: 1 << 4)
    static let noPrivateDB                  = FailureSet(rawValue: 1 << 5)
    static let noSharedDB                   = FailureSet(rawValue: 1 << 6)
}

protocol Assurable {
    func assuredForOptional()->AssuredValues?
}

struct AssuredValues {
    let container: CKContainer
    let privateSubscription: CKSubscription
    let privateDatabase: CKDatabase
    let privateZone: CKRecordZone
}

protocol OptionalValues: Assurable {
    var container: CKContainer? { get set }
    var privateSubscription: CKSubscription? { get set }
    var privateDatabase: CKDatabase? { get set }
    var privateZone: CKRecordZone? { get set }
}

extension OptionalValues {
    func assuredForOptional()->AssuredValues? {
        if let c = container,
        let ps = privateSubscription,
        let pd = privateDatabase,
        let pz = privateZone {
            return AssuredValues(container: c, privateSubscription: ps, privateDatabase: pd, privateZone: pz)
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
    var failureStates: FailureSet = [.notSignedInToICloud,.noPrivateDBSub,.noSharedDBSub,.noPrivateZone,.noSharedZone]
    // Assured properties
    var container: CKContainer?
    var privateSubscription: CKSubscription?
    var sharedSubscription: CKSubscription?
    var privateDatabase: CKDatabase?
    var sharedDatabase: CKDatabase?
    var privateZone: CKRecordZone?
    var sharedZone: CKRecordZone?
    // End Assured properties
    private var privateDBChangeToken: CKServerChangeToken?
    private var sharedDBChangeToken: CKServerChangeToken?
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
        let recordZone2 = CKRecordZone(zoneName: zoneName)
        //        sharedDatabase?.fetch(withRecordZoneID: recordZone2.zoneID) { (retreivedZone, error) in
        //            if let error = error {
        //                print(error)
        //                print(error.localizedDescription)
        //                let ckError = error as NSError
        //                if ckError.code == CKError.zoneNotFound.rawValue {
        //                    CloudKitConnector.sharedConnector.privateDatabase?.save(recordZone2) { (newZone, error) in
        //                        if let error = error {
        //                            print(error.localizedDescription)
        //                        } else {
        //                            CloudKitConnector.sharedConnector.sharedZone = newZone
        //                        }
        //                    }
        //                }
        //            } else {
        //                CloudKitConnector.sharedConnector.sharedZone = retreivedZone
        //                self.failureStates.remove(.noPrivateZone)
        //            }
        //        }
        
        // Setup private subscription if one hasn't been set up already
        if privateSubscription != nil { return }
        let newPrivateSub = CKDatabaseSubscription(subscriptionID: CloudKitConnectorStrings.privateSubName)
        let privateNotificationInfo = CKSubscription.NotificationInfo()
        privateNotificationInfo.shouldSendContentAvailable = true
        newPrivateSub.notificationInfo = privateNotificationInfo
        let operation1 = CKModifySubscriptionsOperation(subscriptionsToSave: [newPrivateSub], subscriptionIDsToDelete: [])
        operation1.modifySubscriptionsCompletionBlock = { [weak self] (subscriptions, strings, error) in
            if error == nil {
                if let sub = subscriptions?.first {
                    self?.privateSubscription = sub
                    self?.failureStates.remove(.noPrivateDBSub)
                    print(sub)
                }
            } else {
                print(error!)
            }
        }
        let configuration = CKOperation.Configuration()
        configuration.isLongLived = true
        configuration.qualityOfService = .utility
        operation1.configuration = configuration
        privateDatabase?.add(operation1)
        
        if sharedSubscription != nil { return }
        let newSharedSub = CKDatabaseSubscription(subscriptionID: CloudKitConnectorStrings.sharedSubName)
        let sharedNotificationInfo = CKSubscription.NotificationInfo()
        sharedNotificationInfo.shouldSendContentAvailable = true
        newSharedSub.notificationInfo = sharedNotificationInfo
        let operation2 = CKModifySubscriptionsOperation(subscriptionsToSave: [newSharedSub], subscriptionIDsToDelete: [])
        operation2.modifySubscriptionsCompletionBlock = { [weak self] (subscriptions, strings, error) in
            if error == nil {
                if let sub = subscriptions?.first {
                    self?.sharedSubscription = sub
                    print(sub)
                }
            } else {
                print(error!)
            }
        }
        operation2.configuration = configuration
        sharedDatabase?.add(operation2)
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
     Generally abstracted method for fetching
     all changed records of all types from all
     zones.
     */
    func fetchRecords(database: CKDatabase, changeToken: CKServerChangeToken?, callback: @escaping ([CKRecord], Error?)->Void) {
        let changesOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: changeToken) // Nil simply fetches all zones
        changesOperation.fetchAllChanges = true
        var changedZones = [CKRecordZone.ID]()
        changesOperation.recordZoneWithIDChangedBlock = { rzid in
            changedZones += [rzid]
        }
        
        // must update changeTokenUpdatedBlock
        // because single operation may result in
        // multiple
        changesOperation.fetchDatabaseChangesCompletionBlock = {
            [weak self] newToken, more, error in
            self?.sharedDBChangeToken = newToken
            self?.fetchZoneChanges(zones: changedZones, allRecords: callback) // using CKFetchRecordZoneChangesOperation
        }
        database.add(changesOperation)
    }
    
    func fetchZoneChanges(zones: [CKRecordZone.ID], allRecords: @escaping ([CKRecord], Error?)->Void) {
        let recordsOperation = CKFetchRecordZoneChangesOperation()
        recordsOperation.recordZoneIDs = zones
        var records = [CKRecord]()
        recordsOperation.recordChangedBlock = { record in
            records += [record]
        }
        recordsOperation.recordZoneFetchCompletionBlock = { (_,_,_,_,error) in
            allRecords(records,error)
        }
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
     fetch records of record type accross both private
     and shared databases.
    */
    func fetchRecords(recordType: String, callback: @escaping ([(CKRecord,CKDatabase.Scope)], Error?)->Void) {
        guard assuredValues != nil else { return }
        fetchPrivateRecords(recordType: recordType) { [weak self](records, error) in
            var records:[(CKRecord,CKDatabase.Scope)] = records.map { ($0, .private) }
            var errors: [Error] = error != nil ? [error!] : []
            if let error = error {
                callback(records,error)
            } else if self?.sharedDatabase == nil {
                callback(records,error)
            } else if let sharedDatabase = self?.sharedDatabase {
                sharedDatabase.fetchAllRecordZones() { (zones, error) in
                    var ops: [CKQueryOperation] = []
                    guard let zones = zones else {
                        callback(records,error)
                        return
                    }
                    for zone in zones {
                        if let op = self?.fetchRecordsOperation(recordType: recordType, zoneID: zone.zoneID, callback: { (zoneRecords, error) in
                            records += zoneRecords.map { ($0,.shared) }
                            if let error = error { errors += [error] }
                        }) {
                            ops += [op]
                        }
                    }
                    if let lastOp = ops.last {
                        lastOp.completionBlock = {
                            callback(records,errors.last)
                        }
                        for op in ops {
                            if op != lastOp {
                                lastOp.addDependency(op)
                            }
                        }
                    }
                    for op in ops {
                        sharedDatabase.add(op)
                    }
                }
            }
        }
    }
    
    private func fetchRecordsOperation(recordType: String, zoneID: CKRecordZone.ID ,callback: @escaping ([CKRecord], Error?)->Void)->CKQueryOperation {
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: recordType, predicate: predicate)
        var records = [CKRecord]()
        let queryOp = CKQueryOperation(query: query)
        queryOp.zoneID = zoneID
        queryOp.recordFetchedBlock = {
            ckRecord in
            // Do we get here
            records += [ckRecord]
        }
        queryOp.queryCompletionBlock = {
            cursor, error in
            callback(records, error)
        }
        return queryOp
    }
    
//    func getSharedRecords(callback: @escaping (([String: NSNumber]) -> Void)) {
//        var sharedData = [String: NSNumber]()
//        guard isCloudKitEnabeld else {
//            callback(sharedData)
//            return
//        }
//
//        sharedDatabase.fetchAllRecordZones { zones, error in
//            if let err = error {
//                print("Error fetting shared record zones: \(err)")
//                callback(sharedData)
//                return
//            }
//            guard let recordZones = zones else {
//                print("no error getting shared zones, but no zones returned")
//                callback(sharedData)
//                return
//            }
//            if recordZones.isEmpty {
//                callback(sharedData)
//                return
//            }
//            var zoneQueriesReturned = 0
//            for zone in recordZones {
//                let query = CKQuery(recordType: CloudKitAccessor.kRecordType, predicate: NSPredicate(value: true))
//                let queryOperation = CKQueryOperation(query: query)
//                queryOperation.zoneID = zone.zoneID
//                queryOperation.qualityOfService = .userInteractive
//                queryOperation.queuePriority = .high
//                queryOperation.recordFetchedBlock = { record in
//                    guard let count = record[CloudKitAccessor.kCountKey] as? NSNumber else {
//                        print("Malformed shared record, skipping: \(record)")
//                        return
//                    }
//                    let recordNameID = record.recordID.zoneID.ownerName
//                    let name = SharedUserStore.getSharedUserDisplayName(nameID: recordNameID) ?? record.recordID.zoneID.ownerName
//                    sharedData[name] = count
//                }
//                queryOperation.queryCompletionBlock = { cursor, error in
//                    if let err = error {
//                        print("Error running shared query: \(err)")
//                    }
//                }
//                queryOperation.completionBlock = {
//                    zoneQueriesReturned += 1
//                    if zoneQueriesReturned == recordZones.count {
//                        callback(sharedData)
//                    }
//                }
//                self.sharedDatabase.add(queryOperation)
//            }
//        }
//    }

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
    
    func shareRecord(_ record: CKRecord)->UICloudSharingController? {
        guard let av = assuredValues else { return nil }
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
