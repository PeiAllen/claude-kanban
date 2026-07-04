import SwiftUI

/// Stub until M3 (the real attention queue of cards waiting on the human).
struct NeedsYouTab: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Nothing needs you",
                                   systemImage: "bell.slash",
                                   description: Text("Cards waiting on you will appear here."))
                .navigationTitle("Needs You")
        }
    }
}
