//
//  MLXCommunityItemView.swift
//  ChatMLX
//
//  Created by John Mai on 2024/8/11.
//

import SwiftUI

struct HStackWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0 // 默认宽度为 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue() // 始终使用最新的宽度值
    }
}

struct MLXCommunityItemView: View {
    @Binding var model: RemoteModel
    @Environment(SettingsViewModel.self) var settingsViewModel

    var animationSpeed: Double = 40.0
    
    @State private var textWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var isAnimating = false
    @State private var isHovering = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.repoId.deletingPrefix("mlx-community/"))
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button(action: download) {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)

                Button(action: {
                    if let url = URL(
                        string: "https://huggingface.co/\(model.repoId)")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Label("\(model.downloads)", systemImage: "arrow.down.circle")
                    .font(.subheadline)

                Label("\(model.likes)", systemImage: "heart.fill")
                    .font(.subheadline)
                    .foregroundColor(.red.opacity(0.6))
                
                Spacer()

                if let pipelineTag = model.pipelineTag {
                    Text(pipelineTag)
                        .font(.subheadline)
                        .padding(4)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(4)
                }
            }

            HStack {
                Text("\(model.createdAt)")
                    .font(.subheadline)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(model.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(4)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                .fixedSize(horizontal:true, vertical: false)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Color.clear
                            .preference(key: HStackWidthPreferenceKey.self, value: geometry.size.width)
                    }
                }
                .offset(x: scrollOffset, y: 0)
                .onPreferenceChange(HStackWidthPreferenceKey.self) { width in
                    textWidth = width
                }
            }
            .clipped()
            .onHover { hovered in
                isHovering = hovered
                if hovered {
                    startAnimation()
                } else {
                    stopAnimation()
                }
            }
        }
        .padding()
        .background(.black.opacity(0.3))
        .listRowSeparator(.hidden)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black, radius: 2)
    }

    func startAnimation() {
        guard !isAnimating else { return }
        isAnimating = true
        withAnimation(.linear(duration: animationDuration()).repeatForever(autoreverses: false)) {
            scrollOffset = -textWidth
        }
    }

    func stopAnimation() {
        isAnimating = false
        withAnimation(.linear(duration: 0.2)) {
            scrollOffset = 0
        }
    }
    
    func animationDuration() -> Double {
        return Double(textWidth) / animationSpeed
    }
    
    private func download() {
        let task = DownloadModelTask(model.repoId)
        task.start()

        settingsViewModel.tasks.append(task)
        settingsViewModel.activeTabID = .downloadManager
    }
}
