import SwiftUI
import UIKit

@main
struct MangarApp: App {
    init() {
        UIView.setAnimationsEnabled(false)
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .buttonStyle(ImmediateButtonStyle())
                .immediateUI()
        }
    }
}
