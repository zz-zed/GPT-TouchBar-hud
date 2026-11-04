import Foundation
import Security
import LocalAuthentication

protocol APICostCredentialVault: AnyObject {
    func read() throws -> String
    func save(_ key: String) throws
    func remove() throws
}

/// Used only by the application after user opt-in. Never enumerates other credentials.
final class APICostKeychain: APICostCredentialVault {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.gpt-touchbar-hud.api-costs",
         kSecAttrAccount as String: "admin-api-key",
         kSecAttrSynchronizable as String: false]
    }
    func read() throws -> String {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Background refresh must not trigger a Keychain prompt.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { throw APICostError.credentialStorage }
        return key
    }
    func save(_ key: String) throws {
        let value: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let result = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if result == errSecItemNotFound {
            var attributes = query.merging(value) { _, value in value }
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw APICostError.credentialStorage }
        } else if result != errSecSuccess { throw APICostError.credentialStorage }
    }
    func remove() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw APICostError.credentialStorage }
    }
}

/// All state changes and client completions are serialized on the main thread.
final class APICostStore {
    static let enabledKey = "apiCosts.enabled"
    static let configuredKey = "apiCosts.configured"
    private let client: APICostFetching
    private let vault: APICostCredentialVault
    private let defaults: UserDefaults
    private let now: () -> Date
    private let schedulesTimers: Bool
    private var timer: Timer?
    private var request: APICostCancellation?
    private var validation: APICostCancellation?
    private var generation = UUID()
    private var validationGeneration = UUID()
    private var running = false
    private var suspended = false
    private var nextAutomatic = Date.distantPast
    private var lastAttempt: Date?
    private var rateLimitedUntil = Date.distantPast
    private var validationRetryAfter = Date.distantPast
    private var failures = 0
    private(set) var state = APICostViewState()
    var onChange: ((APICostViewState) -> Void)?

