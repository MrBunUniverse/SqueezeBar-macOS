import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing
import ImageIO
import AVFoundation
import PDFKit

func loadDroppedFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    var urls: [URL] = []
    let lock = NSLock()
    let group = DispatchGroup()

    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            defer { group.leave() }
            let url = item as? URL ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            guard let url, url.isFileURL else { return }
            lock.lock()
            urls.append(url)
            lock.unlock()
        }
    }

    group.notify(queue: .main) {
        Task { @MainActor in
            if urls.isEmpty { AppState.shared.reportNoSupportedFiles(urls: []) }
            completion(urls)
        }
    }
}

enum SurfaceOpacity {
    static let minimum = 0.45

    static func value(for transparency: Double) -> Double {
        1 - transparency * (1 - minimum)
    }
}

private struct SurfaceOpacityKey: EnvironmentKey {
    static let defaultValue = 1.0
}

extension EnvironmentValues {
    var surfaceOpacity: Double {
        get { self[SurfaceOpacityKey.self] }
        set { self[SurfaceOpacityKey.self] = newValue }
    }
}

private struct SurfaceFill<S: Shape, Style: ShapeStyle>: View {
    @Environment(\.surfaceOpacity) private var opacity
    let shape: S
    let style: Style

    var body: some View {
        shape.fill(style).opacity(opacity)
    }
}

extension Shape {
    func surfaceFill<Style: ShapeStyle>(_ style: Style) -> some View {
        SurfaceFill(shape: self, style: style)
    }
}

private extension Color {
    static func surfaceWhite(_ opacity: Double, for scheme: ColorScheme) -> Color {
        Color.white.opacity(scheme == .dark ? opacity * 0.68 : opacity)
    }
}

private struct DarkControlSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    let shape: S
    var enabled = true
    var dash: [CGFloat] = []
    var highlighted = false
    var borderless = false
    var behindContent = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if !behindContent { surface }
            }
            .background {
                if behindContent { surface }
            }
            .onHover { isHovered = $0 }
    }

    @ViewBuilder private var surface: some View {
        if colorScheme == .dark && enabled {
            shape.surfaceFill(Color(white: (isHovered || highlighted) ? 0.14 : 0.10))
                .overlay {
                    if !borderless {
                        shape.strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.05), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 0.5, dash: dash)
                        )
                    }
                }
                .shadow(color: .black.opacity(0.20), radius: 3.5, y: 1)
                .allowsHitTesting(false)
        }
    }
}

private extension View {
    func darkControlSurface<S: InsettableShape>(_ shape: S, enabled: Bool = true, dash: [CGFloat] = [], highlighted: Bool = false, borderless: Bool = false, behindContent: Bool = false) -> some View {
        modifier(DarkControlSurface(shape: shape, enabled: enabled, dash: dash, highlighted: highlighted, borderless: borderless, behindContent: behindContent))
    }
}

private struct GlassPrismRim: View {
    private static let cornerRadius: CGFloat = 24
    private static let channelOffset: CGFloat = 0.65
    private static let innerInset: CGFloat = 1.1
    private static let lineWidth: CGFloat = 0.9
    private static let opacity: Double = 0.38
    private static let lightModeScale: Double = 0.4
    private static let cornerReach: CGFloat = 64

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius)
        let spectrum = AngularGradient(
            colors: [.cyan, .blue, .purple, .red, .orange, .yellow, .cyan],
            center: .center, startAngle: .degrees(0), endAngle: .degrees(360)
        )
        ZStack {
            shape.strokeBorder(spectrum, lineWidth: Self.lineWidth)
                .offset(x: -Self.channelOffset, y: -Self.channelOffset)
            shape.inset(by: Self.innerInset)
                .strokeBorder(spectrum, lineWidth: Self.lineWidth)
                .rotationEffect(.degrees(180))
                .offset(x: Self.channelOffset, y: Self.channelOffset)
        }
        .mask {
            ZStack {
                LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center)
                ForEach(0..<4) { corner in
                    RadialGradient(
                        colors: [.white.opacity(corner < 2 ? 1 : 0.35), .clear],
                        center: UnitPoint(x: corner % 2 == 0 ? 0 : 1, y: corner < 2 ? 0 : 1),
                        startRadius: 0, endRadius: Self.cornerReach
                    )
                }
            }
        }
        .opacity(Self.opacity * (colorScheme == .dark ? 1 : Self.lightModeScale))
        .blendMode(colorScheme == .dark ? .plusLighter : .multiply)
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}

struct DetachedGlassRim: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24)
        ZStack {
            GlassPrismRim()
            if colorScheme == .dark {
                shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 4)
                    .blur(radius: 3)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
                    .clipShape(shape)
            }
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(colorScheme == .dark ? 0.35 : 0.18),
                             .white.opacity(colorScheme == .dark ? 0.05 : 0.025)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .allowsHitTesting(false)
    }
}

public struct QuickPopoverView: View {
    @ObservedObject private var updates = UpdateChecker.shared
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    // Shows job progress (header, activity list), so it has to observe the job board directly.
    @ObservedObject private var jobs = AppState.shared.jobs
    public var isDetachedWindow: Bool = false
    /// A hidden window drops its SwiftUI tree (HostedPopoverRoot), so the chosen tab is kept here for the reopen.
    private static var lastTab: PopoverTab = .activity
    @State private var selectedTab: PopoverTab = QuickPopoverView.lastTab

    @State private var isWindowDropTargeted: Bool = false
    @State private var activeFormatCategory: MediaFormatCategory = .images
    @State private var isFormatDrawerExpanded: Bool = false
    
    // Project Folders & Batch Edit State
    @State private var isEditMode: Bool = false
    @State private var selectedResultIds: Set<UUID> = []
    @State private var isCreatingFolder: Bool = false
    @State private var newFolderName: String = ""
    @State private var isBatchRenaming: Bool = false
    @State private var renamePattern: String = ""
    @State private var showClearConfirmation: Bool = false
    @State private var showResetStatsConfirmation: Bool = false
    
    // Liquid Glass Collective Hover States (Apple-like Focus Bounce)
    @State private var hoveredTargetLimitMode: TargetSizeMode? = nil
    @State private var hoveredUIScaleOption: UIScaleOption? = nil
    
    enum PopoverTab: String, CaseIterable {
        case activity = "Activity"
        case settings = "Settings"
    }
    
    enum MediaFormatCategory: String, CaseIterable {
        case images = "Images"
        case videos = "Video"
        case audio = "Audio"
        case pdf = "PDF"
        
        var displayName: String {
            switch self {
            case .images: return String(localized: "Images")
            case .videos: return String(localized: "Video")
            case .audio: return String(localized: "Audio")
            case .pdf: return "PDF"
            }
        }
    }
    
    public init(isDetachedWindow: Bool = false) {
        self.isDetachedWindow = isDetachedWindow
    }
    
