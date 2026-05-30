import AppKit
import SwiftUI
import MacActivityCore

enum ActiveProcessMemoryRowTrailingContent: Equatable {
    case memory
    case quit
    case confirmQuit
}

enum ActiveProcessIconSource: Equatable {
    case bundle(URL)
    case fallbackSystemSymbol
}

enum ActiveProcessQuitConfirmationState: Equatable {
    case inactive
    case confirming
}

enum ActiveProcessQuitConfirmationEvent {
    case quitButtonClicked
    case outsideClicked
    case timedOut
}

struct ActiveProcessQuitConfirmationResult {
    let state: ActiveProcessQuitConfirmationState
    let shouldQuit: Bool
}

enum ActiveProcessQuitConfirmationReducer {
    static func reduce(
        _ state: ActiveProcessQuitConfirmationState,
        event: ActiveProcessQuitConfirmationEvent
    ) -> ActiveProcessQuitConfirmationResult {
        switch (state, event) {
        case (.inactive, .quitButtonClicked):
            return ActiveProcessQuitConfirmationResult(state: .confirming, shouldQuit: false)
        case (.confirming, .quitButtonClicked):
            return ActiveProcessQuitConfirmationResult(state: .inactive, shouldQuit: true)
        case (_, .outsideClicked), (_, .timedOut):
            return ActiveProcessQuitConfirmationResult(state: .inactive, shouldQuit: false)
        }
    }
}

struct ActiveProcessQuitButtonConfiguration: Equatable {
    let title: String
    let isDestructive: Bool
}

struct ActiveProcessMemoryRow: View {
    let app: ActiveAppMemoryEntry
    let maxBytes: UInt64
    private let quit: () -> Void
    @Binding private var confirmingQuitProcessIdentifier: pid_t?
    @State private var isHovered = false

    init(
        app: ActiveAppMemoryEntry,
        maxBytes: UInt64,
        confirmingQuitProcessIdentifier: Binding<pid_t?> = .constant(nil),
        quit: @escaping () -> Void
    ) {
        self.app = app
        self.maxBytes = maxBytes
        self._confirmingQuitProcessIdentifier = confirmingQuitProcessIdentifier
        self.quit = quit
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(
                        width: proxy.size.width * ActiveProcessMemoryLayout.progress(
                            bytes: app.residentMemoryBytes,
                            maxBytes: maxBytes
                        )
                    )

                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        icon

                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)

                            Text(app.bundleIdentifier ?? "Process \(app.processIdentifier)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        applyQuitConfirmationEvent(.outsideClicked)
                    }

                    trailingContent
                        .frame(width: ActiveProcessMemoryLayout.trailingActionWidth, alignment: .trailing)
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(height: ActiveProcessMemoryLayout.rowHeight)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .task(id: quitConfirmationState) {
            guard quitConfirmationState == .confirming else { return }
            try? await Task.sleep(nanoseconds: Self.quitConfirmationTimeoutNanoseconds)
            guard Task.isCancelled == false else { return }
            applyQuitConfirmationEvent(.timedOut)
        }
        .onDisappear {
            if quitConfirmationState == .confirming {
                confirmingQuitProcessIdentifier = nil
            }
        }
        .clipped()
    }

    private var quitConfirmationState: ActiveProcessQuitConfirmationState {
        confirmingQuitProcessIdentifier == app.processIdentifier ? .confirming : .inactive
    }

    @ViewBuilder
    private var icon: some View {
        switch Self.iconSource(for: app) {
        case .bundle(let bundleURL):
            Image(nsImage: ActiveProcessIconCache.shared.icon(for: bundleURL))
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .cornerRadius(4)
        case .fallbackSystemSymbol:
            Image(systemName: "app")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
    }

    @ViewBuilder
    private var trailingContent: some View {
        switch Self.trailingContent(isHovered: isHovered, quitConfirmationState: quitConfirmationState) {
        case .memory:
            Text(app.formattedResidentMemory)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .quit, .confirmQuit:
            quitButton
        }
    }

    @ViewBuilder
    private var quitButton: some View {
        let configuration = Self.quitButtonConfiguration(for: quitConfirmationState)

        if configuration.isDestructive {
            Button(configuration.title) {
                applyQuitConfirmationEvent(.quitButtonClicked)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!app.isTerminable)
        } else {
            Button(configuration.title) {
                applyQuitConfirmationEvent(.quitButtonClicked)
            }
            .buttonStyle(.bordered)
            .disabled(!app.isTerminable)
        }
    }

    @MainActor
    private func applyQuitConfirmationEvent(_ event: ActiveProcessQuitConfirmationEvent) {
        if event == .outsideClicked {
            confirmingQuitProcessIdentifier = nil
            return
        }

        let result = ActiveProcessQuitConfirmationReducer.reduce(quitConfirmationState, event: event)

        switch result.state {
        case .inactive:
            if confirmingQuitProcessIdentifier == app.processIdentifier {
                confirmingQuitProcessIdentifier = nil
            }
        case .confirming:
            confirmingQuitProcessIdentifier = app.processIdentifier
        }

        if result.shouldQuit {
            quit()
        }
    }

    static func trailingContent(isHovered: Bool) -> ActiveProcessMemoryRowTrailingContent {
        trailingContent(isHovered: isHovered, quitConfirmationState: .inactive)
    }

    static func trailingContent(
        isHovered: Bool,
        quitConfirmationState: ActiveProcessQuitConfirmationState
    ) -> ActiveProcessMemoryRowTrailingContent {
        switch quitConfirmationState {
        case .inactive:
            return isHovered ? .quit : .memory
        case .confirming:
            return .confirmQuit
        }
    }

    static func quitButtonConfiguration(
        for state: ActiveProcessQuitConfirmationState
    ) -> ActiveProcessQuitButtonConfiguration {
        switch state {
        case .inactive:
            return ActiveProcessQuitButtonConfiguration(title: "Quit", isDestructive: false)
        case .confirming:
            return ActiveProcessQuitButtonConfiguration(title: "Confirm", isDestructive: true)
        }
    }

    static let quitConfirmationTimeoutNanoseconds: UInt64 = 3_000_000_000

    static func iconSource(
        for app: ActiveAppMemoryEntry,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> ActiveProcessIconSource {
        guard let bundleURL = app.bundleURL, fileExists(bundleURL) else {
            return .fallbackSystemSymbol
        }
        return .bundle(bundleURL)
    }
}

@MainActor
private final class ActiveProcessIconCache {
    static let shared = ActiveProcessIconCache()

    private let cache = NSCache<NSURL, NSImage>()

    func icon(for bundleURL: URL) -> NSImage {
        let cacheKey = bundleURL as NSURL
        if let cachedIcon = cache.object(forKey: cacheKey) {
            return cachedIcon
        }

        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        cache.setObject(icon, forKey: cacheKey)
        return icon
    }
}
