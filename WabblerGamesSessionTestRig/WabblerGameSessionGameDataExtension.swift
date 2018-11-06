//
//  WabblerGameSessionGameDataExtension.swift
//  WabblerGamesSessionTestRig
//
//  Created by Paul Lancefield on 06/11/2018.
//  Copyright © 2018 PaulLancefield. All rights reserved.
//

import Foundation

extension WabblerGameSession {
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
            // We have already returned to the main
            // thread in the loadData call
            completionHandler(gameData, anError)
        }
    }
}