    public var body: some View {
        let scale = state.uiScale.scaleFactor
        
        GeometryReader { proxy in
            let availableWidth = proxy.size.width
            let availableHeight = proxy.size.height
            let contentWidth = availableWidth / scale
            let contentHeight = availableHeight / scale
            
            ZStack(alignment: .topLeading) {
                innerMainContent
                    .frame(width: contentWidth, height: contentHeight)
                    .scaleEffect(scale, anchor: .topLeading)
            }
        }
        .frame(minWidth: state.uiScale.baseWidth - 20, maxWidth: .infinity, minHeight: state.uiScale.baseHeight - 40, maxHeight: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: isDetachedWindow ? 24 : 0)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(1 - state.appTransparency))
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: isDetachedWindow ? 24 : 0)
                    .fill(Color.black.opacity(0.35 * state.appTransparency))
                    .allowsHitTesting(false)

                if state.appGlassFrost > 0 {
                    RoundedRectangle(cornerRadius: isDetachedWindow ? 24 : 0)
                        .fill(.ultraThinMaterial)
                        .opacity(state.appGlassFrost)
                        .allowsHitTesting(false)
                }

                if #available(macOS 26.0, *) {
                    Color.clear
                        .glassEffect(.clear.tint(Color.black.opacity(0.12)), in: RoundedRectangle(cornerRadius: isDetachedWindow ? 24 : 0))
                        .allowsHitTesting(false)
                }

                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: isDetachedWindow ? 24 : 0)
                        .fill(Color.black.opacity(0.32 * (1 - state.appTransparency * 0.4)))
                        .allowsHitTesting(false)
                }

                if isDetachedWindow {
                    DetachedGlassRim()
                }

                if isWindowDropTargeted {
                    RoundedRectangle(cornerRadius: isDetachedWindow ? 24 : 0)
                        .strokeBorder(state.accentColor, lineWidth: 2.5)
                        .background(state.accentColor.opacity(0.10))
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: isDetachedWindow ? 24 : 0))
        .ignoresSafeArea()
        .onDrop(of: [.item], isTargeted: $isWindowDropTargeted) { providers in
            extractAndProcess(providers: providers)
        }
        .overlay(alignment: .top) {
            if isWindowDropTargeted {
                Label("Drop here", systemImage: "arrow.down.doc.fill")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(state.accentColor, lineWidth: 1.5))
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isWindowDropTargeted)
        .sheet(item: $state.inspectedResult) { result in
            BeforeAfterInspectorView(result: result) {
                state.inspectedResult = nil
            }
        }
        .background(
            Group {
                Button("") {
                    if let textResponder = NSApp.keyWindow?.firstResponder as? NSText {
                        textResponder.paste(nil)
                    } else {
                        state.squeezeClipboard()
                    }
                }
                .keyboardShortcut("v", modifiers: [.command])
                .disabled(isCreatingFolder || isBatchRenaming)

                Button("") {
                    FloatingDropWindowController.shared.toggleWindow()
                }
                .keyboardShortcut("d", modifiers: [.command])
            }
            .opacity(0)
            .allowsHitTesting(false)
        )
        .font(.system(.body, design: .rounded))
        .environment(\.surfaceOpacity, SurfaceOpacity.value(for: state.appTransparency))
    }
    
    private var innerMainContent: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerView
            if let release = updates.bannerRelease {
                HStack {
                    Text("Version \(release.tag_name) is available")
                    Spacer()
                    Button("View update") {
                        if let url = release.trustedURL { NSWorkspace.shared.open(url) }
                    }
                    Button("Later") { updates.dismiss() }
                }
                .font(.system(size: 11, design: .rounded))
                .padding(10)
                .accessibilityElement(children: .contain)
            }
            
            Divider()
                .opacity(0.3)
            
            // Tab Selector
            tabSelectorView
            
            // Tab Content
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 14) {
                    if selectedTab == .activity {
                        statsSummaryCard
                        
                        // Active Format Configuration Deck (Sliders, Quality, Resolution, Target Size, Codecs)
                        activeFormatSettingsDeck
                        
                        if !jobs.activeJobs.isEmpty {
                            activeQueueSection
                        }
                        
                        if !state.failedJobs.isEmpty {
                            failedJobsSection
                        }
                        
                        recentHistorySection
                    } else {
                        settingsSection
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: selectedTab)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 18)
            }
            
            Divider()
                .opacity(0.3)
            
            // Bottom Action Bar
            footerView
        }
    }
    
    // MARK: - Header
    private var headerView: some View {
        let isDetached = isDetachedWindow || state.isDetached
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                // The animated S mark stands in for the "S" of the name. Idle: slow light sweep;
                // while squeezing: bars light up with overall progress, like the menu bar icon.
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Group {
                        if jobs.isProcessing {
                            SqueezeProgressMark(progress: jobs.overallProgress, color: state.accentColor)
                        } else {
                            SqueezeWaveMark(lit: state.accentColor)
                        }
                    }
                    .frame(width: 17, height: 20)

                    Text(verbatim: "queezeBar")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .tracking(0.35)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("SqueezeBar")
                
                Group {
                    if state.totalBytesSaved > 0 {
                        Text("Saved \(ByteCountFormatter.string(fromByteCount: state.totalBytesSaved, countStyle: .file)) so far")
                    } else {
                        Text("Universal Media Optimizer")
                    }
                }
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundColor(.secondary)
            }
            // Static title: let clicks through to the window drag handle behind the header.
            .allowsHitTesting(false)
            
            Spacer()
            
            if jobs.isProcessing {
                HStack(spacing: 5) {
                    ProgressView()
                        .scaleEffect(0.60)
                        .frame(width: 12, height: 12)
                    Text("Optimizing...")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(state.accentColor)
                    
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            state.cancelAllJobs()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel All Compression")
                    .accessibilityLabel("Cancel All Compression")
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(state.accentColor.opacity(0.12)))
            } else if state.showSuccessBadge {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundColor(.green)
                    Text("Complete")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.12)))
            }
        }
        .padding(.leading, isDetached ? 96 : 20)
        .padding(.trailing, 18)
        .padding(.top, isDetached ? 16 : 14)
        .padding(.bottom, 12)
        // The detached window is dragged by its header (isMovableByWindowBackground is off, see FloatingDropWindow).
        .background { if isDetachedWindow { WindowDragHandle() } }
    }
    
    // MARK: - Tab Selector
    private var tabSelectorView: some View {
        HStack(spacing: 2) {
            tabButton(.activity, title: "Activity", icon: "bolt.horizontal.fill", selectedIcon: "bolt.horizontal.fill")
            tabButton(.settings, title: "Settings", icon: "gearshape", selectedIcon: "gearshape.fill")
                .help("App & Theme Settings")
        }
        .modifier(SelectedPillDragGesture(options: PopoverTab.allCases, selected: selectedTab, style: .tab) { selectTab($0) })
        .padding(2)
        .background(
            Capsule()
                .surfaceFill(Color.black.opacity(colorScheme == .dark ? 0.34 : 0.24))
                .overlay(Capsule().strokeBorder(Color.surfaceWhite(0.08, for: colorScheme), lineWidth: 0.5))
        )
        .clipShape(Capsule())
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func selectTab(_ tab: PopoverTab) {
        selectedTab = tab
        Self.lastTab = tab
        if tab == .settings {
            FloatingDropWindowController.shared.ensureMinimumDimensions(width: 490, height: 660)
            StatusBarController.sharedInstance?.ensurePopoverDimensions(width: 490, height: 660)
        }
    }

    private func tabButton(_ tab: PopoverTab, title: LocalizedStringKey, icon: String, selectedIcon: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectTab(tab)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? selectedIcon : icon)
                    .font(.system(size: 11, design: .rounded))
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium, design: .rounded))
            }
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(LiquidPillPressStyle())
        .liquidPillOption(tab)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Live Format Selector Cards (Images, Video, Audio, PDF)
    private var statsSummaryCard: some View {
        HStack(spacing: 6) {
            profileTile(.images, icon: "photo", primary: state.imageFormatPolicy.displayName, secondary: state.imageResolutionScale < 1 ? String(localized: "\(Int(state.imageQualitySlider * 100))% · \(Int(state.imageResolutionScale * 100))% size") : String(localized: "\(Int(state.imageQualitySlider * 100))% quality"))
            profileTile(.videos, icon: "film", primary: state.videoCodec == .hevc ? "HEVC" : (state.videoCodec == .h264 ? "H.264" : "GIF"), secondary: state.videoFramerate == .original ? String(localized: "\(Int(state.videoQualitySlider * 100))% quality") : "\(state.videoFramerate.displayName) · \(Int(state.videoQualitySlider * 100))%")
            profileTile(.audio, icon: "waveform", primary: state.audioBitrate.shortName, secondary: state.stripMetadata ? String(localized: "Metadata removed") : String(localized: "Metadata kept"))
            profileTile(.pdf, icon: "doc.text.fill", primary: "\(Int(state.pdfDPI.dpiValue)) DPI", secondary: state.pdfGrayscale ? String(localized: "\(Int(state.pdfImageQuality * 100))% quality · Grayscale") : String(localized: "\(Int(state.pdfImageQuality * 100))% quality"))
        }
    }

    private func profileTile(_ category: MediaFormatCategory, icon: String, primary: String, secondary: String) -> some View {
        let title = category.displayName
        let isExpanded = activeFormatCategory == category && isFormatDrawerExpanded

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                if isExpanded {
                    isFormatDrawerExpanded = false
                } else {
                    activeFormatCategory = category
                    isFormatDrawerExpanded = true
                }
            }
        } label: {
            LiveProfileGlowCard(accentColor: .white, isSelected: isExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundColor(.primary.opacity(0.85))
                        Text(title)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(isExpanded ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 2)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .foregroundColor(isExpanded ? .primary : .secondary.opacity(0.85))
                    }
                    .frame(height: 16)

                    Text(primary)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text(secondary)
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .help("Click to toggle \(title) compression settings")
    }
    
    // MARK: - Failed Files (kept until dismissed so errors aren't missed)
    private var failedJobsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Couldn't compress", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.red.opacity(0.9))
                Spacer()
                Button("Dismiss all") {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        state.clearFailures()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
            }
            
            ForEach(state.failedJobs) { failure in
                HStack(alignment: .top, spacing: 9) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.fileName)
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(failure.message)
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            state.dismissFailure(id: failure.id)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss error for \(failure.fileName)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.red.opacity(0.18), lineWidth: 0.5)
                        )
                )
            }
        }
    }
    
    // MARK: - Active Queue Section
    private var activeQueueSection: some View {
        let unfinished = jobs.activeJobs.filter { !$0.isFinished }
        
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Current queue")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer()
                
                if state.hasPausableJobs {
                    let allPaused = state.areAllPausableJobsPaused
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            if allPaused {
                                state.resumeAllJobs()
                            } else {
                                state.pauseAllJobs()
                            }
                        }
                    } label: {
                        Label(allPaused ? "Resume All" : "Pause All", systemImage: allPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(state.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule()
                                    .fill(state.accentColor.opacity(0.12))
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(state.accentColor.opacity(0.25), lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(allPaused ? "Resume all paused tasks" : "Pause running video and audio tasks")
                }
                
                if !unfinished.isEmpty {
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            state.cancelAllJobs()
                        }
                    } label: {
                        Text(unfinished.count > 1 ? "Cancel All" : "Cancel")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(.red.opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule()
                                    .fill(Color.red.opacity(0.12))
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.red.opacity(0.25), lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Cancel running compression tasks")
                }
            }
            
            ForEach(jobs.activeJobs) { job in
                let progressPct = Int(job.progress * 100)
                
                HStack(spacing: 9) {
                    FileThumbnailView(url: job.fileURL, mediaType: job.mediaType, size: 30)
                    
                    VStack(alignment: .leading, spacing: 2.5) {
                        Text(job.fileURL.lastPathComponent)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        if let caption = job.outcomeCaption {
                            Text(caption).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Text(job.statusText)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(job.error == "Cancelled" || job.isFinished || job.isPaused ? .secondary : state.accentColor)
                    }
                    
                    Spacer(minLength: 4)
                    
                    if !job.isFinished {
                        // Compact Progress Pill
                        Text("\(progressPct)%")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundColor(state.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(state.accentColor.opacity(0.15))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(state.accentColor.opacity(0.3), lineWidth: 0.5)
                            )
                        
                        if job.canPause {
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    if job.isPaused {
                                        state.resumeJob(id: job.id)
                                    } else {
                                        state.pauseJob(id: job.id)
                                    }
                                }
                            } label: {
                                Image(systemName: job.isPaused ? "play.circle.fill" : "pause.circle.fill")
                                    .font(.system(size: 14, design: .rounded))
                                    .foregroundColor(job.isPaused ? state.accentColor : .secondary.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .help(job.isPaused ? "Resume this task" : "Pause this task")
                            .accessibilityLabel(job.isPaused ? "Resume \(job.fileURL.lastPathComponent)" : "Pause \(job.fileURL.lastPathComponent)")
                        }
                        
                        // Individual Cancel Button
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                state.cancelJob(id: job.id)
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14, design: .rounded))
                                .foregroundColor(.secondary.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Cancel this compression task")
                        .accessibilityLabel("Cancel \(job.fileURL.lastPathComponent)")
                    } else if job.error == "Cancelled" {
                        Text("Cancelled")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Capsule().surfaceFill(Color.surfaceWhite(0.06, for: colorScheme)))
                    }
                }
                .padding(9)
                .background(
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            // Base Glass Card
                            RoundedRectangle(cornerRadius: 10)
                                .surfaceFill(
                                    LinearGradient(
                                        colors: [Color.surfaceWhite(0.045, for: colorScheme), Color.surfaceWhite(0.015, for: colorScheme)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            
                            // Unified Light Opacity Progress Fill Across Card
                            if !job.isFinished {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                state.accentColor.opacity(0.22),
                                                state.accentColor.opacity(0.12)
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(0, geo.size.width * CGFloat(min(1.0, max(0.0, job.progress)))))
                                    .animation(.linear(duration: ProgressGate.minInterval), value: job.progress)
                            }
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) {
                    if !job.isFinished {
                        Rectangle()
                            .fill(state.accentColor.opacity(0.45))
                            .frame(height: 1)
                    }
                }
            }
        }
    }
    
    // MARK: - Recent History Section with Collapsible Folders & Batch Edit
    private func chooseFilesToSqueeze() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add Files")
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            let urls = panel.urls
            Task {
                await MediaCompressionEngine.shared.processDroppedURLs(urls)
            }
        }
    }

    /// Resting drop target for when history hides the full Quick Squeeze zone.
    private var compactDropStrip: some View {
        Button {
            chooseFilesToSqueeze()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "square.and.arrow.down")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(isDropTargeted ? state.accentColor : .secondary)
                Text(isDropTargeted ? "Release to Squeeze" : "Drop files to squeeze")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.primary)
                Spacer()
                Text("Choose…")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .surfaceFill(isDropTargeted ? state.accentColor.opacity(0.10) : Color.surfaceWhite(0.03, for: colorScheme))
                    .darkControlSurface(RoundedRectangle(cornerRadius: 10), enabled: !isDropTargeted, dash: [4])
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isDropTargeted ? state.accentColor.opacity(0.7) : (colorScheme == .dark ? .clear : Color.surfaceWhite(0.12, for: colorScheme)),
                                style: StrokeStyle(lineWidth: isDropTargeted ? 1.5 : 1, dash: isDropTargeted ? [] : [4])
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Drop files here, or click to choose files to compress")
        .onDrop(of: [.item], isTargeted: $isDropTargeted) { providers in
            extractAndProcess(providers: providers)
        }
    }

    private var recentHistorySection: some View {
        // Lazy: a history of 50 results would otherwise build 50 rows and 50 thumbnail tasks on open.
        LazyVStack(alignment: .leading, spacing: 8) {
            if !(state.recentResults.isEmpty && state.customFolders.isEmpty) {
                VStack(spacing: 8) {
                    compactDropStrip
                    squeezeClipboardButton
                }

                if !state.stagedQueue.isEmpty {
                    customQueueSection
                }
            }

            // Header Bar
            HStack(spacing: 6) {
                Text("Recent")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)



                Spacer()
                
                Menu {
                    Button {
                        newFolderName = String(localized: "Project \(state.customFolders.count + 1)")
                        isCreatingFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    if !state.recentResults.isEmpty {
                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: {
                            Label("Clear History…", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .background(Color.clear.darkControlSurface(RoundedRectangle(cornerRadius: 7)))
                .help("Recent actions")
                .accessibilityLabel("Recent actions")

                if !state.recentResults.isEmpty {
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            isEditMode.toggle()
                            if !isEditMode {
                                selectedResultIds.removeAll()
                            }
                        }
                    } label: {
                        Text(isEditMode ? "Done" : "Edit")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(isEditMode ? state.contrastTextColor : .secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule().surfaceFill(isEditMode ? state.accentColor : Color.surfaceWhite(0.06, for: colorScheme))
                                    .darkControlSurface(Capsule(), enabled: !isEditMode)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Batch Action Toolbar (Visible in Edit Mode)
            if isEditMode {
                batchActionToolbar
            }
            
            if state.recentResults.isEmpty && state.customFolders.isEmpty {
                emptyHistoryView
            } else {
                // 1. Custom Project Folders
                ForEach(state.customFolders) { folder in
                    folderSectionView(folder: folder)
                }
                
                // 2. Uncategorized Recent Items
                let uncategorized = state.recentResults.filter { $0.folderId == nil }
                if !uncategorized.isEmpty || state.customFolders.isEmpty {
                    if !state.customFolders.isEmpty {
                        HStack {
                            Text("Uncategorized")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            if isEditMode {
                                Button("Select All") {
                                    let ids = Set(uncategorized.map { $0.id })
                                    if selectedResultIds.isSuperset(of: ids) {
                                        selectedResultIds.subtract(ids)
                                    } else {
                                        selectedResultIds.formUnion(ids)
                                    }
                                }
                                .font(.system(size: 10.5, design: .rounded))
                                .buttonStyle(.plain)
                                .foregroundColor(state.accentColor)
                            }
                        }
                        .padding(.top, 4)
                    }
                    
                    ForEach(uncategorized) { item in
                        historyRow(item: item)
                    }
                }
            }
        }
        .sheet(isPresented: $isCreatingFolder) {
            newFolderModal
        }
        .sheet(isPresented: $isBatchRenaming) {
            batchRenameModal
        }
        .confirmationDialog("Clear Recent Compressions?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear All History", role: .destructive) {
                state.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove recent items from your activity log. Original files on disk will not be deleted.")
        }
    }
    // MARK: - Batch Action Toolbar (Select All, Delete, Move, Rename)
    private var batchActionToolbar: some View {
        HStack(spacing: 8) {
            Button {
                if selectedResultIds.count == state.recentResults.count {
                    selectedResultIds.removeAll()
                } else {
                    selectedResultIds = Set(state.recentResults.map { $0.id })
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: selectedResultIds.count == state.recentResults.count && !state.recentResults.isEmpty ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundColor(selectedResultIds.isEmpty ? .secondary : state.accentColor)
                    Text(selectedResultIds.count == state.recentResults.count && !state.recentResults.isEmpty ? "Deselect All" : "Select All")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                }
            }
            .buttonStyle(.plain)
            
            Text("(\(selectedResultIds.count) selected)")
                .font(.system(size: 10.5, design: .rounded))
                .foregroundColor(.secondary)
            
            Spacer()
            
            if !selectedResultIds.isEmpty {
                // Batch Rename Button
                Button {
                    renamePattern = "Compressed_#"
                    isBatchRenaming = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "pencil.line")
                            .font(.system(size: 10.5, design: .rounded))
                        Text("Rename")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(state.contrastTextColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(state.accentColor))
                }
                .buttonStyle(.plain)
                .disabled(!state.recentResults.contains { selectedResultIds.contains($0.id) && $0.skipped != true })
                
                // Move to Folder Menu
                Menu {
                    Button("None (Uncategorized)") {
                        state.assignResultsToFolder(resultIds: selectedResultIds, folderId: nil)
                    }
                    ForEach(state.customFolders) { f in
                        Button(f.name) {
                            state.assignResultsToFolder(resultIds: selectedResultIds, folderId: f.id)
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                            .font(.system(size: 10.5, design: .rounded))
                        Text("Move")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().surfaceFill(Color.surfaceWhite(0.08, for: colorScheme)))
                }
                .menuStyle(.borderlessButton)
                
                // Batch Delete Button
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        state.batchDeleteResults(ids: selectedResultIds)
                        selectedResultIds.removeAll()
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundColor(.red.opacity(0.9))
                        .padding(5)
                        .background(Capsule().fill(Color.red.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Remove from History")
                .accessibilityLabel("Remove from History")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .surfaceFill(Color.surfaceWhite(0.04, for: colorScheme))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.surfaceWhite(0.08, for: colorScheme), lineWidth: 0.5))
        )
    }
    
    // MARK: - Collapsible Folder Section View with Direct Drag & Drop Support
    @ViewBuilder
    private func folderSectionView(folder: CompressionFolder) -> some View {
        FolderSectionItemView(
            folder: folder,
            isEditMode: isEditMode,
            selectedResultIds: $selectedResultIds
        )
    }
    
    // MARK: - Modals (New Folder & Format Rename)
    private var newFolderModal: some View {
        VStack(spacing: 12) {
            Text("Create Project Folder")
                .font(.system(size: 13, weight: .bold, design: .rounded))
            
            TextField("Folder Name", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .rounded))
            
            HStack(spacing: 10) {
                Button("Cancel") {
                    isCreatingFolder = false
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .keyboardShortcut(.cancelAction)
                
                Button("Create") {
                    state.addFolder(name: newFolderName)
                    isCreatingFolder = false
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(state.accentColor))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 280)
    }
    
    private var batchRenameModal: some View {
        let previewExample1 = renamePattern.replacingOccurrences(of: "{index}", with: "1").replacingOccurrences(of: "{i}", with: "1").replacingOccurrences(of: "#", with: "1")
        let previewExample2 = renamePattern.replacingOccurrences(of: "{index}", with: "2").replacingOccurrences(of: "{i}", with: "2").replacingOccurrences(of: "#", with: "2")
        let selectedItems = state.recentResults.filter { selectedResultIds.contains($0.id) && $0.skipped != true }
        let ext1 = selectedItems.first?.outputURL.pathExtension ?? ""
        let ext2 = (selectedItems.dropFirst().first ?? selectedItems.first)?.outputURL.pathExtension ?? ext1
        let dotExt1 = ext1.isEmpty ? "" : ".\(ext1)"
        let dotExt2 = ext2.isEmpty ? "" : ".\(ext2)"
        
        return VStack(alignment: .leading, spacing: 12) {
            Text("Batch Format Rename (\(selectedItems.count) files)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
            
            Text("Enter a format pattern. Use '#' or '{index}' for auto-incrementing numbers.")
                .font(.system(size: 10.5, design: .rounded))
                .foregroundColor(.secondary)
            
            TextField("e.g. Homerenovation_# or Project_{index}", text: $renamePattern)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .rounded))
            
            // Live Format Preview Box
            VStack(alignment: .leading, spacing: 3) {
                Text("LIVE PREVIEW:")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.8))
                
                HStack(spacing: 4) {
                    Text(selectedItems.count == 1 ? "\(previewExample1)\(dotExt1)" : "\(previewExample1)\(dotExt1),  \(previewExample2)\(dotExt2) ...")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(state.accentColor)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).surfaceFill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(state.accentColor.opacity(0.3), lineWidth: 0.5))
            }
            
            // Quick preset tokens
            HStack(spacing: 6) {
                Button("Homerenovation_#") {
                    renamePattern = "Homerenovation_#"
                }
                .font(.system(size: 10.5, design: .rounded))
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().surfaceFill(Color.white.opacity(0.06)))
                
                Button("Optimized_{index}") {
                    renamePattern = "Optimized_{index}"
                }
                .font(.system(size: 10.5, design: .rounded))
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().surfaceFill(Color.white.opacity(0.06)))
            }
            
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") {
                    isBatchRenaming = false
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .keyboardShortcut(.cancelAction)
                
                Button("Rename Files") {
                    state.batchRenameResults(ids: selectedResultIds, pattern: renamePattern)
                    isBatchRenaming = false
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(state.accentColor))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 320)
    }
    
    @State private var isDropTargeted: Bool = false
    @State private var isQueueDropTargeted: Bool = false
    
    private var emptyHistoryView: some View {
        VStack(spacing: 14) {
            // 1. Quick Squeeze Area (Top Zone - Instant Compression)
            quickSqueezeZone
            
            // 2. Custom Queue Area (Under Quick Squeeze - Stage & Customize Per File)
            customQueueSection
        }
    }
    
    // MARK: - Quick Squeeze Zone (Instant 1-Drop Compression)
    private var quickSqueezeZone: some View {
        VStack(spacing: 8) {
            Button {
                chooseFilesToSqueeze()
            } label: {
                VStack(spacing: 12) {
                    Group {
                        if isDropTargeted {
                            SqueezeClampShape().fill(state.accentColor)
                        } else {
                            SqueezeWaveMark()
                        }
                    }
                    .frame(width: 48, height: 57)
                    .scaleEffect(isDropTargeted ? 1.12 : 1.0)

                    VStack(spacing: 4) {
                        Text(isDropTargeted ? "Release to Squeeze" : "Drop files to squeeze")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)

                        Text("Compresses immediately with your current presets")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Text("Images · Video · Audio · PDF, or click to choose")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.85))
                }
                .frame(maxWidth: .infinity, minHeight: 190)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .surfaceFill(isDropTargeted ? state.accentColor.opacity(0.10) : Color.surfaceWhite(0.02, for: colorScheme))
                        .darkControlSurface(RoundedRectangle(cornerRadius: 12), enabled: !isDropTargeted, dash: [4])
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    isDropTargeted ? state.accentColor.opacity(0.7) : (colorScheme == .dark ? .clear : Color.surfaceWhite(0.12, for: colorScheme)),
                                    style: StrokeStyle(lineWidth: isDropTargeted ? 1.5 : 1, dash: isDropTargeted ? [] : [4])
                                )
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .help("Drop files here, or click to choose files to compress")
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isDropTargeted)
            .onDrop(of: [.item], isTargeted: $isDropTargeted) { providers in
                extractAndProcess(providers: providers)
            }

            squeezeClipboardButton
        }
    }

    private var squeezeClipboardButton: some View {
        Button {
            state.squeezeClipboard()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                Text("Squeeze from Clipboard")
                Text("⌘V")
                    .foregroundColor(.secondary)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(.secondary)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Custom Staged Queue Section (Customize Settings Per File)
    private var customQueueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.stagedQueue.isEmpty {
                // Empty Queue Drop Target: quiet secondary option, not a second hero
                HStack(spacing: 10) {
                    Image(systemName: isQueueDropTargeted ? "arrow.down.doc.fill" : "slider.horizontal.3")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(isQueueDropTargeted ? state.accentColor : .secondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(isQueueDropTargeted ? "Drop to Add to Queue" : "Review settings first")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)

                        Text("Drop files here to set options per file before squeezing")
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .surfaceFill(isQueueDropTargeted ? state.accentColor.opacity(0.12) : Color.surfaceWhite(0.04, for: colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(isQueueDropTargeted ? state.accentColor.opacity(0.8) : Color.clear, lineWidth: 1.5)
                        )
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isQueueDropTargeted)
                .onDrop(of: [.item], isTargeted: $isQueueDropTargeted) { providers in
                    extractAndAddToQueue(providers: providers)
                }
            } else {
                // Staged Queue Active Card
                stagedQueueActiveView
            }
        }
    }
    
    // MARK: - Active Staged Queue View with Per-File Cards
    private var stagedQueueActiveView: some View {
        VStack(spacing: 8) {
            // Queue Header with Squeeze All Button
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(state.accentColor)
                    
                    Text("Staged Queue (\(state.stagedQueue.count))")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                Button("Clear") {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.72)) {
                        state.clearQueue()
                    }
                }
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(Color.red.opacity(0.88))
                .buttonStyle(.plain)
                
                Button {
                    state.squeezeStagedQueue()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        Text("Squeeze All (\(state.stagedQueue.count))")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(state.accentColor))
                    .shadow(color: state.accentColor.opacity(0.35), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
            
            // Queue Items List
            VStack(spacing: 6) {
                ForEach(state.stagedQueue) { item in
                    StagedQueueRowItem(item: item)
                }
            }
            
            // Drop more files footer strip
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundColor(.secondary)
                Text("Drop more files to add to queue")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.surfaceWhite(0.08, for: colorScheme), style: StrokeStyle(lineWidth: 1, dash: [3]))
            )
            .onDrop(of: [.item], isTargeted: $isQueueDropTargeted) { providers in
                extractAndAddToQueue(providers: providers)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .surfaceFill(Color.surfaceWhite(0.025, for: colorScheme))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.surfaceWhite(0.08, for: colorScheme), lineWidth: 0.5))
        )
    }
    
    private func extractAndProcess(providers: [NSItemProvider]) -> Bool {
        StatusBarController.sharedInstance?.finishFileDragHover(didDrop: true)
        loadDroppedFileURLs(from: providers) { collectedURLs in
            if !collectedURLs.isEmpty {
                Task {
                    await MediaCompressionEngine.shared.processDroppedURLs(collectedURLs)
                }
            }
        }
        return true
    }
    
    private func extractAndAddToQueue(providers: [NSItemProvider]) -> Bool {
        StatusBarController.sharedInstance?.finishFileDragHover(didDrop: true)
        loadDroppedFileURLs(from: providers) { collectedURLs in
            if !collectedURLs.isEmpty {
                state.addFilesToQueue(collectedURLs)
            }
        }
        return true
    }

    private func historyRow(item: CompressionResult) -> some View {
        QuickPopoverHistoryRowItem(
            item: item,
            isEditMode: isEditMode,
            selectedResultIds: $selectedResultIds
        )
    }
    
    // MARK: - Active Format Configuration Deck (Activity Tab Collapsible Drawer)
    @ViewBuilder
    private var activeFormatSettingsDeck: some View {
        if isFormatDrawerExpanded {
            VStack(spacing: 8) {
                // Header with Format Badge & Done Collapse Button
                HStack(spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: activeFormatCategory == .images ? "photo" : (activeFormatCategory == .videos ? "film" : (activeFormatCategory == .audio ? "waveform" : "doc.text.fill")))
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundColor(formatAccentColor(for: activeFormatCategory))
                        Text("\(activeFormatCategory.displayName) Settings")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            isFormatDrawerExpanded = false
                        }
                    } label: {
                        HStack(spacing: 3.5) {
                            Text("Done")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                            Image(systemName: "chevron.up")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(Color.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .surfaceFill(Color.surfaceWhite(0.10, for: colorScheme))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.surfaceWhite(0.18, for: colorScheme), lineWidth: 0.5)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Collapse Format Controls")
                }
                .padding(.horizontal, 2)
                
                if activeFormatCategory == .images {
                    imageSettingsCard
                } else if activeFormatCategory == .videos {
                    videoSettingsCard
                } else if activeFormatCategory == .audio {
                    audioSettingsCard
                } else if activeFormatCategory == .pdf {
                    pdfSettingsCard
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .surfaceFill(Color.black.opacity(colorScheme == .dark ? 0.34 : 0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.surfaceWhite(0.07, for: colorScheme), lineWidth: 0.5)
                    )
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }
    
    private func formatAccentColor(for category: MediaFormatCategory) -> Color {
        return state.accentColor
    }
    
    // MARK: - Settings Tab View (Theme & App Behavior Only)
    private var settingsSection: some View {
        generalSettingsCard
    }
    
    // MARK: - Smart Target Size Automation Card
    private func targetSizeAutomationCard(for category: MediaFormatCategory) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            targetSizeHeader
            targetSizeGliderBar
            
            if state.targetSizeMode == .custom {
                customTargetSizeSlider
            }
            
            if state.targetSizeMode != .off {
                Label(targetSizeAutomaticNote(for: category), systemImage: "wand.and.stars")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                targetSizeToggles(for: category)
            }
        }
        .drawerSection()
    }
    
    private func targetSizeAutomaticNote(for category: MediaFormatCategory) -> String {
        switch category {
        case .images: return String(localized: "Image quality is chosen automatically to fit the limit.")
        case .videos: return String(localized: "Video bitrate is chosen automatically to fit the limit.")
        case .audio: return String(localized: "Audio bitrate is chosen automatically to fit the limit.")
        case .pdf: return String(localized: "DPI and image quality act as upper limits; they're lowered only if needed.")
        }
    }
    
    private var targetSizeHeader: some View {
        HStack {
            Label("Target Size Limit", systemImage: "target")
                .font(.system(size: 11, weight: .bold, design: .rounded))
            Spacer()
            if let targetMB = state.targetSizeMode.targetMegabytes ?? (state.targetSizeMode == .custom ? state.customTargetSizeMB : nil) {
                Text(String(format: "≤ %.0f MB", targetMB))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(state.accentColor)
            } else {
                Text("Manual Quality")
                    .font(.system(size: 10.5, weight: .regular, design: .rounded))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var targetSizeGliderBar: some View {
        GeometryReader { proxy in
            let modes = TargetSizeMode.allCases
            let spacing: CGFloat = 4
            let available = proxy.size.width - spacing * CGFloat(modes.count - 1)
            let baseWidth = available / CGFloat(modes.count)
            let manualSelected = state.targetSizeMode == .off
            let manualWidth = baseWidth * (manualSelected ? 1.28 : 0.62)
            let otherWidth = (available - manualWidth) / CGFloat(modes.count - 1)

            HStack(spacing: spacing) {
                ForEach(modes, id: \.self) { mode in
                    let isSelected = state.targetSizeMode == mode
                    let isHovered = hoveredTargetLimitMode == mode
                    let isOtherHovered = hoveredTargetLimitMode != nil && !isHovered
                    let title = mode == .off
                        ? (isSelected ? String(localized: "Manual") : String(localized: "M", comment: "Single-letter abbreviation of Manual on a narrow pill"))
                        : (mode == .custom ? String(localized: "Custom") : (mode.targetMegabytes.map { String(localized: "\(Int($0)) MB") } ?? mode.displayName))

                    UniversalPillGliderItem(
                        item: mode,
                        title: title,
                        icon: isSelected ? "checkmark" : nil,
                        isSelected: isSelected,
                        accentColor: state.accentColor,
                        contrastTextColor: state.contrastTextColor
                    ) {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                            state.targetSizeMode = mode
                        }
                    }
                    .frame(width: mode == .off ? manualWidth : otherWidth)
                    .accessibilityLabel(mode == .off ? String(localized: "Manual") : title)
                    .scaleEffect(isHovered ? 1.015 : 1.0)
                    .opacity(isOtherHovered ? 0.88 : 1.0)
                    .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.86), value: hoveredTargetLimitMode)
                    .onHover { hovering in
                        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.86)) {
                            if hovering {
                                hoveredTargetLimitMode = mode
                            } else if hoveredTargetLimitMode == mode {
                                hoveredTargetLimitMode = nil
                            }
                        }
                    }
                }
            }
            .modifier(SelectedPillDragGesture(
                options: modes,
                selected: state.targetSizeMode
            ) { mode in
                state.targetSizeMode = mode
            })
        }
        .frame(height: 26)
    }
    
    private var customTargetSizeSlider: some View {
        VStack(spacing: 3) {
            HStack {
                Text("Custom Max Size")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f MB", state.customTargetSizeMB))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(state.accentColor)
            }
            
            LiquidGlassSlider(
                value: Binding(
                    get: { state.customTargetSizeMB },
                    set: { newVal in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            state.customTargetSizeMB = newVal
                        }
                    }
                ),
                range: 1.0...200.0,
                step: 1.0,
                accentColor: state.accentColor
            )
        }
        .padding(.top, 1)
    }
    
    @ViewBuilder
    private func targetSizeToggles(for category: MediaFormatCategory) -> some View {
        Divider()
            .opacity(0.12)
            .padding(.vertical, 1)
        
        VStack(spacing: 5) {
            LiquidGlassToggleRow(
                title: "Lock Original Resolution",
                subtitle: state.preserveResolutionInTargetMode ? "Keeps 100% dimensions and compresses quality/bitrate" : "Allows smart downscaling + bitrate reduction",
                icon: "aspectratio",
                isOn: $state.preserveResolutionInTargetMode
            )
            
            if category == .videos {
                LiquidGlassToggleRow(
                    title: "Lock Original Audio Quality",
                    subtitle: state.preserveAudioQualityInTargetMode ? "Keeps standard 128 kbps audio" : "Dynamically scales audio to maximize video quality",
                    icon: "waveform",
                    isOn: $state.preserveAudioQualityInTargetMode
                )
            }
        }
    }
    
    // MARK: - Image Settings
    private var imageSettingsCard: some View {
        VStack(spacing: 8) {
            targetSizeAutomationCard(for: .images)
            
            // Quality Slider Card
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Image Quality", systemImage: "photo")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    Spacer()
                    Text(String(format: "%.0f%%", state.imageQualitySlider * 100))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(state.accentColor)
                }
                
                LiquidGlassSlider(
                    value: $state.imageQualitySlider,
                    range: 0.30...1.0,
                    step: 0.05,
                    accentColor: state.accentColor
                )
                
                // Quick preset pills with matched geometry glider
                HStack(spacing: 4) {
                    ForEach(QualityPreset.allCases, id: \.self) { preset in
                        UniversalPillGliderItem(
                            item: preset,
                            title: preset.displayName,
                            icon: nil,
                            isSelected: state.imageQualityPreset == preset,
                            accentColor: state.accentColor,
                            contrastTextColor: state.contrastTextColor
                        ) {
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                                state.imageQualityPreset = preset
                            }
                        }
                    }
                }
                .modifier(SelectedPillDragGesture(
                    options: QualityPreset.allCases,
                    selected: state.imageQualityPreset
                ) { preset in
                    state.imageQualityPreset = preset
                })
            }
            .drawerSection()
            .targetSizeLocked(state: state, what: String(localized: "quality"))
            
            // Resolution Slider Card
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Resolution Scale", systemImage: "aspectratio")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    Spacer()
                    Text(state.imageResolutionScale >= 0.99 ? String(localized: "Original (100%)") : String(localized: "\(Int((state.imageResolutionScale * 100).rounded()))% Scale"))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(state.accentColor)
                }
                
                LiquidGlassSlider(
                    value: $state.imageResolutionScale,
                    range: 0.25...1.0,
                    step: 0.05,
                    accentColor: state.accentColor
                )
                
                // Quick resolution pills with matched geometry glider
                let scales = [0.25, 0.50, 0.75, 1.0]
                HStack(spacing: 4) {
                    ForEach(scales, id: \.self) { scale in
                        UniversalPillGliderItem(
                            item: scale,
                            title: scale >= 0.99 ? "Original" : "\(Int(scale * 100))%",
                            icon: nil,
                            isSelected: abs(state.imageResolutionScale - scale) < 0.01,
                            accentColor: state.accentColor,
                            contrastTextColor: state.contrastTextColor
                        ) {
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                                state.imageResolutionScale = scale
                            }
                        }
                    }
                }
                .modifier(SelectedPillDragGesture(
                    options: scales,
                    selected: scales.first { abs(state.imageResolutionScale - $0) < 0.01 }
                ) { scale in
                    state.imageResolutionScale = scale
                })
            }
            .drawerSection()
            
            // Format Policy Card
            VStack(alignment: .leading, spacing: 7) {
                Text("Format Target")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                
                GeometryReader { proxy in
                    let policies = ImageFormatPolicy.allCases
                    let spacing: CGFloat = 4
                    let available = proxy.size.width - spacing * CGFloat(policies.count - 1)
                    let selectedWidth = available / CGFloat(policies.count) * 1.8
                    let otherWidth = (available - selectedWidth) / CGFloat(policies.count - 1)

                    HStack(spacing: spacing) {
                        ForEach(policies, id: \.self) { policy in
                            let isSelected = state.imageFormatPolicy == policy
                            let title = isSelected ? policy.selectedName : policy.shortName

                            UniversalPillGliderItem(
                                item: policy,
                                title: title,
                                icon: nil,
                                isSelected: isSelected,
                                accentColor: state.accentColor,
                                contrastTextColor: state.contrastTextColor
                            ) {
                                withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                                    state.imageFormatPolicy = policy
                                }
                            }
                            .frame(width: isSelected ? selectedWidth : otherWidth)
                            .accessibilityLabel(policy.displayName)
                        }
                    }
                    .modifier(SelectedPillDragGesture(
                        options: policies,
                        selected: state.imageFormatPolicy
                    ) { policy in
                        state.imageFormatPolicy = policy
                    })
                }
                .frame(height: 26)

                if state.imageFormatPolicy == .webpModern {
                    Text("WebP isn't supported by macOS; files are saved as HEIC.")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .drawerSection()
        }
    }
    
    // MARK: - Video Settings
    private var videoSettingsCard: some View {
        VStack(spacing: 8) {
            targetSizeAutomationCard(for: .videos)
            
            // Video Quality / Bitrate Slider
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Video Bitrate", systemImage: "film")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    Spacer()
                    Text(String(format: "%.0f%% of source", state.videoQualitySlider * 90))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(state.accentColor)
                }
                
                LiquidGlassSlider(
                    value: $state.videoQualitySlider,
                    range: 0.30...1.0,
                    step: 0.05,
                    accentColor: state.accentColor
                )
                
                // Quick preset pills with matched geometry glider
                HStack(spacing: 4) {
                    ForEach(QualityPreset.allCases, id: \.self) { preset in
                        UniversalPillGliderItem(
                            item: preset,
                            title: preset.displayName,
                            icon: nil,
                            isSelected: state.videoQualityPreset == preset,
                            accentColor: state.accentColor,
                            contrastTextColor: state.contrastTextColor
                        ) {
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                                state.videoQualityPreset = preset
                            }
                        }
                    }
                }
                .modifier(SelectedPillDragGesture(
                    options: QualityPreset.allCases,
                    selected: state.videoQualityPreset
                ) { preset in
                    state.videoQualityPreset = preset
                })
            }
            .drawerSection()
            .targetSizeLocked(state: state, what: String(localized: "bitrate"))
            
            // Video Resolution Slider Card
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Resolution Scale", systemImage: "aspectratio")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    Spacer()
                    Text(state.videoResolutionScale >= 0.99 ? String(localized: "Original (100%)") : String(localized: "\(Int((state.videoResolutionScale * 100).rounded()))% Scale"))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(state.accentColor)
                }
                
                LiquidGlassSlider(
                    value: $state.videoResolutionScale,
                    range: 0.25...1.0,
                    step: 0.05,
                    accentColor: state.accentColor
                )
                
                // Quick resolution pills with matched geometry glider
                let scaleOptions = [0.25, 0.50, 0.75, 1.0]
                HStack(spacing: 4) {
                    ForEach(scaleOptions, id: \.self) { scale in
                        UniversalPillGliderItem(
                            item: scale,
                            title: scale >= 0.99 ? "Original" : "\(Int(scale * 100))%",
                            icon: nil,
                            isSelected: abs(state.videoResolutionScale - scale) < 0.01,
                            accentColor: state.accentColor,
                            contrastTextColor: state.contrastTextColor
                        ) {
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                                state.videoResolutionScale = scale
                            }
                        }
                    }
                }
                .modifier(SelectedPillDragGesture(
                    options: scaleOptions,
                    selected: scaleOptions.first { abs(state.videoResolutionScale - $0) < 0.01 }
                ) { scale in
                    state.videoResolutionScale = scale
                })
            }
            .drawerSection()
            
            // Framerate & Codec Controls Card
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Framerate (FPS)", systemImage: "speedometer")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    Spacer()
                    Text(state.videoFramerate.displayName)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(state.accentColor)
                }
                
                GeometryReader { proxy in
                    let options = VideoFramerateOption.allCases
                    let spacing: CGFloat = 3.5
                    let available = proxy.size.width - spacing * CGFloat(options.count - 1)
                    let baseWidth = available / CGFloat(options.count)
                    let selectedWidth = baseWidth * 1.55
                    let otherWidth = (available - selectedWidth) / CGFloat(options.count - 1)

                    HStack(spacing: spacing) {
                        ForEach(options, id: \.self) { opt in
                            let isSelected = state.videoFramerate == opt
                            let title = isSelected && opt == .original ? opt.displayName : opt.shortName

                            UniversalPillGliderItem(
                                item: opt,
                                title: title,
                                icon: nil,
                                isSelected: isSelected,
                                accentColor: state.accentColor,
                                contrastTextColor: state.contrastTextColor
                            ) {
                                withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                                    state.videoFramerate = opt
                                }
                            }
                            .frame(width: isSelected ? selectedWidth : otherWidth)
                            .accessibilityLabel(opt.displayName)
                        }
                    }
                    .modifier(SelectedPillDragGesture(
                        options: options,
                        selected: state.videoFramerate
                    ) { option in
                        state.videoFramerate = option
                    })
                }
                .frame(height: 26)
                
                Divider().opacity(0.15)
                
                Text("Format / Codec")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                
                GeometryReader { proxy in
                    let options = VideoCodecPreference.allCases
                    let spacing: CGFloat = 4
                    let available = proxy.size.width - spacing * CGFloat(options.count - 1)
                    let baseWidth = available / CGFloat(options.count)
                    let selectedWidth = baseWidth * 1.25
                    let otherWidth = (available - selectedWidth) / CGFloat(options.count - 1)

                    HStack(spacing: spacing) {
                        ForEach(options, id: \.self) { codec in
                            let isSelected = state.videoCodec == codec

                            UniversalPillGliderItem(
                                item: codec,
                                title: codec.displayName,
                                icon: nil,
                                isSelected: isSelected,
                                accentColor: state.accentColor,
                                contrastTextColor: state.contrastTextColor
                            ) {
                                withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                                    state.videoCodec = codec
                                }
                            }
                            .frame(width: isSelected ? selectedWidth : otherWidth)
                            .accessibilityLabel(codec.displayName)
                        }
                    }
                    .modifier(SelectedPillDragGesture(
                        options: options,
                        selected: state.videoCodec
                    ) { codec in
                        state.videoCodec = codec
                    })
                }
                .frame(height: 26)
                
                if state.videoCodec == .gif {
                    Divider().opacity(0.15)
                    
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label("GIF Framerate", systemImage: "speedometer")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            Spacer()
                            Text(state.gifFramerate.displayName)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundColor(state.accentColor)
                        }
                        
                        HStack(spacing: 4) {
                            ForEach(GIFFramerateOption.allCases, id: \.self) { opt in
                                UniversalPillGliderItem(
                                    item: opt,
                                    title: opt.displayName,
                                    icon: nil,
                                    isSelected: state.gifFramerate == opt,
                                    accentColor: state.accentColor,
                                    contrastTextColor: state.contrastTextColor
                                ) {
                                    withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                                        state.gifFramerate = opt
                                    }
                                }
                            }
                            .modifier(SelectedPillDragGesture(
                                options: GIFFramerateOption.allCases,
                                selected: state.gifFramerate
                            ) { option in
                                state.gifFramerate = option
                            })
                        }
                    }
                } else {
                    Divider().opacity(0.15)
                    
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                            state.videoRemoveAudio.toggle()
                        }
                    } label: {
                        HStack(alignment: .center) {
                            Text("Mute / Remove Audio Track")
                                .font(.system(size: 10.5, design: .rounded))
                                .foregroundColor(.primary)
                            Spacer()
                            LiquidGlassSwitch(isOn: $state.videoRemoveAudio)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isToggle)
                    .accessibilityValue(state.videoRemoveAudio ? String(localized: "On") : String(localized: "Off"))
                }
            }
            .drawerSection()
        }
    }
    
    // MARK: - Audio Settings
    private var audioSettingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Audio Bitrate", systemImage: "waveform")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    Spacer()
                    Text(state.audioBitrate.displayName)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(state.accentColor)
                }
                
                // Bitrate pills with matched geometry glider
                HStack(spacing: 4) {
                    ForEach(AudioBitratePreference.allCases, id: \.self) { rate in
                        UniversalPillGliderItem(
                            item: rate,
                            title: rate.shortName,
                            icon: nil,
                            isSelected: state.audioBitrate == rate,
                            accentColor: state.accentColor,
                            contrastTextColor: state.contrastTextColor
                        ) {
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                                state.audioBitrate = rate
                            }
                        }
                    }
                }
                .modifier(SelectedPillDragGesture(
                    options: AudioBitratePreference.allCases,
                    selected: state.audioBitrate
                ) { rate in
                    state.audioBitrate = rate
                })
            }
            .drawerSection()
            .targetSizeLocked(state: state, what: String(localized: "bitrate"))
        }
    }
    
    // MARK: - PDF Settings
    private var pdfSettingsCard: some View {
        VStack(spacing: 8) {
            targetSizeAutomationCard(for: .pdf)
            
            // DPI / Resolution Preset Card
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Document Resolution (DPI)", systemImage: "doc.text.image")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    Spacer()
                    Text("\(Int(state.pdfDPI.dpiValue)) DPI")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(state.accentColor)
                }
                
                HStack(spacing: 5) {
                    ForEach(PDFDPIOption.allCases, id: \.self) { dpi in
                        UniversalPillGliderItem(
                            item: dpi,
                            title: dpi.displayName,
                            icon: nil,
                            isSelected: state.pdfDPI == dpi,
                            accentColor: state.accentColor,
                            contrastTextColor: state.contrastTextColor
                        ) {
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                                state.pdfDPI = dpi
                            }
                        }
                    }
                }
                .modifier(SelectedPillDragGesture(
                    options: PDFDPIOption.allCases,
                    selected: state.pdfDPI
                ) { dpi in
                    state.pdfDPI = dpi
                })

                Text("Pages are re-rendered as images; text won't be selectable.")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .drawerSection()
            
            // Embedded Image Quality Slider Card
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Image Compression Quality", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    Spacer()
                    Text(String(format: "%.0f%%", state.pdfImageQuality * 100))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(state.accentColor)
                }
                
                LiquidGlassSlider(
                    value: $state.pdfImageQuality,
                    range: 0.30...1.0,
                    step: 0.05,
                    accentColor: state.accentColor
                )
                
                // Quick preset pills
                let qualities = [0.50, 0.70, 0.85]
                HStack(spacing: 5) {
                    ForEach(qualities, id: \.self) { quality in
                        let title = quality == 0.50 ? "50% Compact" : (quality == 0.70 ? "70% Balanced" : "85% High")
                        UniversalPillGliderItem(
                            item: quality,
                            title: title,
                            icon: nil,
                            isSelected: abs(state.pdfImageQuality - quality) < 0.01,
                            accentColor: state.accentColor,
                            contrastTextColor: state.contrastTextColor
                        ) {
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                                state.pdfImageQuality = quality
                            }
                        }
                    }
                }
                .modifier(SelectedPillDragGesture(
                    options: qualities,
                    selected: qualities.first { abs(state.pdfImageQuality - $0) < 0.01 }
                ) { quality in
                    state.pdfImageQuality = quality
                })
            }
            .drawerSection()
            
            // Advanced Document Optimization Toggles
            VStack(alignment: .leading, spacing: 7) {
                Text("Document Optimization")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                
                VStack(spacing: 5) {
                    LiquidGlassToggleRow(
                        title: "Convert to Grayscale (B&W)",
                        subtitle: "Converts scans & images to monochrome for extra reduction",
                        icon: "circle.lefthalf.filled",
                        isOn: $state.pdfGrayscale
                    )
                    
                    LiquidGlassToggleRow(
                        title: "Strip Document Metadata",
                        subtitle: "Removes author info and embedded thumbnail bloat",
                        icon: "tag.slash",
                        isOn: $state.pdfStripMetadata
                    )
                }
            }
            .drawerSection()
        }
    }
    
    // MARK: - General Settings
    // MARK: - Settings building blocks
    private func settingsGroupCard<Content: View>(_ title: LocalizedStringKey, icon: String, summary: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer()
                if let summary {
                    Text(summary)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 8) {
                content()
                    .font(.system(size: 11, design: .rounded))
            }
            .padding(14)
            .contentShape(Rectangle())
            .darkControlSurface(RoundedRectangle(cornerRadius: 10), behindContent: true)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .surfaceFill(Color.surfaceWhite(0.035, for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.surfaceWhite(0.07, for: colorScheme), lineWidth: 0.5)
            )
        }
    }

    private func settingsToggleRow(_ title: LocalizedStringKey, isOn: Binding<Bool>, detail: LocalizedStringKey? = nil, badge: LocalizedStringKey? = nil, action: (() -> Void)? = nil) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                if let action { action() } else { isOn.wrappedValue.toggle() }
            }
        } label: {
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.primary)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().surfaceFill(Color.surfaceWhite(0.10, for: colorScheme)))
                        }
                    }
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10.5, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                LiquidGlassSwitch(isOn: isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn.wrappedValue ? String(localized: "On") : String(localized: "Off"))
    }

    private func settingsDivider() -> some View {
        Divider().opacity(0.15)
    }

    private var saveDestinationSummary: String {
        state.customOutputFolder != nil
            ? String(localized: "Custom directory")
            : (state.exportToSubfolder ? String(localized: "Automatic subfolder") : String(localized: "Next to original"))
    }

    private func chooseOutputFolder() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = true
        openPanel.prompt = String(localized: "Select Output Folder")
        if openPanel.runModal() == .OK, let selectedURL = openPanel.url {
            state.customOutputFolder = selectedURL.path
        }
    }

    private var generalSettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsGroupCard("Saving", icon: "folder", summary: saveDestinationSummary) {
                HStack(spacing: 8) {
                    Text("Save to")
                        .font(.system(size: 11, design: .rounded))
                    Spacer(minLength: 8)
                    Text(state.customOutputFolder ?? String(localized: "Next to original"))
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(state.customOutputFolder == nil ? "Choose…" : "Change…") {
                        chooseOutputFolder()
                    }
                    .controlSize(.small)
                    if state.customOutputFolder != nil {
                        Button("Clear") { state.customOutputFolder = nil }
                            .controlSize(.small)
                    }
                }

                settingsDivider()

                HStack {
                    Text("File suffix")
                        .font(.system(size: 11, design: .rounded))
                    Spacer()
                    TextField("_min", text: $state.outputSuffix)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                settingsDivider()

                settingsToggleRow("Subfolder", isOn: $state.exportToSubfolder)

                if state.exportToSubfolder {
                    settingsDivider()
                    HStack(spacing: 6) {
                        Text("Subfolder name")
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundColor(.secondary)
                        Spacer()
                        TextField("Squeezed", text: $state.subfolderName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                            .font(.system(size: 10.5, design: .rounded))
                    }
                    .transition(.opacity)
                }

                settingsDivider()
                settingsToggleRow("Remove metadata", isOn: $state.stripMetadata, detail: "Applies to images. Location data is always removed.")
            }
            settingsGroupCard("Add files", icon: "square.and.arrow.down") {
                settingsToggleRow("DropBall", isOn: $state.floatingBallEnabled, detail: "Floating drop target that snaps to a screen edge")
                settingsDivider()
                settingsToggleRow("Shake to summon", isOn: $state.shakeToSummonEnabled, detail: "Shake a file while dragging to bring the ball to your cursor")
                settingsDivider()
                settingsToggleRow("Finder action", isOn: $state.finderServiceEnabled, badge: "BETA")
                settingsDivider()
                VStack(alignment: .leading, spacing: 8) {
                    settingsToggleRow("Watch folder", isOn: $state.isWatchFolderEnabled, detail: "Compresses new files added to this folder")

                    if state.isWatchFolderEnabled {
                        settingsDivider()
                        HStack(spacing: 8) {
                            Text(state.watchFolderPath ?? String(localized: "No folder selected"))
                                .font(.system(size: 10.5, design: .rounded))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button(state.watchFolderPath == nil ? "Choose…" : "Change…") {
                                selectWatchFolder()
                            }
                            .controlSize(.small)
                        }
                        .transition(.opacity)
                    }
                }
                .onChange(of: state.isWatchFolderEnabled) { _, enabled in
                    if enabled, let path = state.watchFolderPath {
                        FolderWatchService.shared.startMonitoring(path: path)
                    } else {
                        FolderWatchService.shared.stopMonitoring()
                    }
                }
            }

            settingsGroupCard("Appearance", icon: "paintbrush", summary: String(localized: "Scale, glass, accent color")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                    Text("Accent color")
                    Spacer(minLength: 8)
                    // Native macOS Style Swatch Circles
                    HStack(spacing: 8) {
                        ForEach(AccentColorTheme.allCases, id: \.self) { theme in
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                    state.accentTheme = theme
                                }
                                if theme != .custom {
                                    CustomColorPanelManager.shared.close()
                                }
                            } label: {
                                ZStack {
                                    if theme == .custom {
                                        // Angular rainbow gradient colorwheel circle with live center pip
                                        ZStack {
                                            AngularGradient(
                                                gradient: Gradient(colors: [.red, .yellow, .green, .blue, .purple, .pink, .red]),
                                                center: .center
                                            )
                                            .clipShape(Circle())
                                            .frame(width: 22, height: 22)

                                            // Center preview orb of current custom color
                                            Circle()
                                                .fill(state.accentColor)
                                                .frame(width: 10, height: 10)
                                                .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 0.5))
                                        }
                                    } else {
                                        Circle()
                                            .fill(themeColor(for: theme))
                                            .frame(width: 22, height: 22)
                                    }

                                    // Selected Ring
                                    if state.accentTheme == theme {
                                        Circle()
                                            .strokeBorder(Color.white, lineWidth: 2)
                                            .frame(width: 28, height: 28)
                                            .shadow(color: Color.black.opacity(0.3), radius: 2)
                                    }
                                }
                                .frame(width: 30, height: 30)
                            }
                            .buttonStyle(.plain)
                            .help(theme == .custom ? String(localized: "Custom Color Wheel & Spectrum") : String(localized: "\(theme.displayName) Accent"))
                        }
                    }
                    .padding(.vertical, 2)
                    }

                    // Custom HEX Color Tab (Expands when Custom Color Wheel is active)
                    if state.accentTheme == .custom {
                        VStack(alignment: .leading, spacing: 6) {
                            Divider().opacity(0.15)

                            HStack(spacing: 8) {
                                Text("HEX code")
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .foregroundColor(.secondary)

                                HStack(spacing: 3) {
                                    Text("#")
                                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                        .foregroundColor(.secondary)

                                    TextField("007AFF", text: Binding(
                                        get: { state.customAccentHex },
                                        set: { newHex in
                                            let filtered = newHex.filter { "0123456789abcdefABCDEF".contains($0) }.prefix(6)
                                            state.customAccentHex = String(filtered).uppercased()
                                        }
                                    ))
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    .frame(width: 65)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .surfaceFill(Color.surfaceWhite(0.06, for: colorScheme))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(state.accentColor.opacity(0.4), lineWidth: 0.75)
                                        )
                                )

                                // Anchored Color Wheel Button (Opens Color Wheel right under button)
                                Button {
                                    CustomColorPanelManager.shared.toggle(initialColor: state.accentColor)
                                } label: {
                                    HStack(spacing: 4) {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(state.accentColor)
                                            .frame(width: 22, height: 16)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .strokeBorder(Color.white.opacity(0.40), lineWidth: 0.75)
                                            )
                                            .shadow(color: Color.black.opacity(0.2), radius: 2)

                                        Image(systemName: "paintpalette")
                                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .surfaceFill(Color.surfaceWhite(0.06, for: colorScheme))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(Color.surfaceWhite(0.12, for: colorScheme), lineWidth: 0.5)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                                .help("Open Anchored Color Wheel")

                                // Screen Eyedropper Loupe Button
                                if #available(macOS 10.15, *) {
                                    Button {
                                        NSColorSampler().show { selectedColor in
                                            guard let selectedColor = selectedColor,
                                                  let srgb = selectedColor.usingColorSpace(.sRGB) else { return }
                                            Task { @MainActor in
                                                let r = Int(round(srgb.redComponent * 255))
                                                let g = Int(round(srgb.greenComponent * 255))
                                                let b = Int(round(srgb.blueComponent * 255))
                                                let hex = String(format: "%02X%02X%02X", r, g, b)
                                                withAnimation(.spring(response: 0.2)) {
                                                    state.customAccentHex = hex
                                                    state.accentTheme = .custom
                                                }
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "eyedropper.halffull")
                                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                            .foregroundColor(.secondary)
                                            .frame(width: 22, height: 22)
                                            .background(
                                                Circle()
                                                    .surfaceFill(Color.surfaceWhite(0.06, for: colorScheme))
                                                    .overlay(Circle().stroke(Color.surfaceWhite(0.12, for: colorScheme), lineWidth: 0.5))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .help("Pick color from screen")
                                }

                                Spacer()

                                // Quick Popular Hex Swatches
                                HStack(spacing: 4) {
                                    ForEach(["FF2D55", "5856D6", "00C7BE", "30D158", "FF9500"], id: \.self) { quickHex in
                                        Button {
                                            withAnimation(.spring(response: 0.25)) {
                                                state.customAccentHex = quickHex
                                            }
                                        } label: {
                                            Circle()
                                                .fill(AppState.colorFromHex(quickHex) ?? .blue)
                                                .frame(width: 14, height: 14)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }
                        .transition(.opacity)
                    }

                }
                settingsDivider()
                HStack(spacing: 8) {
                    Text("Interface size")
                    Spacer(minLength: 8)
                    // Liquid Pill Glider with Matched Geometry and Collective Focus Bounce
                    HStack(spacing: 5) {
                        ForEach(UIScaleOption.allCases, id: \.self) { option in
                            let isHovered = hoveredUIScaleOption == option
                            let isOtherHovered = hoveredUIScaleOption != nil && !isHovered

                            UniversalPillGliderItem(
                                item: option,
                                title: option.displayName,
                                icon: state.uiScale == option ? "checkmark" : (option == .small ? "arrow.down.right.and.arrow.up.left" : (option == .large ? "arrow.up.left.and.arrow.down.right" : "rectangle.center.inset.filled")),
                                isSelected: state.uiScale == option,
                                accentColor: state.accentColor,
                                contrastTextColor: state.contrastTextColor
                            ) {
                                withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                    state.uiScale = option
                                }
                            }
                            .help("\(option.displayName) (\(option.percentageLabel))")
                            .scaleEffect(isHovered ? 1.015 : 1.0)
                            .opacity(isOtherHovered ? 0.88 : 1.0)
                            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.86), value: hoveredUIScaleOption)
                            .onHover { hovering in
                                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.86)) {
                                    if hovering {
                                        hoveredUIScaleOption = option
                                    } else if hoveredUIScaleOption == option {
                                        hoveredUIScaleOption = nil
                                    }
                                }
                            }
                        }
                    }
                    .modifier(SelectedPillDragGesture(
                        options: UIScaleOption.allCases,
                        selected: state.uiScale
                    ) { option in
                        state.uiScale = option
                    })

                }
                settingsDivider()
                HStack(spacing: 8) {
                    Text("Transparency")
                    Spacer(minLength: 8)
                    LiquidGlassSlider(value: $state.appTransparency, range: 0...1, accentColor: state.accentColor)
                        .frame(width: 160)
                        .accessibilityLabel("App transparency")
                    Text("\(Int((state.appTransparency * 100).rounded()))%")
                        .foregroundColor(state.accentColor)
                        .frame(width: 34, alignment: .trailing)
                    Button("Reset") {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            state.appTransparency = 0
                            state.appGlassFrost = 0.12
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                settingsDivider()
                HStack(spacing: 8) {
                    Text("Blur")
                    Spacer(minLength: 8)
                    LiquidGlassSlider(value: $state.appGlassFrost, range: 0...1, accentColor: state.accentColor)
                        .frame(width: 160)
                        .accessibilityLabel("Window blur")
                    Text("\(Int((state.appGlassFrost * 100).rounded()))%")
                        .foregroundColor(state.accentColor)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            settingsGroupCard("Sound", icon: "speaker.wave.3.fill", summary: state.soundEnabled ? state.soundTheme.displayName : String(localized: "Off")) {
                settingsToggleRow("Completion sound", isOn: $state.soundEnabled)

                if state.soundEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        settingsDivider()
                        HStack(spacing: 8) {
                            Text("Sound")
                            Spacer(minLength: 8)
                            Picker("Sound", selection: Binding(
                                get: { state.soundTheme },
                                set: { sound in
                                    state.soundTheme = sound
                                    NSSound(named: sound.systemSoundName)?.play()
                                }
                            )) {
                                ForEach(SoundEffectTheme.allCases, id: \.self) { sound in
                                    Text(sound.displayName).tag(sound)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityLabel("Sound")
                            Button {
                                NSSound(named: state.soundTheme.systemSoundName)?.play()
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Preview sound")
                            .accessibilityLabel("Preview sound")
                        }
                        .font(.system(size: 11, design: .rounded))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: state.soundEnabled)

            settingsGroupCard("System", icon: "gearshape") {
                settingsToggleRow("Check for updates automatically", isOn: $updates.automatic)
                Text("Checks GitHub for new versions. Your files are never uploaded.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.secondary)
                Button("Check for Updates") { Task { await updates.check(manual: true) } }
                    .disabled(updates.checking)
                if updates.checking { Text("Checking for updates…") }
                if let feedback = updates.feedback { Text(feedback).font(.caption) }
                Button("Report a Bug") { NSWorkspace.shared.open(UpdateChecker.bugReportURL()) }
                settingsDivider()

                settingsToggleRow("Launch at login", isOn: $state.launchAtLogin, action: {
                    state.setLaunchAtLogin(enabled: !state.launchAtLogin)
                })
                settingsDivider()
                Button {
                    WelcomeWindowController.shared.show()
                } label: {
                    HStack(alignment: .center) {
                        Text("Welcome & file access")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                settingsDivider()
                Button("Reset statistics…", role: .destructive) {
                    showResetStatsConfirmation = true
                }
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.red.opacity(0.85))
                .buttonStyle(.plain)
            }
            .confirmationDialog("Reset all compression stats?", isPresented: $showResetStatsConfirmation, titleVisibility: .visible) {
                Button("Reset stats", role: .destructive) { state.resetAllStats() }
                Button("Cancel", role: .cancel) {}
            }

        }
    }

    private func selectWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Select Watch Folder")
        
        if panel.runModal() == .OK, let url = panel.url {
            state.watchFolderPath = url.path
            state.isWatchFolderEnabled = true
            FolderWatchService.shared.startMonitoring(path: url.path)
        }
    }
    
    // MARK: - Footer
    private var footerView: some View {
        HStack {
            Text("SqueezeBar v1.2.4")
                .font(.system(size: 10.5, design: .rounded))
                .foregroundColor(.secondary)
            
            Spacer()
            
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
    
    private func themeColor(for theme: AccentColorTheme) -> Color {
        switch theme {
        case .custom:
            return state.accentColor
        case .blue:
            return Color(red: 0.1, green: 0.5, blue: 1.0)
        case .purple:
            return Color(red: 0.65, green: 0.32, blue: 0.88)
        case .pink:
            return Color(red: 0.98, green: 0.32, blue: 0.58)
        case .red:
            return Color(red: 0.95, green: 0.28, blue: 0.28)
        case .orange:
            return Color(red: 0.98, green: 0.55, blue: 0.18)
        case .yellow:
            return Color(red: 0.98, green: 0.78, blue: 0.12)
        case .green:
            return Color(red: 0.32, green: 0.82, blue: 0.42)
        case .graphite:
            return Color(red: 0.58, green: 0.60, blue: 0.64)
        }
    }
}

// MARK: - Target-size lock for controls the engine ignores
/// In a target-size mode the engine derives quality/bitrate from the size limit, so the manual control is dimmed and explained instead of silently doing nothing.
/// Drawer controls sit on one surface separated by hairlines, not nested cards.
private extension View {
    func drawerSection() -> some View {
        padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().opacity(0.12) }
    }
}

private struct TargetSizeLockModifier: ViewModifier {
    @ObservedObject var state: AppState
    let what: String

    private var limitLabel: String {
        let mb = state.targetSizeMode.targetMegabytes ?? state.customTargetSizeMB
        return String(format: "%g MB", mb)
    }

    func body(content: Content) -> some View {
        let isLocked = state.targetSizeMode != .off
        VStack(alignment: .leading, spacing: 5) {
            content
                .disabled(isLocked)
                .opacity(isLocked ? 0.4 : 1)
            if isLocked {
                Label("Automatic at \(limitLabel). Choose Manual to adjust \(what).", systemImage: "lock.fill")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isLocked)
    }
}

private extension View {
    func targetSizeLocked(state: AppState, what: String) -> some View {
        modifier(TargetSizeLockModifier(state: state, what: what))
    }
}

// MARK: - File Thumbnail View
public struct FileThumbnailView: View {
    @Environment(\.colorScheme) private var colorScheme
    let url: URL
    let mediaType: MediaType
    var size: CGFloat = 28
    var usesDarkControlSurface = false
    
    @State private var thumbnail: NSImage?
    
    public init(url: URL, mediaType: MediaType, size: CGFloat = 28, usesDarkControlSurface: Bool = false) {
        self.url = url
        self.mediaType = mediaType
        self.size = size
        self.usesDarkControlSurface = usesDarkControlSurface
    }
    
    public var body: some View {
        ZStack {
            if let thumbnail = thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark && usesDarkControlSurface ? 0 : 0.15), lineWidth: 0.5)
                    )
            } else {
                // Frosted Glass Media Placeholder
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size, height: size)
                    .darkControlSurface(RoundedRectangle(cornerRadius: 6), enabled: usesDarkControlSurface, borderless: true)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark && usesDarkControlSurface ? 0 : 0.08), lineWidth: 0.5)
                    )
                    .overlay(
                        Image(systemName: mediaIconName)
                            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                            .foregroundColor(mediaIconColor)
                    )
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            await loadThumbnail()
        }
    }
    
    private var mediaIconName: String {
        switch mediaType {
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.text.fill"
        case .image: return "photo"
        case .unsupported: return "doc.fill"
        }
    }
    
    private var mediaIconColor: Color {
        return .secondary.opacity(0.85)
    }
    
    private func loadThumbnail() async {
        if let cached = ThumbnailCache.shared.image(for: url) {
            self.thumbnail = cached
            return
        }
        
        let loaded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let maxPixelSize = Int(size * 3.0)
            
            // 1. Direct ImageIO Thumbnail for Images (Ultra-fast, hardware accelerated)
            let ext = url.pathExtension.lowercased()
            if mediaType == .image || ["png", "jpg", "jpeg", "webp", "gif", "heic", "tiff", "bmp", "avif"].contains(ext) {
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                    ]
                    if let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                        return NSImage(cgImage: cgThumb, size: CGSize(width: size, height: size))
                    }
                }
                if let directImg = NSImage(contentsOf: url) {
                    return directImg
                }
            }
            
            // 2. AVAsset Video Frame Thumbnail
            if mediaType == .video || ["mp4", "mov", "m4v", "mkv", "avi"].contains(ext) {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
                let time = CMTime(seconds: 0.5, preferredTimescale: 600)
                if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                    return NSImage(cgImage: cgImage, size: CGSize(width: size, height: size))
                }
            }
            
            // 3. PDF Kit Thumbnail
            if mediaType == .pdf || ext == "pdf" {
                if let doc = PDFDocument(url: url), let page = doc.page(at: 0) {
                    return page.thumbnail(of: CGSize(width: size * 2, height: size * 2), for: .mediaBox)
                }
            }
            
            // 4. QuickLook Thumbnail Generator
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: size * 2, height: size * 2),
                scale: 2.0,
                representationTypes: .thumbnail
            )
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                return representation.nsImage
            }
            
            return nil
        }.value
        
        if let loaded = loaded {
            ThumbnailCache.shared.setImage(loaded, for: url)
            self.thumbnail = loaded
        }
    }
}

