//
//  DownloadTaskView.swift
//  ChatMLX
//
//  Created by John Mai on 2024/8/11.
//

import SwiftUI

struct DownloadTaskView: View {
    @Bindable var task: DownloadModelTask
    @Environment(SettingsViewModel.self) private var settingsViewModel

    var body: some View {
        HStack {
            VStack {
                HStack {
                    Text(task.repoId.deletingPrefix("mlx-community/"))
                        .font(.headline)
                        .lineLimit(1)
                        .help(task.repoId)

                    Spacer()

                    Text("\(task.progress * 100, specifier: "%.2f")%")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .frame(width: 100, alignment: .trailing)
                }

                HStack {
                    Text(task.downloadingFileName)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .frame(alignment: .trailing)
                    
                    Spacer()
                    
                    Text("\(String(format: "%.2f", task.downloadedFileSize/(1024.0 * 1024.0))) / \(String(format: "%.2f", task.downloadingFileSize/(1024.0 * 1024.0))) Mbytes")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white.opacity(0.7))

                    Text("\(task.downloadingFileNumber) / \(task.totalFiles)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }

                ProgressView(value: task.progress)
                    .progressViewStyle(LinearProgressViewStyle())
                    .frame(height: 4)
            }

            Spacer()

            if task.state == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                if task.state == .downloading {
                    Button(action: {
                        task.pause()
                    }) {
                        Image(systemName: "pause.circle")
                            .foregroundColor(.yellow)
                    }
                } else {
                    HStack {
                        Button(action: {
                            task.start()
                        }) {
                            Image(systemName: "play.circle")
                                .foregroundColor(.green)
                        }

                        Button(action: {
                            removeTask(task)
                        }) {
                            Image(systemName: "trash")
                                .renderingMode(.original)
                        }
                    }
                }
            }
        }
        .imageScale(.large)
        .buttonStyle(.plain)
        .padding()
        .background(.black.opacity(0.3))
        .listRowSeparator(.hidden)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black, radius: 2)
    }
    
    private func removeTask(_ task: DownloadModelTask) {
        task.cancel()
        settingsViewModel.tasks.removeAll { $0.id == task.id }
    }
}
