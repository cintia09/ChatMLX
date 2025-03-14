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

@Observable
class DownloadModelTask: NSObject, Identifiable {
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
    
    let id = UUID()
    private let logger = Logger(label: Bundle.main.bundleIdentifier!)
    private let source: URL
    private let destination: URL
    private let authToken: String?
    private let maxRetryAttempts = 5
    private let baseDelay: TimeInterval = 1.0
    
    private var currentRetryAttempts = 0
    private var urlSession: URLSession? = nil
    private var resumeData: Data?
    private var downloadTask: URLSessionDownloadTask?
    
    var downloadState = DownloadState.notStarted
    var progress: Double = 0
    
    static func == (lhs: DownloadModelTask, rhs: DownloadModelTask) -> Bool {
        lhs.id == rhs.id
    }
    
    init(
        from url: URL, to destination: URL, using authToken: String? = nil,
        inBackground: Bool = false
    ) {
        self.destination = destination
        self.source = url
        self.authToken = authToken
        super.init()
        let sessionIdentifier = "swift-transformers.hub.downloader"

        var config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if inBackground {
            config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
        }

        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        setupDownload(from: self.source, with: self.authToken)
    }

    deinit {
        self.downloadTask = nil
        self.downloadState = .completed
        urlSession?.invalidateAndCancel()
    }
    
    private func setupDownload(from url: URL, with authToken: String?) {
        downloadState = .downloading
        urlSession?.getAllTasks { tasks in
            // If there's an existing pending background task with the same URL, let it proceed.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                if self.downloadState == .paused
                    || self.downloadTask?.state == .canceling
                    || self.downloadTask?.state == .completed {
                    logger.info("Download task is paused or completed, will not attempt to resume or restart.")
                    return
                }
                
                if let existing = tasks.filter({ $0.originalRequest?.url == url }).first {
                    switch existing.state {
                    case .running:
                        return
                    case .suspended:
                        existing.resume()
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
                
                self.downloadTask = self.urlSession?.downloadTask(with: request)
                self.downloadTask?.resume()
            }
        }
    }
    
    func pauseDownload() {
        downloadTask?.cancel(byProducingResumeData: { resumeData in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.resumeData = resumeData
                self.downloadTask = nil
                self.downloadState = .paused
                self.logger.info("Download paused, resume data saved: \(resumeData?.count ?? 0) bytes")
            }
        })
    }
    
    func resumeDownload() {
        guard let resumeData = resumeData else {
            setupDownload(from: source, with: authToken)
            return
        }
        
        downloadState = .downloading
        downloadTask = urlSession?.downloadTask(withResumeData: resumeData)
        downloadTask?.resume()
        self.resumeData = nil
    }
}

extension DownloadModelTask: URLSessionDownloadDelegate {
    func urlSession(
        _: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.downloadState = .downloading
            self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        }
    }

    func urlSession(
        _: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.moveDownloadedFile(from: location, to: self.destination)
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.downloadState = .completed
                self.progress = 1.0
            }
        } catch {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.downloadState = .failed(error)
                logger.error("Failed to move downloaded file: \(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        guard let downloadTask = task as? URLSessionDownloadTask else { return }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if let error = error as? NSError {
                if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
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
                    
                    Task {
                        try await Task.sleep(for: .seconds(delayTime))
                        
                        if Task.isCancelled { return }
                        
                        await MainActor.run { [weak self] in
                            guard let self = self else { return }
                            
                            if self.downloadState == .paused
                                || self.downloadTask?.state == .canceling
                                || self.downloadTask?.state == .completed {
                                logger.info("Download task is paused or completed, will not attempt to resume or restart.")
                                return
                            }
                            
                            if let resumeData = self.resumeData {
                                self.downloadTask = self.urlSession?.downloadTask(withResumeData: resumeData)
                                self.downloadTask?.resume()
                                self.resumeData = nil
                                self.downloadState = .downloading
                            } else {
                                self.setupDownload(from: self.source, with: self.authToken)
                            }
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

extension FileManager {
    func moveDownloadedFile(from srcURL: URL, to dstURL: URL) throws {
        if fileExists(atPath: dstURL.path) {
            try removeItem(at: dstURL)
        }
        try moveItem(at: srcURL, to: dstURL)
    }
}
