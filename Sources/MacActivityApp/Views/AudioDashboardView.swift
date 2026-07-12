import SwiftUI
import CoreAudio
import MacActivityCore

struct AudioDashboardView: View {
    @ObservedObject var model: AudioDashboardModel

    var body: some View {
        let presentation = AudioDashboardPresentation(
            snapshot: model.snapshot,
            supportsProcessControls: model.supportsProcessControls
        )
        LazyVStack(alignment: .leading, spacing: 14) {
            AudioDashboardSection(
                title: AppLocalization.string(.audioDevicesTitle),
                accessibilityIdentifier: "audio.devices.section"
            ) {
                ForEach(presentation.devices) { device in
                    AudioDeviceControlRow(presentation: device, model: model)
                }
            }

            if let processSection = presentation.processSection {
                AudioDashboardSection(
                    title: AppLocalization.string(.audioProcessesTitle),
                    accessibilityIdentifier: "audio.processes.section"
                ) {
                    if processSection.processes.isEmpty {
                        Text(AppLocalization.string(.audioProcessesEmpty))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("audio.processes.empty")
                    } else {
                        ForEach(processSection.processes) { process in
                            AudioProcessControlRow(presentation: process, model: model)
                        }
                    }
                }
            }
        }
    }
}

private struct AudioDashboardSection<Content: View>: View {
    let title: String
    let accessibilityIdentifier: String
    let content: Content

