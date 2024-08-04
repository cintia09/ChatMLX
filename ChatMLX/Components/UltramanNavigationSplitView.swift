//
//  UltramanNavigationSplitView.swift
//  ChatMLX
//
//  Created by John Mai on 2024/8/3.
//

import SwiftUI

struct UltramanNavigationSplitView<Sidebar: View, Detail: View>: View {
    @Binding var sidebarWidth: CGFloat
    @State private var lastNonZeroWidth: CGFloat = 0
    let minSidebarWidth: CGFloat = 200
    let maxSidebarWidth: CGFloat = 300
    let sidebar: () -> Sidebar
    let detail: () -> Detail
    let title: String
    
    @State private var isDragging = false
    @State private var isSidebarVisible = true
    
    var body: some View {
        GeometryReader { _ in
            HStack(spacing: 0) {
                if isSidebarVisible {
                    sidebar()
                        .frame(width: max(sidebarWidth, 0))
                    
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 3)
                        .onHover { inside in
                            if inside {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let newWidth = sidebarWidth + value.translation.width
                                    sidebarWidth = min(max(newWidth, minSidebarWidth), maxSidebarWidth)
                                }
                        )
                }
                
                VStack(spacing: 0) {
                    header()
                    Divider()
                    detail()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
    
    @ViewBuilder
    func header() -> some View {
        VStack(spacing: 0) {
            Spacer()
                
            HStack {
                if !isSidebarVisible {
                    Spacer()
                        .frame(width: 80)
                }
                
                Button {
                    toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.leading")
                }.buttonStyle(.plain)

                Spacer()
                Text(title)
                    .font(.title2)

                Spacer()

                Image(systemName: "square.and.arrow.up")
            }
            .padding(.horizontal, 10)
            .padding(.trailing, 5)
            Spacer()
        }
        .frame(height: 50)
        .foregroundColor(.white)
    }
    
    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.3)) {
            if isSidebarVisible {
                lastNonZeroWidth = sidebarWidth
                sidebarWidth = 0
            } else {
                sidebarWidth = lastNonZeroWidth
            }
            isSidebarVisible.toggle()
        }
    }
}
