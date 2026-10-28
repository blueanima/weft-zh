import AppKit
import WeftKit
import SwiftUI

/// Borderless windows above everything else, on every Space, for the break screen and the
/// distraction blocker.
@MainActor
final class OverlayController {
    private var breakWindows: [NSWindow] = []
    private var blockerWindow: NSWindow?

    func showBreak(model: AppModel) {
        hideBreak()
        breakWindows = NSScreen.screens.map { screen in
            makeWindow(on: screen, content: BreakOverlayView().environment(model))
        }
    }

    func hideBreak() {
        breakWindows.forEach { $0.orderOut(nil) }
        breakWindows.removeAll()
    }

    func showBlocker(model: AppModel) {
        guard blockerWindow == nil, let screen = NSScreen.main else { return }
        blockerWindow = makeWindow(on: screen, content: BlockerOverlayView().environment(model))
    }

    func hideBlocker() {
        blockerWindow?.orderOut(nil)
        blockerWindow = nil
    }

    /// A non-activating panel can take keyboard focus without activating the app, which
    /// macOS no longer allows us to do on our own. It also keeps the tracker from seeing
    /// Weft as the frontmost app while an overlay is up.
    private func makeWindow(on screen: NSScreen, content: some View) -> NSWindow {
        let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

private final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct BreakOverlayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)
            Color.black.opacity(0.35)
            VStack(spacing: 20) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.9))
                Text("休息一下！")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("站起来、伸展一下，看看远处。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if let session = model.sessions.active {
                    Text(Format.countdown(session.remaining(at: model.sessions.now)))
                        .font(.system(size: 72, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                HStack(spacing: 16) {
                    Button("延长 5 分钟") { model.sessions.extend(minutes: 5) }
                    Button("结束休息") { model.sessions.stop() }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.extraLarge)
                .font(.title3)
            }
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

struct BlockerOverlayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            if let incident = model.distractionGuard.incident {
                VStack(spacing: 16) {
                    Image(nsImage: AppIcons.icon(for: incident.context.bundleID))
                        .resizable().frame(width: 56, height: 56)
                    Text("分心了？")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("**\(incident.displayName)** 被归入 **\(incident.category.name)**。")
                        .foregroundStyle(.secondary)
                    if let session = model.sessions.active {
                        Text("专注时段还剩 \(Format.countdown(session.remaining(at: model.sessions.now)))。")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button("回到工作") { model.distractionGuard.backToWork() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    HStack(spacing: 16) {
                        Button("这不算分心") { model.distractionGuard.notADistraction() }
                        Button("本次时段内关闭拦截") { model.distractionGuard.disableForSession() }
                        Button("仍然继续") { model.distractionGuard.ignore() }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
                .padding(36)
                .frame(maxWidth: 520)
                .background(RoundedRectangle(cornerRadius: 20).fill(.regularMaterial))
            }
        }
        .ignoresSafeArea()
    }
}
