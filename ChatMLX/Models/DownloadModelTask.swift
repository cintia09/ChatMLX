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

@Observable
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
    
    enum State {
        case idle
        case downloading
        case paused
        case canceled
        case completed
        case failed
    }
    
    @MainActor
    private class DownloadStateMachine {
        weak var downloadTask: DownloadModelTask?
        init(_ downloadTask: DownloadModelTask) {
            self.downloadTask = downloadTask
        }
        
        func start() {
            guard let downloadTask = self.downloadTask else { return }
            switch downloadTask.state {
            case .idle:
                downloadTask.state = .downloading
                downloadTask.getFilenames()
                break
            case .paused, .failed:
                downloadTask.state = .downloading
                downloadTask.resumeDownload()
                break
            case .downloading, .canceled, .completed:
                break
            }
            downloadTask.currentRetryAttempts = 0
        }
        
        func pause() {
            guard let downloadTask = self.downloadTask else { return }
            switch downloadTask.state {
            case .downloading:
                downloadTask.pauseDownload()
                break
            case .idle, .paused, .canceled, .completed, .failed:
                break
            }
            downloadTask.state = .paused
            downloadTask.currentRetryAttempts = 0
        }
        
        func cancel() {
            guard let downloadTask = self.downloadTask else { return }
            downloadTask.state = .canceled
            downloadTask.urlSession?.invalidateAndCancel()
            downloadTask.stateMachine = nil
            downloadTask.downloadTask = nil
        }
        
        func filenamesGetted() {
            guard let downloadTask = self.downloadTask else { return }
            switch downloadTask.state {
            case .downloading:
                downloadTask.resumeDownload()
                break
            case .idle, .paused, .canceled, .completed, .failed:
                break
            }
        }
        
        func filenamesGetFailed() {
            guard let downloadTask = self.downloadTask else { return }
            downloadTask.state = .idle
        }
        
        func downloadCompeted(isDownloadAll: Bool) {
            guard let downloadTask = self.downloadTask else { return }
            if isDownloadAll {
                downloadTask.state = .completed
            } else if downloadTask.state == .downloading {
                downloadTask.resumeDownload()
            }
        }
        
        func downloadErrors() {
            guard let downloadTask = self.downloadTask else { return }
            switch downloadTask.state {
            case .downloading:
                if downloadTask.currentRetryAttempts < downloadTask.maxRetryAttempts {
                    downloadTask.currentRetryAttempts += 1
                    let delayTime = downloadTask.baseDelay * pow(2.0, Double(downloadTask.currentRetryAttempts - 1))
                    downloadTask.retriveDownload(delayTime: delayTime)
                }
                else {
                    downloadTask.state = .failed
                    downloadTask.currentRetryAttempts = 0
                }
                break
            case .idle, .paused, .canceled, .completed, .failed:
                break
            }
        }
        
        func downloadProgress(progress: Double, fileSize: Double, downloadedFileSize: Double) {
            guard let downloadTask = self.downloadTask else { return }
            downloadTask.progress = progress
            downloadTask.downloadingFileSize = fileSize
            downloadTask.downloadedFileSize = downloadedFileSize
            downloadTask.currentRetryAttempts = 0
        }
    }
    
    let id = UUID()
    let repoId: String
    private let globs: [String]
    private let authToken: String?
    private let destination: URL
    private let source: URL
    private let repoURL: URL
    private let decodeData: (Data) async throws -> [String]
    private var urlSession: URLSession?
    private var resumeData: Data?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadFiles: [(URL, URL, String, Int)] = []
    private var filenames: [String] = []
    private var downloadingDestination: URL
    
    private var stateMachine: DownloadStateMachine?
    var state = State.idle
    var progress: Double = 0
    var totalFiles: Int = 0
    var downloadingFileNumber: Int = 0
    var downloadingFileName: String = ""
    var downloadingFileSize: Double = 0
    var downloadedFileSize: Double = 0
    
    private let maxRetryAttempts = 5
    private let baseDelay: TimeInterval = 1.0
    private var currentRetryAttempts = 0
    
    
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
        self.downloadingDestination = destination
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
        logger.info("DownloadModelTask deinited")
    }
    
    private func getFilenames()
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
                    var filenumber = 0
                    for filename in self.filenames {
                        let source = self.source.appending(path: filename)
                        let destination = self.destination.appending(path: filename)
                        let downloaded = FileManager.default.fileExists(atPath: destination.path)
                        guard !downloaded else { continue }
                        
                        filenumber += 1
                        self.downloadFiles.append((source, destination, filename, filenumber))
                    }
                }
            } catch {
                await stateMachine?.filenamesGetFailed()
                return
            }
            
            totalFiles = downloadFiles.count
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
                
                self.downloadingDestination = url.1
                self.downloadingFileName = url.2
                self.downloadingFileNumber = url.3
                var request = URLRequest(url: source)
                if let authToken = authToken {
                    request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                }
                
                self.downloadTask = self.urlSession?.downloadTask(with: request)
                self.downloadTask?.resume()
            }
        }
    }
    
    private func pauseDownload() {
        downloadTask?.suspend()
    }
    
    private func resumeDownload() {
        guard let downloadTask = self.downloadTask else {
            guard let resumeData = self.resumeData else {
                setupDownload()
                return
            }
            
            downloadTask = urlSession?.downloadTask(withResumeData: resumeData)
            downloadTask?.resume()
            return
        }
        
        if downloadTask.state == .suspended {
            downloadTask.resume()
        }
    }
    
    private func retriveDownload(delayTime: Double) {
        Task {
            try await Task.sleep(for: .seconds(delayTime))
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if self.state == .downloading {
                    self.resumeDownload()
                }
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
            stateMachine?.downloadProgress(progress: Double(totalBytesWritten) / Double(totalBytesExpectedToWrite),
                                           fileSize: Double(totalBytesExpectedToWrite),
                                           downloadedFileSize: Double(totalBytesWritten))
        }
    }

    func urlSession(
        _: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        FileManager.default.moveDownloadedFile(from: location, to: self.downloadingDestination)
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            stateMachine?.downloadProgress(progress: 1.0,
                                           fileSize: self.downloadingFileSize,
                                           downloadedFileSize: self.downloadedFileSize)
            self.downloadTask = nil
            self.resumeData = nil
            if !self.downloadFiles.isEmpty {
                self.downloadFiles.removeFirst()
            }
            stateMachine?.downloadCompeted(isDownloadAll: self.downloadFiles.isEmpty)
            logger.info("Destination URL: \(self.downloadingDestination), isDownloadAll: \(self.downloadFiles.isEmpty)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if self.downloadTask == nil {
                return
            }
            
            if let error = error as? NSError {
                if let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    self.resumeData = resumeData
                    logger.info("Download error occurred, resume data saved: \(resumeData.count) bytes")
                } else {
                    logger.warning("Download error occurred, but no resume data available.")
                }
                
                if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                    logger.info("Download paused, resume data saved: \(resumeData?.count ?? 0) bytes")
                    return
                }
            } else if let error = error {
                logger.error("Download failed with unexpected error: \(error.localizedDescription)")
            }
            
            self.downloadTask = nil
            self.stateMachine?.downloadErrors()
        }
    }
}

extension FileManager {
    func moveDownloadedFile(from srcURL: URL, to dstURL: URL) {
        do {
            logger.info("Found matching srcURL URL: \(srcURL)")
            logger.info("Found matching dstURL URL: \(dstURL)")
            if fileExists(atPath: dstURL.path) {
                try removeItem(at: dstURL)
            }
            
            let destinationDirectoryURL = dstURL.deletingLastPathComponent()
            try createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true, attributes: nil)
            try moveItem(at: srcURL, to: dstURL)
        }
        catch {
            logger.error("Failed to move downloaded file: \(error.localizedDescription)")
        }
    }
}
