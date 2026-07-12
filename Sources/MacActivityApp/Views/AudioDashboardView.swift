import SwiftUI
import CoreAudio
import MacActivityCore

struct AudioAccessibilityContract: Equatable {
    let identifier: String
    let label: String?
    let value: String?
    let isEnabled: Bool

    init(
        identifier: String,
        label: String? = nil,
        value: String? = nil,
        isEnabled: Bool = true
    ) {
        self.identifier = identifier
        self.label = label
        self.value = value
        self.isEnabled = isEnabled
    }
}

private func audioTargetLabel(_ localized: String, target: String) -> String {
    localized.contains(target) ? localized : "\(target), \(localized)"
}

private struct AudioAccessibilityModifier: ViewModifier {
    let contract: AudioAccessibilityContract

    @ViewBuilder
    func body(content: Content) -> some View {
        if let label = contract.label, let value = contract.value {
            content
                .accessibilityIdentifier(contract.identifier)
                .accessibilityLabel(label)
                .accessibilityValue(value)
                .disabled(!contract.isEnabled)
        } else if let label = contract.label {
            content
                .accessibilityIdentifier(contract.identifier)
                .accessibilityLabel(label)
                .disabled(!contract.isEnabled)
        } else if let value = contract.value {
            content
                .accessibilityIdentifier(contract.identifier)
                .accessibilityValue(value)
                .disabled(!contract.isEnabled)
        } else {
            content
                .accessibilityIdentifier(contract.identifier)
                .disabled(!contract.isEnabled)
        }
    }
}

extension View {
    func audioAccessibility(_ contract: AudioAccessibilityContract) -> some View {
        modifier(AudioAccessibilityModifier(contract: contract))
    }
}

