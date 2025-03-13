//
//  111.swift
//  ChatMLX
//
//  Created by mingdw on 2025/3/13.
//

//
//  DownloadModelTask.swift
//  ChatMLX
//
//  Created by mingdw on 2025/3/12.
//

import Foundation
import SwiftUI
import Logging
import Defaults
import OSLog

/// 优化后的下载任务类，使用现代Swift特性
@Observable
class DownloadModelTask111: NSObject, Identifiable, Hashable {
    enum DownloadState: Equatable {
        case notStarted
        case downloading
        case paused
        case completed
        case failed(Error)
        
        static func == (lhs: DownloadState, rhs: DownloadState) -> Bool {
            switch (lhs, rhs) {
            case (.notStarted, .notStarted), (.downloading, .downloading),
                 (.paused, .paused), (.completed, .completed):
                return true
            case (.failed, .failed):
                // 不比较具体错误，只比较状态类型
                return true
            default:
                return false
            }
        }
    }

    enum DownloadError: Error {
        case invalidDownloadLocation
        case unexpectedError
        case cancelled
        case networkError(underlying: Error)
    }
    
    // 使用nonisolated让这些属性在任何上下文中都可访问
    nonisolated let id = UUID()
    private let logger = Logger(label: Bundle.main.bundleIdentifier!)
    private let source: URL
    private let destination: URL
    private let authToken: String?
    private let maxRetryAttempts = 5
    private let baseDelay: TimeInterval = 1.0
    private let inBackground: Bool
    
    private var currentRetryAttempts = 0
    private var urlSession: URLSession? = nil
    private var resumeData: Data?
    private var downloadTask: URLSessionDownloadTask?
    
