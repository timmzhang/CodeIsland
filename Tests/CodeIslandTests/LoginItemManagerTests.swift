import XCTest
@testable import CodeIsland

@MainActor
final class LoginItemManagerTests: XCTestCase {
    private final class FakeService {
        var enabled: Bool
        var calls: [String] = []
        var registerError: Error?
        var unregisterError: Error?

        init(enabled: Bool) {
            self.enabled = enabled
        }

        var adapter: LoginItemService {
            LoginItemService(
                isEnabled: { self.enabled },
                register: {
                    self.calls.append("register")
                    if let error = self.registerError { throw error }
                    self.enabled = true
                },
                unregister: {
                    self.calls.append("unregister")
                    if let error = self.unregisterError { throw error }
                    self.enabled = false
                }
            )
        }
    }

    private struct TestError: LocalizedError {
        let errorDescription: String? = "test failure"
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "LoginItemManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testTransientBuildPathsAreRejected() {
        XCTAssertTrue(LoginItemPathPolicy.isTransientBuildPath(
            "/Users/me/CodeIsland/.build/arm64-apple-macosx/release/CodeIsland.app"
        ))
        XCTAssertTrue(LoginItemPathPolicy.isTransientBuildPath(
            "/Users/me/Library/Developer/Xcode/DerivedData/CodeIsland/Build/Products/CodeIsland.app"
        ))
        XCTAssertFalse(LoginItemPathPolicy.isTransientBuildPath("/Applications/CodeIsland.app"))
    }

    func testEnablingFromTransientBundleDoesNotRegister() {
        let fake = FakeService(enabled: false)
        let manager = LoginItemManager(
            service: fake.adapter,
            defaults: makeDefaults(),
            bundleURL: { URL(fileURLWithPath: "/tmp/CodeIsland/.build/release/CodeIsland.app") }
        )

        let result = manager.setEnabled(true)

        guard case .failure(.transientBundle) = result else {
            return XCTFail("expected transient bundle rejection")
        }
        XCTAssertEqual(fake.calls, [])
    }

    func testStableBundleRegistrationPersistsPathAndDisableClearsIt() {
        let fake = FakeService(enabled: false)
        let defaults = makeDefaults()
        let manager = LoginItemManager(
            service: fake.adapter,
            defaults: defaults,
            bundleURL: { URL(fileURLWithPath: "/Applications/CodeIsland.app") }
        )

        guard case .success = manager.setEnabled(true) else {
            return XCTFail("expected stable bundle registration to succeed")
        }
        XCTAssertEqual(fake.calls, ["register"])
        XCTAssertEqual(
            defaults.string(forKey: LoginItemManager.registeredBundlePathKey),
            "/Applications/CodeIsland.app"
        )

        guard case .success = manager.setEnabled(false) else {
            return XCTFail("expected unregister to succeed")
        }
        XCTAssertEqual(fake.calls, ["register", "unregister"])
        XCTAssertNil(defaults.string(forKey: LoginItemManager.registeredBundlePathKey))
    }

    func testRegistrationFailureIsReturnedAndNotPersisted() {
        let fake = FakeService(enabled: false)
        fake.registerError = TestError()
        let defaults = makeDefaults()
        let manager = LoginItemManager(
            service: fake.adapter,
            defaults: defaults,
            bundleURL: { URL(fileURLWithPath: "/Applications/CodeIsland.app") }
        )

        guard case .failure(.operationFailed(let message)) = manager.setEnabled(true) else {
            return XCTFail("expected registration failure")
        }
        XCTAssertEqual(message, "test failure")
        XCTAssertEqual(fake.calls, ["register"])
        XCTAssertNil(defaults.string(forKey: LoginItemManager.registeredBundlePathKey))
        XCTAssertFalse(defaults.bool(forKey: LoginItemManager.migrationRequestedKey))
        XCTAssertEqual(manager.lastError, .operationFailed("test failure"))
    }