// MARK: - Thumbnail Cache
private final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()
    
    private init() {
        cache.countLimit = 150
    }
    
    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }
    
    func setImage(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

// MARK: - Liquid Glass Toggle Row
private struct LiquidGlassToggleRow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let icon: String
    @Binding var isOn: Bool
    
    var body: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                isOn.toggle()
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                // Left text block
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: icon)
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundColor(isOn ? state.accentColor : .secondary)
                        Text(title)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                    }
                    
                    Text(subtitle)
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer(minLength: 8)
                
                // Right Liquid Glass Toggle Switch
                LiquidGlassSwitch(isOn: $isOn)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .surfaceFill(isOn ? state.accentColor.opacity(0.06) : Color.surfaceWhite(0.02, for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isOn ? state.accentColor.opacity(0.18) : Color.surfaceWhite(0.04, for: colorScheme), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? String(localized: "On") : String(localized: "Off"))
    }
}

// MARK: - Liquid Glass Switch
public struct LiquidGlassSwitch: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isOn: Bool
    
    public init(isOn: Binding<Bool>) {
        self._isOn = isOn
    }
    
    public var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            // Track Capsule with Glassmorphism
            Capsule()
                .fill(
                    isOn ?
                    LinearGradient(
                        colors: [state.accentColor.opacity(0.95), state.accentColor.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ) :
                    LinearGradient(
                        colors: [Color.surfaceWhite(0.12, for: colorScheme), Color.surfaceWhite(0.06, for: colorScheme)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 38, height: 21)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isOn ?
                            LinearGradient(colors: [Color.white.opacity(0.5), state.accentColor.opacity(0.3)], startPoint: .top, endPoint: .bottom) :
                            LinearGradient(colors: [Color.surfaceWhite(0.2, for: colorScheme), Color.surfaceWhite(0.05, for: colorScheme)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.75
                        )
                )
                .shadow(color: isOn ? state.accentColor.opacity(0.4) : Color.black.opacity(0.2), radius: isOn ? 4 : 1, y: 1)
            
            // Thumb Orb with Frosted Glass Reflection & Shadow
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(white: 0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 17, height: 17)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.28), radius: 2.5, x: isOn ? -1 : 1, y: 1)
                .padding(2)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.72)) {
                isOn.toggle()
            }
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.72), value: isOn)
    }
}