    init(client: APICostFetching = APICostClient(), vault: APICostCredentialVault = APICostKeychain(),
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init, schedulesTimers: Bool = true) {
        self.client = client; self.vault = vault; self.defaults = defaults; self.now = now; self.schedulesTimers = schedulesTimers
        state.configured = defaults.bool(forKey: Self.configuredKey)
        state.enabled = state.configured && defaults.bool(forKey: Self.enabledKey)
        state.period = .month(containing: now())
    }
    deinit { timer?.invalidate(); request?.cancel(); validation?.cancel() }
    func start() {
        guard !running else { return }
        running = true
        if schedulesTimers {
            let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        tick()
    }
    func stop() {
        running = false; timer?.invalidate(); timer = nil
        invalidateRequest(); cancelValidation()
        state.snapshot = nil
        publish()
    }
    func setSuspended(_ value: Bool) {
        suspended = value
        if value { invalidateRequest(); cancelValidation(); publish() }
        else { tick() }
    }
    func setEnabled(_ value: Bool) {
        guard state.configured else { return }
        state.enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        invalidateRequest(); cancelValidation()
        if value { nextAutomatic = .distantPast; tick() } else { publish() }
    }
    func disconnect() {
        invalidateRequest(); cancelValidation()
        do { try vault.remove() }
        catch { state.validationError = .credentialStorage; publish(); return }
        defaults.removeObject(forKey: Self.enabledKey)
        defaults.removeObject(forKey: Self.configuredKey)
        state = APICostViewState(); state.period = .month(containing: now())
        lastAttempt = nil; failures = 0; nextAutomatic = .distantPast
        // Preserve server backoff across local disconnect/reconnect attempts.
        publish()
    }
    func cancelValidation() {
        validationGeneration = UUID(); validation?.cancel(); validation = nil
        state.validating = false; state.validationError = nil
        publish()
    }
    func validateAndConnect(_ candidate: String, completion: @escaping (Bool) -> Void) {
        guard running, !suspended else { completion(false); return }
        cancelValidation()
        guard now() >= max(validationRetryAfter, rateLimitedUntil) else {
            state.validationError = .rateLimited(max(validationRetryAfter, rateLimitedUntil)); publish(); completion(false); return
        }
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            state.validationError = .authentication; publish(); completion(false); return
        }
        let id = validationGeneration
        let date = now(), period = APICostPeriod.month(containing: now())
        state.validating = true; publish()
        validation = client.fetch(key: key, period: period, end: date) { [weak self] result in
            guard let self, self.running, !self.suspended, id == self.validationGeneration else { return }
            self.validation = nil; self.state.validating = false
            switch result {
            case .failure(let error):
                self.state.validationError = error
                if case .rateLimited(let until) = error {
                    self.validationRetryAfter = until ?? self.now().addingTimeInterval(60)
                }
                self.publish(); completion(false)
            case .success(let snapshot):
                do { try self.vault.save(key) }
                catch { self.state.validationError = .credentialStorage; self.publish(); completion(false); return }
                self.invalidateRequest()
                self.defaults.set(true, forKey: Self.configuredKey)
                self.defaults.set(true, forKey: Self.enabledKey)
                self.state.configured = true; self.state.enabled = true
                self.state.period = .month(containing: self.now())
                self.state.snapshot = snapshot.period == self.state.period ? snapshot : nil
                self.state.error = nil; self.state.validationError = nil
                self.failures = 0; self.lastAttempt = self.now()
                self.nextAutomatic = self.state.snapshot == nil ? .distantPast : self.now().addingTimeInterval(900)
                self.publish(); completion(true)
            }
        }
    }
    func tick() {
        guard running, !suspended else { return }
        let period = APICostPeriod.month(containing: now())
        if period != state.period {
            invalidateRequest()
            state.period = period; state.snapshot = nil
            nextAutomatic = .distantPast
        }
        if state.visible, !state.refreshing, state.error?.requiresRepair != true, now() >= nextAutomatic {
            refresh(manual: false)
        } else { publish() }
    }
    func refresh(manual: Bool = true) {
        guard running, !suspended, state.visible, !state.refreshing, state.error?.requiresRepair != true else { publish(); return }
        let date = now()
        guard date >= rateLimitedUntil, lastAttempt.map({ date.timeIntervalSince($0) >= 30 }) ?? true else { publish(); return }
        let period = APICostPeriod.month(containing: date)
        if state.period != period { state.period = period; state.snapshot = nil }
        guard Int64(date.timeIntervalSince1970) > Int64(period.start.timeIntervalSince1970) else { publish(); return }
        let key: String
        do { key = try vault.read() }
        catch { state.error = .credentialStorage; publish(); return }
        lastAttempt = date; state.refreshing = true
        let id = generation
        publish()
        request = client.fetch(key: key, period: period, end: date) { [weak self] result in
            guard let self, self.running, id == self.generation, !self.suspended, self.state.visible else { return }
            self.request = nil; self.state.refreshing = false
            guard period == APICostPeriod.month(containing: self.now()) else { self.tick(); return }
            switch result {
            case .success(let snapshot):
                self.state.snapshot = snapshot; self.state.error = nil; self.failures = 0
                self.nextAutomatic = self.now().addingTimeInterval(900)
            case .failure(let error):
                self.state.error = error; self.failures += 1
                let delay: TimeInterval = self.failures == 1 ? 60 : self.failures == 2 ? 300 : 900
                self.nextAutomatic = self.now().addingTimeInterval(delay)
                if case .rateLimited(let until) = error {
                    self.rateLimitedUntil = max(until ?? self.nextAutomatic, self.now().addingTimeInterval(30))
                    self.nextAutomatic = max(self.nextAutomatic, self.rateLimitedUntil)
                }
            }
            self.publish()
        }
    }
    private func invalidateRequest() {
        generation = UUID(); request?.cancel(); request = nil; state.refreshing = false
    }
    private func publish() {
        state.isStale = state.snapshot.map { now().timeIntervalSince($0.fetchedAt) > 1800 } ?? false
        state.canRefresh = running && !suspended && state.visible && !state.refreshing && state.error?.requiresRepair != true
            && now() >= rateLimitedUntil && (lastAttempt.map { now().timeIntervalSince($0) >= 30 } ?? true)
        onChange?(state)
    }
}
