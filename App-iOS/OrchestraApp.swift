import SwiftUI

// Temporary empty shell — exists only so the App-iOS target compiles+links OrchestraKit/OrchestraUI/
// SwiftTerm for iOS (Task 1, the SwiftTerm-iOS build canary). Task 4 replaces this with the real
// TabView shell driven by the shared OrchestraUI.BoardModel.
@main
struct OrchestraiOSApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Orchestra iOS — skeleton")
        }
    }
}
