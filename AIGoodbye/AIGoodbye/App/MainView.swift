//
//  MainView.swift
//  AIGoodbye
//
//  Main container view with side menu and chat.
//  v3.0: the menu now follows your finger during edge swipes.
//

import SwiftUI
import Combine

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @State private var dragOffset: CGFloat = 0

    private let menuWidth: CGFloat = 300

    /// How far the menu is currently revealed, combining state and live drag.
    private var revealAmount: CGFloat {
        let base: CGFloat = appState.showSideMenu ? menuWidth : 0
        return min(max(base + dragOffset, 0), menuWidth)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Main Content
                ChatView()
                    .frame(width: geometry.size.width)
                    .offset(x: revealAmount)
                    .disabled(appState.showSideMenu)

                // Dimmed overlay when menu is open (or being dragged open)
                if revealAmount > 0 {
                    Color.black.opacity(0.3 * (revealAmount / menuWidth))
                        .ignoresSafeArea()
                        .offset(x: revealAmount)
                        .onTapGesture {
                            appState.toggleSideMenu()
                        }
                        .accessibilityLabel(Text("Close menu"))
                        .accessibilityAddTraits(.isButton)
                }

                // Side Menu
                SideMenuView()
                    .frame(width: menuWidth)
                    .offset(x: revealAmount - menuWidth)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { value in
                        // Only react to clearly horizontal drags, and only open
                        // from the left edge, so chat scrolling stays untouched.
                        let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.5
                        guard horizontal else { return }

                        if !appState.showSideMenu {
                            guard value.startLocation.x < 60 else { return }
                            if value.translation.width > 0 {
                                dragOffset = min(value.translation.width, menuWidth)
                            }
                        } else if value.translation.width < 0 {
                            dragOffset = max(value.translation.width, -menuWidth)
                        }
                    }
                    .onEnded { value in
                        let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.5
                        withAnimation(.spring(response: 0.3)) {
                            defer { dragOffset = 0 }
                            guard horizontal else { return }

                            if !appState.showSideMenu {
                                if value.startLocation.x < 60 {
                                    appState.showSideMenu = value.translation.width > menuWidth / 2
                                }
                            } else {
                                appState.showSideMenu = value.translation.width > -menuWidth / 2
                            }
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
