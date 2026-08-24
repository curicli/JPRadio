import SwiftUI

/// FM 调频刻度尺：中央固定指针，刻度随选中频率左右滑动；也可直接拖动刻度尺调台。
///
/// 布局要点（曾经踩过的坑）：**不要**把一条比容器宽的刻度尺用 `.offset` + `.frame(alignment:)`
/// 平移——弹性 frame 不会报告比子视图更小的宽度，ZStack 于是把这条 988pt 的尺子整体居中，
/// 刻度就与中央指针差了一个恒定的 (988 - 屏宽)/2。现在改为**只画可见范围**：
/// 每个刻度的 x 都由「离中心频率多远」直接算出，与容器宽度无关，天然对齐指针。
struct FrequencyDialView: View {
    let stations: [Station]
    @Binding var selectedID: String?

    private let pointsPerMHz: CGFloat = 52
    private let height: CGFloat = 96

    /// 拖动中的临时偏移（手指右移 → 频率减小）。
    @State private var dragOffset: CGFloat = 0
    /// 实际驱动刻度尺的中心频率（选台时用弹簧动画过渡）。
    @State private var centerFrequency: Double = 80.0

    // MARK: - 可调范围：由当前拨盘上的电台决定，两端各留一点余量。
    //  这样拨盘不会滑进大片没有电台的空白区（也就是「刻度都能超出去」）。

    private var stationFrequencies: [Double] { stations.map(\.frequency).sorted() }

    private var lowerBound: Double {
        guard let first = stationFrequencies.first else { return Station.dialLowerBound }
        return max(first - 1.2, Station.dialLowerBound)
    }

    private var upperBound: Double {
        guard let last = stationFrequencies.last else { return Station.dialUpperBound }
        return min(last + 1.2, Station.dialUpperBound)
    }

    private var selectedFrequency: Double {
        // 找不到选中台时不要硬编码 80.0——那会让读数与指针下的刻度对不上。
        stations.first { $0.id == selectedID }?.frequency
            ?? stationFrequencies.first
            ?? Station.dialLowerBound
    }

    /// 拖动过程中跟手的频率（始终夹在可调范围内）。
    private var displayFrequency: Double {
        let delta = Double(dragOffset / pointsPerMHz)
        return clamp(centerFrequency - delta)
    }

    private func clamp(_ f: Double) -> Double { min(max(f, lowerBound), upperBound) }

    var body: some View {
        ZStack {
            DialRuler(centerFrequency: displayFrequency,
                      stationFrequencies: stationFrequencies,
                      pointsPerMHz: pointsPerMHz,
                      lowerBound: lowerBound,
                      upperBound: upperBound)
            needle
            readout
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { dragOffset = $0.translation.width }
                .onEnded { _ in
                    let target = displayFrequency
                    let nearest = stations.min {
                        abs($0.frequency - target) < abs($1.frequency - target)
                    }
                    dragOffset = 0
                    guard let nearest else { return }
                    // 同频台在刻度上重叠（不同城市复用同一频率在日本很常见）：拖到同一处时
                    // 依次轮换，否则同频的第二台永远只能靠滑卡片选到。
                    let cluster = stations.filter { abs($0.frequency - nearest.frequency) < 0.001 }
                    var pick = nearest
                    if cluster.count > 1, let current = selectedID,
                       let idx = cluster.firstIndex(where: { $0.id == current }) {
                        pick = cluster[(idx + 1) % cluster.count]
                    }
                    // 先把中心频率落到目标台，再改 selectedID，避免读数跳两次。
                    centerFrequency = pick.frequency
                    // 带动画地改 selectedID，上方卡片才会平滑滚到中间（与上下曲一致）。
                    if pick.id != selectedID {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            selectedID = pick.id
                        }
                    }
                }
        )
        .mask(fadeMask)
        // 选台（滑卡片 / 上下曲 / 切地区）时让刻度尺弹到新频率。
        .onChange(of: selectedID) { _, _ in
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                centerFrequency = clamp(selectedFrequency)
            }
        }
        .onChange(of: stations.map(\.id)) { _, _ in
            // 切地区后可调范围变了，立刻夹紧，别停在别的拨盘的位置上。
            centerFrequency = clamp(selectedFrequency)
        }
        .onAppear { centerFrequency = clamp(selectedFrequency) }
    }

    // MARK: - 中央指针

    private var needle: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(Color.brand)
                .frame(width: 14, height: 9)
            Rectangle()
                .fill(Color.brand)
                .frame(width: 2.5)
                .shadow(color: Color.brand.opacity(0.8), radius: 6)
        }
        .frame(height: height - 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 2)
        .allowsHitTesting(false)
    }

    /// 中央下方的实时频率读数（与指针下的刻度同源，必然一致）。
    private var readout: some View {
        Text(String(format: "%.1f", displayFrequency))
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.white.opacity(0.12), in: Capsule())
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
    }

    /// 左右淡出遮罩，让刻度尺两端柔和消失。
    private var fadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.88),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }
}

// MARK: - 刻度绘制

/// 只绘制当前可见的一段刻度。实现 `Animatable`，使 `centerFrequency`
/// 能被 SwiftUI 逐帧插值——Canvas 里的内容本身不参与隐式动画。
private struct DialRuler: View, Animatable {
    var centerFrequency: Double
    var stationFrequencies: [Double]
    var pointsPerMHz: CGFloat
    var lowerBound: Double
    var upperBound: Double

    var animatableData: Double {
        get { centerFrequency }
        set { centerFrequency = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let mid = size.width / 2
            /// 频率 → 屏幕 x。指针恒在 mid，故 centerFrequency 必然落在指针正下方。
            func x(_ mhz: Double) -> CGFloat {
                mid + CGFloat(mhz - centerFrequency) * pointsPerMHz
            }

            // 只遍历可见范围（各留 1MHz 余量），并夹在可调范围内。
            let span = Double(size.width / 2 / pointsPerMHz) + 1
            let from = max(centerFrequency - span, lowerBound)
            let to = min(centerFrequency + span, upperBound)

            // 以 0.1MHz 为步长；用整数计数避免浮点累加误差导致「整数刻度判不出来」。
            let firstTenth = Int((from * 10).rounded(.up))
            let lastTenth = Int((to * 10).rounded(.down))
            guard firstTenth <= lastTenth else { return }

            for tenth in firstTenth...lastTenth {
                let mhz = Double(tenth) / 10
                let px = x(mhz)
                let isInteger = tenth % 10 == 0
                let isHalf = tenth % 5 == 0

                let tickHeight: CGFloat = isInteger ? 30 : (isHalf ? 18 : 10)
                let opacity: Double = isInteger ? 0.9 : (isHalf ? 0.5 : 0.3)
                let lineWidth: CGFloat = isInteger ? 2 : 1

                var path = Path()
                path.move(to: CGPoint(x: px, y: 6))
                path.addLine(to: CGPoint(x: px, y: 6 + tickHeight))
                context.stroke(path, with: .color(.white.opacity(opacity)),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                if isInteger {
                    context.draw(
                        Text("\(tenth / 10)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.7)),
                        at: CGPoint(x: px, y: 6 + tickHeight + 12))
                }
            }

            // 电台标记：刻度数字下方的小圆点。
            for freq in stationFrequencies where freq >= from - 0.5 && freq <= to + 0.5 {
                let px = x(freq)
                context.fill(Path(ellipseIn: CGRect(x: px - 3.5, y: 60, width: 7, height: 7)),
                             with: .color(Color.brand))
            }
        }
    }
}

/// 指向下方的小三角（指针帽）。
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
