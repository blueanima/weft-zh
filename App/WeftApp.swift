import WeftKit
import SwiftUI

@main
struct WeftApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        MenuBarExtra {
            OnlyWhileVisible {
                MenuBarView()
                    .environment(model)
                    .modelContainer(model.container)
                    .environment(\.locale, .weftUI)
            }
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Weft", id: MainView.windowID) {
            OnlyWhileVisible {
                MainView()
                    .environment(model)
                    .modelContainer(model.container)
                    .environment(\.locale, .weftUI)
            }
        }
        .defaultSize(width: 1080, height: 760)
        .defaultLaunchBehavior(model.preferences.hasCompletedOnboarding ? .suppressed : .presented)

        Settings {
            SettingsView()
                .environment(model)
                .modelContainer(model.container)
                .environment(\.locale, .weftUI)
        }
    }
}

private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let session = model.sessions.active {
                Image(systemName: session.kind.symbol)
                Text(Format.countdown(session.remaining(at: model.sessions.now)))
                    .monospacedDigit()
            } else {
                Image(systemName: model.preferences.trackingPaused ? "pause.circle" : "circle.circle")
            }
        }
        .task {
            // The label is always alive, unlike the popover, so it provides `openWindow`.
            model.openDashboard = {
                openWindow(id: MainView.windowID)
                NSApp.activate()
            }
        }
    }
}

/// Owns the model so `weft://` URLs can reach it even when no window is open.
///
///     weft://focus?minutes=50   weft://meeting   weft://break
///     weft://stop               weft://pause     weft://resume
///     weft://dashboard
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "weft" {
            handle(url)
        }
    }

    private func handle(_ url: URL) {
        let minutes = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "minutes" }?.value.flatMap(Int.init)
        switch url.host() {
        case "focus": model.startSession(.focus, minutes: minutes)
        case "meeting": model.startSession(.meeting, minutes: minutes)
        case "break": model.startSession(.breakTime, minutes: minutes)
        case "stop": model.sessions.stop()
        case "pause": model.preferences.trackingPaused = true
        case "resume": model.preferences.trackingPaused = false
        case "dashboard":
            model.showDay()
            model.openDashboard?()
        default: break
        }
    }
}
