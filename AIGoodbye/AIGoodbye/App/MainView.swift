//
//  MainView.swift
//  AIGoodbye
//
//  Main container: the chat, and the conversation list beside or over it.
//
//  Two presentations of one list, chosen by the window's width, never by
//  the device:
//
//  - Compact width (any iPhone, the outer display of iPhone Duo, an iPad
//    Slide Over window): a drawer that slides over the chat and follows
//    the finger during edge swipes.
//  - Regular width (iPad, the inner display of iPhone Duo, a wide iPhone
//    Mirroring window): a sidebar that sits beside the chat, like Mail or
//    Notes, so the larger display shows one more level of the hierarchy
//    instead of the same single column with wider margins.
//
//  Regular width alone is not enough for the sidebar: the window also has
//  to be wide enough that what is left for the chat is a comfortable
//  column. The inner display of iPhone Duo held upright is regular width
//  at 669 pt, and a sidebar there left a 389 pt chat whose toolbar - which
//  on that display shares its row with the status bar - had no room for
//  the title. Below the threshold the drawer is used, as it is on any
//  iPhone, the way NavigationSplitView collapses its sidebar on an iPad
//  held upright.
//
//  The chat is the SAME view in both, in the same place in the hierarchy.
//  That matters more than it looks: an iPhone Duo resizes the window every
//  time it folds, and if the two layouts were two branches of an `if`, a
//  fold would rebuild the chat - dismissing whatever it was presenting,
//  including a recorder in the middle of a meeting.
//

import SwiftUI
import Combine

/// How the conversation list is presented beside a chat: a drawer that
/// slides over it, or a sidebar that sits next to it. `MainView` decides
/// per window and hands the answer down, so the chat's toolbar button
/// toggles the right one without guessing from its size class.
enum ConversationListStyle {
    case drawer
    case sidebar
}