// MARK: - Format Tile
private struct LiveProfileGlowCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let accentColor: Color
    var isSelected: Bool = false
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).surfaceFill(isSelected ? accentColor.opacity(0.12) : Color.surfaceWhite(0.035, for: colorScheme))
                .darkControlSurface(RoundedRectangle(cornerRadius: 8), enabled: !isSelected))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? accentColor.opacity(0.45) : Color.clear, lineWidth: 0.75))
    }
}

// MARK: - AppKit Window Drag Handle (moves the window from clicks no SwiftUI control takes)
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ nsView: HandleView, context: Context) {}

    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - AppKit Non-Draggable View (Prevents window drag during slider scrub)
private struct NonDraggableArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NonDraggableNSView {
        NonDraggableNSView()
    }
    
    func updateNSView(_ nsView: NonDraggableNSView, context: Context) {}
}

private final class NonDraggableNSView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        return false
    }
}

// MARK: - Modern Liquid Glass Slider with Subtle White Specular Dynamics
struct LiquidGlassSlider: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let accentColor: Color
    
    @State private var isDragging: Bool = false
    @State private var isHovered: Bool = false
    /// Continuous pointer position (0...1) while dragging. The thumb follows this with easing; `value` still snaps to `step`.
    @State private var dragPercentage: CGFloat? = nil
    @State private var dragVelocity: CGFloat = 0.0
    @State private var lastLocationX: CGFloat = 0.0
    @State private var lastDragTimestamp: Date = Date()
    
    var body: some View {
        GeometryReader { geometry in
            let totalWidth = max(1, geometry.size.width)
            let clampedValue = min(max(value, range.lowerBound), range.upperBound)
            let valuePercentage = CGFloat((clampedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
            let percentage = dragPercentage ?? valuePercentage
            let fillWidth = max(0, min(totalWidth, totalWidth * percentage))
            let thumbSize: CGFloat = isDragging ? 14 : (isHovered ? 12.5 : 11)
            let thumbCenter = max(thumbSize / 2, min(totalWidth - thumbSize / 2, fillWidth))
            
            let whiteGlowRadius: CGFloat = 4.0 + (dragVelocity * 6.0)
            let whiteGlowOpacity: Double = 0.20 + Double(dragVelocity * 0.25)
            
            ZStack(alignment: .leading) {
                // Non-Draggable AppKit Anchor (Prevents Window Drag in Detached Mode)
                NonDraggableArea()
                
                // Background Track
                Capsule()
                    .fill(Color.surfaceWhite(0.09, for: colorScheme))
                    .frame(height: 6)
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.surfaceWhite(0.08, for: colorScheme), lineWidth: 0.5)
                    )
                
                // Active Filled Track with Accent Gradient
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.85), accentColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth, height: 6)
                    .shadow(color: accentColor.opacity(0.20), radius: 2)
                
                // Subtle Neutral White Specular Aura Bloom on Hold / Velocity Scrub
                if isDragging {
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    Color.white.opacity(whiteGlowOpacity),
                                    Color.white.opacity(whiteGlowOpacity * 0.35),
                                    Color.clear
                                ]),
                                center: .center,
                                startRadius: 1,
                                endRadius: thumbSize * 1.1 + (dragVelocity * 5.0)
                            )
                        )
                        .frame(width: 32 + (dragVelocity * 10), height: 32 + (dragVelocity * 10))
                        .offset(x: thumbCenter - (16 + (dragVelocity * 5)))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                
                // Frosted Thumb Indicator with Subtle Neutral Specular Glow
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(isDragging ? 0.95 : 0.40), lineWidth: isDragging ? 1.2 : 0.8)
                    )
                    .shadow(
                        color: Color.black.opacity(isDragging ? 0.25 : 0.20),
                        radius: isDragging ? 2.5 : 1.5,
                        y: 1
                    )
                    .shadow(
                        color: isDragging ? Color.white.opacity(whiteGlowOpacity * 0.90) : (isHovered ? Color.white.opacity(0.12) : Color.clear),
                        radius: isDragging ? whiteGlowRadius : 2,
                        y: 0
                    )
                    .scaleEffect(isDragging ? (1.10 + dragVelocity * 0.08) : (isHovered ? 1.05 : 1.0))
                    .offset(x: max(0, min(totalWidth - thumbSize, fillWidth - (thumbSize / 2))))
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .background(NonDraggableArea())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let locationX = gesture.location.x
                        let now = Date()
                        let timeDelta = max(0.008, now.timeIntervalSince(lastDragTimestamp))
                        
                        if isDragging {
                            let distance = abs(locationX - lastLocationX)
                            let instantVelocity = distance / CGFloat(timeDelta)
                            let normalizedSpeed = min(1.0, instantVelocity / 850.0)
                            withAnimation(.easeOut(duration: 0.08)) {
                                dragVelocity = dragVelocity * 0.35 + normalizedSpeed * 0.65
                            }
                        } else {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                isDragging = true
                                dragVelocity = 0.15
                            }
                        }
                        
                        lastLocationX = locationX
                        lastDragTimestamp = now
                        
                        let newPct = max(0.0, min(1.0, Double(locationX / totalWidth)))
                        // The thumb glides to the pointer; only the stored value is quantized.
                        withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.88, blendDuration: 0.1)) {
                            dragPercentage = CGFloat(newPct)
                        }
                        var newValue = range.lowerBound + newPct * (range.upperBound - range.lowerBound)
                        // Continuous sliders store 1% steps: each write re-renders everything observing AppState.
                        let quantum = step ?? (range.upperBound - range.lowerBound) / 100
                        if quantum > 0 {
                            newValue = (newValue / quantum).rounded() * quantum
                        }
                        newValue = min(max(newValue, range.lowerBound), range.upperBound)
                        if newValue != value {
                            value = newValue
                        }
                    }
                    .onEnded { _ in
                        // Releasing eases the thumb from the pointer to the snapped value instead of jumping.
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                            dragPercentage = nil
                            isDragging = false
                            dragVelocity = 0.0
                        }
                    }
            )
            .onHover { hovering in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    isHovered = hovering
                }
            }
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityValue("\(Int(((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound) * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let increment = step ?? (range.upperBound - range.lowerBound) / 20
            let proposed = direction == .increment ? value + increment : value - increment
            value = min(max(proposed, range.lowerBound), range.upperBound)
        }
    }
}

