import Foundation

/// Its serial delegate queue owns all fields except URLSession's thread-safe cancellation.
final class AppUpdateDownload: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private let destination: URL
    private let onProgress: (Int64) -> Void
    private let completion: (Result<URL, Error>) -> Void
    private var downloaded: Result<URL, Error>?

    init(configuration: URLSessionConfiguration, destination: URL,
         onProgress: @escaping (Int64) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.destination = destination; self.onProgress = onProgress; self.completion = completion
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func start(_ url: URL) {
        task = session.downloadTask(with: url)
        task?.resume()
    }

    func cancel() { session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "AppUpdateDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: "安装包下载失败。"])
            }
            try FileManager.default.copyItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            downloaded = .success(destination)
        } catch { downloaded = .failure(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil, case let .success(file) = downloaded { try? FileManager.default.removeItem(at: file) }
        let result = error.map { Result<URL, Error>.failure($0) } ?? downloaded ?? .failure(URLError(.badServerResponse))
        downloaded = nil
        session.finishTasksAndInvalidate()
        completion(result)
    }
}
