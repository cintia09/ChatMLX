//
//  RemoteModel.swift
//  ChatMLX
//
//  Created by John Mai on 2024/8/11.
//

import Foundation
import Defaults

struct RemoteModel: Codable, Identifiable {
    let id: String
    let repoId: String
    let modelId: String
    let likes: Int
    let trendingScore: Int?
    let isPrivate: Bool
    let downloads: Int
    let tags: [String]
    let pipelineTag: String?
    let libraryName: String?
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id = "_id"
        case repoId = "id"
        case likes
        case trendingScore
        case isPrivate = "private"
        case downloads
        case tags
        case pipelineTag = "pipeline_tag"
        case libraryName = "library_name"
        case createdAt
        case modelId
    }

    private enum RepoType: String {
        case models
        case datasets
        case spaces
    }

    private struct Repo {
        let id: String
        let type: RepoType
    }
        
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        repoId = try container.decode(String.self, forKey: .repoId)
        modelId = try container.decode(String.self, forKey: .modelId)
        likes = try container.decode(Int.self, forKey: .likes)
        trendingScore = try container.decodeIfPresent(Int.self, forKey: .trendingScore) ?? 0
        isPrivate = try container.decode(Bool.self, forKey: .isPrivate)
        downloads = try container.decode(Int.self, forKey: .downloads)
        tags = try container.decode([String].self, forKey: .tags)
        pipelineTag = try container.decodeIfPresent(String.self, forKey: .pipelineTag)
        libraryName = try container.decodeIfPresent(String.self, forKey: .libraryName)

        let dateString = try container.decode(String.self, forKey: .createdAt)
        let dateFormatter = DateFormatter()

        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        if let date = dateFormatter.date(from: dateString) {
            createdAt = date
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt, in: container,
                debugDescription: "Date string does not match expected format")
        }
    }
    
    private func getFilenames(from repo: Repo, matching globs: [String] = []) async throws
        -> [String]
    {
        // Read repo info and only parse "siblings"
        let url = URL(string: "\(endpoint)/api/\(repo.type)/\(repo.id)")!
        let (data, _) = try await httpGet(for: url)
        let response = try JSONDecoder().decode(SiblingsResponse.self, from: data)
        let filenames = response.siblings.map { $0.rfilename }
        guard globs.count > 0 else { return filenames }

        var selected: Set<String> = []
        for glob in globs {
            selected = selected.union(filenames.matching(glob: glob))
        }
        return Array(selected)
    }
    
    func getModelURL() -> URL? {
        let currentEndpoint = Defaults[.huggingFaceEndpoint]
        let repo = Repo(id: repoId, type: .models)
        let downloadBase: URL = FileManager.default.temporaryDirectory
        downloadBase.appending(component: repo.type.rawValue).appending(component: repo.id)
        
        var url = URL(string: currentEndpoint)
        url.appending(repo.id)
        url.appending(path: "resolve/main")  // TODO: revisions
        url.appending(path: relativeFilename)

        var destination: URL {
            repoDestination.appending(path: relativeFilename)
        }

        var downloaded: Bool {
            FileManager.default.fileExists(atPath: destination.path)
        }
        
        let filenames = try await getFilenames(from: repoId, matching: ["*.safetensors", "*.json"])
        return URL(string: "\(baseURL)/\(repoId)")
    }
}
