import Foundation
import ServiceManagement

enum LoginItemManagerError: Error, Equatable {
    case transientBundle(String)
    case operationFailed(String)
}

enum LoginItemReconcileResult: Equatable {
    case disabled
    case skippedTransient
    case removedTransient
    case current
    case repaired
    case failed(String)
}

struct LoginItemService {
    var isEnabled: () -> Bool
    var register: () throws -> Void
    var unregister: () throws -> Void

    static let live = LoginItemService(
        isEnabled: { SMAppService.mainApp.status == .enabled },
        register: { try SMAppService.mainApp.register() },
        unregister: { try SMAppService.mainApp.unregister() }
    )
}

enum LoginItemPathPolicy {
    static func normalizedBundlePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func isTransientBuildPath(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if components.contains(".build") { return true }
        return components.contains("DerivedData")
    }
}

/// Keeps the system login-item registration attached to a stable installed app
/// rather than whichever development bundle happened to be running when the
/// preference was toggled.
@MainActor
final class LoginItemManager {
    static let shared = LoginItemManager()

    static let registeredBundlePathKey = "loginItemRegisteredBundlePath"
    static let migrationRequestedKey = "loginItemMigrationRequested"

    private let service: LoginItemService
    private let defaults: UserDefaults
    private let bundleURL: () -> URL

    private(set) var lastError: LoginItemManagerError?

    init(
        service: LoginItemService = .live,
        defaults: UserDefaults = .standard,
        bundleURL: @escaping () -> URL = { Bundle.main.bundleURL }
    ) {
        self.service = service
        self.defaults = defaults
        self.bundleURL = bundleURL
    }

    var isEnabled: Bool { service.isEnabled() }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Result<Void, LoginItemManagerError> {
        let currentPath = LoginItemPathPolicy.normalizedBundlePath(bundleURL())
        if enabled, LoginItemPathPolicy.isTransientBuildPath(currentPath) {
            let error = LoginItemManagerError.transientBundle(currentPath)
            lastError = error
            return .failure(error)
        }

        do {
            if enabled {
                try service.register()
                defaults.set(currentPath, forKey: Self.registeredBundlePathKey)
                defaults.removeObject(forKey: Self.migrationRequestedKey)
            } else {
                try service.unregister()
                defaults.removeObject(forKey: Self.registeredBundlePathKey)
                defaults.removeObject(forKey: Self.migrationRequestedKey)
            }
            lastError = nil
            return .success(())
        } catch {
            let wrapped = LoginItemManagerError.operationFailed(error.localizedDescription)
            lastError = wrapped
            return .failure(wrapped)
        }
    }

    /// Migrates legacy registrations once the stable installed app starts.
    /// Development bundles never take ownership of an existing login item.
    @discardableResult
    func reconcileOnLaunch() -> LoginItemReconcileResult {
        let currentPath = LoginItemPathPolicy.normalizedBundlePath(bundleURL())
        let isTransient = LoginItemPathPolicy.isTransientBuildPath(currentPath)

        if isTransient {
            guard service.isEnabled() else { return .skippedTransient }
            do {
                try service.unregister()
                defaults.removeObject(forKey: Self.registeredBundlePathKey)
                defaults.set(true, forKey: Self.migrationRequestedKey)
                lastError = nil
                return .removedTransient
            } catch {
                let message = error.localizedDescription
                lastError = .operationFailed(message)
                return .failed(message)
            }
        }

        guard service.isEnabled() else {
            if defaults.bool(forKey: Self.migrationRequestedKey) {
                do {
                    try service.register()
                    defaults.set(currentPath, forKey: Self.registeredBundlePathKey)
                    defaults.removeObject(forKey: Self.migrationRequestedKey)
                    lastError = nil
                    return .repaired
                } catch {
                    let message = error.localizedDescription
                    lastError = .operationFailed(message)
                    return .failed(message)
                }
            }
            defaults.removeObject(forKey: Self.registeredBundlePathKey)
            lastError = nil
            return .disabled
        }

        if defaults.string(forKey: Self.registeredBundlePathKey) == currentPath {
            defaults.removeObject(forKey: Self.migrationRequestedKey)
            lastError = nil
            return .current
        }

        do {
            // Persist the user's enabled intent before unregistering. If the
            // replacement registration fails, the next stable launch retries
            // instead of silently leaving Launch at Login disabled.
            defaults.set(true, forKey: Self.migrationRequestedKey)
            try service.unregister()
            try service.register()
            defaults.set(currentPath, forKey: Self.registeredBundlePathKey)
            defaults.removeObject(forKey: Self.migrationRequestedKey)
            lastError = nil
            return .repaired
        } catch {
            let message = error.localizedDescription
            lastError = .operationFailed(message)
            return .failed(message)
        }
    }
}
