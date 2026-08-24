import SwiftUI

// MARK: - 番組表（选节目 → 收听提醒 / 预约录制）

/// 某台某个放送日的节目单：高亮并自动滚动到正在直播的一档，每行右侧可直接
/// **设收听提醒**与**预约录制** —— 起止时间取节目表里的真实时刻，
/// 不必再去「自定义时间段」那边手调（那本来是给没有节目表的台留的后路）。
///
/// - 🔔 提醒：一条本地通知（可选提前 0/5/10/15/30 分钟）。通知不依赖 App 存活，
///   点一下会跳到该台并开播（见 `NotificationRouter`）。
/// - ⏺ 录制：radiko 播完后取 タイムフリー 存档；直连台没有存档，只能在 App 开着时实时录。
/// - 🔖 收藏：把这档节目记进收藏（按「台 + 节目名」记，见 `FavoriteProgram`），
///   下次从主界面顶部的收藏按钮点回来即可，不必再翻番組表找。星标留给「收藏电台」，
///   收藏节目用书签，两者不至于混。
///
/// `allowsStationSwitch` 打开时顶部多一个换台菜单：从录音库进来时没有「当前台」的语境，
/// 得先挑台才谈得上选节目。
struct ProgramSheet: View {
    @ObservedObject var reservations: ReservationStore
    @ObservedObject var reminders: ReminderStore
    @ObservedObject var favoritePrograms: FavoriteProgramStore
    /// 允许在表内换台（从录音库进入时用）。
    let allowsStationSwitch: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var stationID: String
    @State private var programs: [RadikoProgram] = []
    @State private var isLoading = true
    @State private var failed = false
    /// 失败的具体原因（显示在错误页上）。
    @State private var errorDetail: String?
    @State private var dayOffset = 0
    @State private var scrollTarget: String?
    /// 从主界面顶部的 ★ 收藏按钮进来时要定位到的节目名（经 init 传入）。`load()` 每载一天就
    /// 找一次：当天有这档就滚过去、清空；没有就往后翻一天接着找（收藏按周复播，一周内必命中）。
    @State private var pendingFavoriteTitle: String?
    /// 预约了直连台（无存档）时给出的「仅实时」提示。
    @State private var showLiveOnlyNote = false
    /// 直连台番組表的自查报告（真实响应原样呈现，可复制）。
    @State private var report: DiagnosticsReport?
    @State private var isDiagnosing = false

    init(station: Station, reservations: ReservationStore, reminders: ReminderStore,
         favoritePrograms: FavoriteProgramStore, allowsStationSwitch: Bool = false,
         initialFavoriteTitle: String? = nil) {
        self.reservations = reservations
        self.reminders = reminders
        self.favoritePrograms = favoritePrograms
        self.allowsStationSwitch = allowsStationSwitch
        _stationID = State(initialValue: station.id)
        // 从主界面 ★ 收藏菜单进来时带着要定位的节目名：首次 load 就往后翻着找它。
        _pendingFavoriteTitle = State(initialValue: initialFavoriteTitle)
    }

    /// 兜底同 `CustomReservationSheet`：静态字面量数组，必非空。
    private var station: Station { Station.station(id: stationID) ?? Station.kantoFM[0] }

