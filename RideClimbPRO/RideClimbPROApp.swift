import SwiftUI

@main
struct RideClimbPROApp: App {
    @StateObject private var trainer = TrainerManager()
    @StateObject private var ride = RideModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(trainer)
                .environmentObject(ride)
        }
    }
}