// MARK: - Liquid selection fill shared by segmented pill rows

/// Colours of the liquid selection in one pill row.
struct LiquidPillStyle {
    var stroke: Color = .white.opacity(0.18)
    var glow: Color = .white.opacity(0.11)
    var volume = true
    /// Label colour outside the liquid; inside it labels are white.
    var label: Color = .primary.opacity(0.85)

    static let pill = LiquidPillStyle()
    static let tab = LiquidPillStyle(stroke: .white.opacity(0.24), glow: .clear, volume: true, label: .secondary)
}

private let liquidPillRowSpace = "liquidPillRow"

/// Option frames in the row's coordinate space, keyed by option.
struct LiquidPillFramesKey: PreferenceKey {
    static var defaultValue: [AnyHashable: CGRect] = [:]

    static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct PillLiquidRevealKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PillLiquidLabelKey: EnvironmentKey {
    static let defaultValue = Color.primary.opacity(0.85)
}

private extension EnvironmentValues {
    /// True inside the white label copy that is masked to the liquid.
    var pillLiquidReveal: Bool {
        get { self[PillLiquidRevealKey.self] }
        set { self[PillLiquidRevealKey.self] = newValue }
    }

    var pillLiquidLabel: Color {
        get { self[PillLiquidLabelKey.self] }
        set { self[PillLiquidLabelKey.self] = newValue }
    }
}

/// Marks a view as one option of a liquid pill row: reports its frame and takes the row's label colour.
private struct LiquidPillOptionModifier: ViewModifier {
    let id: AnyHashable
    @Environment(\.pillLiquidReveal) private var isRevealCopy
    @Environment(\.pillLiquidLabel) private var labelColor

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isRevealCopy ? Color.white : labelColor)
            .background {
                if !isRevealCopy {
                    GeometryReader { proxy in
                        Color.clear.preference(key: LiquidPillFramesKey.self, value: [id: proxy.frame(in: .named(liquidPillRowSpace))])
                    }
                }
            }
    }
}

