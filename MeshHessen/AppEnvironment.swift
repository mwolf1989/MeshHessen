import SwiftUI

// MARK: - Environment Key for AppState

private struct AppStateKey: EnvironmentKey {
    static var defaultValue: AppState {
        MainActor.assumeIsolated {
            AppState()
        }
    }
}

extension EnvironmentValues {
    var appState: AppState {
        get { self[AppStateKey.self] }
        set { self[AppStateKey.self] = newValue }
    }

    var persistenceController: PersistenceController {
        get { self[PersistenceControllerKey.self] }
        set { self[PersistenceControllerKey.self] = newValue }
    }
}

private struct PersistenceControllerKey: EnvironmentKey {
    static let defaultValue: PersistenceController = .shared
}