    init(
        title: String,
        accessibilityIdentifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct AudioDeviceControlRow: View {
    let presentation: AudioDeviceRowPresentation
    @ObservedObject var model: AudioDashboardModel

    private var snapshot: AudioDeviceControlSnapshot { presentation.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(snapshot.device.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 12)
                volumeControl
                    .frame(maxWidth: 150)
                muteControl
            }

            if presentation.showsRetry {
                recoveryStatus
            }

            if presentation.showsWriteFailure {
                Text(AppLocalization.string(.audioDeviceWriteFailed))
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("audio.device.\(snapshot.id).writeFailed")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audio.device.\(snapshot.id)")
    }

    @ViewBuilder
    private var volumeControl: some View {
        switch presentation.volume {
        case .slider(let value):
            Slider(
                value: Binding(
                    get: { value },
                    set: { model.setDeviceVolume($0, for: snapshot.id) }
                ),
                in: 0...1
            )
            .accessibilityLabel(volumeAccessibility(value))
            .accessibilityIdentifier("audio.device.\(snapshot.id).volume.slider")

        case .readOnly(let value):
            Text(value, format: .percent.precision(.fractionLength(0)))
                .foregroundStyle(.secondary)
                .accessibilityLabel(volumeAccessibility(value))
                .accessibilityIdentifier("audio.device.\(snapshot.id).volume.readOnly")

        case .unsupported:
            Text(AppLocalization.string(.audioUnsupportedDeviceVolume))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("audio.device.\(snapshot.id).volume.unsupported")

        case .unavailable:
            statusText(
                AppLocalization.string(.audioDeviceUnavailable),
                identifier: "audio.device.\(snapshot.id).volume.unavailable"
            )

        case .failed:
            statusText(
                AppLocalization.string(.audioDeviceReadFailed),
                identifier: "audio.device.\(snapshot.id).volume.failed"
            )
        }
    }

    @ViewBuilder
    private var muteControl: some View {
        switch presentation.mute {
        case .button(let isMuted):
            Button {
                model.setDeviceMuted(!isMuted, for: snapshot.id)
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.string(
                isMuted ? .audioUnmuteAccessibility : .audioMuteAccessibility,
                snapshot.device.name
            ))
            .accessibilityIdentifier("audio.device.\(snapshot.id).mute")

        case .readOnly(let isMuted):
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel(snapshot.device.name)
                .accessibilityValue(isMuted ? "Muted" : "Not muted")
                .accessibilityIdentifier("audio.device.\(snapshot.id).mute.readOnly")

        case .unsupported:
            EmptyView()

        case .unavailable:
            Image(systemName: "exclamationmark.triangle")
                .accessibilityLabel(AppLocalization.string(.audioDeviceUnavailable))
                .accessibilityIdentifier("audio.device.\(snapshot.id).mute.unavailable")

        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .accessibilityLabel(AppLocalization.string(.audioDeviceReadFailed))
                .accessibilityIdentifier("audio.device.\(snapshot.id).mute.failed")
        }
    }

    private var recoveryStatus: some View {
        HStack(spacing: 6) {
            Button(AppLocalization.string(.audioRetry)) {
                model.retryDevice(snapshot.id)
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("audio.device.\(snapshot.id).retry")
        }
    }

    private func volumeAccessibility(_ value: Double) -> String {
        AppLocalization.string(
            .audioVolumeAccessibility,
            snapshot.device.name,
            Int((value * 100).rounded())
        )
    }

    private func statusText(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(identifier)
    }
}

private struct AudioProcessControlRow: View {
    let presentation: AudioProcessRowPresentation
    @ObservedObject var model: AudioDashboardModel

    private var snapshot: AudioProcessControlSnapshot { presentation.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(snapshot.process.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 12)

                Slider(value: volumeBinding, in: 0...1)
                    .frame(maxWidth: 130)
                    .accessibilityLabel(volumeAccessibility)
                    .accessibilityIdentifier("audio.process.\(snapshot.id).volume.slider")

                Button {
                    model.setProcessMuted(!snapshot.isMuted, for: snapshot.id)
                } label: {
                    Image(systemName: snapshot.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string(
                    snapshot.isMuted ? .audioUnmuteAccessibility : .audioMuteAccessibility,
                    snapshot.process.name
                ))
                .accessibilityIdentifier("audio.process.\(snapshot.id).mute")

                routeMenu

                Button(AppLocalization.string(.audioReset)) {
                    model.reset(processObjectID: snapshot.id)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("audio.process.\(snapshot.id).reset")
            }

            processStatus
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audio.process.\(snapshot.id)")
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { snapshot.volume },
            set: { model.setProcessVolume($0, for: snapshot.id) }
        )
    }

    private var routeMenu: some View {
        Menu {
            Button {
                model.setProcessRoute(.followOriginal, for: snapshot.id)
            } label: {
                routeLabel(
                    AppLocalization.string(.audioRouteFollowOriginal),
                    selected: snapshot.route == .followOriginal
                )
            }

            Divider()
            ForEach(snapshot.routeOptions) { option in
                Toggle(isOn: routeBinding(for: option)) {
                    Text(option.isAvailable
                         ? option.name
                         : AppLocalization.string(.audioRouteDeviceUnavailable, option.name))
                }
                .disabled(option.isSelected && selectedRouteUIDs.count == 1)
                .accessibilityLabel(option.name)
                .accessibilityValue(option.isSelected ? "Selected" : "Not selected")
                .accessibilityIdentifier("audio.process.\(snapshot.id).route.\(option.uid)")
            }
        } label: {
            Label(AppLocalization.string(.audioRouteTitle), systemImage: "airplayaudio")
        }
        .help(AppLocalization.string(.audioRouteClearHelp))
        .accessibilityValue(routeAccessibilityValue)
        .accessibilityIdentifier("audio.process.\(snapshot.id).route")
    }

    private func routeBinding(for option: AudioRouteDeviceOption) -> Binding<Bool> {
        Binding(
            get: { option.isSelected },
            set: { selected in
                guard let uids = AudioDashboardRouteSelection.updating(
                    options: snapshot.routeOptions,
                    uid: option.uid,
                    selected: selected
                ) else { return }
                model.setProcessRoute(.explicit(targetDeviceUIDs: uids), for: snapshot.id)
            }
        )
    }

    private var selectedRouteUIDs: [String] {
        snapshot.routeOptions.filter(\.isSelected).map(\.uid)
    }

    private var routeAccessibilityValue: String {
        switch snapshot.route {
        case .followOriginal:
            return AppLocalization.string(.audioRouteFollowOriginal)
        case .explicit:
            return AppLocalization.string(.audioRouteSelectedSummary, selectedRouteUIDs.count)
        }
    }

    private var volumeAccessibility: String {
        AppLocalization.string(
            .audioVolumeAccessibility,
            snapshot.process.name,
            Int((snapshot.volume * 100).rounded())
        )
    }

    @ViewBuilder
    private var processStatus: some View {
        switch presentation.status {
        case .failed(let error):
            HStack(spacing: 8) {
                Text(error.map(errorText) ?? AppLocalization.string(.audioProcessOperationFailed))
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("audio.process.\(snapshot.id).error")
                Button(AppLocalization.string(.audioRetry)) {
                    model.retry(processObjectID: snapshot.id)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("audio.process.\(snapshot.id).retry")
            }
        case .preparing:
                Text(AppLocalization.string(.audioProcessPreparing))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("audio.process.\(snapshot.id).preparing")
        case .active:
                Text(AppLocalization.string(.audioProcessActive))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("audio.process.\(snapshot.id).active")
        case .idle:
                EmptyView()
        }
    }

    private func routeLabel(_ title: String, selected: Bool) -> some View {
        Label(title, systemImage: selected ? "checkmark" : "circle")
    }

    private func errorText(_ error: AudioControlUserError) -> String {
        switch error {
        case .permissionDenied:
            return AppLocalization.string(.audioProcessPermissionDenied)
        case .targetUnavailable:
            return AppLocalization.string(.audioProcessTargetUnavailable)
        case .deviceRead:
            return AppLocalization.string(.audioDeviceReadFailed)
        case .deviceWrite:
            return AppLocalization.string(.audioDeviceWriteFailed)
        case .operationFailed, .persistenceFailed:
            return AppLocalization.string(.audioProcessOperationFailed)
        }
    }
}

enum AudioDashboardRouteSelection {
    static func updating(
        options: [AudioRouteDeviceOption],
        uid: String,
        selected: Bool
    ) -> [String]? {
        var selectedUIDs = options.filter(\.isSelected).map(\.uid)
        if selected {
            guard !selectedUIDs.contains(uid) else { return selectedUIDs }
            selectedUIDs.append(uid)
        } else {
            selectedUIDs.removeAll { $0 == uid }
        }
        return selectedUIDs.isEmpty ? nil : selectedUIDs
    }
}

struct AudioDashboardPresentation {
    let devices: [AudioDeviceRowPresentation]
    let processSection: AudioProcessSectionPresentation?

    init(snapshot: AudioControlSnapshot, supportsProcessControls: Bool) {
        devices = snapshot.devices.map(AudioDeviceRowPresentation.init)
        processSection = supportsProcessControls
            ? AudioProcessSectionPresentation(processes: snapshot.processes.map(AudioProcessRowPresentation.init))
            : nil
    }

    var accessibilityIdentifiers: Set<String> {
        var result: Set<String> = ["audio.devices.section"]
        devices.forEach { result.formUnion($0.accessibilityIdentifiers) }
        if let processSection {
            result.insert("audio.processes.section")
            result.formUnion(processSection.accessibilityIdentifiers)
        }
        return result
    }
}

struct AudioProcessSectionPresentation {
    let processes: [AudioProcessRowPresentation]

    var accessibilityIdentifiers: Set<String> {
        if processes.isEmpty { return ["audio.processes.empty"] }
        return processes.reduce(into: Set<String>()) { result, row in
            result.formUnion(row.accessibilityIdentifiers)
        }
    }
}

enum AudioVolumeControlPresentation: Equatable {
    case slider(Double)
    case readOnly(Double)
    case unsupported
    case unavailable
    case failed

    var identifierSuffix: String {
        switch self {
        case .slider: return "volume.slider"
        case .readOnly: return "volume.readOnly"
        case .unsupported: return "volume.unsupported"
        case .unavailable: return "volume.unavailable"
        case .failed: return "volume.failed"
        }
    }
}

enum AudioMuteControlPresentation: Equatable {
    case button(Bool)
    case readOnly(Bool)
    case unsupported
    case unavailable
    case failed

    var identifierSuffix: String? {
        switch self {
        case .button: return "mute"
        case .readOnly: return "mute.readOnly"
        case .unsupported: return nil
        case .unavailable: return "mute.unavailable"
        case .failed: return "mute.failed"
        }
    }
}

struct AudioDeviceRowPresentation: Identifiable {
    let snapshot: AudioDeviceControlSnapshot
    let volume: AudioVolumeControlPresentation
    let mute: AudioMuteControlPresentation
    let showsRetry: Bool
    let showsWriteFailure: Bool

    var id: String { snapshot.id }
    var accessibilityPrefix: String { "audio.device.\(id)" }

    init(_ snapshot: AudioDeviceControlSnapshot) {
        self.snapshot = snapshot
        switch snapshot.device.volume {
        case .value(let value, isWritable: true): volume = .slider(value)
        case .value(let value, isWritable: false): volume = .readOnly(value)
        case .unsupported: volume = .unsupported
        case .unavailable: volume = .unavailable
        case .failed: volume = .failed
        }
        switch snapshot.device.mute {
        case .value(let value, isWritable: true): mute = .button(value)
        case .value(let value, isWritable: false): mute = .readOnly(value)
        case .unsupported: mute = .unsupported
        case .unavailable: mute = .unavailable
        case .failed: mute = .failed
        }
        showsRetry = snapshot.device.volume.needsAudioRetry
            || snapshot.device.mute.needsAudioRetry
            || snapshot.error != nil
        showsWriteFailure = snapshot.error == .deviceWrite
    }

    var accessibilityIdentifiers: Set<String> {
        var result: Set<String> = [
            accessibilityPrefix,
            "\(accessibilityPrefix).\(volume.identifierSuffix)"
        ]
        if let suffix = mute.identifierSuffix {
            result.insert("\(accessibilityPrefix).\(suffix)")
        }
        if showsRetry { result.insert("\(accessibilityPrefix).retry") }
        if showsWriteFailure { result.insert("\(accessibilityPrefix).writeFailed") }
        return result
    }
}

enum AudioProcessStatusPresentation: Equatable {
    case idle
    case preparing
    case active
    case failed(AudioControlUserError?)
}

struct AudioProcessRowPresentation: Identifiable {
    let snapshot: AudioProcessControlSnapshot
    let status: AudioProcessStatusPresentation

    var id: AudioObjectID { snapshot.id }
    var accessibilityPrefix: String { "audio.process.\(id)" }

    init(_ snapshot: AudioProcessControlSnapshot) {
        self.snapshot = snapshot
        if let error = snapshot.error {
            status = .failed(error)
        } else {
            switch snapshot.session.state {
            case .idle: status = .idle
            case .preparing, .rebuilding, .stopping: status = .preparing
            case .running: status = .active
            case .failed: status = .failed(nil)
            }
        }
    }

    var accessibilityIdentifiers: Set<String> {
        var result: Set<String> = [
            accessibilityPrefix,
            "\(accessibilityPrefix).volume.slider",
            "\(accessibilityPrefix).mute",
            "\(accessibilityPrefix).route",
            "\(accessibilityPrefix).reset"
        ]
        snapshot.routeOptions.forEach {
            result.insert("\(accessibilityPrefix).route.\($0.uid)")
        }
        if case .failed = status { result.insert("\(accessibilityPrefix).retry") }
        return result
    }
}

private extension AudioPropertyValue {
    var needsAudioRetry: Bool {
        switch self {
        case .unavailable, .failed: return true
        case .value, .unsupported: return false
        }
    }
}
