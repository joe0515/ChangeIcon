import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var store: IconSchemeStore
    @EnvironmentObject private var appearance: AppearanceMonitor
    @EnvironmentObject private var applier: IconApplier
    @EnvironmentObject private var previewCache: IconPreviewCache

    @State private var selection: IconScheme.ID?
    @State private var searchText = ""
    @State private var isSidebarTargeted = false

    private var filteredSchemes: [IconScheme] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.schemes }
        return store.schemes.filter { scheme in
            scheme.appName.localizedCaseInsensitiveContains(query)
                || scheme.appURL.path.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedScheme: IconScheme? {
        store.schemes.first { $0.id == selection } ?? store.schemes.first
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 480)
        } detail: {
            detail
                .frame(minWidth: 400)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 960)
        .onAppear {
            selection = selection ?? store.schemes.first?.id
            SharedAppState.shared.openWindowAction = { id in
                openWindow(id: id)
            }
        }
        .onChange(of: store.schemes) { _, schemes in
            if let selection, schemes.contains(where: { $0.id == selection }) {
                return
            }
            withAnimation(.easeInOut(duration: 0.2)) { selection = schemes.first?.id }
        }
        .onReceive(NotificationCenter.default.publisher(for: .iconSchemeApplied)) { notification in
            guard
                let id = notification.userInfo?["id"] as? UUID,
                let mode = notification.userInfo?["mode"] as? AppearanceMode
            else { return }
            store.markApplied(
                id,
                mode: mode
            )
            // Invalidate preview cache so app icon reflects current state
            if let scheme = store.schemes.first(where: { $0.id == id }) {
                previewCache.invalidateAppIcon(for: scheme.appURL)
            }
        }
        .alert("🔐 权限设置引导", isPresented: $applier.needsPermissionSetup) {
            Button("打开系统设置") {
                applier.needsPermissionSetup = false
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("我已手动安装") {
                applier.needsPermissionSetup = false
            }
            Button("稍后", role: .cancel) {
                applier.needsPermissionSetup = false
            }
        } message: {
            Text(applier.permissionGuideMessage)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索应用名称或路径", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .top], 12)

            List(filteredSchemes, selection: $selection) { scheme in
                AppRow(scheme: scheme, isCurrentMode: scheme.lastAppliedMode == appearance.current)
                    .tag(scheme.id)
                    .contextMenu {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([scheme.appURL])
                        }
                        Divider()
                        Button("复制应用路径") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(scheme.appURL.path, forType: .string)
                        }
                        Divider()
                        Button("移除", role: .destructive) {
                            store.remove(scheme)
                        }
                    }
            }
            .overlay {
                if store.schemes.isEmpty {
                    ContentUnavailableView(
                        "拖拽应用到此处",
                        systemImage: "app.badge",
                        description: Text("把一个 .app 拖进来，然后为它分别设置浅色和深色图标。")
                    )
                } else if filteredSchemes.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .overlay(alignment: .center) {
                if isSidebarTargeted && store.schemes.isEmpty {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.blue, style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isSidebarTargeted) { providers in
                handleSidebarDrop(providers: providers)
            }

            Divider()

            HStack {
                Button {
                    pickApps()
                } label: {
                    Label("添加应用", systemImage: "plus")
                }
                .keyboardShortcut("o", modifiers: .command)

                Spacer()

                Menu {
                    Button("导入图标包") { importIconPack() }
                    Divider()
                    Button("导出方案...") { exportSchemes() }
                    Button("导入方案...") { importSchemes() }
                    Divider()
                    Button("撤销 (⌘Z)") { store.undo() }
                        .disabled(!store.canUndo)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Detail

    private var detail: some View {
        ZStack(alignment: .bottom) {
            if let scheme = selectedScheme {
                SchemeDetailView(scheme: scheme)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 46))
                        .foregroundStyle(.secondary)
                    Text("选择一个应用开始")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("拖拽 .app 到这里，或在侧边栏点击 + 添加")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        pickApps()
                    } label: {
                        Label("添加应用", systemImage: "plus")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let progress = applier.currentProgress {
                VStack(spacing: 8) {
                    ProgressView(value: Double(progress.current), total: Double(progress.total))
                        .progressViewStyle(.linear)
                    Text("正在处理 \(progress.current) / \(progress.total)...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut, value: progress.current)
            }
        }
    }

    // MARK: - Actions

    private func pickApps() {
        let panel = NSOpenPanel()
        panel.title = "选择要更换图标的应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(store.addApp)
        selection = panel.urls.first.flatMap { url in
            store.schemes.first { $0.appURL.standardizedFileURL == url.standardizedFileURL }?.id
        } ?? selection
    }

    private func importIconPack() {
        let panel = NSOpenPanel()
        panel.title = "选择图标包文件夹"
        panel.prompt = "导入"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.importIconPack(from: url)
        previewCache.removeAll()
    }

    private func exportSchemes() {
        let panel = NSSavePanel()
        panel.title = "导出图标方案"
        panel.nameFieldStringValue = "ChangeIcon_Schemes.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.exportSchemes(to: url)
    }

    private func importSchemes() {
        let panel = NSOpenPanel()
        panel.title = "导入图标方案"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.importSchemes(from: url)
    }

    func handleSidebarDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let data = item as? Data
                guard
                    let url = data.flatMap({ URL(dataRepresentation: $0, relativeTo: nil) }),
                    url.pathExtension.lowercased() == "app"
                else { return }
                Task { @MainActor in
                    store.addApp(url)
                    selection = store.schemes.first { $0.appURL.standardizedFileURL == url.standardizedFileURL }?.id ?? selection
                }
            }
        }
        return true
    }
}

// MARK: - App Row

private struct AppRow: View {
    @EnvironmentObject private var previewCache: IconPreviewCache
    @EnvironmentObject private var appearance: AppearanceMonitor

    let scheme: IconScheme
    let isCurrentMode: Bool

    private var displayIcon: NSImage {
        if scheme.isAppInstalled {
            return previewCache.appIcon(for: scheme.appURL, size: NSSize(width: 34, height: 34))
        }
        // For uninstalled apps, show the previously set icon for the current mode
        if let iconURL = scheme.iconURL(for: appearance.current),
           let image = NSImage(contentsOf: iconURL) {
            image.size = NSSize(width: 34, height: 34)
            return image
        }
        // Fallback: generic app placeholder
        let placeholder = NSWorkspace.shared.icon(for: .applicationBundle)
        placeholder.size = NSSize(width: 34, height: 34)
        return placeholder
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: displayIcon)
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .opacity(scheme.isAppInstalled ? 1 : 0.7)

            VStack(alignment: .leading, spacing: 3) {
                Text(scheme.appName)
                    .lineLimit(1)
                    .font(.headline)
                    .foregroundStyle(scheme.isAppInstalled ? .primary : .secondary)
                HStack(spacing: 6) {
                    if !scheme.isAppInstalled {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text("已卸载")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Circle()
                            .fill(scheme.enabled ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(scheme.enabled ? "已启用" : "已停用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isCurrentMode {
                            Text("· 已匹配")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }

            Spacer()

            if scheme.isAppInstalled, let mode = scheme.lastAppliedMode {
                Image(systemName: mode == .light ? "sun.max.fill" : "moon.fill")
                    .font(.caption2)
                    .foregroundStyle(mode == .light ? .yellow : .indigo)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Scheme Detail View

private struct SchemeDetailView: View {
    @EnvironmentObject private var store: IconSchemeStore
    @EnvironmentObject private var appearance: AppearanceMonitor
    @EnvironmentObject private var applier: IconApplier
    @EnvironmentObject private var previewCache: IconPreviewCache
    @EnvironmentObject private var suggestionEngine: IconSuggestionEngine
    @EnvironmentObject private var userIconLibrary: UserIconLibrary

    let scheme: IconScheme
    @State private var isApplying = false
    @State private var showSuggestions = false
    @State private var libraryMatches: [URL] = []
    @State private var isSchemeLoading = true

    /// Cached bundle identifier of the target app, used to filter the user icon library.
    /// Falls back to reading from the app bundle, then to looking up from stored icon associations.
    private var appBundleID: String? {
        // 1. Stored cache (persisted even when app is uninstalled)
        if let cached = scheme.cachedBundleID { return cached }
        // 2. Read from live app bundle
        if let live = Bundle(url: scheme.appURL)?.bundleIdentifier { return live }
        // 3. Infer from existing icon associations (fallback for pre-v0.6.0 schemes)
        let iconURLs = [scheme.lightIconURL, scheme.darkIconURL].compactMap { $0 }
        for url in iconURLs {
            if let apps = userIconLibrary.associations(for: url.lastPathComponent), !apps.isEmpty {
                return apps.first
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    iconPickers
                    importSummary
                    libraryPanel
                    shapeSettings
                    suggestionPanel
                    actions
                    logs
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: scheme.id) {
            showSuggestions = false
            libraryMatches = []
            isSchemeLoading = true
            
            let appName = scheme.appName
            libraryMatches = IconLibrary.shared.findMatches(for: appName)
            
            isSchemeLoading = false
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: previewCache.appIcon(for: scheme.appURL, size: NSSize(width: 56, height: 56)))
                .resizable()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 5) {
                Text(scheme.appName)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(scheme.appURL.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Picker("当前外观", selection: .constant(appearance.current)) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .disabled(true)

            Toggle("启用", isOn: Binding(
                get: { scheme.enabled },
                set: { enabled in
                    var updated = scheme
                    updated.enabled = enabled
                    store.update(updated)
                }
            ))
            .toggleStyle(.switch)
        }
        .padding(24)
    }

    private var iconPickers: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("图标设置")
                .font(.headline)

            HStack(alignment: .top, spacing: 12) {
                // Light mode column
                VStack(spacing: 12) {
                    IconDropTarget(
                        title: "浅色模式图标",
                        systemImage: "sun.max.fill",
                        iconURL: scheme.lightIconURL,
                        accent: .yellow,
                        onPick: { url in
                            _ = userIconLibrary.addIcon(from: url, mode: .light, appIdentifier: appBundleID)
                            store.setIcon(url, for: scheme, mode: .light)
                        },
                        onDelete: { store.clearIcon(for: scheme, mode: .light) },
                        defaultIconName: "AppIcon-light"
                    )

                    if !userIconLibrary.lightIcons.isEmpty {
                        iconLibraryGrid(mode: .light)
                    }
                }

                // Dark mode column
                VStack(spacing: 12) {
                    IconDropTarget(
                        title: "深色模式图标",
                        systemImage: "moon.fill",
                        iconURL: scheme.darkIconURL,
                        accent: .indigo,
                        onPick: { url in
                            _ = userIconLibrary.addIcon(from: url, mode: .dark, appIdentifier: appBundleID)
                            store.setIcon(url, for: scheme, mode: .dark)
                        },
                        onDelete: { store.clearIcon(for: scheme, mode: .dark) },
                        defaultIconName: "AppIcon-dark"
                    )

                    if !userIconLibrary.darkIcons.isEmpty {
                        iconLibraryGrid(mode: .dark)
                    }
                }
            }
        }
    }

    private func iconLibraryGrid(mode: AppearanceMode) -> some View {
        let icons = userIconLibrary.filteredIcons(mode: mode, for: appBundleID)
        let allCount = mode == .light ? userIconLibrary.lightIcons.count : userIconLibrary.darkIcons.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(mode == .light ? "浅色图标库" : "深色图标库")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if icons.count != allCount {
                    Text("\(icons.count)/\(allCount)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("\(icons.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if icons.isEmpty {
                Text("还没有为此应用添加图标。拖拽图标到上方区域或点击「选择」按钮添加。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(icons, id: \.absoluteString) { iconURL in
                        iconLibraryItem(iconURL, for: mode)
                    }
                }
            }
        }
    }

    private func iconLibraryItem(_ iconURL: URL, for mode: AppearanceMode) -> some View {
        Button {
            store.setIcon(iconURL, for: scheme, mode: mode)
        } label: {
            if let image = previewCache.image(for: iconURL, size: NSSize(width: 40, height: 40)) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 40, height: 40)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("应用到浅色") {
                store.setIcon(iconURL, for: scheme, mode: .light)
            }
            Button("应用到深色") {
                store.setIcon(iconURL, for: scheme, mode: .dark)
            }
            Divider()
            Button("从库中删除", role: .destructive) {
                userIconLibrary.removeIcon(iconURL)
            }
        }
        .help(iconURL.lastPathComponent)
    }
    // MARK: - Suggestion Panel (双栏浅色/深色)

    private var suggestionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("图标建议")
                    .font(.headline)

                if suggestionEngine.isLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text(suggestionEngine.loadingMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    if showSuggestions {
                        if suggestionEngine.suggestions.contains(where: { $0.source == .ai }) {
                            Label("AI", systemImage: "brain.head.profile")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.green.opacity(0.1)))
                        }
                        if suggestionEngine.isAILoading {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.5)
                                Text("AI 生成中")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Label("本地", systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.purple.opacity(0.1)))
                    }

                    Button {
                        if showSuggestions {
                            showSuggestions = false
                        } else {
                            Task {
                                await suggestionEngine.generateSuggestions(
                                    for: scheme.appURL,
                                    appName: scheme.appName
                                )
                                showSuggestions = true
                            }
                        }
                    } label: {
                        Label(
                            showSuggestions ? "重新生成" : "生成建议",
                            systemImage: showSuggestions ? "arrow.clockwise" : "wand.and.stars"
                        )
                        .font(.caption)
                    }
                }
            }
            .padding(.bottom, 4)

            if showSuggestions && !suggestionEngine.suggestions.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    suggestionColumn(
                        mode: .light,
                        icon: "sun.max.fill",
                        color: Color.orange,
                        suggestions: suggestionEngine.suggestions.filter { $0.mode == .light }
                    )

                    Divider()

                    suggestionColumn(
                        mode: .dark,
                        icon: "moon.fill",
                        color: Color.indigo,
                        suggestions: suggestionEngine.suggestions.filter { $0.mode == .dark }
                    )
                }
                .padding(.top, 4)
            } else if showSuggestions && !suggestionEngine.isLoading {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在搜索图标资源...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 24)
            } else if !showSuggestions {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.yellow)
                    Text("点击「生成建议」为当前应用自动生成多种风格图标方案。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func suggestionColumn(mode: AppearanceMode, icon: String, color: Color, suggestions: [IconSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.subheadline)
                Text(mode == .light ? "浅色模式" : "深色模式")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(suggestions.count) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if suggestions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: mode == .light ? "sun.max" : "moon")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("暂无建议")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                let groups = Dictionary(grouping: suggestions) { $0.category }

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(IconSuggestion.SuggestionCategory.allCases, id: \.self) { category in
                            if let items = groups[category], !items.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 4) {
                                        Image(systemName: categoryIcon(for: category))
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                        Text(category.rawValue)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }

                                    LazyVGrid(
                                        columns: [
                                            GridItem(.adaptive(minimum: 68, maximum: 80), spacing: 8)
                                        ],
                                        spacing: 8
                                    ) {
                                        ForEach(items) { suggestion in
                                            suggestionCard(suggestion)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(maxWidth: .infinity)
    }


    private func categoryIcon(for category: IconSuggestion.SuggestionCategory) -> String {
        switch category {
        case .generated: "sparkles"
        case .flat: "square.on.square"
        case .duotone: "circle.lefthalf.striped.horizontal"
        case .coloroverlay: "paintpalette.fill"
        case .ai: "brain.head.profile"
        }
    }

    private func suggestionCard(_ suggestion: IconSuggestion) -> some View {
        Button {
            store.setIcon(suggestion.previewURL, for: scheme, mode: suggestion.mode)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(suggestion.mode == .light ? Color.white : Color(white: 0.13))
                        .aspectRatio(1, contentMode: .fit)
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)

                    if let image = NSImage(contentsOf: suggestion.previewURL) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(5)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    // Source badge - top right
                    VStack {
                        HStack {
                            Spacer()
                            if suggestion.source == .ai {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.white)
                                    .padding(2)
                                    .background(Circle().fill(Color.green))
                                    .offset(x: 3, y: -3)
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.white)
                                    .padding(2)
                                    .background(Circle().fill(Color.purple))
                                    .offset(x: 3, y: -3)
                            }
                        }
                        Spacer()
                    }
                }

                Text(suggestion.label)
                    .font(.system(size: 8))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("点击应用 · 右键保存")
        .contextMenu {
            Button {
                store.setIcon(suggestion.previewURL, for: scheme, mode: suggestion.mode)
            } label: {
                Label("应用到此模式", systemImage: "square.and.arrow.down")
            }

            Button {
                saveSuggestionToFile(suggestion)
            } label: {
                Label("保存图标文件...", systemImage: "square.and.arrow.down")
            }

            if suggestion.mode == .light {
                Button {
                    store.setIcon(suggestion.previewURL, for: scheme, mode: .dark)
                } label: {
                    Label("也设为深色模式", systemImage: "moon.fill")
                }
            } else {
                Button {
                    store.setIcon(suggestion.previewURL, for: scheme, mode: .light)
                } label: {
                    Label("也设为浅色模式", systemImage: "sun.max.fill")
                }
            }

            Divider()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([suggestion.previewURL])
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
        }
    }

    private func saveSuggestionToFile(_ suggestion: IconSuggestion) {
        let panel = NSSavePanel()
        panel.title = "保存图标"
        panel.nameFieldStringValue = "\(scheme.appName)_\(suggestion.label)_\(suggestion.mode.rawValue).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let saveURL = panel.url else { return }
        try? FileManager.default.copyItem(at: suggestion.previewURL, to: saveURL)
    }

    private var shapeSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("图标形状")
                .font(.headline)

            HStack(spacing: 10) {
                ForEach(IconShape.allCases) { shape in
                    shapeButton(shape)
                }
            }
        }
    }

    private func shapeButton(_ shape: IconShape) -> some View {
        let isSelected = Binding(
            get: { scheme.iconShape == shape },
            set: { selected in
                if selected {
                    var updated = scheme
                    updated.iconShape = shape
                    store.update(updated)
                }
            }
        )

        return Button {
            var updated = scheme
            updated.iconShape = shape
            store.update(updated)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: shape.cornerRadius(for: 36))
                        .fill(Color.accentColor.opacity(isSelected.wrappedValue ? 0.2 : 0.05))
                        .frame(width: 36, height: 36)

                    Image(systemName: shape.systemImage)
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected.wrappedValue ? .blue : .secondary)
                }

                Text(shape.title)
                    .font(.caption2)
                    .foregroundStyle(isSelected.wrappedValue ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }


    @ViewBuilder
    private var libraryPanel: some View {
        if isSchemeLoading {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("图标库", systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.7)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(0..<5, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(nsColor: .quaternaryLabelColor))
                                .frame(width: 64, height: 64)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if !libraryMatches.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("图标库", systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                    Spacer()
                    Text("\(libraryMatches.count) 个匹配")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(libraryMatches.prefix(30), id: \.absoluteString) { iconURL in
                            Button {
                                store.setIcon(iconURL, for: scheme, mode: .light)
                                store.setIcon(iconURL, for: scheme, mode: .dark)
                            } label: {
                                VStack(spacing: 4) {
                                    if let image = previewCache.image(for: iconURL, size: NSSize(width: 64, height: 64)) {
                                        Image(nsImage: image)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 64, height: 64)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    } else {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color(nsColor: .controlBackgroundColor))
                                            .frame(width: 64, height: 64)
                                    }

                                    Text(iconURL.deletingPathExtension().lastPathComponent)
                                        .font(.system(size: 9))
                                        .lineLimit(1)
                                        .frame(width: 72)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("点击同时设为浅色和深色图标")
                            .contextMenu {
                                Button {
                                    store.setIcon(iconURL, for: scheme, mode: .light)
                                } label: {
                                    Label("设为浅色模式", systemImage: "sun.max.fill")
                                }
                                Button {
                                    store.setIcon(iconURL, for: scheme, mode: .dark)
                                } label: {
                                    Label("设为深色模式", systemImage: "moon.fill")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var importSummary: some View {
        Group {
            if !store.importSummary.isEmpty {
                Label(store.importSummary, systemImage: "tray.and.arrow.down.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("操作")
                .font(.headline)

            HStack(spacing: 12) {
                Button {
                    isApplying = true
                    Task {
                        await applier.apply([scheme], appearance: appearance.current)
                        previewCache.removeAll()
                        isApplying = false
                    }
                } label: {
                    Label("应用当前外观图标", systemImage: "paintbrush.pointed.fill")
                }
                .disabled(isApplying)
                .keyboardShortcut("r", modifiers: .command)

                Button {
                    Task {
                        await applier.restore(scheme)
                        previewCache.removeAll()
                    }
                } label: {
                    Label("恢复原始图标", systemImage: "arrow.uturn.backward")
                }

                Button {
                    exportIcon(for: scheme)
                } label: {
                    Label("导出当前图标", systemImage: "square.and.arrow.up")
                }
                .disabled(scheme.iconURL(for: appearance.current) == nil)

                Spacer()

                if isApplying {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
        }
    }

    private func exportIcon(for scheme: IconScheme) {
        guard let iconURL = scheme.iconURL(for: appearance.current) else { return }
        let panel = NSSavePanel()
        panel.title = "导出图标"
        panel.nameFieldStringValue = "\(scheme.appName)_\(appearance.current.rawValue).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let saveURL = panel.url else { return }

        if let image = NSImage(contentsOf: iconURL),
           let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: saveURL)
        } else {
            try? FileManager.default.copyItem(at: iconURL, to: saveURL)
        }
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("操作记录")
                .font(.headline)

            if applier.logs.isEmpty {
                Text("还没有操作记录。")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(applier.logs.prefix(12)) { log in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: log.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(log.isError ? .red : .green)
                            Text(log.message)
                                .textSelection(.enabled)
                                .font(.callout)
                            Spacer()
                            Text(log.date, style: .time)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

}
// MARK: - Icon Drop Target

private struct IconDropTarget: View {
    @EnvironmentObject private var previewCache: IconPreviewCache

    let title: String
    let systemImage: String
    let iconURL: URL?
    let accent: Color
    let onPick: (URL) -> Void
    let onDelete: (() -> Void)?
    let defaultIconName: String

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(accent)
                Spacer()
                if iconURL != nil, let onDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
                Button {
                    pickIcon()
                } label: {
                    Label(iconURL != nil ? "替换" : "选择", systemImage: "folder")
                }
            }

            HStack(spacing: 16) {
                iconPreview

                VStack(alignment: .leading, spacing: 6) {
                    Text(iconURL?.lastPathComponent ?? "支持 .icns、.png、.jpg")
                        .font(.callout)
                        .lineLimit(2)
                    Text(iconURL?.path ?? "点击选择，或拖拽/粘贴图片到此处")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Spacer()
            }
            .padding(16)
            .frame(minHeight: 110)
            .background(isTargeted ? accent.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isTargeted ? accent : Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }
            .onPasteCommand(of: [.fileURL, .image]) { providers in
                _ = handleDrop(providers: providers)
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity)
    }

    @ViewBuilder
    private var iconPreview: some View {
        if let iconURL, let image = previewCache.image(for: iconURL, size: NSSize(width: 76, height: 76)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let defaultURL = Bundle.main.url(forResource: defaultIconName, withExtension: "png"),
                  let defaultImage = NSImage(contentsOf: defaultURL) {
            Image(nsImage: defaultImage)
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .frame(width: 76, height: 76)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let data = item as? Data
                    let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    if let url, Self.isSupported(url) {
                        Task { @MainActor in onPick(url) }
                    }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                    guard let image = item as? NSImage else { return }
                    Task { @MainActor in
                        let tempURL = saveImageToTemp(image)
                        if let tempURL { onPick(tempURL) }
                    }
                }
                return true
            }
        }
        return false
    }

    private func saveImageToTemp(_ image: NSImage) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChangeIcon-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let pngURL = tempDir.appendingPathComponent("pasted.png")

        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else { return nil }

        do {
            try pngData.write(to: pngURL)
            return pngURL
        } catch {
            return nil
        }
    }

    private func pickIcon() {
        let panel = NSOpenPanel()
        panel.title = "选择图标文件"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "icns")!,
            .png,
            .jpeg,
            .tiff
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onPick(url)
    }

    nonisolated private static func isSupported(_ url: URL) -> Bool {
        ["icns", "png", "jpg", "jpeg", "tif", "tiff"].contains(url.pathExtension.lowercased())
    }
}
