//
//  NotchOverlayView.swift
//  leanring-buddy
//
//  HeyClicky Dynamic-Island style notch: collapsed pill ↔ expanded Home /
//  Agents / Settings pages with spring-smoothed morphs.
//

import AppKit
import SwiftUI

struct NotchOverlayView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var presentation: NotchPresentationModel
    var onOpenLegacySettings: () -> Void

    @State private var isHoveringCollapsed = false
    @State private var agentMessagesUsed: Int = 2
    @State private var islandShakeOffset: CGFloat = 0
    @State private var islandHoverBoostScale: CGFloat = 1
    @State private var isExpandingFromHover = false
    private let agentMessagesLimit: Int = 25
    private let talkMessagesLimit: Int = 25

    private var spring: Animation {
        .spring(response: 0.38, dampingFraction: 0.78, blendDuration: 0.12)
    }

    var body: some View {
        // Fixed transparent panel canvas — only the island animates & receives hits.
        ZStack(alignment: .top) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            islandBody
                .frame(
                    width: presentation.islandSize.width,
                    height: presentation.islandSize.height,
                    alignment: .top
                )
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(
                                key: NotchInteractiveFrameKey.self,
                                value: geo.frame(in: .named("notchPanel"))
                            )
                    }
                )
        }
        .frame(
            width: NotchPresentationModel.panelWidth,
            height: NotchPresentationModel.panelHeight,
            alignment: .top
        )
        .coordinateSpace(name: "notchPanel")
        .onPreferenceChange(NotchInteractiveFrameKey.self) { frame in
            presentation.interactiveFrame = frame
        }
        .animation(spring, value: presentation.isExpanded)
        .animation(spring, value: presentation.page)
    }

    private var islandBody: some View {
        ZStack(alignment: .top) {
            notchChrome

            Group {
                if presentation.isExpanded {
                    expandedContent
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                            )
                        )
                } else {
                    collapsedContent
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.88, anchor: .top)),
                                removal: .opacity
                            )
                        )
                }
            }
        }
        .contentShape(NotchIslandShape(progress: presentation.isExpanded ? 1 : 0))
        .offset(x: islandShakeOffset)
        .scaleEffect(islandHoverBoostScale, anchor: .top)
        .onHover { hovering in
            handleHover(hovering)
        }
        .onChange(of: presentation.isExpanded) { expanded in
            if !expanded {
                islandShakeOffset = 0
                islandHoverBoostScale = 1
            }
        }
    }

    // MARK: - Chrome (shared morphing background)

    private var notchChrome: some View {
        NotchIslandShape(progress: presentation.isExpanded ? 1 : 0)
            .fill(Color.black)
            .shadow(
                color: Color.black.opacity(presentation.isExpanded ? 0.4 : 0.18),
                radius: presentation.isExpanded ? 16 : 3,
                x: 0,
                y: presentation.isExpanded ? 8 : 1
            )
            .animation(spring, value: presentation.isExpanded)
    }

    // MARK: - Collapsed Island

    private var collapsedContent: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: {
                expandWithEntranceFeedback(fromHover: false)
            }) {
                ZStack {
                    // Soft luminous halo behind the play glyph (official look).
                    Circle()
                        .fill(DS.Colors.accent.opacity(0.45))
                        .frame(width: 22, height: 22)
                        .blur(radius: 6)
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(DS.Colors.accentText)
                        .shadow(color: DS.Colors.accent.opacity(0.95), radius: 5)
                }
                .scaleEffect(isHoveringCollapsed ? 1.06 : 1.0)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.trailing, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            expandWithEntranceFeedback(fromHover: false)
        }
    }

    // MARK: - Expanded Shell

    private var expandedContent: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Group {
                switch presentation.page {
                case .home:
                    homePage
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                case .agents:
                    agentsPage
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                case .settings:
                    settingsPage
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            if presentation.page != .settings {
                tabCapsule(.home)
                tabCapsule(.agents)
            } else {
                Button(action: {
                    withAnimation(spring) {
                        presentation.page = .home
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(DS.Colors.surface2))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            Spacer(minLength: 8)

            if presentation.page == .agents {
                Button(action: {}) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .nativeTooltip("Search agents")
            }

            upgradeButton

            Button(action: {
                withAnimation(spring) {
                    if presentation.page == .settings {
                        presentation.page = .home
                    } else {
                        presentation.page = .settings
                    }
                }
            }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(
                        presentation.page == .settings
                            ? DS.Colors.textPrimary
                            : DS.Colors.textSecondary
                    )
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill(
                                presentation.page == .settings
                                    ? DS.Colors.surface3
                                    : DS.Colors.surface2
                            )
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Settings")
        }
    }

    private func tabCapsule(_ page: NotchPresentationModel.Page) -> some View {
        let isSelected = presentation.page == page
        let title = page == .home ? "Home" : "Agents"
        let icon = page == .home ? "house.fill" : "sparkles"

        return Button(action: {
            withAnimation(spring) {
                presentation.page = page
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected ? DS.Colors.surface3 : Color.clear)
                    .overlay(
                        Capsule()
                            .stroke(
                                isSelected ? DS.Colors.borderStrong.opacity(0.7) : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private var upgradeButton: some View {
        Button(action: {
            if let url = URL(string: "https://heyclicky.com") {
                NSWorkspace.shared.open(url)
            }
        }) {
            Text("Upgrade to Pro")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(DS.Colors.accent))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Home

    private var homePage: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                addSkillsColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                shortcutsColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 4)

            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.5))
                .padding(.vertical, 10)

            homeBottomBar
                .padding(.bottom, 12)
        }
    }

    private var addSkillsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add skills")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Skills give HeyClicky superpowers")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {}) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 56, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.top, 8)
            .nativeTooltip("Add a skill (coming soon)")
        }
    }

    private var shortcutsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("⌘")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("Shortcuts")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            VStack(spacing: 8) {
                shortcutRow(
                    label: "Talk",
                    capsules: BuddyPushToTalkShortcut.currentShortcutOption.keyCapsuleLabels
                )
                shortcutRow(label: "Text", capsules: ["ctrl", "2×"])
                shortcutRow(label: "Dictate", capsules: ["fn", "control"])
                shortcutRow(label: "Hands-free...", capsules: ["fn", "control", "2×"])
            }
            .padding(.top, 2)
        }
    }

    private func shortcutRow(label: String, capsules: [String]) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 88, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(capsules, id: \.self) { capsule in
                    ShortcutKeyCapsule(label: capsule)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var homeBottomBar: some View {
        HStack(spacing: 12) {
            Text("Integrations")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {}) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(DS.Colors.surface2))
            }
            .buttonStyle(.plain)
            .pointerCursor()

            integrationChip("Cursor")
            integrationChip("Slack")

            Spacer(minLength: 8)

            undockCursorButton

            Button(action: {}) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("About HeyClicky")
        }
    }

    private func integrationChip(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(DS.Colors.surface2))
            .overlay(
                Capsule().stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
            )
    }

    private var undockCursorButton: some View {
        Button(action: {
            companionManager.setClickyCursorEnabled(!companionManager.isClickyCursorEnabled)
        }) {
            HStack(spacing: 8) {
                Image(systemName: companionManager.isClickyCursorEnabled ? "play.fill" : "play.slash.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DS.Colors.accentText)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(DS.Colors.accentSubtle))

                Text(companionManager.isClickyCursorEnabled ? "Undock Cursor" : "Dock Cursor")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(DS.Colors.surface2))
            .overlay(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Agents

    private var agentsPage: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 24)

            Image(systemName: "play.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.accentText)
                .shadow(color: DS.Colors.accent.opacity(0.7), radius: 8)

            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Text("No agents yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            Text("Just say or type what you need. HeyClicky picks up agentic tasks automatically.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Settings

    private var settingsPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                planSection
                communitySection
                supportSection
                connectionsSection
                customizationSection
            }
            .padding(.bottom, 16)
        }
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("PLAN")

            Text("Hi, you're on our Free plan.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("You get a monthly allotment of Talk and Agent messages. Upgrade anytime.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            usageBar(
                title: "Talk to HeyClicky",
                used: 0,
                limit: talkMessagesLimit,
                fill: 0
            )

            usageBar(
                title: "Agent Messages",
                used: agentMessagesUsed,
                limit: agentMessagesLimit,
                fill: CGFloat(agentMessagesUsed) / CGFloat(agentMessagesLimit)
            )

            Button(action: {
                if let url = URL(string: "https://heyclicky.com") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Upgrade HeyClicky")
                            .font(.system(size: 13, weight: .semibold))
                        Text("See HeyClicky Pro and Max, then pick the plan that fits.")
                            .font(.system(size: 11, weight: .medium))
                            .opacity(0.9)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundColor(.white)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(DS.Colors.accent)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.top, 4)
        }
    }

    private func usageBar(title: String, used: Int, limit: Int, fill: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text("\(used)/\(limit)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DS.Colors.surface3)
                    Capsule()
                        .fill(DS.Colors.blue400)
                        .frame(width: max(0, geo.size.width * min(max(fill, 0), 1)))
                        .animation(.easeOut(duration: 0.55), value: fill)
                }
            }
            .frame(height: 4)
        }
    }

    private var communitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("COMMUNITY")
            HStack(spacing: 10) {
                settingsGridButton(title: "WhatsApp", systemImage: "phone.fill") {
                    openURL("https://heyclicky.com")
                }
                settingsGridButton(title: "Reddit", systemImage: "bubble.left.and.bubble.right.fill") {
                    openURL("https://heyclicky.com")
                }
            }
        }
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("SUPPORT & UPDATES")
            HStack(spacing: 10) {
                settingsGridButton(title: "Request a Feature", systemImage: "lightbulb.fill") {}
                settingsGridButton(title: "Report a bug", systemImage: "ant.fill") {}
            }
            settingsRowButton(title: "Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                onOpenLegacySettings()
            }
        }
    }

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("CONNECTIONS")
            settingsChevronRow(title: "Integrations", subtitle: nil, systemImage: "link") {}
            settingsChevronRow(
                title: "Skills",
                subtitle: "Power-ups that attach to HeyClicky",
                systemImage: "puzzlepiece.extension.fill"
            ) {}
        }
    }

    private var customizationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("CUSTOMIZATION")
            settingsChevronRow(
                title: "Dictation",
                subtitle: nil,
                systemImage: "waveform",
                trailing: AnyView(
                    HStack(spacing: 8) {
                        Text("NEW")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(DS.Colors.accent))
                        Text("Automatic")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                )
            ) {}

            settingsChevronRow(title: "Shortcuts", subtitle: nil, systemImage: "keyboard") {}

            settingsChevronRow(
                title: "Cursor",
                subtitle: nil,
                systemImage: "cursorarrow",
                trailing: AnyView(
                    Image(systemName: companionManager.isClickyCursorEnabled ? "play.fill" : "play.slash.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(DS.Colors.accentText)
                )
            ) {
                companionManager.setClickyCursorEnabled(!companionManager.isClickyCursorEnabled)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(DS.Colors.textTertiary)
            .tracking(0.6)
    }

    private func settingsGridButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func settingsRowButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func settingsChevronRow(
        title: String,
        subtitle: String?,
        systemImage: String,
        trailing: AnyView? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }

                Spacer(minLength: 0)

                if let trailing {
                    trailing
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Hover / Expand Entrance

    private func handleHover(_ hovering: Bool) {
        // Ignore hover flicker while the entrance morph is locked — shake/scale
        // and size changes otherwise fire leave→enter loops (multi haptic + collapse).
        if presentation.isEntranceLocked || isExpandingFromHover {
            return
        }

        withAnimation(.easeOut(duration: 0.15)) {
            isHoveringCollapsed = hovering && !presentation.isExpanded
        }

        guard hovering else { return }
        guard !presentation.isExpanded else { return }
        expandWithEntranceFeedback(fromHover: true)
    }

    /// Trackpad haptic buzz + short visual shake, then spring-expand the island.
    private func expandWithEntranceFeedback(fromHover: Bool) {
        guard !presentation.isExpanded else { return }
        guard !isExpandingFromHover else { return }
        guard !presentation.isEntranceLocked else { return }

        isExpandingFromHover = true
        // Lock out mouse-leave collapse + re-entrant hover for the whole morph.
        presentation.beginEntranceLock(holdingFor: 0.7)

        performNotchHapticFeedback()

        // Visual "vibrate": one short buzz, then morph open (no repeated hover cycles).
        withAnimation(.easeInOut(duration: 0.035).repeatCount(3, autoreverses: true)) {
            islandShakeOffset = 2.0
        }
        withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
            islandHoverBoostScale = 1.08
        }

        let expandDelay: TimeInterval = fromHover ? 0.1 : 0.06
        DispatchQueue.main.asyncAfter(deadline: .now() + expandDelay) {
            self.islandShakeOffset = 0
            withAnimation(self.spring) {
                self.islandHoverBoostScale = 1
                let targetPage: NotchPresentationModel.Page =
                    self.presentation.page == .settings ? .home : self.presentation.page
                self.presentation.expand(to: targetPage)
            }
            // Allow a future hover expand only after this entrance finishes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                self.isExpandingFromHover = false
            }
        }
    }

    private func performNotchHapticFeedback() {
        // Single alignment pulse — avoid multi-tick which feels like a bug when
        // combined with any residual hover noise.
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment,
            performanceTime: .now
        )
    }

    private func openURL(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Interactive Frame Preference

private struct NotchInteractiveFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Island Shape (official: top-out / bottom-in — NOT a capsule)

/// Official collapsed HeyClicky chrome:
/// - **Top-left / top-right: curve outward** (flare to the screen edge; top is the widest)
/// - **Bottom-left / bottom-right: curve inward** (normal rounded corners cutting into the body)
/// This is NOT a capsule (capsule = same semicircle on both ends).
private struct NotchIslandShape: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t = smoothstep(min(max(progress, 0), 1))
        let w = rect.width
        let h = max(rect.height, 1)

        // Collapsed: clear top-out / bottom-in (NOT a capsule).
        // Expanded: flush panel with large inward bottom corners.
        let wing = lerp(10, 0, t)         // bottom inset — top stays full-width (向外)
        let topFlare = lerp(13, 2, t)     // shoulder drop from the top outer corners
        let bottomR = lerp(min(h * 0.48, 15), 22, t)  // 向内 bottom arcs


        return topOutBottomInPath(
            width: w,
            height: h,
            wing: wing,
            topFlare: topFlare,
            bottomRadius: min(bottomR, h * 0.5)
        )
    }

    /// Top edge full-width with outward shoulders; bottom edge inset with inward arcs.
    private func topOutBottomInPath(
        width w: CGFloat,
        height h: CGFloat,
        wing: CGFloat,
        topFlare: CGFloat,
        bottomRadius: CGFloat
    ) -> Path {
        let wing = max(wing, 0)
        // Keep bottom arcs inside the inset bottom edge.
        let maxBottomR = max(0.5, (w - 2 * wing) * 0.5 - 0.5)
        let bottomR = min(min(max(bottomRadius, 0.5), maxBottomR), h * 0.5)
        let flare = min(max(topFlare, 0.5), h * 0.55)

        let bottomLeft = wing
        let bottomRight = w - wing

        var path = Path()

        // Flat top, flush with the screen — full width (the “outward” span).
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: w, y: 0))

        // Top-right 向外: leave the top-right outer corner, flare along the side,
        // then arrive above the bottom-right inward arc.
        path.addCurve(
            to: CGPoint(x: bottomRight, y: h - bottomR),
            control1: CGPoint(x: w, y: flare),
            control2: CGPoint(x: bottomRight + wing * 0.35, y: (h - bottomR) * 0.55)
        )

        // Bottom-right 向内圆弧
        path.addArc(
            center: CGPoint(x: bottomRight - bottomR, y: h - bottomR),
            radius: bottomR,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )

        path.addLine(to: CGPoint(x: bottomLeft + bottomR, y: h))

        // Bottom-left 向内圆弧
        path.addArc(
            center: CGPoint(x: bottomLeft + bottomR, y: h - bottomR),
            radius: bottomR,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )

        // Top-left 向外: mirror of the right shoulder back to (0,0).
        path.addCurve(
            to: CGPoint(x: 0, y: 0),
            control1: CGPoint(x: bottomLeft - wing * 0.35, y: (h - bottomR) * 0.55),
            control2: CGPoint(x: 0, y: flare)
        )

        path.closeSubpath()
        return path
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    private func smoothstep(_ t: CGFloat) -> CGFloat {
        t * t * (3 - 2 * t)
    }
}

// MARK: - Shortcut Key Capsule

private struct ShortcutKeyCapsule: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
    }
}
