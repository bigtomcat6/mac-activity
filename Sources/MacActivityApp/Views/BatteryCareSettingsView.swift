import AppKit
import SwiftUI
import MacActivityBatteryControl

struct BatteryCareSettingsView: NSViewRepresentable {
    @ObservedObject var model: BatteryCareModel

    func makeNSView(context: Context) -> BatteryCareNativeSettings { BatteryCareNativeSettings(model: model) }
    func updateNSView(_ view: BatteryCareNativeSettings, context: Context) { view.update(model.presentation) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BatteryCareNativeSettings, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}

/// Backend strings are diagnostic tokens, never localized user messages.
enum BatteryCareText {
    static func string(_ key: AppLocalization.Key) -> String { AppLocalization.string(key) }
    static func percent(_ key: AppLocalization.Key, _ value: Int) -> String { String(format: string(key), value) }

    static func reason(_ reason: BatteryCarePresentation.DisabledReason?) -> String? {
        guard let reason else { return nil }
        let key: AppLocalization.Key
        switch reason {
        case .noInternalBattery: key = .batteryCareNoBattery
        case .unknownBattery, .sampleUnknown: key = .batteryCareSampleUnknown
        case .unverified: key = .batteryCareUnverified
        case .unsupported(let token): return backendReason(token, fallback: .batteryCareUnsupported)
        case .notAuthorized: key = .batteryCareNotAuthorized
        case .managementDisabled: key = .batteryCareDisabled
        case .noExternalPower: key = .batteryCareAwaitPower
        case .recoveryUnconfirmed: key = .batteryCareRecovery
        case .suspended: key = .batteryCareSuspended
        case .temporaryModeActive: key = .batteryCareTemporaryActive
        case .regularAlreadyAllowsFull: key = .batteryCareRegularAlreadyAllowsFull
        }
        return string(key)
    }

    static func backendReason(_ token: String, fallback: AppLocalization.Key = .batteryCareRejected) -> String {
        let key: AppLocalization.Key
        switch token {
        case "helperIncompatible", "helperVersionIncompatible": key = .batteryCareHelperIncompatible
        case "serviceUnavailable", "helperMissing", "disconnected": key = .batteryCareUnavailable
        case "authorizationDenied", "notAuthorized": key = .batteryCareNotAuthorized
        case "releaseUnconfirmed", "temporaryExitEvidenceUnavailable": key = .batteryCareRecovery
        case "regularAlreadyAllowsFull": key = .batteryCareRegularAlreadyAllowsFull
        default: key = fallback
        }
        return string(key)
    }

    static func status(_ p: BatteryCarePresentation) -> String {
        if let failure = p.saveFailure {
            return string(failure == .limit ? .batteryCareSaveLimitFailed :
                failure == .enable ? .batteryCareSaveEnableFailed : .batteryCareSaveDisableFailed)
        }
        if p.lastIntent == .stopDischarge || p.lastIntent == .cancelFullCharge {
            if p.isPending { return string(.batteryCareStopping) }
        }
        if p.requestOutcome == .outcomeUnknown { return string(.batteryCareOutcomeUnknown) }
        if p.recoveryStatus == .unconfirmed || p.recoveryStatus == .conflict { return string(.batteryCareRecovery) }
        if p.isPending { return string(.batteryCareSubmitting) }
        if case .rejected(let token) = p.requestOutcome { return backendReason(token) }
        if let target = p.effectiveTarget {
            switch target {
            case .regular(let value): return percent(.batteryCareRegularTarget, value)
            case .discharge(let value): return percent(.batteryCareDischargeTarget, value)
            case .fullCharge: return string(.batteryCareFullTarget)
            case .systemManaged: return string(.batteryCareSystemManaged)
            }
        }
        if p.requestOutcome == .accepted { return string(.batteryCareAccepted) }
        if let token = p.pauseReason { return backendReason(token, fallback: .batteryCareSuspended) }
        if !p.savedEnabled { return string(.batteryCareDisabled) }
        if p.sample?.externalPower == false { return string(.batteryCareAwaitPower) }
        return string(.batteryCareTargetUnknown)
    }

    static func capability(_ capability: BatteryCareCapability?) -> String {
        switch capability {
        case .verified: string(.batteryCareVerified)
        case .unsupported(let token): backendReason(token, fallback: .batteryCareUnsupported)
        default: string(.batteryCareUnverified)
        }
    }
}

final class BatteryCareActionButton: NSButton {
    var perform: () -> Void = {}
    init() {
        super.init(frame: .zero)
        target = self
        action = #selector(invoke)
        bezelStyle = .rounded
        cell?.wraps = true
        cell?.lineBreakMode = .byWordWrapping
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    @objc private func invoke() { guard isEnabled else { return }; perform() }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }
}

final class BatteryCareNativeSettings: NSStackView {
    private let management = BatteryCareActionButton()
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let reason = NSTextField(wrappingLabelWithString: "")
    private let authorization = NSTextField(wrappingLabelWithString: "")
    private let capabilities = BatteryCareOperation.allCases.map { _ in NSTextField(wrappingLabelWithString: "") }
    private let recovery = NSTextField(wrappingLabelWithString: "")
    private let retry = BatteryCareActionButton()

    init(model: BatteryCareModel) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        management.setButtonType(.switch)
        management.setAccessibilityIdentifier("batteryCare.management")
        management.perform = { [weak model, weak management] in
            guard let model, let management else { return }
            let enabled = management.state == .on
            Task { await model.setManagementEnabled(enabled) }
        }
        retry.perform = { [weak model] in Task { await model?.retryRegular() } }
        for view in [management, explanation, reason, authorization] + capabilities + [recovery, retry] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: 308).isActive = true
            if let field = view as? NSTextField { field.preferredMaxLayoutWidth = 308 }
        }
        update(model.presentation)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ p: BatteryCarePresentation) {
        management.title = BatteryCareText.string(.batteryCareEnable)
        management.state = p.savedEnabled ? .on : .off
        let action = p.savedEnabled ? p.disableManagement : p.enableManagement
        management.isEnabled = action.isEnabled
        let disabledReason = BatteryCareText.reason(action.disabledReason)
        management.setAccessibilityHelp(disabledReason)
        reason.stringValue = disabledReason ?? BatteryCareText.status(p)
        explanation.stringValue = BatteryCareText.string(.batteryCareExplanation)
        authorization.stringValue = BatteryCareText.string(.batteryCareAuthorization) + ": " +
            BatteryCareText.string(p.authorization == .authorized ? .batteryCareAuthorized : .batteryCareNotAuthorized)
        let names: [AppLocalization.Key] = [.batteryCareRegularOperation, .batteryCareDischargeOperation,
                                           .batteryCareFullOperation, .batteryCareReleaseOperation]
        for (index, operation) in BatteryCareOperation.allCases.enumerated() {
            capabilities[index].stringValue = BatteryCareText.string(names[index]) + ": " + BatteryCareText.capability(p.capabilities[operation])
        }
        recovery.stringValue = BatteryCareText.string(p.recoveryStatus == .released ? .batteryCareReleased : .batteryCareRecovery)
            + "\n" + BatteryCareText.status(p)
        retry.title = BatteryCareText.string(.batteryCareRetry)
        retry.isHidden = !p.requiresRetry
        retry.isEnabled = p.retryRegular.isEnabled
        retry.setAccessibilityHelp(BatteryCareText.reason(p.retryRegular.disabledReason))
    }
}
