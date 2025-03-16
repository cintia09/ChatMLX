//
//  DownloadModelTask.swift
//  ChatMLX
//
//  Created by mingdw on 2025/3/12.
//

import Foundation
import Logging
import Defaults
import OSLog

@MainActor
@Observable
class DownloadStateMachine {
    enum State {
        case idle
        case downloading
        case paused
        case canceled
        case completed
        case failed
    }
    
    let downloadTask: DownloadModelTask
    init(_ downloadTask: DownloadModelTask) {
        self.downloadTask = downloadTask
    }
    
    var state = State.idle
    var progress: Double = 0
    
    private let maxRetryAttempts = 5
    private let baseDelay: TimeInterval = 1.0
    private var currentRetryAttempts = 0
    
    func start() {
        switch state {
        case .idle:
            state = .downloading
            downloadTask.getFilenames()
            break
        case .paused, .failed:
            state = .downloading
            downloadTask.resumeDownload()
            break
        case .downloading, .canceled, .completed:
            break
        }
        currentRetryAttempts = 0
    }
    
    func pause() {
        switch state {
        case .downloading:
            state = .paused
            downloadTask.pauseDownload()
            break
        case .idle, .paused, .canceled, .completed, .failed:
            break
        }
        currentRetryAttempts = 0
    }
    
    func cancel() {
        state = .canceled
    }
    
    func filenamesGetted() {
        switch state {
        case .downloading:
            downloadTask.resumeDownload()
            break
        case .idle, .paused, .canceled, .completed, .failed:
            break
        }
    }
    
    func filenamesGetFailed() {
        state = .idle
    }
    
    func downloadCompeted(location: URL, destination: URL, isDownloadAll: Bool) {
        if isDownloadAll {
            state = .completed
        } else if state == .downloading {
            downloadTask.resumeDownload()
        }
        
        FileManager.default.moveDownloadedFile(from: location, to: destination)
    }
    
    func downloadErrors() {
        switch state {
        case .downloading:
            if currentRetryAttempts < maxRetryAttempts {
                currentRetryAttempts += 1
                let delayTime = baseDelay * pow(2.0, Double(currentRetryAttempts - 1))
                downloadTask.retriveDownload(delayTime: delayTime)
            }
            else {
                state = .failed
                currentRetryAttempts = 0
            }
            break
        case .idle, .paused, .canceled, .completed, .failed:
            break
        }
    }
    
    func downloadProgress(progress: Double) {
        self.progress = progress
        currentRetryAttempts = 0
    }
}

class DownloadModelTask: NSObject, Identifiable {
    enum DownloadError: Error {
        case invalidDownloadLocation
        case unexpectedError
        case cancelled
        case networkError(underlying: Error)
    }
   
    private enum HubClientError: Error {
        case parse
        case authorizationRequired
        case unexpectedError
        case httpStatusCode(Int)
    }
    
    let id = UUID()
    let repoId: String
    private let logger = Logger(label: Bundle.main.bundleIdentifier!)
    private let globs: [String]
    private let authToken: String?
    private let destination: URL
    private let source: URL
    private let repoURL: URL
    private let decodeData: (Data) async throws -> [String]
    private var urlSession: URLSession?
    private var resumeData: Data?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadFiles: [(URL, URL)] = []
    private var filenames: [String] = []
    
    var stateMachine: DownloadStateMachine?
    
    static func == (lhs: DownloadModelTask, rhs: DownloadModelTask) -> Bool {
        lhs.id == rhs.id
    }
    
