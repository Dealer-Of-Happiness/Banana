//
//  MainView.swift
//  AIGoodbye
//
//  Main container view with side menu and chat
//

import SwiftUI
import Combine

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @State private var dragOffset: CGFloat = 0

    private let menuWidth: CGFloat = 300

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Main Content
                ChatView()
                    .frame(width: geometry.size.width)
                    .offset(x: appState.showSideMenu ? menuWidth : 0)
                    .disabled(appState.showSideMenu)

                // Dimmed overlay when menu is open
                if appState.showSideMenu {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .offset(x: menuWidth)
                        .onTapGesture {
                            appState.toggleSideMenu()
                        }
                }

                // Side Menu
                SideMenuView()
                    .frame(width: menuWidth)
                    .offset(x: appState.showSideMenu ? 0 : -menuWidth)
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if !appState.showSideMenu && value.translation.width > 0 {
                            dragOffset = min(value.translation.width, menuWidth)
                        } else if appState.showSideMenu && value.translation.width < 0 {
                            dragOffset = max(value.translation.width, -menuWidth)
                        }
                    }
                    .onEnded { value in
                        withAnimation(.spring(response: 0.3)) {
                            if !appState.showSideMenu {
                                appState.showSideMenu = value.translation.width > menuWidth / 2
                            } else {
                                appState.showSideMenu = value.translation.width > -menuWidth / 2
                            }
                            dragOffset = 0
                        }
                    }
            )
        }
    }
}

#Preview {
    MainView()
        .environmentObject(AppState())
}
