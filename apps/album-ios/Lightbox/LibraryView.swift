import SwiftUI

@MainActor
struct LibraryView: View {
    @StateObject private var model = LibraryModel()
    @State private var search = ""
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @State private var showSelections = false
    @State private var filter = PlaybackFilter.all
    @AppStorage("randomPlayback") private var random = true
    @AppStorage("photoInterval") private var interval = 5.0
    @State private var favoritesOnly = false

    private var filtered: [AlbumEntry] {
        search.isEmpty ? model.entries : model.entries.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.service == nil { connectionForm }
                else { browser }
            }
            .navigationTitle("光盒相簿")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("診斷紀錄", systemImage: "waveform.path.ecg") { showDiagnostics = true }
                }
                if model.service != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("播放設定", systemImage: "slider.horizontal.3") { showSettings = true }
                            Button("查看勾選（\(model.selections.count)）", systemImage: "checklist") { showSelections = true }
                            Button("重新整理", systemImage: "arrow.clockwise") { Task { await model.navigate(model.currentPath) } }
                            Button("重新掃描已選範圍", systemImage: "arrow.triangle.2.circlepath") { model.scan(filter: filter, random: random, favoritesOnly: favoritesOnly, force: true) }.disabled(model.selections.isEmpty)
                            Button("更換連線", systemImage: "network") { model.disconnect() }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .disabled(model.busy)
                    }
                }
            }
            .alert("相簿提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("知道了") { model.error = nil }
            } message: { Text(model.error ?? "") }
            .sheet(isPresented: $showSettings) { playbackSettings }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .sheet(isPresented: $showSelections) { selectionList }
            .sheet(isPresented: $model.showScan) { scanProgress.interactiveDismissDisabled() }
            .fullScreenCover(isPresented: $model.showPlayer) {
                if let service = model.service, !model.playlist.isEmpty {
                    PlayerView(entries: model.playlist, service: service, interval: interval, library: model)
                }
            }
        }
    }

    private var connectionForm: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "photo.stack.fill").font(.system(size: 38)).foregroundStyle(.tint)
                    Text("把回憶，慢慢播放。").font(.title2.bold())
                    Text("連接你的電腦或 NAS，照片留在原處，手機直接播放。").font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 14)
            }
            Section {
                TextField("主機 IP 或名稱", text: $model.settings.server).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("分享名稱，例如 Photos 或 e", text: $model.settings.share).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("起始資料夾，例如 相簿（可留空）", text: $model.settings.folder).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("相簿位置") } footer: { Text("不是填 Z:\\相簿。請拆成主機、分享名稱、分享內的資料夾。手機需與主機網路互通；使用 ZeroTier 位址時，手機也要加入該網路。") }
            Section {
                TextField("帳號（留空使用 guest）", text: $model.settings.username).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                SecureField("密碼", text: $model.password).textContentType(.password)
                TextField("網域（通常留空）", text: $model.settings.domain).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("要求 SMB3 加密", isOn: $model.settings.encrypted)
            } header: { Text("登入") } footer: { Text("密碼只儲存在這台 iPhone 的鑰匙圈。App 僅讀取相簿，不會修改或刪除分享內檔案。") }
            Section {
                Button { Task { await model.connect() } } label: {
                    HStack { Spacer(); if model.busy { ProgressView() }; Text(model.busy ? "正在連線…" : "連接相簿"); Spacer() }
                }.disabled(model.busy || model.settings.server.isEmpty || model.settings.share.isEmpty)
            }
            Section {
                Text("第一版 · iPhone\n支援照片輪播、SMB 影片串流與收藏。部分影片編碼不支援時會提示，不會宣稱播放成功。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .disabled(model.busy)
    }

    private var browser: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.settings.server + " / " + model.settings.share, systemImage: "externaldrive.connected.to.line.below").font(.caption).foregroundStyle(.secondary)
                    Text(model.currentPath.isEmpty ? "分享根目錄" : model.currentPath).font(.headline).textSelection(.enabled)
                }.padding(.vertical, 5)
                if model.canGoUp {
                    Button("上一層", systemImage: "arrow.up") {
                        search = ""
                        Task { await model.navigate(model.parentPath) }
                    }.disabled(model.busy)
                }
                Button {
                    model.toggle(model.currentFolder)
                } label: {
                    Label(model.isIncluded(model.currentFolder) ? "已包含此資料夾" : "勾選此資料夾及所有子目錄", systemImage: model.isIncluded(model.currentFolder) ? "checkmark.circle.fill" : "circle")
                }.disabled(model.busy)
            }
            Section {
                if model.busy { HStack { ProgressView(); Text("讀取目錄中…") } }
                else if filtered.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "這層沒有相簿項目" : "沒有符合的名稱", systemImage: "folder", description: Text("資料夾、照片與影片會顯示在這裡。"))
                } else {
                    ForEach(filtered) { entry in
                        HStack(spacing: 12) {
                            Button { model.toggle(entry) } label: {
                                Image(systemName: model.isIncluded(entry) ? "checkmark.circle.fill" : "circle").font(.title2).frame(width: 36, height: 44)
                            }.buttonStyle(.borderless).accessibilityLabel("勾選 " + entry.name)
                            Button {
                                if entry.kind == .folder {
                                    search = ""
                                    Task { await model.navigate(entry.path) }
                                } else { model.toggle(entry) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: entry.kind.symbol).font(.title2).foregroundStyle(.tint).frame(width: 32)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.name).foregroundStyle(.primary).lineLimit(2)
                                        Text(entry.kind.label + (entry.kind == .folder ? "" : " · " + ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if entry.kind == .folder { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            } header: { Text("\(filtered.count) 個項目") } footer: { Text("點資料夾名稱進入；勾選資料夾會遞迴包含子目錄。父子目錄重疊時，播放清單會自動去重。") }
        }
        .searchable(text: $search, prompt: "搜尋此層名稱")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 14) {
                Button { showSelections = true } label: {
                    VStack(alignment: .leading) { Text("\(model.selections.count) 個已選").font(.headline); Text("查看清單").font(.caption) }
                }
                Spacer()
                Button {
                    model.scan(filter: filter, random: random, favoritesOnly: favoritesOnly)
                } label: { Label("開始播放", systemImage: "play.fill").padding(.vertical, 7) }
                    .buttonStyle(.borderedProminent).disabled(model.selections.isEmpty || model.busy)
            }.padding().background(.regularMaterial)
        }
    }

    private var playbackSettings: some View {
        NavigationStack {
            Form {
                Picker("播放內容", selection: $filter) { ForEach(PlaybackFilter.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("隨機播放", isOn: $random)
                Picker("照片停留時間", selection: $interval) { ForEach([2.0, 3, 5, 10, 15, 30], id: \.self) { Text("\(Int($0)) 秒").tag($0) } }
                Toggle("只播勾選範圍內的收藏", isOn: $favoritesOnly)
                Text("照片保持比例，不裁切。影片播完再換下一個；不支援的格式會停下提示，可手動略過。").font(.footnote).foregroundStyle(.secondary)
                Text("開啟隨機時，每次開始建立新順序；同一輪清單循環播放時保留順序。").font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("播放設定").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } } }
        }
    }

    private var selectionList: some View {
        NavigationStack {
            List {
                if model.selections.isEmpty { Text("還沒有勾選項目").foregroundStyle(.secondary) }
                ForEach(model.selections.values.sorted { $0.path < $1.path }) { entry in
                    HStack {
                        Label(entry.path.isEmpty ? "分享根目錄" : entry.path, systemImage: entry.kind.symbol).font(.subheadline)
                        Spacer()
                        Button { model.removeSelection(entry.path) } label: { Image(systemName: "minus.circle").foregroundStyle(.red).frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel("取消 " + entry.name)
                    }
                }
            }.navigationTitle("已選項目").toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("清空") { model.clearSelection() } }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { showSelections = false } }
            }
        }
    }

    private var scanProgress: some View {
        NavigationStack {
            List {
                Section {
                    if !model.scanFinished { ProgressView() }
                    Text(model.scanFinished ? "播放清單已整理" : "準備播放清單").font(.title2.bold())
                    Text(model.scanNote).font(.subheadline).foregroundStyle(.secondary)
                    Text("\(model.scanCount) 個媒體 · \(model.scanFolders) 個資料夾")
                    if !model.scanFinished { Text(model.scanPath).font(.caption).foregroundStyle(.secondary) }
                    if model.scanFinished && model.playlist.isEmpty { Text("沒有找到符合條件的照片或影片，請調整選取或播放設定。") }
                }
                if model.warningCount > 0 {
                    Section("\(model.warningCount) 個掃描提示（最多列出 20 筆）") {
                        ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, text in Text(text).font(.caption) }
                    }
                }
                if model.scanFinished && !model.playlist.isEmpty {
                    Button("播放 \(model.playlist.count) 個項目") { model.beginPlayback() }.font(.headline)
                }
                if model.scanFinished {
                    Button("重新掃描", systemImage: "arrow.clockwise") { model.scan(filter: filter, random: random, favoritesOnly: favoritesOnly, force: true) }
                }
            }.navigationTitle("準備播放").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(model.scanFinished ? "返回" : "取消掃描") { model.cancelScan() } }
            }
        }
    }
}
