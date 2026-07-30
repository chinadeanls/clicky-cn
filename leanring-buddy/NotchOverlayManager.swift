//
//  NotchOverlayManager.swift
//  leanring-buddy
//
//  Fixed large transparent NSPanel at top-center. Only the black island
//  inside animates; transparent regions return nil from hitTest so clicks
//  pass through to apps underneath.
//

import AppKit
import Combine
import SwiftUI

private final class NotchKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Hosting view that only accepts hits inside the animated island bounds.
private final class NotchHitThroughHostingView: NSHostingView<NotchOverlayView> {
    var interactiveFrameProvider: (() -> CGRect)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let island = interactiveFrameProvider?() ?? .zero
        guard !island.isEmpty else { return nil }

        // `island` is reported in SwiftUI top-left coordinates within this view.
        let appKitIsland = CGRect(
            x: island.minX,
            y: bounds.height - island.minY - island.height,
            width: island.width,
            height: island.height
        )

        guard appKitIsland.insetBy(dx: -1, dy: -1).contains(point) else {
            return nil
        }
        return super.hitTest(point)
    }
}

/// Shared presentation state — island content size morphs; panel stays fixed.
@MainActor
final class NotchPresentationModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case home
        case agents
        case settings

        var id: String { rawValue }
    }

    @Published var isExpanded: Bool = false
    @Published var page: Page = .home

    /// Island frame in the panel's SwiftUI coordinate space (top-left origin).
    /// Used by the hosting view for click-through hit testing.
    @Published var interactiveFrame: CGRect = .zero

    static let collapsedWidth: CGFloat = 380
    static let collapsedHeight: CGFloat = 32

    /// Matches official HeyClicky proportions (~25–30% width on a 14" MacBook).
    static let expandedWidth: CGFloat = 580
    static let homeHeight: CGFloat = 248
    static let agentsHeight: CGFloat = 260
    static let settingsWidth: CGFloat = 380
    static let settingsHeight: CGFloat = 560

    /// Fixed transparent hit-through container (slightly larger than max island).
    static let panelWidth: CGFloat = 640
    static let panelHeight: CGFloat = 600

    var islandSize: CGSize {
        guard isExpanded else {
            return CGSize(width: Self.collapsedWidth, height: Self.collapsedHeight)
        }
        switch page {
        case .home:
            return CGSize(width: Self.expandedWidth, height: Self.homeHeight)
        case .agents:
            return CGSize(width: Self.expandedWidth, height: Self.agentsHeight)
        case .settings:
            return CGSize(width: Self.settingsWidth, height: Self.settingsHeight)
        }
    }

    func expand(to page: Page = .home) {
        self.page = page
        isExpanded = true
    }

    func collapse() {
        isExpanded = false
    }

    /// While true, ignore mouse-leave collapse and suppress re-entrant hover expand/haptics.
    /// Set for the whole entrance animation so mid-morph hover flicker can't loop.
    @Published private(set) var isEntranceLocked: Bool = false
    private var entranceLockWorkItem: DispatchWorkItem?

    func beginEntranceLock(holdingFor duration: TimeInterval = 0.65) {
        entranceLockWorkItem?.cancel()
        isEntranceLocked = true
        let work = DispatchWorkItem { [weak self] in
            self?.isEntranceLocked = false
            self?.entranceLockWorkItem = nil
        }
        entranceLockWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func endEntranceLock() {
        entranceLockWorkItem?.cancel()
        entranceLockWorkItem = nil
        isEntranceLocked = false
    }
}

@MainActor
final class NotchOverlayManager {
    private var panel: NSPanel?
    private var hostingView: NotchHitThroughHostingView?
    private var screenChangeObserver: NSObjectProtocol?
    private var eligibilityCancellable: AnyCancellable?
    private var presentationCancellable: AnyCancellable?
    private var clickOutsideMonitor: Any?
    private var mouseLeavePollTimer: Timer?
    private var collapseDebounceWorkItem: DispatchWorkItem?

    private let companionManager: CompanionManager
    private let presentation = NotchPresentationModel()
    private let onOpenMenuBarSettings: () -> Void
    private let mouseLeaveCollapseDelay: TimeInterval = 0.2

    init(companionManager: CompanionManager, onOpenSettings: @escaping () -> Void) {
        self.companionManager = companionManager
        self.onOpenMenuBarSettings = onOpenSettings
        bindVisibility()
        bindPresentation()
        observeScreenChanges()
        updateVisibility()
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        mouseLeavePollTimer?.invalidate()
    }

    // MARK: - Visibility