    init(repoId: String,
         repoURL: URL,
         source: URL,
         destination: URL,
         matching globs: [String] = [],
         using authToken: String? = nil,
         inBackground: Bool = false,
         decodeData: @escaping (Data) async throws -> [String]
    ) {
        self.repoId = repoId
        self.repoURL = repoURL
        self.source = source
        self.destination = destination
        self.globs = globs
        self.authToken = authToken
        self.decodeData = decodeData

        super.init()
        
        var config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if inBackground {
            config = URLSessionConfiguration.background(withIdentifier: "swift-transformers.hub.downloader")
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
        }

        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit {
        self.downloadTask = nil
        urlSession?.invalidateAndCancel()
    }
    
    func getFilenames()
    {
        Task {
            do {
                let (data, _) = try await httpGet(for: repoURL, token: authToken)
                self.filenames = try await self.decodeData(data)
                if globs.count > 0 {
                    var selected: Set<String> = []
                    for glob in globs {
                        selected = selected.union(self.filenames.matching(glob: glob))
                    }
                    
                    self.filenames = Array(selected)
                }
                
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    for filename in self.filenames {
                        let source = self.source.appending(path: filename)
                        let destination = self.destination.appending(path: filename)
                        let downloaded = FileManager.default.fileExists(atPath: destination.path)
                        guard !downloaded else { continue }
                        
                        self.downloadFiles.append((source, destination))
                    }
                }
            } catch {
                await stateMachine?.filenamesGetFailed()
            }
            
            await stateMachine?.filenamesGetted()
        }
    }
    
    private func httpGet(for url: URL, token: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw HubClientError.unexpectedError
        }

        switch response.statusCode {
            case 200 ..< 300: break
            case 400 ..< 500: throw HubClientError.authorizationRequired
            default: throw HubClientError.httpStatusCode(response.statusCode)
        }

        return (data, response)
    }
    
    private func setupDownload() {
        if self.downloadFiles.isEmpty {
            return
        }
        
        urlSession?.getAllTasks { tasks in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                if self.downloadTask?.state == .canceling || self.downloadTask?.state == .completed {
                    logger.info("Download task is paused or completed, will not attempt to resume or restart.")
                    return
                }
                
                guard let url = self.downloadFiles.first else { return }
                let source = url.0
                if let existing = tasks.filter({ $0.originalRequest?.url == source }).first {
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
                
                var request = URLRequest(url: source)
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
                self.logger.info("Download paused, resume data saved: \(resumeData?.count ?? 0) bytes")
            }
        })
    }
    
    func resumeDownload() {
        guard let resumeData = self.resumeData else {
            setupDownload()
            return
        }
        
        downloadTask = urlSession?.downloadTask(withResumeData: resumeData)
        downloadTask?.resume()
        self.resumeData = nil
    }
    
    func retriveDownload(delayTime: Double) {
        Task {
            try await Task.sleep(for: .seconds(delayTime))
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                guard let downloadTask = self.downloadTask else { return }
                if downloadTask.state == .canceling || downloadTask.state == .completed {
                    logger.info("Download task is paused or completed, will not attempt to resume.")
                    return
                }
                self.resumeDownload()
            }
        }
    }
    
    func createStateMachine() async {
        await self.stateMachine = DownloadStateMachine(self)
    }
    
    func start() {
        Task {
            await stateMachine?.start()
        }
    }
    
    func pause() {
        Task {
            await stateMachine?.pause()
        }
    }
    
    func cancel() {
        Task {
            await stateMachine?.cancel()
        }
    }
}

extension DownloadModelTask: URLSessionDownloadDelegate {
    func urlSession(
        _: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            stateMachine?.downloadProgress(progress: Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(
        _: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            stateMachine?.downloadProgress(progress: 1.0)
            if let originalRequest = downloadTask?.originalRequest {
                var downloadURL: URL?
                var indexToRemove: Int?
                for (index, (source, destination)) in self.downloadFiles.enumerated() {
                    if source == originalRequest.url {
                        downloadURL = destination
                        indexToRemove = index
                        break
                    }
                }
                
                if let index = indexToRemove {
                    self.downloadFiles.remove(at: index)
                }
                
                self.downloadTask = nil
                self.resumeData = nil
                stateMachine?.downloadCompeted(location: location, destination: downloadURL!, isDownloadAll: self.downloadFiles.isEmpty)
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
            } else if let error = error {
                self.resumeData = nil
                logger.error("Download failed with unexpected error: \(error.localizedDescription)")
            }
            
            self.stateMachine?.downloadErrors()
        }
    }
}

extension FileManager {
    func moveDownloadedFile(from srcURL: URL, to dstURL: URL) {
        Task {
            do {
                if fileExists(atPath: dstURL.path) {
                    try removeItem(at: dstURL)
                }
                try moveItem(at: srcURL, to: dstURL)
            }
            catch {
                logger.error("Failed to move downloaded file: \(error.localizedDescription)")
            }
        }
    }
}