    var downloadState = DownloadState.notStarted
    var progress: Double = 0
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: DownloadModelTask111, rhs: DownloadModelTask111) -> Bool {
        lhs.id == rhs.id
    }
    
    init(
        from url: URL, to destination: URL, using authToken: String? = nil,
        inBackground: Bool = false
    ) {
        self.destination = destination
        self.source = url
        self.authToken = authToken
        self.inBackground = inBackground
        super.init()
    }
    
    /// 开始下载任务
    func start() {
        let sessionIdentifier = "swift-transformers.hub.downloader"

        var config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if inBackground {
            config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
        }

        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        Task {
            await setupDownload(from: source, with: authToken)
        }
    }

    deinit {
        urlSession?.invalidateAndCancel()
    }
    
    /// 异步设置并开始下载
    @MainActor
    private func setupDownload(from url: URL, with authToken: String?) async {
        downloadState = .downloading
        
        guard let urlSession = urlSession else {
            downloadState = .failed(DownloadError.unexpectedError)
            return
        }
        
        do {
            let tasks = try await urlSession.allTasks()
            
            // 检查是否有相同URL的任务正在运行
            if let existing = tasks.first(where: { $0.originalRequest?.url == url }) as? URLSessionDownloadTask {
                switch existing.state {
                case .running:
                    self.downloadTask = existing
                    return
                case .suspended:
                    existing.resume()
                    self.downloadTask = existing
                    return
                case .canceling:
                    break
                case .completed:
                    break
                @unknown default:
                    existing.cancel()
                }
            }
            
            var request = URLRequest(url: url)
            if let authToken = authToken {
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            }

            self.downloadTask = urlSession.downloadTask(with: request)
            self.downloadTask?.resume()
        } catch {
            downloadState = .failed(error)
            logger.error("Failed to start download task: \(error.localizedDescription)")
        }
    }
    
    /// 暂停下载
    @MainActor
    func pauseDownload() async {
        guard let task = downloadTask else { return }
        
        return await withCheckedContinuation { continuation in
            task.cancel(byProducingResumeData: { resumeData in
                self.resumeData = resumeData
                self.downloadTask = nil
                self.downloadState = .paused
                self.logger.info("Download paused, resume data saved: \(resumeData?.count ?? 0) bytes")
                continuation.resume()
            })
        }
    }
    
    /// 恢复下载
    @MainActor
    func resumeDownload() async {
        if let resumeData = resumeData {
            downloadState = .downloading
            downloadTask = urlSession?.downloadTask(withResumeData: resumeData)
            downloadTask?.resume()
            self.resumeData = nil
        } else {
            await setupDownload(from: source, with: authToken)
        }
    }
    
    /// 取消下载
    func cancelDownload() {
        downloadTask?.cancel()
        resumeData = nil
        downloadTask = nil
        
        Task { @MainActor in
            downloadState = .notStarted
            progress = 0
        }
    }
    
    /// 获取下载进度流
    var downloadProgress: AsyncStream<Double> {
        AsyncStream { continuation in
            Task {
                while true {
                    if case .downloading = downloadState {
                        continuation.yield(progress)
                    } else if case .completed = downloadState {
                        continuation.yield(1.0)
                        continuation.finish()
                        break
                    } else if case .failed = downloadState {
                        continuation.finish()
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }
    
    /// 异步等待下载完成
    func waitForDownload() async throws -> URL {
        if downloadState == .notStarted {
            start()
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                while true {
                    switch downloadState {
                    case .completed:
                        continuation.resume(returning: destination)
                        return
                    case .failed(let error):
                        continuation.resume(throwing: error)
                        return
                    case .notStarted, .downloading, .paused:
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate
extension DownloadModelTask111: URLSessionDownloadDelegate {
    func urlSession(
        _: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            self.downloadState = .downloading
            self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        }
    }

    func urlSession(
        _: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        do {
            // 如果下载的文件已存在，覆盖它
            try FileManager.default.moveDownloadedFile(from: location, to: self.destination)
            
            Task { @MainActor in
                self.downloadState = .completed
                self.progress = 1.0
            }
        } catch {
            Task { @MainActor in
                self.downloadState = .failed(error)
                logger.error("Failed to move downloaded file: \(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask else { return }
        
        Task { @MainActor in
            if let error = error as? NSError {
                if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                    // 如果是用户取消，我们已经在pauseDownload中设置了状态，这里不需要额外操作
                    return
                }
                
                if let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    self.resumeData = resumeData
                    logger.info("Download error occurred, resume data saved.")
                } else {
                    self.resumeData = nil
                    logger.warning("Download error occurred, but no resume data available.")
                }
                
                if currentRetryAttempts < maxRetryAttempts {
                    currentRetryAttempts += 1
                    let delayTime = baseDelay * pow(2.0, Double(currentRetryAttempts - 1))
                    logger.info("Download failed, retrying attempt \(currentRetryAttempts) in \(delayTime) seconds... Error: \(error.localizedDescription)")
                    
                    // 使用Task延迟而不是DispatchQueue
                    Task {
                        try await Task.sleep(for: .seconds(delayTime))
                        
                        if Task.isCancelled { return }
                        
                        if let resumeData = self.resumeData {
                            self.downloadTask = self.urlSession?.downloadTask(withResumeData: resumeData)
                            self.downloadTask?.resume()
                        } else {
                            await self.setupDownload(from: self.source, with: self.authToken)
                        }
                    }
                } else {
                    self.downloadState = .failed(DownloadError.networkError(underlying: error))
                    self.downloadTask = nil
                    logger.error("Download failed after \(maxRetryAttempts) retries. Error: \(error.localizedDescription)")
                }
            } else if let error = error {
                self.downloadState = .failed(error)
                self.downloadTask = nil
                self.resumeData = nil
                logger.error("Download failed with unexpected error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 使用示例
extension DownloadModelTask {
    static func downloadExample() async {
        let downloader = DownloadModelTask(
            from: URL(string: "https://example.com/file.zip")!,
            to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("file.zip")
        )
        
        // 开始下载
        downloader.start()
        
        // 观察进度
        Task {
            for await progress in downloader.downloadProgress {
                print("下载进度: \(Int(progress * 100))%")
            }
        }
        
        do {
            // 等待下载完成
            let fileURL = try await downloader.waitForDownload()
            print("下载完成，文件位置: \(fileURL.path)")
        } catch {
            print("下载失败: \(error)")
        }
    }
}