    /// 可查看的放送日范围：radiko 前后各一周，直连台只有未来表。
    private var dayRange: ClosedRange<Int> { ProgramCatalog.dayRange(for: station) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if allowsStationSwitch { stationBar }
                dateBar
                content
            }
            .navigationTitle(station.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(T.close) { dismiss() }
                }
            }
        }
        // 换台与切日期都要重拉，两者拼成一个 id（省一个 .task，也保证换台时立刻刷新）。
        .task(id: "\(stationID)#\(dayOffset)") { await load() }
        .presentationDetents([.large, .medium])
        .sheet(item: $report) { DiagnosticsSheet(text: $0.text) }
        .alert(T.reserved, isPresented: $showLiveOnlyNote) {
            Button(T.close) { }
        } message: {
            Text(T.liveOnlyNote)
        }
    }

    // MARK: - 换台（地区 → 电台两级菜单）

    /// 摊平成一个列表不可用（ListenRadio 有上百个频道），所以按地区分层。
    private var stationBar: some View {
        Menu {
            ForEach(Station.regions) { region in
                Menu("\(region.name) · \(region.subtitle)") {
                    ForEach(region.stations) { s in
                        Button("\(s.name) · \(s.frequencyText)") { select(s) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                Text(station.name).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.secondary.opacity(0.15), in: Capsule())
        }
        .padding(.top, 8)
        .accessibilityLabel(T.changeStation)
    }

    /// 换台后把日期夹回新台允许的范围（直连台没有过去的表）。
    private func select(_ s: Station) {
        stationID = s.id
        let range = ProgramCatalog.dayRange(for: s)
        dayOffset = min(max(dayOffset, range.lowerBound), range.upperBound)
    }

    // MARK: - 日期切换条

    private var dateBar: some View {
        HStack {
            Button {
                if dayOffset > dayRange.lowerBound { dayOffset -= 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .disabled(dayOffset <= dayRange.lowerBound)

            Spacer()

            VStack(spacing: 1) {
                Text(RadikoProgramService.dayPrimaryLabel(dayOffset: dayOffset))
                    .font(.subheadline.weight(.semibold))
                Text(RadikoProgramService.daySecondaryLabel(dayOffset: dayOffset))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .animation(.easeInOut(duration: 0.2), value: dayOffset)

            Spacer()

            Button {
                if dayOffset < dayRange.upperBound { dayOffset += 1 }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .disabled(dayOffset >= dayRange.upperBound)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView(T.loading)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if failed {
            errorView
        } else if programs.isEmpty {
            Text(T.noProgram)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(programs) { program in
                        row(for: program)
                            .id(program.id)
                            .listRowBackground(program.isOnAir ? Color.brand.opacity(0.14) : Color.clear)
                    }
                } footer: {
                    // 只留时区说明。「选中节目自动套用起止时间」那句话去掉了：
                    // 行右侧的 🔔/⏺ 圆钮已经把用法说明白，写在底部只是占地方。
                    Text(T.jstNote)
                }
            }
            .listStyle(.plain)
            // 用 .task(id:) 而不是 .onChange(of:)：`list` 只有在 isLoading 变 false 之后才被创建，
            // 而 scrollTarget 早在那之前就由 load() 赋好值了 —— onChange 根本看不到那次变化，
            // 「自动定位到直播中的一档」因此从来没生效过。.task(id:) 在首次出现时就会跑一遍。
            .task(id: scrollTarget) { await scrollToTarget(proxy) }
        }
    }

    /// 定位到正在直播的一档。List 的行是懒加载的，一次 scrollTo 常常只能滚个大概，
    /// 故先无动画粗定位，再隔几帧做两次修正。
    private func scrollToTarget(_ proxy: ScrollViewProxy) async {
        guard let target = scrollTarget else { return }
        proxy.scrollTo(target, anchor: .center)
        for delay in [80_000_000, 250_000_000] as [UInt64] {
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    // MARK: - 节目行

    private func row(for program: RadikoProgram) -> some View {
        let reserved = reservations.isReserved(programID: program.id)
        return HStack(alignment: .top, spacing: 10) {
            Text(program.timeText)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(program.isOnAir ? Color.brand : .primary)
                .frame(width: 88, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if program.isOnAir {
                        Text(T.onAir)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.brand, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Text(program.title)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !program.performer.isEmpty {
                    Text(program.performer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 已排上通知的那一次播出把「提前多久」写出来 —— 只亮个星标的话，
                // 看不出这次到底会不会响、提前几分钟响。
                if let r = reminders.reminder(programID: program.id) {
                    Label(T.leadLabel(r.leadMinutes), systemImage: "bell.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                favoriteButton(for: program)
                reserveButton(for: program, reserved: reserved)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) { reserveAction(for: program, reserved: reserved) }
    }

    /// 🔖 收藏节目 —— 同时就是「每次播出前提醒我」。用书签而不是星标：星标已经是「收藏**电台**」
    /// 的标志（主界面拨盘上的「★ 收藏」区），两者摆在一起会分不清，收藏**节目**改用书签。
    ///
    /// 原先这里并排三颗圆钮（收藏 / 🔔 提醒 / ⏺ 录制），既挤又要用户想清楚两者的差别；
    /// 而「收藏了却不想被提醒」本来就不是谁想要的状态，于是合成一颗：
    /// 点一下收藏并给这档节目在表里的每一次未来播出排上通知，再点一下连通知一起撤掉。
    /// 长按可改提前时间。已经播完的节目照样能收藏（收藏的是节目本身，只是这一次排不了通知）。
    private func favoriteButton(for program: RadikoProgram) -> some View {
        let starred = favoritePrograms.isFavorite(program: program, station: station)
        return Button {
            toggleFavorite(program)
        } label: {
            icon(starred ? "bookmark.fill" : "bookmark", tint: starred ? .brand : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(starred ? T.unfavoriteProgram : T.favoriteProgram)
        .contextMenu { leadMenu(for: program, starred: starred) }
    }

    /// 长按 ★ 的菜单：改提前时间 / 取消收藏。没收藏时不给菜单（还没有可调的东西）。
    @ViewBuilder
    private func leadMenu(for program: RadikoProgram, starred: Bool) -> some View {
        if starred {
            let current = favoritePrograms.lead(stationID: station.id, title: program.title)
                ?? reminders.defaultLead
            Section(T.remindLead) {
                ForEach(ReminderStore.leadChoices, id: \.self) { m in
                    Button {
                        setLead(m, for: program)
                    } label: {
                        Label(T.leadLabel(m), systemImage: m == current ? "checkmark" : "bell")
                    }
                }
            }
            Button(role: .destructive) {
                toggleFavorite(program)
            } label: {
                Label(T.unfavoriteProgram, systemImage: "bookmark.slash")
            }
        }
    }

    /// 收藏 / 取消收藏，连提醒一起。
    private func toggleFavorite(_ program: RadikoProgram) {
        if favoritePrograms.toggle(program: program, station: station) {
            // 刚收藏：把当前这张表里这档节目的每一次未来播出都排上通知
            //（翻到别的日期时 `load()` 会再对齐一次）。
            reminders.syncFavorites(favoritePrograms, programs: programs, station: station)
        } else {
            reminders.removeAll(stationID: station.id, title: program.title)
        }
    }

    /// 改提前时间：记进收藏，已排的通知重排，顺手把还没排上的未来播出补齐。
    private func setLead(_ minutes: Int, for program: RadikoProgram) {
        favoritePrograms.setLead(minutes, stationID: station.id, title: program.title)
        reminders.updateLead(minutes, stationID: station.id, title: program.title)
        reminders.syncFavorites(favoritePrograms, programs: programs, station: station)
    }

    /// ⏺ 预约录制。直连台按下后弹「仅实时」说明（没有存档，播出时 App 关着就录不到）。
    @ViewBuilder
    private func reserveButton(for program: RadikoProgram, reserved: Bool) -> some View {
        if reserved {
            Button { cancelReservation(program) } label: { icon("record.circle.fill", tint: .red) }
                .buttonStyle(.plain)
                .accessibilityLabel(T.cancelReserve)
        } else if program.start != nil, program.end != nil {
            Button { reserve(program) } label: { icon("record.circle", tint: .secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel(T.reserve)
        } else {
            // 占位，保证同一列的 ★/🔔 不会因为这台没有起止时间而整排右移。
            icon("record.circle", tint: .clear)
        }
    }

    /// 一行右侧的圆钮统一尺寸。★ 与 ⏺ 两颗并排（🔔 已并进 ★），
    /// 所以宽度可以给到 38 —— 比原来三颗时的 34 好按，又不至于挤掉节目名。
    private func icon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 17))
            .foregroundStyle(tint)
            .frame(width: 38, height: 40)
            .contentShape(Rectangle())
    }

    /// 节目行右滑：与行内圆钮同一套动作（老习惯留着，两处都能用）。
    @ViewBuilder
    private func reserveAction(for program: RadikoProgram, reserved: Bool) -> some View {
        if reserved {
            Button(role: .destructive) { cancelReservation(program) } label: {
                Label(T.cancelReserve, systemImage: "xmark.circle")
            }
        } else if program.end != nil, program.start != nil {
            Button { reserve(program) } label: {
                Label(T.reserve, systemImage: "record.circle")
            }
            .tint(.red)
        }
    }

    private func reserve(_ program: RadikoProgram) {
        if reservations.add(program: program, station: station) {
            showLiveOnlyNote = true      // 直连台：无存档，只能尽力实时录
        }
    }

    private func cancelReservation(_ program: RadikoProgram) {
        guard let r = reservations.items.first(where: { $0.id == program.id }) else { return }
        reservations.remove(r)
    }

    // MARK: - 出错页

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(T.loadFailed)
                .foregroundStyle(.secondary)
            // 具体原因（HTTP 状态 / 响应片段 / 没对上的字段名）。
            // 只说一句「加载失败」的话，番組表取不到时根本无从下手查。
            if let errorDetail {
                Text(errorDetail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)
            }
            HStack(spacing: 12) {
                Button(T.retry) { Task { await load() } }
                    .buttonStyle(.bordered)
                // 直连台（ListenRadio）的番組表接口无从在沙箱里核实，
                // 这个按钮把真机上的真实响应原样抓下来，便于把字段名对上。
                if station.isDirect { diagnoseButton }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diagnoseButton: some View {
        Button {
            Task {
                isDiagnosing = true
                let text = await ListenRadioProgramService.diagnose(station: station)
                isDiagnosing = false
                report = DiagnosticsReport(text: text)
            }
        } label: {
            if isDiagnosing {
                ProgressView().controlSize(.small)
            } else {
                Text(T.diagnose)
            }
        }
        .buttonStyle(.bordered)
        .disabled(isDiagnosing)
    }

    // MARK: - 取数

    private func load() async {
        isLoading = true
        failed = false
        errorDetail = nil
        scrollTarget = nil
        do {
            let result = try await ProgramCatalog.fetch(station: station, dayOffset: dayOffset)
            programs = result
            // 每载一天就把这张表里被收藏的每一次未来播出对齐到提醒排程（提醒已并入收藏）。
            reminders.syncFavorites(favoritePrograms, programs: result, station: station)
            scrollTarget = resolveTarget(in: result)
        } catch {
            failed = true
            errorDetail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    /// 决定自动滚动到哪一行。从 ★ 收藏跳进来（`pendingFavoriteTitle` 有值）时优先找那一档：
    /// 当天命中就滚过去并清空；没命中就往后翻一天（会再触发一次 `load`）继续找，
    /// 翻到范围尽头仍没有才放弃，退回「正在直播」的默认定位。
    private func resolveTarget(in list: [RadikoProgram]) -> String? {
        guard let title = pendingFavoriteTitle else { return preferredTarget(in: list) }
        if let hit = list.first(where: { $0.title == title }) {
            pendingFavoriteTitle = nil
            return hit.id
        }
        if dayOffset < dayRange.upperBound {
            dayOffset += 1          // 触发 .task(id:) → 再 load 一天
            return nil
        }
        pendingFavoriteTitle = nil  // 一周内都没排到：放弃定位
        return preferredTarget(in: list)
    }

    /// 自动定位的目标行：优先「正在直播」；节目表有空档时退到最后一档已开始的节目
    /// （只在「今天」这一天做，其它日期让列表停在顶部）。
    private func preferredTarget(in list: [RadikoProgram]) -> String? {
        if let onAir = list.first(where: { $0.isOnAir }) { return onAir.id }
        guard dayOffset == 0 else { return nil }
        let now = Date()
        return list.last { ($0.start ?? .distantFuture) <= now }?.id
    }
}

/// 番組表自查报告（`.sheet(item:)` 需要 Identifiable，故包一层）。
struct DiagnosticsReport: Identifiable {
    let id = UUID()
    let text: String
}
/// 原样显示自查报告，可整篇复制 —— 字段名对不上时把这段贴出来即可定位。
struct DiagnosticsSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle(T.diagnose)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label(T.copy, systemImage: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(T.close) { dismiss() }
                }
            }
        }
    }
}
