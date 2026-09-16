import Foundation

// Read-only opt-in live check. Prints only aggregate counts, never account/auth metadata.
@main
enum AccountTokenUsageSmoke {
    static func main() {
        let client = CodexAppServerClient()
        var completed = false
        var failed = false
        let usage = AccountTokenUsageStore(client: client)
        usage.onUpdate = { display in
            guard let display else { return }
            if display.updatedAt != nil {
                print("account/usage/read with account validation: success")
                print("yesterdayDate=\(AccountTokenUsageResponse.yesterday(now: Date(), calendar: Calendar(identifier: .gregorian)))")
                print("yesterdayTokens=\(display.yesterdayTokens.map(String.init) ?? "null")")
                print("lifetimeTokens=\(display.cumulativeTokens.map(String.init) ?? "null")")
                print("\(display.yesterdayText); \(display.cumulativeText)")
                completed = true
            } else if let status = display.status {
                print("FAIL: \(status)"); failed = true; completed = true
            }
        }
        client.start { result in
            guard case .success = result else {
                print("FAIL: app-server initialization"); failed = true; completed = true; return
            }
            usage.refresh()
        }
        let deadline = Date().addingTimeInterval(65)
        while !completed && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        usage.invalidate()
        client.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if !completed || failed { exit(1) }
    }
}
