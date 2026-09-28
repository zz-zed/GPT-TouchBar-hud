import Foundation
import CryptoKit

protocol QuotaSnapshotClient: AnyObject {
    func readAccountIdentity(completion: @escaping (Result<String?, Error>) -> Void)
    func readRateLimits(completion: @escaping (Result<GetAccountRateLimitsResponse, Error>) -> Void)
}

extension CodexAppServerClient: QuotaSnapshotClient {}

struct VerifiedQuotaSnapshot {
    let accountKey: String?
    let response: GetAccountRateLimitsResponse
}

enum QuotaIdentityError: LocalizedError {
    case unavailable, changed

    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法确认登录账号，请确认客户端已登录后刷新。"
        case .changed: return "登录账号在刷新期间发生变化，请重新刷新额度。"
        }
    }
}

/// Verify ownership around the read. Only a hash leaves this reader; credentials
/// and raw account metadata never enter notification preferences or reports.
final class VerifiedQuotaReader {
    private let client: QuotaSnapshotClient

    init(client: QuotaSnapshotClient) { self.client = client }

    func read(completion: @escaping (Result<VerifiedQuotaSnapshot, Error>) -> Void) {
        client.readAccountIdentity { [weak self] first in
            guard let self else { return }
            guard case .success(let identity?) = first, !identity.isEmpty else {
                // Older hosts may expose quotas without account metadata. Keep
                // their live display available, but never authorize an alert.
                self.client.readRateLimits { result in
                    completion(result.map { VerifiedQuotaSnapshot(accountKey: nil, response: $0) })
                }
                return
            }
            self.client.readRateLimits { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success(let response):
                    self.client.readAccountIdentity { last in
                        guard case .success(let confirmed?) = last, !confirmed.isEmpty else {
                            completion(.failure(QuotaIdentityError.unavailable))
                            return
                        }
                        guard confirmed == identity else {
                            completion(.failure(QuotaIdentityError.changed))
                            return
                        }
                        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                        completion(.success(VerifiedQuotaSnapshot(accountKey: key, response: response)))
                    }
                }
            }
        }
    }
}