    func testLegacyRegistrationMigratesOnceToStableBundle() {
        let fake = FakeService(enabled: true)
        let defaults = makeDefaults()
        let manager = LoginItemManager(
            service: fake.adapter,
            defaults: defaults,
            bundleURL: { URL(fileURLWithPath: "/Applications/CodeIsland.app") }
        )

        XCTAssertEqual(manager.reconcileOnLaunch(), .repaired)
        XCTAssertEqual(fake.calls, ["unregister", "register"])
        XCTAssertEqual(
            defaults.string(forKey: LoginItemManager.registeredBundlePathKey),
            "/Applications/CodeIsland.app"
        )

        fake.calls.removeAll()
        XCTAssertEqual(manager.reconcileOnLaunch(), .current)
        XCTAssertEqual(fake.calls, [])
    }

    func testTransientBundleRemovesItsExistingRegistrationAndRequestsMigration() {
        let fake = FakeService(enabled: true)
        let defaults = makeDefaults()
        defaults.set("/Applications/CodeIsland.app", forKey: LoginItemManager.registeredBundlePathKey)
        let manager = LoginItemManager(
            service: fake.adapter,
            defaults: defaults,
            bundleURL: { URL(fileURLWithPath: "/Users/me/CodeIsland/.build/release/CodeIsland.app") }
        )

        XCTAssertEqual(manager.reconcileOnLaunch(), .removedTransient)
        XCTAssertEqual(fake.calls, ["unregister"])
        XCTAssertNil(defaults.string(forKey: LoginItemManager.registeredBundlePathKey))
        XCTAssertTrue(defaults.bool(forKey: LoginItemManager.migrationRequestedKey))
    }

    func testStableBundleCompletesMigrationRequestedByTransientBundle() {
        let fake = FakeService(enabled: false)
        let defaults = makeDefaults()
        defaults.set(true, forKey: LoginItemManager.migrationRequestedKey)
        let manager = LoginItemManager(
            service: fake.adapter,
            defaults: defaults,
            bundleURL: { URL(fileURLWithPath: "/Applications/CodeIsland.app") }
        )

        XCTAssertEqual(manager.reconcileOnLaunch(), .repaired)
        XCTAssertEqual(fake.calls, ["register"])
        XCTAssertEqual(
            defaults.string(forKey: LoginItemManager.registeredBundlePathKey),
            "/Applications/CodeIsland.app"
        )
        XCTAssertFalse(defaults.bool(forKey: LoginItemManager.migrationRequestedKey))
    }

    func testFailedMigrationIsReportedAndDoesNotPersistPath() {
        let fake = FakeService(enabled: true)
        fake.unregisterError = TestError()
        let defaults = makeDefaults()
        let manager = LoginItemManager(
            service: fake.adapter,
            defaults: defaults,
            bundleURL: { URL(fileURLWithPath: "/Applications/CodeIsland.app") }
        )

        XCTAssertEqual(manager.reconcileOnLaunch(), .failed("test failure"))
        XCTAssertEqual(fake.calls, ["unregister"])
        XCTAssertNil(defaults.string(forKey: LoginItemManager.registeredBundlePathKey))
        XCTAssertTrue(defaults.bool(forKey: LoginItemManager.migrationRequestedKey))
        XCTAssertEqual(manager.lastError, .operationFailed("test failure"))
    }

    func testFailedReplacementRegistrationRetriesOnNextLaunch() {
        let fake = FakeService(enabled: true)
        fake.registerError = TestError()
        let defaults = makeDefaults()
        let manager = LoginItemManager(
            service: fake.adapter,
            defaults: defaults,
            bundleURL: { URL(fileURLWithPath: "/Applications/CodeIsland.app") }
        )

        XCTAssertEqual(manager.reconcileOnLaunch(), .failed("test failure"))
        XCTAssertEqual(fake.calls, ["unregister", "register"])
        XCTAssertFalse(fake.enabled)
        XCTAssertNil(defaults.string(forKey: LoginItemManager.registeredBundlePathKey))
        XCTAssertTrue(defaults.bool(forKey: LoginItemManager.migrationRequestedKey))
        XCTAssertEqual(manager.lastError, .operationFailed("test failure"))
    }
}
