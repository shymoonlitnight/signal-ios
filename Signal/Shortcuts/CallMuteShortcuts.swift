//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AppIntents
import AVFoundation
import Foundation

@available(iOS 16.0, *)
enum CallMuteShortcutError: LocalizedError, Equatable {
    case noActiveCall
    case callEnded
    case unableToChangeMuteState

    var errorDescription: String? {
        switch self {
        case .noActiveCall:
            return "No active call."
        case .callEnded:
            return "The call has already ended."
        case .unableToChangeMuteState:
            return "Unable to change microphone mute state right now."
        }
    }
}

@available(iOS 16.0, *)
private func withCurrentCall<T>(
    _ work: @MainActor (CallService, SignalCall) async throws -> T
) async throws -> T {
    let (callService, call) = try await MainActor.run {
        guard let callService = AppEnvironment.shared.callService else {
            throw CallMuteShortcutError.noActiveCall
        }
        guard let call = callService.callServiceState.currentCall else {
            throw CallMuteShortcutError.noActiveCall
        }
        if call.hasTerminated {
            throw CallMuteShortcutError.callEnded
        }
        return (callService, call)
    }

    return try await work(callService, call)
}

@available(iOS 16.0, *)
private protocol CallShortcutIntent: AppIntent {}

@available(iOS 16.0, *)
extension CallShortcutIntent {
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { true }
}

@available(iOS 16.0, *)
@MainActor
private func applyMutedStateDirectly(
    _ isMuted: Bool,
    callService: CallService,
    call: SignalCall
) {
    switch call.mode {
    case .groupThread(let groupCall as GroupCall), .callLink(let groupCall as GroupCall):
        groupCall.ringRtcCall.isOutgoingAudioMuted = isMuted
        groupCall.groupCall(onLocalDeviceStateChanged: groupCall.ringRtcCall)
    case .individual(let individualCall):
        individualCall.isMuted = isMuted
        callService.individualCallService.ensureAudioState(call: call)
    }
}

@available(iOS 16.0, *)
@MainActor
private func waitForMuteState(
    _ targetState: Bool,
    call: SignalCall
) async -> Bool {
    for _ in 0..<20 {
        if call.isOutgoingAudioMuted == targetState {
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return call.isOutgoingAudioMuted == targetState
}

@available(iOS 16.0, *)
@MainActor
private func setMicrophoneMuteState(
    _ isMuted: Bool,
    callService: CallService,
    call: SignalCall
) async throws -> Bool {
    if isMuted || AVAudioSession.sharedInstance().recordPermission == .granted {
        // Keep shortcut-specific behavior isolated from shared call controls:
        // when permission is already granted, apply mute/unmute directly so this
        // works while locked/backgrounded or without visible call controls.
        applyMutedStateDirectly(isMuted, callService: callService, call: call)
    } else {
        // Fall back to existing app flow so permission UI and existing behavior
        // are unchanged when unmuting requires permission.
        callService.updateIsLocalAudioMuted(isLocalAudioMuted: isMuted)
    }

    guard await waitForMuteState(isMuted, call: call) else {
        throw CallMuteShortcutError.unableToChangeMuteState
    }

    callService.callUIAdapter.setIsMuted(call: call, isMuted: isMuted)
    return call.isOutgoingAudioMuted
}

@available(iOS 16.0, *)
struct ToggleMicrophoneMuteIntent: CallShortcutIntent {
    static var title: LocalizedStringResource = "Toggle Microphone Mute"
    static var description = IntentDescription("Toggle microphone mute for the current call.")

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let isMuted = try await withCurrentCall { callService, call in
            return try await setMicrophoneMuteState(!call.isOutgoingAudioMuted, callService: callService, call: call)
        }
        return .result(value: isMuted)
    }
}

@available(iOS 16.0, *)
struct SetMicrophoneMuteIntent: CallShortcutIntent {
    static var title: LocalizedStringResource = "Set Microphone Mute"
    static var description = IntentDescription("Set microphone mute for the current call.")

    @Parameter(title: "Muted")
    var isMuted: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set microphone mute to \(\.$isMuted)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let updatedMuteState = try await withCurrentCall { callService, call in
            return try await setMicrophoneMuteState(self.isMuted, callService: callService, call: call)
        }
        return .result(value: updatedMuteState)
    }
}

@available(iOS 16.0, *)
struct GetMicrophoneMuteStateIntent: CallShortcutIntent {
    static var title: LocalizedStringResource = "Get Microphone Mute State"
    static var description = IntentDescription("Get microphone mute state for the current call.")

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let isMuted = try await withCurrentCall { _, call in
            call.isOutgoingAudioMuted
        }
        return .result(value: isMuted)
    }
}

@available(iOS 16.0, *)
struct GetActiveCallStateIntent: CallShortcutIntent {
    static var title: LocalizedStringResource = "Get Active Call State"
    static var description = IntentDescription("Get whether there is an active call.")

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let hasActiveCall = await MainActor.run {
            guard let callService = AppEnvironment.shared.callService else {
                return false
            }
            guard let call = callService.callServiceState.currentCall else {
                return false
            }
            return !call.hasTerminated
        }
        return .result(value: hasActiveCall)
    }
}

@available(iOS 16.0, *)
struct CallMuteShortcutsProvider: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleMicrophoneMuteIntent(),
            phrases: [
                "Toggle microphone mute in \(.applicationName)",
                "Toggle mute in \(.applicationName)",
            ],
            shortTitle: "Toggle Mute",
            systemImageName: "mic.slash"
        )
        AppShortcut(
            intent: SetMicrophoneMuteIntent(),
            phrases: [
                "Set microphone mute in \(.applicationName)",
                "Set mute in \(.applicationName)",
            ],
            shortTitle: "Set Mute",
            systemImageName: "mic.slash"
        )
        AppShortcut(
            intent: GetMicrophoneMuteStateIntent(),
            phrases: [
                "Get microphone mute state in \(.applicationName)",
                "Get mute state in \(.applicationName)",
            ],
            shortTitle: "Get Mute State",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: GetActiveCallStateIntent(),
            phrases: [
                "Get active call state in \(.applicationName)",
                "Get active call in \(.applicationName)",
            ],
            shortTitle: "Get Active Call",
            systemImageName: "phone"
        )
    }
}