@MainActor
enum AudioDashboardControlBindings {
    static func deviceVolume(
        model: AudioDashboardModel,
        deviceUID: String,
        fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: {
                guard let row = model.snapshot.devices.first(where: { $0.id == deviceUID }),
                      case .value(let value, _) = row.device.volume else { return fallback }
                return value
            },
            set: { value in
                guard let row = model.snapshot.devices.first(where: { $0.id == deviceUID }),
                      row.device.volume.isWritable else { return }
                model.setDeviceVolume(value, for: deviceUID)
            }
        )
    }

    static func processVolume(
        model: AudioDashboardModel,
        processObjectID: AudioObjectID,
        fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: {
                model.snapshot.processes.first(where: { $0.id == processObjectID })?.volume
                    ?? fallback
            },
            set: { value in
                guard model.snapshot.processes.contains(where: { $0.id == processObjectID }) else {
                    return
                }
                model.setProcessVolume(value, for: processObjectID)
            }
        )
    }

    static func routeTarget(
        model: AudioDashboardModel,
        processObjectID: AudioObjectID,
        deviceUID: String
    ) -> Binding<Bool> {
        Binding(
            get: {
                guard let row = model.snapshot.processes.first(where: { $0.id == processObjectID }),
                      case .explicit(let uids) = row.route else { return false }
                return uids.contains(deviceUID)
            },
            set: { selected in
                guard let row = model.snapshot.processes.first(where: { $0.id == processObjectID }),
                      let uids = AudioDashboardRouteSelection.updating(
                        route: row.route,
                        options: row.routeOptions,
                        uid: deviceUID,
                        selected: selected
                      ) else { return }
                model.setProcessRoute(
                    .explicit(targetDeviceUIDs: uids), for: processObjectID
                )
            }
        )
    }

    static func toggleDeviceMute(model: AudioDashboardModel, deviceUID: String) {
        guard let row = model.snapshot.devices.first(where: { $0.id == deviceUID }),
              case .value(let current, isWritable: true) = row.device.mute else { return }
        model.setDeviceMuted(!current, for: deviceUID)
    }

    static func toggleProcessMute(
        model: AudioDashboardModel,
        processObjectID: AudioObjectID
    ) {
        guard let row = model.snapshot.processes.first(where: { $0.id == processObjectID })
        else { return }
        model.setProcessMuted(!row.isMuted, for: processObjectID)
    }
}

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
                accessibility: presentation.devicesAccessibility
            ) {
                ForEach(presentation.devices) { device in
                    AudioDeviceControlRow(presentation: device, model: model)
                }
            }

            if let processSection = presentation.processSection {
                AudioDashboardSection(
                    title: AppLocalization.string(.audioProcessesTitle),
                    accessibility: processSection.accessibility
                ) {
                    if processSection.processes.isEmpty {
                        Text(AppLocalization.string(.audioProcessesEmpty))
                            .foregroundStyle(.secondary)
                            .audioAccessibility(processSection.emptyAccessibility)
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
    let accessibility: AudioAccessibilityContract
    let content: Content

    init(
        title: String,
        accessibility: AudioAccessibilityContract,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessibility = accessibility
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
        .audioAccessibility(accessibility)
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

            if let retryAccessibility = presentation.retryAccessibility {
                recoveryStatus
                    .audioAccessibility(retryAccessibility)
            }

            if let writeFailureAccessibility = presentation.writeFailureAccessibility {
                Text(AppLocalization.string(.audioDeviceWriteFailed))
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .audioAccessibility(writeFailureAccessibility)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .accessibilityElement(children: .contain)
        .audioAccessibility(presentation.rowAccessibility)
    }

    @ViewBuilder
    private var volumeControl: some View {
        switch presentation.volume {
        case .slider(let value):
            Slider(
                value: AudioDashboardControlBindings.deviceVolume(
                    model: model, deviceUID: snapshot.id, fallback: value
                ),
                in: 0...1
            )
            .audioAccessibility(presentation.volumeAccessibility)

        case .readOnly(let value):
            Text(value, format: .percent.precision(.fractionLength(0)))
                .foregroundStyle(.secondary)
                .audioAccessibility(presentation.volumeAccessibility)

        case .unsupported:
            Text(AppLocalization.string(.audioUnsupportedDeviceVolume))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .audioAccessibility(presentation.volumeAccessibility)

        case .unavailable:
            statusText(AppLocalization.string(.audioDeviceUnavailable))
                .audioAccessibility(presentation.volumeAccessibility)

        case .failed:
            statusText(AppLocalization.string(.audioDeviceReadFailed))
                .audioAccessibility(presentation.volumeAccessibility)
        }
    }

    @ViewBuilder
    private var muteControl: some View {
        switch presentation.mute {
        case .button(let isMuted):
            Button {
                AudioDashboardControlBindings.toggleDeviceMute(
                    model: model, deviceUID: snapshot.id
                )
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .audioAccessibility(presentation.muteAccessibility)

        case .readOnly(let isMuted):
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
                .audioAccessibility(presentation.muteAccessibility)

        case .unsupported:
            EmptyView()

        case .unavailable(let text):
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .audioAccessibility(presentation.muteAccessibility)

        case .failed(let text):
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .audioAccessibility(presentation.muteAccessibility)
        }
    }

    private var recoveryStatus: some View {
        HStack(spacing: 6) {
            Button(AppLocalization.string(.audioRetry)) {
                model.retryDevice(snapshot.id)
            }
            .buttonStyle(.link)
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
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
                    .audioAccessibility(presentation.volumeAccessibility)

                Button {
                    AudioDashboardControlBindings.toggleProcessMute(
                        model: model, processObjectID: snapshot.id
                    )
                } label: {
                    Image(systemName: snapshot.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .audioAccessibility(presentation.muteAccessibility)

                routeMenu

                Button(AppLocalization.string(.audioReset)) {
                    model.reset(processObjectID: snapshot.id)
                }
                .buttonStyle(.link)
                .audioAccessibility(presentation.resetAccessibility)
            }

            processStatus
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .accessibilityElement(children: .contain)
        .audioAccessibility(presentation.rowAccessibility)
    }

    private var volumeBinding: Binding<Double> {
        AudioDashboardControlBindings.processVolume(
            model: model,
            processObjectID: snapshot.id,
            fallback: snapshot.volume
        )
    }

    private var routeMenu: some View {
        Menu {
            Button {
                guard model.snapshot.processes.contains(where: { $0.id == snapshot.id }) else {
                    return
                }
                model.setProcessRoute(.followOriginal, for: snapshot.id)
            } label: {
                routeLabel(
                    AppLocalization.string(.audioRouteFollowOriginal),
                    selected: snapshot.route == .followOriginal
                )
            }

            Divider()
            ForEach(snapshot.routeOptions) { option in
                let contract = presentation.routeTargetAccessibility(option)
                Toggle(isOn: routeBinding(for: option)) {
                    Text(contract.label ?? option.name)
                }
                .audioAccessibility(contract)
            }
        } label: {
            Label(AppLocalization.string(.audioRouteTitle), systemImage: "airplayaudio")
        }
        .help(AppLocalization.string(.audioRouteClearHelp))
        .audioAccessibility(presentation.routeAccessibility)
    }

    private func routeBinding(for option: AudioRouteDeviceOption) -> Binding<Bool> {
        AudioDashboardControlBindings.routeTarget(
            model: model,
            processObjectID: snapshot.id,
            deviceUID: option.uid
        )
    }

    @ViewBuilder
    private var processStatus: some View {
        switch presentation.status {
        case .failed:
            HStack(spacing: 8) {
                Text(presentation.statusAccessibility?.label
                     ?? AppLocalization.string(.audioProcessOperationFailed))
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .audioAccessibility(presentation.statusAccessibility
                        ?? AudioAccessibilityContract(
                            identifier: "audio.process.\(snapshot.id).error"
                        ))
                if let retryAccessibility = presentation.retryAccessibility {
                    Button(AppLocalization.string(.audioRetry)) {
                        model.retry(processObjectID: snapshot.id)
                    }
                    .buttonStyle(.link)
                    .audioAccessibility(retryAccessibility)
                }
            }
        case .preparing:
            processStatusText
        case .rebuilding:
            processStatusText
        case .running:
            processStatusText
        case .stopping:
            processStatusText
        case .idle:
                EmptyView()
        }
    }

    @ViewBuilder
    private var processStatusText: some View {
        if let accessibility = presentation.statusAccessibility {
            Text(accessibility.label ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .audioAccessibility(accessibility)
        }
    }

    private func routeLabel(_ title: String, selected: Bool) -> some View {
        Label(title, systemImage: selected ? "checkmark" : "circle")
    }

}

enum AudioDashboardRouteSelection {
    static func updating(
        route: AudioRouteMode,
        options: [AudioRouteDeviceOption],
        uid: String,
        selected: Bool
    ) -> [String]? {
        guard options.contains(where: { $0.uid == uid }) else { return nil }
        var selectedUIDs: [String]
        switch route {
        case .followOriginal:
            selectedUIDs = []
        case .explicit(let targetDeviceUIDs):
            selectedUIDs = targetDeviceUIDs
        }
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
    let devicesAccessibility = AudioAccessibilityContract(
        identifier: "audio.devices.section",
        label: AppLocalization.string(.audioDevicesTitle)
    )

    init(snapshot: AudioControlSnapshot, supportsProcessControls: Bool) {
        devices = snapshot.devices.map(AudioDeviceRowPresentation.init)
        processSection = supportsProcessControls
            ? AudioProcessSectionPresentation(processes: snapshot.processes.map(AudioProcessRowPresentation.init))
            : nil
    }

    var accessibilityContracts: [AudioAccessibilityContract] {
        [devicesAccessibility]
            + devices.flatMap(\.accessibilityContracts)
            + (processSection?.accessibilityContracts ?? [])
    }
}

struct AudioProcessSectionPresentation {
    let processes: [AudioProcessRowPresentation]
    let accessibility = AudioAccessibilityContract(
        identifier: "audio.processes.section",
        label: AppLocalization.string(.audioProcessesTitle)
    )

    var emptyAccessibility: AudioAccessibilityContract {
        let text = AppLocalization.string(.audioProcessesEmpty)
        return AudioAccessibilityContract(
            identifier: "audio.processes.empty", label: text, value: text
        )
    }

    var accessibilityContracts: [AudioAccessibilityContract] {
        [accessibility] + (processes.isEmpty ? [emptyAccessibility] : [])
            + processes.flatMap(\.accessibilityContracts)
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
    case unavailable(String)
    case failed(String)

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

    var id: String { snapshot.id }
    var accessibilityPrefix: String { "audio.device.\(id)" }
    var rowAccessibility: AudioAccessibilityContract {
        AudioAccessibilityContract(identifier: accessibilityPrefix, label: snapshot.device.name)
    }
    var volumeAccessibility: AudioAccessibilityContract {
        let identifier = "\(accessibilityPrefix).\(volume.identifierSuffix)"
        switch volume {
        case .slider(let value):
            return AudioAccessibilityContract(
                identifier: identifier,
                label: audioTargetLabel(
                    AppLocalization.string(
                        .audioVolumeAccessibility, snapshot.device.name,
                        Int((value * 100).rounded())
                    ), target: snapshot.device.name
                ),
                value: value.formatted(.percent.precision(.fractionLength(0)))
            )
        case .readOnly(let value):
            return AudioAccessibilityContract(
                identifier: identifier,
                label: audioTargetLabel(
                    AppLocalization.string(
                        .audioVolumeAccessibility, snapshot.device.name,
                        Int((value * 100).rounded())
                    ), target: snapshot.device.name
                ),
                value: value.formatted(.percent.precision(.fractionLength(0)))
            )
        case .unsupported:
            let text = AppLocalization.string(.audioUnsupportedDeviceVolume)
            return AudioAccessibilityContract(identifier: identifier, label: text, value: text)
        case .unavailable:
            let text = AppLocalization.string(.audioDeviceUnavailable)
            return AudioAccessibilityContract(identifier: identifier, label: text, value: text)
        case .failed:
            let text = AppLocalization.string(.audioDeviceReadFailed)
            return AudioAccessibilityContract(identifier: identifier, label: text, value: text)
        }
    }
    var retryAccessibility: AudioAccessibilityContract? {
        guard snapshot.device.volume.needsAudioRetry
                || snapshot.device.mute.needsAudioRetry
                || snapshot.error != nil else { return nil }
        return AudioAccessibilityContract(
            identifier: "\(accessibilityPrefix).retry",
            label: AppLocalization.string(.audioRetry)
        )
    }
    var writeFailureAccessibility: AudioAccessibilityContract? {
        guard snapshot.error == .deviceWrite else { return nil }
        let text = AppLocalization.string(.audioDeviceWriteFailed)
        return AudioAccessibilityContract(
            identifier: "\(accessibilityPrefix).writeFailed", label: text, value: text
        )
    }

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
        case .unavailable:
            mute = .unavailable(
                "\(snapshot.device.name) \(AppLocalization.string(.audioDeviceUnavailable))"
            )
        case .failed:
            mute = .failed(
                "\(snapshot.device.name) \(AppLocalization.string(.audioDeviceReadFailed))"
            )
        }
    }

    var muteAccessibility: AudioAccessibilityContract {
        let identifier = "\(accessibilityPrefix).\(mute.identifierSuffix ?? "mute")"
        switch mute {
        case .button(let isMuted):
            return AudioAccessibilityContract(
                identifier: identifier,
                label: audioTargetLabel(
                    AppLocalization.string(
                        isMuted ? .audioUnmuteAccessibility : .audioMuteAccessibility,
                        snapshot.device.name
                    ), target: snapshot.device.name
                ),
                value: AppLocalization.string(isMuted ? .audioMuted : .audioNotMuted)
            )
        case .readOnly(let isMuted):
            return AudioAccessibilityContract(
                identifier: identifier,
                label: snapshot.device.name,
                value: AppLocalization.string(isMuted ? .audioMuted : .audioNotMuted)
            )
        case .unsupported:
            return AudioAccessibilityContract(identifier: identifier)
        case .unavailable(let text), .failed(let text):
            return AudioAccessibilityContract(identifier: identifier, label: text, value: text)
        }
    }

    var accessibilityContracts: [AudioAccessibilityContract] {
        [rowAccessibility, volumeAccessibility]
            + (mute.identifierSuffix == nil ? [] : [muteAccessibility])
            + (retryAccessibility.map { [$0] } ?? [])
            + (writeFailureAccessibility.map { [$0] } ?? [])
    }
}

enum AudioProcessStatusPresentation: Equatable {
    case idle
    case preparing
    case rebuilding
    case running
    case stopping
    case failed(AudioControlUserError?)
}

struct AudioProcessRowPresentation: Identifiable {
    let snapshot: AudioProcessControlSnapshot
    let status: AudioProcessStatusPresentation

    var id: AudioObjectID { snapshot.id }
    var accessibilityPrefix: String { "audio.process.\(id)" }
    var rowAccessibility: AudioAccessibilityContract {
        AudioAccessibilityContract(identifier: accessibilityPrefix, label: snapshot.process.name)
    }
    var volumeAccessibility: AudioAccessibilityContract {
        AudioAccessibilityContract(
            identifier: "\(accessibilityPrefix).volume.slider",
            label: audioTargetLabel(
                AppLocalization.string(
                    .audioVolumeAccessibility, snapshot.process.name,
                    Int((snapshot.volume * 100).rounded())
                ), target: snapshot.process.name
            ),
            value: snapshot.volume.formatted(.percent.precision(.fractionLength(0)))
        )
    }
    var muteAccessibility: AudioAccessibilityContract {
        AudioAccessibilityContract(
            identifier: "\(accessibilityPrefix).mute",
            label: audioTargetLabel(
                AppLocalization.string(
                    snapshot.isMuted ? .audioUnmuteAccessibility : .audioMuteAccessibility,
                    snapshot.process.name
                ), target: snapshot.process.name
            ),
            value: AppLocalization.string(snapshot.isMuted ? .audioMuted : .audioNotMuted)
        )
    }
    var routeAccessibility: AudioAccessibilityContract {
        AudioAccessibilityContract(
            identifier: "\(accessibilityPrefix).route",
            label: AppLocalization.string(.audioRouteTitle),
            value: routeValue
        )
    }
    var resetAccessibility: AudioAccessibilityContract {
        AudioAccessibilityContract(
            identifier: "\(accessibilityPrefix).reset",
            label: AppLocalization.string(.audioReset)
        )
    }
    var retryAccessibility: AudioAccessibilityContract? {
        guard case .failed = status else { return nil }
        return AudioAccessibilityContract(
            identifier: "\(accessibilityPrefix).retry",
            label: AppLocalization.string(.audioRetry)
        )
    }

    func routeTargetAccessibility(_ option: AudioRouteDeviceOption) -> AudioAccessibilityContract {
        let selectedUIDs = snapshot.route.targetDeviceUIDs
        let title: String
        if option.isAvailable {
            title = option.name
        } else {
            title = audioTargetLabel(
                AppLocalization.string(.audioRouteDeviceUnavailable, option.name),
                target: option.name
            )
        }
        return AudioAccessibilityContract(
            identifier: "\(accessibilityPrefix).route.\(option.uid)",
            label: title,
            isEnabled: !(selectedUIDs.contains(option.uid) && selectedUIDs.count == 1)
        )
    }

    init(_ snapshot: AudioProcessControlSnapshot) {
        self.snapshot = snapshot
        if let error = snapshot.error {
            status = .failed(error)
        } else {
            switch snapshot.session.state {
            case .idle: status = .idle
            case .preparing: status = .preparing
            case .rebuilding: status = .rebuilding
            case .running: status = .running
            case .stopping: status = .stopping
            case .failed: status = .failed(nil)
            }
        }
    }

    var statusAccessibility: AudioAccessibilityContract? {
        let pair: (String, String)?
        switch status {
        case .idle: pair = nil
        case .preparing: pair = ("preparing", AppLocalization.string(.audioProcessPreparing))
        case .rebuilding: pair = ("rebuilding", AppLocalization.string(.audioProcessRebuilding))
        case .running: pair = ("running", AppLocalization.string(.audioProcessActive))
        case .stopping: pair = ("stopping", AppLocalization.string(.audioProcessStopping))
        case .failed(let error):
            pair = ("error", Self.errorText(error))
        }
        guard let pair else { return nil }
        return AudioAccessibilityContract(
            identifier: "\(accessibilityPrefix).\(pair.0)", label: pair.1, value: pair.1
        )
    }

    var accessibilityContracts: [AudioAccessibilityContract] {
        [rowAccessibility, volumeAccessibility, muteAccessibility, routeAccessibility,
         resetAccessibility]
            + snapshot.routeOptions.map(routeTargetAccessibility)
            + (statusAccessibility.map { [$0] } ?? [])
            + (retryAccessibility.map { [$0] } ?? [])
    }

    private var routeValue: String {
        switch snapshot.route {
        case .followOriginal:
            return AppLocalization.string(.audioRouteFollowOriginal)
        case .explicit(let targetDeviceUIDs):
            return AppLocalization.string(.audioRouteSelectedSummary, targetDeviceUIDs.count)
        }
    }

    private static func errorText(_ error: AudioControlUserError?) -> String {
        guard let error else { return AppLocalization.string(.audioProcessOperationFailed) }
        switch error {
        case .permissionDenied: return AppLocalization.string(.audioProcessPermissionDenied)
        case .targetUnavailable: return AppLocalization.string(.audioProcessTargetUnavailable)
        case .deviceRead: return AppLocalization.string(.audioDeviceReadFailed)
        case .deviceWrite: return AppLocalization.string(.audioDeviceWriteFailed)
        case .operationFailed, .persistenceFailed:
            return AppLocalization.string(.audioProcessOperationFailed)
        }
    }
}

private extension AudioRouteMode {
    var targetDeviceUIDs: [String] {
        guard case .explicit(let targetDeviceUIDs) = self else { return [] }
        return targetDeviceUIDs
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
