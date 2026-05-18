import SwiftUI

struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppLifecycleManager.self) private var lifecycle

    var body: some View {
        PopoverContentView()
            .frame(width: 320)
    }
}

#Preview {
    MainWindowView()
        .environment(AppState())
        .environment(AppLifecycleManager())
}
