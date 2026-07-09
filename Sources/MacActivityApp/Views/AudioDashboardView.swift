import SwiftUI
import MacActivityCore

struct AudioDashboardView: View {
    @ObservedObject var model: AudioDashboardModel

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            AudioDashboardSection(title: AppLocalization.string(.audioDevicesTitle)) {
                ForEach(model.devices) { device in
                    AudioDeviceVolumeRow(device: device, model: model)
                }
            }

            if model.showsProcessControls {
                AudioDashboardSection(title: AppLocalization.string(.audioProcessesTitle)) {
                    ForEach(model.processes) { process in
                        AudioProcessVolumeRow(process: process, model: model)
                    }
                }
            }
        }
        .task {
            model.refresh()
        }
    }
}

private struct AudioDashboardSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            content
        }
    }
}

private struct AudioDeviceVolumeRow: View {
    let device: AudioOutputDeviceVolume
    @ObservedObject var model: AudioDashboardModel

    private var showsUnsupportedStatus: Bool {
        device.volumeAvailability != .writable || device.muteAvailability != .writable
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                if showsUnsupportedStatus {
                    Text(AppLocalization.string(.audioUnsupportedShort))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            Slider(value: deviceVolumeBinding, in: 0...1)
                .frame(maxWidth: 130)

            Button {
                model.setDeviceMuted(!device.isMuted, for: device.id)
            } label: {
                Image(systemName: device.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .disabled(device.muteAvailability != .writable)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .disabled(device.volumeAvailability != .writable)
    }

    private var deviceVolumeBinding: Binding<Double> {
        Binding(
            get: { device.volume },
            set: { newValue in
                model.setDeviceVolume(newValue, for: device.id)
            }
        )
    }
}

private struct AudioProcessVolumeRow: View {
    let process: AudioProcessEntry
    @ObservedObject var model: AudioDashboardModel
    @State private var volume = 1.0
    @State private var isMuted = false

    var body: some View {
        HStack(spacing: 10) {
            Text(process.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 12)

            Slider(value: volumeBinding, in: 0...1)
                .frame(maxWidth: 130)

            Button {
                isMuted.toggle()
                model.setProcessMuted(isMuted, for: process.processIdentifier)
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { volume },
            set: { newValue in
                volume = newValue
                if isMuted && newValue > 0 {
                    isMuted = false
                    model.setProcessMuted(false, for: process.processIdentifier)
                }
                model.setProcessVolume(newValue, for: process.processIdentifier)
            }
        )
    }
}