    private func bindVisibility() {
        eligibilityCancellable = companionManager.$isNotchUIEligible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVisibility()
            }
    }

    private func bindPresentation() {
        presentationCancellable = presentation.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateInteractionMonitors()
                }
            }
    }

    private func updateVisibility() {
        if companionManager.isNotchUIEligible {
            showNotch()
        } else {
            hideNotch()
        }
    }

    private func showNotch() {
        if panel == nil {
            createPanel()
        }
        positionFixedPanel()
        panel?.orderFrontRegardless()
    }

    private func hideNotch() {
        presentation.collapse()
        cancelScheduledCollapse()
        removeInteractionMonitors()
        panel?.orderOut(nil)
    }

    // MARK: - Panel Lifecycle

    private func createPanel() {
        let rootView = NotchOverlayView(
            companionManager: companionManager,
            presentation: presentation,
            onOpenLegacySettings: onOpenMenuBarSettings
        )

        let hosting = NotchHitThroughHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        hosting.interactiveFrameProvider = { [weak presentation] in
            presentation?.interactiveFrame ?? .zero
        }
        hostingView = hosting

        let size = CGSize(
            width: NotchPresentationModel.panelWidth,
            height: NotchPresentationModel.panelHeight
        )

        let notchPanel = NotchKeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        notchPanel.isFloatingPanel = true
        notchPanel.level = .statusBar
        notchPanel.isOpaque = false
        notchPanel.backgroundColor = .clear
        notchPanel.hasShadow = false
        notchPanel.hidesOnDeactivate = false
        notchPanel.isExcludedFromWindowsMenu = true
        notchPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        notchPanel.isMovableByWindowBackground = false
        notchPanel.titleVisibility = .hidden
        notchPanel.titlebarAppearsTransparent = true
        notchPanel.animationBehavior = .none
        notchPanel.contentView = hosting
        panel = notchPanel

        hosting.frame = NSRect(origin: .zero, size: size)
    }

    /// Panel size is fixed; only recenters on the primary screen.
    private func positionFixedPanel() {
        guard let panel else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let size = CGSize(
            width: NotchPresentationModel.panelWidth,
            height: NotchPresentationModel.panelHeight
        )
        let originX = screen.frame.midX - (size.width / 2)
        let originY = screen.frame.maxY - size.height

        panel.setFrame(
            NSRect(x: originX, y: originY, width: size.width, height: size.height),
            display: true
        )
        hostingView?.frame = NSRect(origin: .zero, size: size)
    }

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.companionManager.isNotchUIEligible else { return }
                self.positionFixedPanel()
            }
        }
    }

    // MARK: - Interaction Monitors

    private func updateInteractionMonitors() {
        if presentation.isExpanded {
            installClickOutsideMonitor()
            // Don't watch mouse-leave until the expand morph finishes — otherwise
            // a mid-animation interactiveFrame mismatch collapses the panel and
            // retriggers hover expand (haptic loop → ends collapsed).
            if presentation.isEntranceLocked {
                cancelScheduledCollapse()
                removeMouseLeaveMonitor()
            } else {
                installMouseLeaveMonitor()
            }
        } else {
            cancelScheduledCollapse()
            removeInteractionMonitors()
        }
    }

    private func removeInteractionMonitors() {
        removeClickOutsideMonitor()
        removeMouseLeaveMonitor()
    }

    /// Poll mouse location while expanded. Prefer polling over global mouseMoved
    /// monitors — the latter often require Accessibility permission and miss events
    /// once hit-through makes this window ignore the cursor.
    private func installMouseLeaveMonitor() {
        removeMouseLeaveMonitor()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleGlobalMouseMovement()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseLeavePollTimer = timer
    }

    private func handleGlobalMouseMovement() {
        guard presentation.isExpanded, panel?.isVisible == true else { return }
        guard !presentation.isEntranceLocked else {
            cancelScheduledCollapse()
            return
        }

        guard let screenFrame = islandFrameInScreenCoordinates() else {
            scheduleCollapseFromMouseLeave()
            return
        }

        // Generous pad during normal use so moving between controls doesn't flicker.
        if screenFrame.insetBy(dx: -10, dy: -10).contains(NSEvent.mouseLocation) {
            cancelScheduledCollapse()
        } else {
            scheduleCollapseFromMouseLeave()
        }
    }

    private func scheduleCollapseFromMouseLeave() {
        guard collapseDebounceWorkItem == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseDebounceWorkItem = nil
            guard self.presentation.isExpanded else { return }

            if let screenFrame = self.islandFrameInScreenCoordinates(),
               screenFrame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) {
                return
            }

            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                self.presentation.collapse()
            }
        }
        collapseDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + mouseLeaveCollapseDelay, execute: work)
    }

    private func cancelScheduledCollapse() {
        collapseDebounceWorkItem?.cancel()
        collapseDebounceWorkItem = nil
    }

    private func removeMouseLeaveMonitor() {
        mouseLeavePollTimer?.invalidate()
        mouseLeavePollTimer = nil
    }

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel?.isVisible == true else { return }
                guard let screenFrame = self.islandFrameInScreenCoordinates() else {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        self.presentation.collapse()
                    }
                    return
                }
                if !screenFrame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        self.presentation.collapse()
                    }
                }
            }
        }
    }

    private func islandFrameInScreenCoordinates() -> CGRect? {
        guard let panel, let hostingView else { return nil }
        let island = presentation.interactiveFrame
        guard !island.isEmpty else { return nil }

        let appKitInHosting = CGRect(
            x: island.minX,
            y: hostingView.bounds.height - island.minY - island.height,
            width: island.width,
            height: island.height
        )
        return panel.convertToScreen(hostingView.convert(appKitInHosting, to: nil))
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