extension EnvironmentValues {
    @Entry var conversationListStyle: ConversationListStyle = .drawer
}

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var dragOffset: CGFloat = 0
    /// Drawer width. The window can be narrower than the drawer: in iPad
    /// Slide Over a fixed 300 pt covers almost everything and pushes the
    /// chat off-screen.
    @State private var menuWidth: CGFloat = 300
    /// Sidebar width, in regular width.
    @State private var sidebarWidth: CGFloat = 320

    /// Narrowest window that gets a sidebar. Leaves the chat at least an
    /// iPhone's width beside a 280 pt sidebar. Just under it: the inner
    /// display of iPhone Duo held upright (669 pt) and half of a 13-inch
    /// iPad in landscape (678 pt); just over: an iPad mini held upright
    /// (744 pt).
    nonisolated static let sidebarMinimumWidth: CGFloat = 700

    /// Whether a window of this size class and width shows the sidebar.
    nonisolated static func usesSidebar(sizeClass: UserInterfaceSizeClass?, width: CGFloat) -> Bool {
        sizeClass == .regular && width >= sidebarMinimumWidth
    }

    /// How far the drawer is currently revealed, combining state and live drag.
    private var drawerReveal: CGFloat {
        let base: CGFloat = appState.showSideMenu ? menuWidth : 0
        return min(max(base + dragOffset, 0), menuWidth)
    }

    var body: some View {
        GeometryReader { geometry in
            let twoPane = Self.usesSidebar(sizeClass: horizontalSizeClass, width: geometry.size.width)
            // On an iPhone Duo folded like a book, the inner display is
            // divided at the hinge. Put the list in one half and the chat
            // in the other, so the divider sits on the fold instead of a
            // column running across it.
            let fold = Self.verticalFold(in: geometry)
            let listWidth: CGFloat = twoPane ? (fold?.listWidth ?? sidebarWidth) : menuWidth
            let chatStart: CGFloat = twoPane ? (fold?.chatStart ?? sidebarWidth) : menuWidth
            let reveal: CGFloat = twoPane ? (appState.showSidebar ? chatStart : 0) : drawerReveal
            let chatWidth = twoPane ? max(geometry.size.width - reveal, 0) : geometry.size.width

            ZStack(alignment: .leading) {
                // Laid out at the trailing edge in two-pane mode rather than
                // offset there: safe-area insets follow layout frames, not
                // offsets, so an offset chat kept the leading inset (an
                // empty gutter beside the hinge or the Dynamic Island) and
                // lost the trailing one. The drawer path still offsets,
                // because the chat under an open drawer is dimmed and
                // disabled anyway. Same modifiers in both modes, with
                // different values, so the view's identity never changes.
                ChatView(viewModel: appState.chatViewModel)
                    .environment(\.conversationListStyle, twoPane ? .sidebar : .drawer)
                    .frame(width: chatWidth)
                    .frame(maxWidth: .infinity, alignment: twoPane ? .trailing : .leading)
                    .offset(x: twoPane ? 0 : reveal)
                    .disabled(!twoPane && appState.showSideMenu)
                    .accessibilityHidden(!twoPane && appState.showSideMenu)

                // Dimmed overlay while the drawer is open (or being dragged
                // open). Never for the sidebar: the chat stays usable.
                if !twoPane, reveal > 0 {
                    Color.black.opacity(0.3 * (reveal / menuWidth))
                        .ignoresSafeArea()
                        .offset(x: reveal)
                        .onTapGesture {
                            appState.toggleSideMenu()
                        }
                        .accessibilityLabel(Text("Close menu"))
                        .accessibilityAddTraits(.isButton)
                }

                // The list. Hidden from VoiceOver while off-screen - offset
                // views otherwise stay swipe-reachable.
                SideMenuView(isSidebar: twoPane)
                    .frame(width: listWidth)
                    .offset(x: Self.listOffset(
                        reveal: reveal,
                        listWidth: listWidth,
                        leadingInset: geometry.safeAreaInsets.leading
                    ))
                    .accessibilityHidden(reveal == 0)
                    .overlay(alignment: .trailing) {
                        // A one-point separator. `Divider` alone takes its
                        // axis from an enclosing stack and, with none, lies
                        // horizontally across the middle of the list.
                        if twoPane, reveal > 0 {
                            Rectangle()
                                .fill(Color(.separator))
                                .frame(width: 1)
                                .ignoresSafeArea()
                        }
                    }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { value in
                        // Edge swipes belong to the drawer. A sidebar is
                        // toggled from the toolbar, not dragged.
                        guard !twoPane else { return }
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
                        guard !twoPane else { return }
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
            .onChange(of: geometry.size.width, initial: true) { _, width in
                // Drawer: leave at least 15% of the window showing the chat.
                menuWidth = min(320, max(240, width * 0.85))
                // Sidebar: a third of the window, within reason. On an
                // iPhone Duo folded like a book the inner display divides
                // in two at the hinge; Duo-aware builds refine this so the
                // divider lands on the fold (see `sidebarWidth(for:)`).
                sidebarWidth = Self.sidebarWidth(for: width)
            }
            .onChange(of: twoPane, initial: true) { _, isTwoPane in
                // Crossing from sidebar to drawer, or back, resets the live
                // drag and closes a drawer that would otherwise reappear
                // thrown open over the chat on the smaller display.
                dragOffset = 0
                if isTwoPane, appState.showSideMenu { appState.showSideMenu = false }
            }
        }
    }

    /// Where the list sits for a given reveal. Hidden means entirely
    /// off-screen, which is not the same as `-listWidth`: the geometry
    /// here starts at the safe area, and in landscape there is a leading
    /// inset beside the Dynamic Island, so a list parked at `-listWidth`
    /// left its last 60 points showing in that strip - a column of
    /// half-buttons down the edge of every landscape screen.
    nonisolated static func listOffset(reveal: CGFloat, listWidth: CGFloat, leadingInset: CGFloat) -> CGFloat {
        guard listWidth > 0 else { return 0 }
        let hidden = -(listWidth + leadingInset)
        let fraction = min(max(reveal / listWidth, 0), 1)
        return hidden * (1 - fraction)
    }

    /// The sidebar's width for a window of `width` points.
    nonisolated static func sidebarWidth(for width: CGFloat) -> CGFloat {
        min(360, max(280, width * 0.34))
    }

    /// Where a hinge divides the window left from right, if one does right
    /// now: the list ends where the fold begins and the chat starts where
    /// it ends. Nil when the display is flat, closed, or folded the other
    /// way (top from bottom), where a side-by-side split makes no sense.
    private static func verticalFold(in geometry: GeometryProxy) -> (listWidth: CGFloat, chatStart: CGFloat)? {
        guard #available(iOS 27.1, *) else { return nil }
        let divisions = geometry.reservedRegions(kind: .division)
        guard let fold = divisions.first(where: { $0.frame.height > $0.frame.width }) else { return nil }
        // The frame already includes the region's margins.
        let listWidth = fold.frame.minX
        let chatStart = fold.frame.maxX
        guard listWidth > 200, chatStart < geometry.size.width - 200 else { return nil }
        return (listWidth, chatStart)
    }
}

#Preview {
    MainView()
        .environmentObject(AppState())
}
