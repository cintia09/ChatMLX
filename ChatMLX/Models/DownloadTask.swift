//
//  DownloadTask.swift
//  ChatMLX
//
//  Created by John Mai on 2024/8/11.
//

import Defaults
import Foundation
import Logging

@Observable
class DownloadTask: Identifiable, Equatable {
    let logger = Logger(label: Bundle.main.bundleIdentifier!)

    private let maxRetryAttempts = 5
    private let baseDelay: TimeInterval = 1.0
    
    static func == (lhs: DownloadTask, rhs: DownloadTask) -> Bool {
        lhs.id == rhs.id
    }

    let id: UUID
    let repoId: String
    var progress: Double = 0
    var isDownloading = false
    var isCompleted = false
    var error: Error?
    var hub: HubApi?
    var totalUnitCount: Int64 = 0
    var completedUnitCount: Int64 = 0

    init(_ repoId: String) {
        self.id = UUID()
        self.repoId = repoId
    }

    func start(retryCount: Int = 0) {
        self.isDownloading = true
        self.error = nil
        self.progress = 0
        let currentEndpoint = Defaults[.huggingFaceEndpoint]
        self.hub = HubApi(
            downloadBase: FileManager.default.temporaryDirectory, endpoint: currentEndpoint)
        
        Task { [weak self] in
            guard let self = self else { return }
            
            do {
                let repo = Hub.Repo(id: self.repoId)
                let temporaryModelDirectory = try await self.hub!.snapshot(
                    from: repo, matching: ["*.safetensors", "*.json"]
                ) { progress in
                    Task { @MainActor in
                        self.progress = progress.fractionCompleted
                        self.totalUnitCount = progress.totalUnitCount
                        self.completedUnitCount = progress.completedUnitCount
                    }
                }

                self.hub = nil

                try await moveToDocumentsDirectory(from: temporaryModelDirectory)

                await MainActor.run {
                    self.isDownloading = false
                    self.isCompleted = true
                    self.progress = 1.0
                }
            } catch {
                guard self.hub != nil else { return }
                logger.error("DownloadTask Error: \(error.localizedDescription)")
                
                if retryCount < maxRetryAttempts {
                    let delay = baseDelay * pow(2.0, Double(retryCount)) // 指数退避延迟
                    logger.info("Retrying download in \(String(format: "%.1f", delay)) seconds...") // 记录重试延迟

                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { // 使用 DispatchQueue.asyncAfter 延迟执行重试
                        self.start(retryCount: retryCount + 1) // ✅ 递归调用 start，增加 retryCount
                    }
                    return // 提前返回，不设置 isDownloading = false，因为重试会再次设置
                } else {
                    logger.error("Max retry attempts reached for download task. Download failed permanently.") // ✅ 达到最大重试次数，记录最终失败
                }
                
                await MainActor.run {
                    self.error = error
                    self.isDownloading = false
                    self.hub = nil
                }
            }
        }
    }

    func stop() {
        if let hub {
            hub.cancelCurrentDownload()
            self.isDownloading = false
            self.hub = nil
        }
    }

    private func moveToDocumentsDirectory(from temporaryModelDirectory: URL) async throws {
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let downloadBase = documents.appending(component: "huggingface").appending(path: "models")

        let destinationPath = downloadBase.appendingPathComponent(self.repoId)
        
        logger.info("Model start moved to: \(destinationPath.path)")
        
        try fileManager.createDirectory(at: destinationPath, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationPath.path) {
            try fileManager.removeItem(at: destinationPath)
        }

        try fileManager.copyItem(at: temporaryModelDirectory, to: destinationPath)

        logger.info("Model end moved to: \(destinationPath.path)")
    }
}