extension View {
    func liquidPillOption(_ id: AnyHashable) -> some View {
        modifier(LiquidPillOptionModifier(id: id))
    }
}

/// A blob of liquid lying in a pill row: two round ends joined by sides that pinch into a neck when stretched.
struct LiquidPillShape: Shape {
    var minX: CGFloat
    var maxX: CGFloat
    var midY: CGFloat
    var height: CGFloat
    /// 0 = straight sides, 1 = deepest neck.
    var pinch: CGFloat = 0
    /// Vertical squash (< 0) or stretch (> 0) as a fraction of the height.
    var squash: CGFloat = 0
    var leadsRight = true

    static let hidden = LiquidPillShape(minX: 0, maxX: 0, midY: 0, height: 0)

    init(minX: CGFloat, maxX: CGFloat, midY: CGFloat, height: CGFloat, pinch: CGFloat = 0, squash: CGFloat = 0, leadsRight: Bool = true) {
        self.minX = minX
        self.maxX = maxX
        self.midY = midY
        self.height = height
        self.pinch = pinch
        self.squash = squash
        self.leadsRight = leadsRight
    }

    init(_ rect: CGRect) {
        self.init(minX: rect.minX, maxX: rect.maxX, midY: rect.midY, height: rect.height)
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(minX, maxX), AnimatablePair(midY, height)) }
        set {
            minX = newValue.first.first
            maxX = newValue.first.second
            midY = newValue.second.first
            height = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let width = maxX - minX
        guard width > 1, height > 1 else { return Path() }
        let ease = pinch * pinch * (3 - 2 * pinch)
        let half = height / 2
        // The leading end keeps its mass; the tail thins out as it is pulled along.
        let leadR = min(half * (1 + squash * 0.5), width / 2)
        let tailR = min(half * (1 + squash) * (1 - 0.18 * ease), width / 2)
        let rL = leadsRight ? tailR : leadR
        let rR = leadsRight ? leadR : tailR
        let cL = minX + rL
        let cR = maxX - rR
        // The neck forms a little behind the middle, where the liquid is thinnest.
        let neckX = (cL + cR) / 2 + (cR - cL) * (leadsRight ? -0.12 : 0.12)
        let neck = min(rL, rR) * (1 - 0.46 * ease)

        var path = Path()
        path.move(to: CGPoint(x: cL, y: midY - rL))
        Self.addSide(&path, from: CGPoint(x: cL, y: midY - rL), neck: CGPoint(x: neckX, y: midY - neck), to: CGPoint(x: cR, y: midY - rR))
        path.addArc(center: CGPoint(x: cR, y: midY), radius: rR, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        Self.addSide(&path, from: CGPoint(x: cR, y: midY + rR), neck: CGPoint(x: neckX, y: midY + neck), to: CGPoint(x: cL, y: midY + rL))
        path.addArc(center: CGPoint(x: cL, y: midY), radius: rL, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }

    /// Two cubics with flat tangents at the ends and at the neck, so the side meets the round ends smoothly.
    private static func addSide(_ path: inout Path, from a: CGPoint, neck m: CGPoint, to b: CGPoint) {
        let k: CGFloat = 0.55
        path.addCurve(to: m, control1: CGPoint(x: a.x + (m.x - a.x) * k, y: a.y), control2: CGPoint(x: m.x - (m.x - a.x) * k, y: m.y))
        path.addCurve(to: b, control1: CGPoint(x: m.x + (b.x - m.x) * k, y: m.y), control2: CGPoint(x: b.x - (b.x - m.x) * k, y: b.y))
    }
}

private struct InvertedPathShape: Shape {
    let blobPath: Path

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -12, dy: -12))
        path.addPath(blobPath)
        return path
    }
}

