//
//  MLXCommunityView.swift
//  ChatMLX
//
//  Created by John Mai on 2024/8/11.
//

import Alamofire
import Luminare
import SwiftUI

struct MLXCommunityView: View {
    @Environment(SettingsViewModel.self) var settingsViewModel

    @State private var searchQuery = ""
    @State var isFetching = false
    @State var next: String?
    @State var status: Status = .isLoading
    @State var sortValue: String = "downloads"

    private let sessionManager: Session

    enum Status {
        case isLoading
        case idle
        case error(String)
    }

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024, diskCapacity: 0)

        sessionManager = Session(configuration: configuration)
    }

    var body: some View {
        @Bindable var settingsViewModel = settingsViewModel
        VStack {
            LuminareSection {
                UltramanTextField(
                    $searchQuery, placeholder: Text("Search...")
                ) {
                    Task {
                        settingsViewModel.remoteModels = []
                        await fetchModels(search: searchQuery)
                    }
                }
            }
            .padding(.top)
            .padding(.horizontal)

            List {
                ForEach($settingsViewModel.remoteModels) { model in
                    MLXCommunityItemView(model: model)
                }
                lastRowView
            }
            .scrollContentBackground(.hidden)
            .scrollIndicatorsFlash(onAppear: true)
            .scrollIndicatorsFlash(trigger: settingsViewModel.remoteModels.count)
        }
        .onAppear {
            Task {
                await fetchModels()
            }
        }
        .ultramanNavigationTitle("MLX Community")
        .ultramanToolbar(alignment: .trailing) {
            Button(action: {
                sortValue = "downloads"
                Task {
                    settingsViewModel.remoteModels = []
                    await fetchModels()
                }
            }) {
                Image(systemName: "arrow.down.to.line.compact")
            }
            .disabled(isFetching)
            .buttonStyle(.plain)
            
            Button(action: {
                sortValue = "createdAt"
                Task {
                    settingsViewModel.remoteModels = []
                    await fetchModels()
                }
            }) {
                Image(systemName: "clock.arrow.circlepath")
            }
            .disabled(isFetching)
            .buttonStyle(.plain)
        }
    }

    @MainActor
    @ViewBuilder
    var lastRowView: some View {
        ZStack(alignment: .center) {
            switch status {
            case .isLoading:
                ProgressView()
            case .idle:
                EmptyView()
            case .error(let error):
                Text(error)
            }
        }
        .frame(height: 50)
        .frame(maxWidth: .infinity)
        .onAppear {
            Task {
                await loadMoreModelsIfNeeded()
            }
        }
    }

    func parseLinks(_ links: String?) -> [String: String] {
        guard let links else { return [:] }

        var linkDict = [String: String]()
        let linkComponents = links.split(separator: ",")

        for component in linkComponents {
            let parts = component.split(separator: ";")
            if parts.count == 2 {
                let urlPart = parts[0].trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let relPart = parts[1].trimmingCharacters(
                    in: .whitespacesAndNewlines)

                let url = urlPart.trimmingCharacters(
                    in: CharacterSet(charactersIn: "<>"))
                let rel = relPart.replacingOccurrences(of: "rel=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

                linkDict[rel] = url
            }
        }

        return linkDict
    }

    func fetchModels(search: String? = nil, retryCount: Int = 0) async {
        guard !isFetching else { return }
        isFetching = true
        status = .isLoading
        
        let maxRetryAttempts = 5
        let baseDelay: TimeInterval = 1.0

        var urlComponents = URLComponents(
            string: "https://huggingface.co/api/models")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "author", value: "mlx-community"),
            URLQueryItem(name: "sort", value: sortValue),
            URLQueryItem(name: "pipeline_tag", value: "text-generation"),
        ]

        if let search {
            queryItems.append(URLQueryItem(name: "search", value: search))
        }

        urlComponents.queryItems = queryItems

        guard let url = urlComponents.url else { return }

        sessionManager.request(url).validate().responseDecodable(
            of: [RemoteModel].self
        ) { response in
            switch response.result {
            case .success(let decodedResponse):
                settingsViewModel.remoteModels = decodedResponse
                if let links = response.response?.allHeaderFields["Link"]
                    as? String
                {
                    next = parseLinks(links)["next"]
                }
                status = .idle
            case .failure(let error):
                logger.error("Failed to fetch models: \(error)")
                
                if retryCount < maxRetryAttempts {
                    isFetching = false
                    let delay = baseDelay * pow(2.0, Double(retryCount))
                    logger.info("Retrying in \(String(format: "%.1f", delay)) seconds...")

                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        Task {
                            await fetchModels(retryCount: retryCount + 1)
                        }
                    }
                    return
                } else {
                    logger.error("Max retry attempts reached. Fetching models failed permanently.")
                }
                
                status = .error(error.localizedDescription)
            }
            isFetching = false
        }
    }

    func loadMoreModelsIfNeeded() async {
        guard !isFetching, let nextURL = URL(string: next ?? "") else { return }
        isFetching = true
        status = .isLoading

        sessionManager.request(nextURL).validate().responseDecodable(
            of: [RemoteModel].self
        ) { response in
            switch response.result {
            case .success(let decodedResponse):
                settingsViewModel.remoteModels.append(
                    contentsOf: decodedResponse)
                if let links = response.response?.allHeaderFields["Link"]
                    as? String
                {
                    next = parseLinks(links)["next"]
                }
                status = .idle
            case .failure(let error):
                logger.error("Failed to fetch more models: \(error)")
                status = .error(error.localizedDescription)
            }
            isFetching = false
        }
    }
}
