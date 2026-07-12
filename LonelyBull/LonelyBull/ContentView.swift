import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        TabView(selection: $app.selectedTab) {
            ChatView()
                .tabItem { Label(AppTab.chat.title, systemImage: AppTab.chat.systemImage) }
                .tag(AppTab.chat)

            ModelsView()
                .tabItem { Label(AppTab.models.title, systemImage: AppTab.models.systemImage) }
                .tag(AppTab.models)

            VoiceHubView()
                .tabItem { Label(AppTab.voice.title, systemImage: AppTab.voice.systemImage) }
                .tag(AppTab.voice)

            SettingsView()
                .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage) }
                .tag(AppTab.settings)
        }
        .tint(CursorTheme.accent)
        .cursorTabBarBehavior()
        .background(CursorTheme.background.ignoresSafeArea())
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