/// Spring physics for the liquid: each edge has its own spring, the edge facing the travel direction is
/// quick and the trailing edge is slower and hangs on briefly, so the blob stretches across the gap and
/// then contracts into the target with a jelly wobble. Only stepped while something moves.
final class LiquidPillSim: ObservableObject {
    private struct Edge {
        var x: CGFloat = 0
        var v: CGFloat = 0
    }

    private struct Spring {
        let response: CGFloat
        let damping: CGFloat
    }

    private static let lead = Spring(response: 0.28, damping: 0.72)
    private static let trail = Spring(response: 0.45, damping: 0.68)
    private static let dragLead = Spring(response: 0.11, damping: 0.86)
    private static let dragTrail = Spring(response: 0.30, damping: 0.74)
    private static let jelly = Spring(response: 0.24, damping: 0.40)

    private var lo = Edge()
    private var hi = Edge()
    private var squash = Edge()
    private var goalLo: CGFloat = 0
    private var goalHi: CGFloat = 0
    private var midY: CGFloat = 0
    private var height: CGFloat = 0
    private var restWidth: CGFloat = 0
    private var movingRight = true
    private var holdUntil: TimeInterval = 0
    private var holdX: CGFloat = 0
    private var dragging = false
    private var lastTarget: CGRect?
    private var visible = false
    private var clock: TimeInterval = 0
    private var edgesRestingSince: TimeInterval?
    private(set) var isSettled = true
    private var completionPending = false
    private let onArrival: () -> Void
    var onDetent: () -> Void = {}

    init(onArrival: @escaping () -> Void = {}) {
        self.onArrival = onArrival
    }

    func selectionChanged(animated: Bool) {
        completionPending = true
        if !animated { completeMove() }
    }

    func cancelArrival() {
        completionPending = false
    }

    private func completeMove() {
        guard completionPending else { return }
        completionPending = false
        onArrival()
    }

    /// Feeds the current goal: the selected option's frame, or the drag position while dragging.
    func update(target: CGRect?, drag: (center: CGFloat, option: CGRect)?, at time: TimeInterval) {
        if let drag {
            follow(center: drag.center, option: drag.option, at: time)
            return
        }
        let dragEnded = dragging
        dragging = false
        guard let target else {
            visible = false
            lastTarget = nil
            return
        }
        if !visible || dragEnded || target != lastTarget {
            move(to: target, at: time, snap: !visible)
        }
    }

    func advance(to time: TimeInterval) {
        guard !isSettled, time > clock else { return }
        var remaining = CGFloat(min(time - clock, 1.0 / 30))
        clock = time
        let holding = time < holdUntil
        while remaining > 0 {
            let h = min(1.0 / 240, remaining)
            remaining -= h
            integrate(h, holding: holding)
        }
        // The fast edge lands before the trailing edge and jelly finish resting.
        let leadingEdgeArrived = movingRight ? hi.x >= goalHi - 2 : lo.x <= goalLo + 2
        if !dragging && !holding && leadingEdgeArrived { completeMove() }
        let edgesResting = !dragging && !holding
            && abs(lo.x - goalLo) < 0.25 && abs(hi.x - goalHi) < 0.25
            && abs(lo.v) < 4 && abs(hi.v) < 4
        if edgesResting {
            if edgesRestingSince == nil { edgesRestingSince = time }
        } else {
            edgesRestingSince = nil
        }
        let deformationResting = abs(squash.x) < 0.004 && abs(squash.v) < 0.08
        if edgesResting && (deformationResting || time - (edgesRestingSince ?? time) >= 0.3) {
            lo = Edge(x: goalLo)
            hi = Edge(x: goalHi)
            squash = Edge()
            restWidth = goalHi - goalLo
            isSettled = true
            completeMove()
        }
    }

    var shape: LiquidPillShape {
        guard visible else { return .hidden }
        // Drawn with soft limits so long trips don't turn into a noodle or fly past the end of the row.
        let soft = { (amount: CGFloat, limit: CGFloat) in amount > 0 ? limit * tanh(amount / limit) : amount }
        var minX = lo.x
        var maxX = hi.x
        if movingRight {
            maxX = goalHi + soft(maxX - goalHi, height * 0.2)
        } else {
            minX = goalLo - soft(goalLo - minX, height * 0.2)
        }
        let rest = max(restWidth, goalHi - goalLo)
        let length = rest + soft(maxX - minX - rest, height * 3)
        if movingRight { minX = maxX - length } else { maxX = minX + length }
        return LiquidPillShape(
            minX: minX, maxX: maxX, midY: midY, height: height,
            pinch: min(max((length - rest) / max(height, 1) / 2, 0), 1),
            squash: squash.x,
            leadsRight: movingRight
        )
    }

    /// How much longer than at rest the blob is, in pill heights.
    private var stretch: CGFloat {
        (hi.x - lo.x - max(restWidth, goalHi - goalLo)) / max(height, 1)
    }

    private func wake(at time: TimeInterval) {
        if isSettled {
            clock = time
            isSettled = false
        }
    }

    /// Hidden views resume at the current selection, without replaying an old flight.
    func snap(to target: CGRect?, at time: TimeInterval) {
        completionPending = false
        dragging = false
        holdUntil = 0
        edgesRestingSince = nil
        clock = time
        if let target {
            move(to: target, at: time, snap: true)
        } else {
            visible = false
            lastTarget = nil
            isSettled = true
        }
    }

    private func move(to rect: CGRect, at time: TimeInterval, snap: Bool) {
        lastTarget = rect
        midY = rect.midY
        height = rect.height
        goalLo = rect.minX
        goalHi = rect.maxX
        if snap {
            lo = Edge(x: rect.minX)
            hi = Edge(x: rect.maxX)
            squash = Edge()
            restWidth = rect.width
            visible = true
            isSettled = true
            return
        }
        let trip = rect.midX - (lo.x + hi.x) / 2
        guard abs(trip) > 2 else {
            let wasMoving = !isSettled
            move(to: rect, at: time, snap: true)
            if wasMoving { completeMove() }
            return
        }
        edgesRestingSince = nil
        wake(at: time)
        movingRight = trip > 0
        restWidth = hi.x - lo.x
        holdX = movingRight ? lo.x : hi.x
        // The trailing edge lets go a moment later, longer on longer trips.
        holdUntil = time + min(0.03 + 0.02 * Double(abs(trip) / max(rect.width, 1)), 0.09)
    }

    private func follow(center: CGFloat, option: CGRect, at time: TimeInterval) {
        if !visible { move(to: option, at: time, snap: true) }
        wake(at: time)
        dragging = true
        lastTarget = nil
        holdUntil = 0
        let newLo = center - option.width / 2
        if abs(newLo - goalLo) > 1 { movingRight = newLo > goalLo }
        goalLo = newLo
        goalHi = newLo + option.width
        restWidth = option.width
        midY = option.midY
        height = option.height
    }

    private func integrate(_ h: CGFloat, holding: Bool) {
        // A re-selection can capture a stretched width; it must not become a permanent rest width.
        restWidth += (goalHi - goalLo - restWidth) * (1 - exp(-12 * h))
        let lead = dragging ? Self.dragLead : Self.lead
        let trail = dragging ? Self.dragTrail : Self.trail
        if movingRight {
            Self.step(&hi, to: goalHi, lead, h)
            Self.step(&lo, to: holding ? holdX : goalLo, trail, h)
        } else {
            Self.step(&lo, to: goalLo, lead, h)
            Self.step(&hi, to: holding ? holdX : goalHi, trail, h)
        }
        // Volume is roughly kept: a stretched blob gets thinner, a compressed one taller, and it wobbles back.
        Self.step(&squash, to: min(max(-0.09 * stretch, -0.16), 0.08), Self.jelly, h)
    }

    private static func step(_ edge: inout Edge, to goal: CGFloat, _ spring: Spring, _ h: CGFloat) {
        let omega = 2 * .pi / spring.response
        let acceleration = -omega * omega * (edge.x - goal) - 2 * spring.damping * omega * edge.v
        edge.v += acceleration * h
        edge.x += edge.v * h
    }
}

struct LiquidPillPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private final class PillRowRenderToken {
    private var version: UInt64 = 0
    func next() -> UInt64 {
        version &+= 1
        return version
    }
}

private struct StaticPillRow<Row: View>: View, Equatable {
    let version: UInt64
    let row: Row

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version
    }

    var body: some View {
        row
    }
}

/// Retains the current detent until the pointer clears the next midpoint by 4 pt.
func liquidPillDetentIndex(at x: CGFloat, centers: [CGFloat], current: Int) -> Int {
    guard centers.indices.contains(current) else { return current }
    var index = current
    while index + 1 < centers.count, x >= (centers[index] + centers[index + 1]) / 2 + 4 {
        index += 1
    }
    while index > 0, x <= (centers[index - 1] + centers[index]) / 2 - 4 {
        index -= 1
    }
    return index
}

private final class PillDetentHaptics {
    private var lastDetent = -Double.infinity

