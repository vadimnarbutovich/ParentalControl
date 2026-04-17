//
//  ParentalControlApp.swift
//  ParentalControl
//
//  Created by Vadzim Narbutovich on 17.04.2026.
//

import SwiftUI
import CoreData

@main
struct ParentalControlApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