    func detent() {
        lastDetent = ProcessInfo.processInfo.systemUptime
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func arrival() {
        guard ProcessInfo.processInfo.systemUptime - lastDetent >= 0.08 else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// One liquid selection behind a row of `liquidPillOption` views, with drag-to-switch and VoiceOver adjust.
struct SelectedPillDragGesture<Option: Hashable>: ViewModifier {
    @EnvironmentObject private var state: AppState
    let options: [Option]
    let selected: Option?
    var style = LiquidPillStyle.pill
    let onSelect: (Option) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var frames: [AnyHashable: CGRect] = [:]
    @State private var dragX: CGFloat?
    @State private var dragRejected = false
    @State private var dragOption: Option?
    @StateObject private var sim: LiquidPillSim

    init(options: [Option], selected: Option?, style: LiquidPillStyle = .pill, onSelect: @escaping (Option) -> Void) {
        self.options = options
        self.selected = selected
        self.style = style
        self.onSelect = onSelect
        _sim = StateObject(wrappedValue: {
            let haptics = PillDetentHaptics()
            let sim = LiquidPillSim(onArrival: { haptics.arrival() })
            sim.onDetent = { haptics.detent() }
            return sim
        }())
    }
    @State private var isRunning = false
    @State private var windowVisible = false
    @State private var renderToken = PillRowRenderToken()

    private var targetFrame: CGRect? {
        selected.flatMap { frames[AnyHashable($0)] }
    }

    private func nearestOption(to x: CGFloat) -> Option? {
        options.filter { frames[AnyHashable($0)] != nil }
            .min { abs(frames[AnyHashable($0)]!.midX - x) < abs(frames[AnyHashable($1)]!.midX - x) }
    }

    func body(content: Content) -> some View {
        let rowVersion = renderToken.next()
        let row = content
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.7), value: selected)
            .environment(\.pillLiquidLabel, style.label)
        let staticBaseRow = StaticPillRow(version: rowVersion, row: row)
        let staticRevealRow = StaticPillRow(
            version: rowVersion,
            row: row.environment(\.pillLiquidReveal, true).padding(2).drawingGroup().padding(-2)
        )

        Group {
            if reduceMotion {
                let rect = dragX.flatMap(nearestOption(to:)).flatMap { frames[AnyHashable($0)] } ?? targetFrame
                liquidLayers(baseRow: staticBaseRow, revealRow: staticRevealRow, blob: rect.map(LiquidPillShape.init) ?? .hidden)
                    .animation(.easeInOut(duration: 0.18), value: rect)
            } else {
                TimelineView(.animation(paused: !windowVisible || !isRunning)) { context in
                    let blob = tick(context.date)
                    liquidLayers(baseRow: staticBaseRow, revealRow: staticRevealRow, blob: blob)
                        .onChange(of: sim.isSettled, initial: true) { _, _ in
                            isRunning = windowVisible && !sim.isSettled
                        }
                }
            }
        }
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .onChange(of: windowVisible) { _, _ in
            sim.snap(to: targetFrame, at: Date().timeIntervalSinceReferenceDate)
            isRunning = false
        }
        .onChange(of: selected) { _, _ in
            guard windowVisible, targetFrame != nil else { return }
            sim.selectionChanged(animated: !reduceMotion)
        }
        .onPreferenceChange(LiquidPillFramesKey.self) { newFrames in
            if frames != newFrames {
                frames = newFrames
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(dragGesture, including: isEnabled ? .all : .subviews)
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            guard isEnabled, let selected, let index = options.firstIndex(of: selected) else { return }
            switch direction {
            case .increment where index + 1 < options.count: onSelect(options[index + 1])
            case .decrement where index > 0: onSelect(options[index - 1])
            default: break
            }
        }
        .coordinateSpace(.named(liquidPillRowSpace))
    }

    /// Labels outside the liquid in the row colour, the liquid fill, and white labels clipped to the liquid.
    private func liquidLayers<BaseRow: View & Equatable, RevealRow: View & Equatable>(baseRow: BaseRow, revealRow: RevealRow, blob: LiquidPillShape) -> some View {
        let blobPath = blob.path(in: .zero)
        let hasGlow = style.glow != .clear

        return baseRow
            .equatable()
            .mask(InvertedPathShape(blobPath: blobPath).fill(style: FillStyle(eoFill: true)))
            .background {
                ZStack {
                    blobPath.fill(LinearGradient(colors: [state.accentColor.opacity(0.95), state.accentColor.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if style.volume {
                        // Lighter on top, slightly deeper underneath.
                        blobPath.fill(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0), .black.opacity(0.10)], startPoint: .top, endPoint: .bottom))
                    }
                    blobPath.stroke(style.stroke, lineWidth: 0.5)
                }
                .shadow(color: hasGlow ? style.glow : .clear, radius: hasGlow ? 5 : 0, y: hasGlow ? 1.5 : 0)
            }
            .overlay {
                revealRow
                    .equatable()
                    .mask(blobPath)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    private func tick(_ date: Date) -> LiquidPillShape {
        let drag = dragX.flatMap { x -> (center: CGFloat, option: CGRect)? in
            let centers = options.compactMap { frames[AnyHashable($0)]?.midX }
            guard let first = centers.min(), let last = centers.max(),
                  let option = nearestOption(to: x).flatMap({ frames[AnyHashable($0)] }) else { return nil }
            // Rubber-band past the first and last option.
            let center = x < first ? first + (x - first) * 0.25 : (x > last ? last + (x - last) * 0.25 : x)
            return (center, option)
        }
        if windowVisible {
            sim.update(target: targetFrame, drag: drag, at: date.timeIntervalSinceReferenceDate)
            sim.advance(to: date.timeIntervalSinceReferenceDate)
        } else {
            sim.snap(to: targetFrame, at: date.timeIntervalSinceReferenceDate)
        }
        return sim.shape
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(liquidPillRowSpace))
            .onChanged { value in
                guard isEnabled, !dragRejected else { return }
                // Mostly vertical: leave it to scrolling.
                if dragX == nil, abs(value.translation.height) > abs(value.translation.width) {
                    dragRejected = true
                    return
                }
                let ordered = options.compactMap { option -> (Option, CGFloat)? in
                    frames[AnyHashable(option)].map { (option, $0.midX) }
                }.sorted { $0.1 < $1.1 }
                if dragX == nil {
                    sim.cancelArrival()
                    dragOption = nearestOption(to: value.startLocation.x)
                }
                if let current = ordered.firstIndex(where: { $0.0 == dragOption }) {
                    let next = liquidPillDetentIndex(at: value.location.x, centers: ordered.map { $0.1 }, current: current)
                    // A fast event can cross several boundaries.
                    for _ in 0..<abs(next - current) { sim.onDetent() }
                    dragOption = ordered[next].0
                }
                dragX = value.location.x
            }
            .onEnded { value in
                defer {
                    dragX = nil
                    dragRejected = false
                    dragOption = nil
                }
                guard dragX != nil, isEnabled, !dragRejected else { return }
                let x = value.location.x + (value.predictedEndLocation.x - value.location.x) * 0.15
                if let option = nearestOption(to: x), option != selected {
                    onSelect(option)
                }
            }
    }
}

// MARK: - Reusable selectable pill
struct UniversalPillGliderItem<T: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: T
    let title: String
    let icon: String?
    let isSelected: Bool
    let accentColor: Color
    let contrastTextColor: Color
    let action: () -> Void
    
    @Environment(\.pillLiquidReveal) private var isRevealCopy

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10.5, design: .rounded))
                }
                Text(title)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 26)
            .frame(maxWidth: .infinity)
            .background {
                if !isRevealCopy {
                    Capsule()
                        .surfaceFill(LinearGradient(colors: [Color.surfaceWhite(0.08, for: colorScheme), Color.surfaceWhite(0.03, for: colorScheme)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .darkControlSurface(Capsule(), enabled: !isSelected)
                        .overlay(
                            Capsule().strokeBorder(
                                LinearGradient(colors: [Color.surfaceWhite(0.10, for: colorScheme), Color.surfaceWhite(0.04, for: colorScheme)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 0.5
                            )
                        )
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(LiquidPillPressStyle())
        .liquidPillOption(item)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Dedicated Folder Section Item View with Drag & Drop Targeting & Inline Customization
private struct FolderSectionItemView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    let folder: CompressionFolder
    let isEditMode: Bool
    @Binding var selectedResultIds: Set<UUID>
    
    @State private var isFolderDropTargeted: Bool = false
    @State private var isEditingName: Bool = false
    @State private var editedName: String = ""
    @State private var showColorPicker: Bool = false
    
    private var effectiveFolderColor: Color {
        if let hex = folder.colorHex, !hex.isEmpty {
            return AppState.colorFromHex(hex) ?? state.accentColor
        }
        return state.accentColor
    }
    
    var body: some View {
        let itemsInFolder = state.recentResults.filter { $0.folderId == folder.id }
        let totalFolderSavedBytes = itemsInFolder.reduce(0) { $0 + max(0, $1.originalSize - $1.compressedSize) }
        let formattedFolderSaved = ByteCountFormatter.string(fromByteCount: totalFolderSavedBytes, countStyle: .file)
        
        VStack(alignment: .leading, spacing: 6) {
            // Folder Header
            HStack(spacing: 6) {
                // Collapse Chevron
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                        state.toggleFolderCollapse(id: folder.id)
                    }
                } label: {
                    Image(systemName: folder.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                        .frame(width: 14, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                // Folder Icon (Double Click to Change Folder Color)
                Image(systemName: isFolderDropTargeted ? "folder.badge.plus" : folder.icon)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(isFolderDropTargeted ? .green : effectiveFolderColor)
                    .scaleEffect(isFolderDropTargeted ? 1.2 : 1.0)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        showColorPicker = true
                    }
                    .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
                        folderColorPaletteView
                    }
                    .help("Double-click to change folder color")
                
                // Folder Name (Double Click to Inline Edit)
                if isEditingName {
                    TextField("Folder Name", text: $editedName, onCommit: {
                        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            state.renameFolder(id: folder.id, newName: trimmed)
                        }
                        isEditingName = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).surfaceFill(Color.surfaceWhite(0.12, for: colorScheme)))
                    .frame(maxWidth: 140)
                } else {
                    Text(folder.name)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            editedName = folder.name
                            isEditingName = true
                        }
                        .help("Double-click to rename folder")
                }
                
                // Folder item count & space saved badge
                HStack(spacing: 3) {
                    Text("(\(itemsInFolder.count))")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundColor(.secondary)
                    
                    if totalFolderSavedBytes > 0 {
                        Text("• -\(formattedFolderSaved)")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(.green.opacity(0.9))
                    }
                }
                
                if isFolderDropTargeted {
                    Text("Drop to Add")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.2)))
                }
                
                Spacer()
                
                if isEditMode {
                    Button("Select All") {
                        let ids = Set(itemsInFolder.map { $0.id })
                        if selectedResultIds.isSuperset(of: ids) {
                            selectedResultIds.subtract(ids)
                        } else {
                            selectedResultIds.formUnion(ids)
                        }
                    }
                    .font(.system(size: 10.5, design: .rounded))
                    .buttonStyle(.plain)
                    .foregroundColor(effectiveFolderColor)
                }
                
                // Folder Options Menu
                Menu {
                    Button("Rename Folder") {
                        editedName = folder.name
                        isEditingName = true
                    }
                    Button("Change Color") {
                        showColorPicker = true
                    }
                    Divider()
                    Button("Delete Folder") {
                        state.deleteFolder(id: folder.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundColor(.secondary)
                        .padding(4)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .surfaceFill(isFolderDropTargeted ? Color.green.opacity(0.12) : Color.surfaceWhite(0.03, for: colorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isFolderDropTargeted ? Color.green.opacity(0.6) : Color.clear, lineWidth: 1)
                    )
            )
            
            // Folder Contents (Collapsible)
            if !folder.isCollapsed {
                if itemsInFolder.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: isFolderDropTargeted ? "arrow.down.doc.fill" : "plus.square.dashed")
                            .font(.system(size: 14, design: .rounded))
                            .foregroundColor(isFolderDropTargeted ? .green : effectiveFolderColor.opacity(0.6))
                        
                        Text(isFolderDropTargeted ? "Release to drop into \(folder.name)" : "Drop files here or use 'Move' in Edit mode")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundColor(isFolderDropTargeted ? .green : .secondary.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .surfaceFill(isFolderDropTargeted ? Color.green.opacity(0.08) : Color.surfaceWhite(0.015, for: colorScheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        isFolderDropTargeted ? Color.green.opacity(0.5) : effectiveFolderColor.opacity(0.2),
                                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                                    )
                            )
                    )
                    .padding(.leading, 12)
                } else {
                    HStack(spacing: 6) {
                        // Vertical hierarchy tree line
                        Rectangle()
                            .fill(effectiveFolderColor.opacity(0.25))
                            .frame(width: 2)
                            .cornerRadius(1)
                            .padding(.leading, 10)
                        
                        VStack(spacing: 6) {
                            ForEach(itemsInFolder) { item in
                                QuickPopoverHistoryRowItem(
                                    item: item,
                                    isEditMode: isEditMode,
                                    selectedResultIds: $selectedResultIds
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .onDrop(of: [.item], isTargeted: $isFolderDropTargeted) { providers in
            extractAndProcessFolderDrop(providers: providers, targetFolderId: folder.id)
        }
    }
    
    // MARK: - Folder Color Palette Popover (Matches Settings Theme Tab)
    private var folderColorPaletteView: some View {
        let presetThemes: [(AccentColorTheme, String, Color)] = [
            (.blue, "1A80FF", Color(red: 0.1, green: 0.5, blue: 1.0)),
            (.purple, "A652E0", Color(red: 0.65, green: 0.32, blue: 0.88)),
            (.pink, "FA5294", Color(red: 0.98, green: 0.32, blue: 0.58)),
            (.red, "F24747", Color(red: 0.95, green: 0.28, blue: 0.28)),
            (.orange, "FA8C2E", Color(red: 0.98, green: 0.55, blue: 0.18)),
            (.yellow, "FAC71F", Color(red: 0.98, green: 0.78, blue: 0.12)),
            (.green, "52D16B", Color(red: 0.32, green: 0.82, blue: 0.42)),
            (.graphite, "9499A3", Color(red: 0.58, green: 0.60, blue: 0.64))
        ]
        
        return VStack(alignment: .leading, spacing: 8) {
            Text("Folder Color")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            
            HStack(spacing: 8) {
                // Default theme accent option
                Button {
                    state.updateFolderColor(id: folder.id, colorHex: nil)
                    showColorPicker = false
                } label: {
                    ZStack {
                        Circle()
                            .fill(state.accentColor)
                            .frame(width: 20, height: 20)
                        
                        if folder.colorHex == nil {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .black, design: .rounded))
                                .foregroundColor(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Default App Theme Color")
                
                // Color presets from theme palette
                ForEach(presetThemes, id: \.1) { item in
                    let hex = item.1
                    let col = item.2
                    Button {
                        state.updateFolderColor(id: folder.id, colorHex: hex)
                        showColorPicker = false
                    } label: {
                        ZStack {
                            Circle()
                                .fill(col)
                                .frame(width: 20, height: 20)
                            
                            if folder.colorHex?.uppercased() == hex.uppercased() {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .black, design: .rounded))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(item.0.displayName)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
    }
    
    private func extractAndProcessFolderDrop(providers: [NSItemProvider], targetFolderId: UUID) -> Bool {
        StatusBarController.sharedInstance?.finishFileDragHover(didDrop: true)
        loadDroppedFileURLs(from: providers) { collectedURLs in
            if !collectedURLs.isEmpty {
                Task {
                    await MediaCompressionEngine.shared.processDroppedURLs(collectedURLs, targetFolderId: targetFolderId)
                }
            }
        }
        return true
    }
}

// MARK: - Reusable History Row Item
private struct QuickPopoverHistoryRowItem: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    let item: CompressionResult
    let isEditMode: Bool
    @Binding var selectedResultIds: Set<UUID>
    
    @State private var isHovered: Bool = false
    private var resultBadge: some View {
        let sizeDifference = item.compressedSize - item.originalSize
        let tint: Color
        let label: String
        let fillOpacity: Double

        if item.skipped == true {
            tint = .secondary
            label = String(localized: "Skipped")
            fillOpacity = 0.03
        } else if sizeDifference < 0 {
            tint = state.accentColor
            label = String(format: "-%.0f%%", item.percentSaved)
            fillOpacity = 0.07
        } else if sizeDifference > 0 {
            tint = .orange
            label = String(localized: "\(ByteCountFormatter.string(fromByteCount: sizeDifference, countStyle: .file)) larger")
            fillOpacity = 0.05
        } else {
            tint = .secondary
            label = "0%"
            fillOpacity = 0.03
        }

        return Text(label)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundColor(tint)
            .lineLimit(1)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(tint.opacity(fillOpacity)))
    }
    
    var body: some View {
        let isSelected = selectedResultIds.contains(item.id)
        
        HStack(spacing: 9) {
            if isEditMode {
                Button {
                    withAnimation(.spring(response: 0.2)) {
                        if isSelected {
                            selectedResultIds.remove(item.id)
                        } else {
                            selectedResultIds.insert(item.id)
                        }
                    }
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(isSelected ? state.accentColor : .secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isSelected ? Text("Deselect item") : Text("Select item"))
                .accessibilityLabel(isSelected ? Text("Deselect item") : Text("Select item"))
            }
            
            FileThumbnailView(url: item.outputURL, mediaType: item.mediaType, size: 30, usesDarkControlSurface: true)
            
            VStack(alignment: .leading, spacing: 2.5) {
                Text(item.fileName)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                if let caption = item.outcomeCaption {
                    Text(caption).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 5) {
                    Text(item.formattedOriginalSize)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.85))
                    Text(item.formattedCompressedSize)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(item.compressedSize < item.originalSize ? state.accentColor : .secondary)
                    Text("·  \(item.timestamp, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.85))
                        .lineLimit(1)
                }
            }
            
            Spacer(minLength: 4)
            
            resultBadge
            
            // Action Buttons in Frosted Mini Glass
            HStack(spacing: 2) {
                Button {
                    InspectorWindowController.shared.show(result: item)
                } label: {
                    Image(systemName: "slider.horizontal.below.rectangle")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.clear.darkControlSurface(RoundedRectangle(cornerRadius: 7), borderless: true))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.skipped == true)
                .help("Open Before/After Comparison Inspector")
                .accessibilityLabel("Compare before and after")
                
                Button {
                    state.revealInFinder(url: item.outputURL)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.clear.darkControlSurface(RoundedRectangle(cornerRadius: 7), borderless: true))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background {
            if colorScheme == .dark && !isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.clear)
                    .darkControlSurface(RoundedRectangle(cornerRadius: 8), highlighted: isHovered)
            } else {
                Rectangle().surfaceFill(isSelected ? state.accentColor.opacity(0.08) : Color.surfaceWhite(isHovered ? 0.025 : 0.008, for: colorScheme))
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.surfaceWhite(0.045, for: colorScheme)).frame(height: 0.5)
        }
        .onHover { h in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                isHovered = h
            }
        }
        .onDrag {
            NSItemProvider(object: item.outputURL as NSURL)
        }
    }
}

// MARK: - Staged Queue Row Item with Per-File Custom Settings
private struct StagedQueueRowItem: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var item: StagedQueueItem
    @State private var showSettingsSheet: Bool = false
    @State private var isHovered: Bool = false
    
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .surfaceFill(Color.surfaceWhite(0.06, for: colorScheme))
                    .frame(width: 28, height: 28)
                
                Image(systemName: iconForMediaType(item.mediaType))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(state.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 1.5) {
                Text(item.fileName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                HStack(spacing: 4) {
                    Text(item.formattedOriginalSize)
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .font(.system(size: 8, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.85))
                    
                    Text(customSettingSummary)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(state.accentColor.opacity(0.95))
                }
            }
            
            Spacer(minLength: 4)
            
            // Custom Settings Button
            Button {
                showSettingsSheet = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    Text("Custom")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().surfaceFill(Color.surfaceWhite(0.08, for: colorScheme)))
                .overlay(Capsule().strokeBorder(Color.surfaceWhite(0.12, for: colorScheme), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSettingsSheet, arrowEdge: .trailing) {
                QueueItemSettingsSheet(item: item)
            }
            
            // Remove Button
            Button {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
                    state.removeFromQueue(id: item.id)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.85))
                    .padding(3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            ZStack {
                NonDraggableArea()
                RoundedRectangle(cornerRadius: 8)
                    .surfaceFill(Color.surfaceWhite(isHovered ? 0.05 : 0.03, for: colorScheme))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.surfaceWhite(0.06, for: colorScheme), lineWidth: 0.5))
            }
        )
        .onHover { h in
            isHovered = h
        }
    }
    
    private var customSettingSummary: String {
        var parts: [String] = []
        if item.customTargetSizeMode != .off {
            if let mb = item.customTargetSizeMode.targetMegabytes {
                parts.append(String(localized: "\(Int(mb))MB Limit"))
            }
        }
        parts.append(String(localized: "\(Int(item.customQuality * 100))% Q", comment: "Quality percentage, abbreviated"))
        if item.customResolutionScale < 0.99 {
            parts.append(String(localized: "\(Int(item.customResolutionScale * 100))% Scale"))
        }
        return parts.joined(separator: " • ")
    }
    
    private func iconForMediaType(_ type: MediaType) -> String {
        switch type {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.text.fill"
        case .unsupported: return "doc"
        }
    }
}
