import SwiftUI
import NocturnalCore

/// SwiftUI ports of [dotmatrix](https://github.com/zzzzshawn/matrix) **dotm-square-1…5**.
///
/// 5×5 LED-style loaders driven by pure math + `TimelineView` (no WebView, no Metal).
/// Opacity curves mirror the upstream CSS keyframes / stepped snake path.
///
/// License: upstream allows product use; these are reimplementations, not a republished
/// component library.
struct DotmSquareLoader: View {
    enum Style: Int, CaseIterable, Identifiable, Sendable {
        case square1 // diagonal alt sweep (TR→BL)
        case square2 // row-cycle snake with tail
        case square3 // spiral inward snake
        case square4 // dual ring snakes (outer CW, middle CCW)
        case square5 // diagonal boustrophedon snake

        var id: Int { rawValue }

        var accessibilityName: String {
            switch self {
            case .square1: return "Diagonal sweep"
            case .square2: return "Snake path"
            case .square3: return "Spiral"
            case .square4: return "Dual ring"
            case .square5: return "Diagonal snake"
            }
        }
    }

    var style: Style = .square2
    /// Outer box (width = height).
    var size: CGFloat = 24
    var dotSize: CGFloat = 3
    var color: Color = NocturnalPalette.fgPrimary
    /// 1 = ~1.5s cycle (matches upstream `--dmx-cycle`).
    var speed: Double = 1
    /// When false, freezes a uniform 50% opacity grid (static rest state).
    var animate: Bool = true
    /// Circular dots (upstream default) vs square pixels.
    var squareDots: Bool = false
    /// Per-dot opacity used when `animate` is false (default 50% opaque matrix).
    var staticOpacity: Double = 0.5

    var body: some View {
        let gap = max(0.5, (size - CGFloat(DotmSquareMath.matrix) * dotSize) / CGFloat(DotmSquareMath.matrix - 1))
        Group {
            if animate, speed > 0 {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    grid(at: context.date, gap: gap)
                }
            } else {
                grid(at: nil, gap: gap)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(style.accessibilityName)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private func grid(at date: Date?, gap: CGFloat) -> some View {
        let t = DotmSquareMath.phase(at: date, speed: speed)
        VStack(spacing: gap) {
            ForEach(0..<DotmSquareMath.matrix, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<DotmSquareMath.matrix, id: \.self) { col in
                        let index = DotmSquareMath.rowMajor(row, col)
                        let opacity = DotmSquareMath.opacity(
                            style: style,
                            index: index,
                            row: row,
                            col: col,
                            t: t,
                            animate: animate && date != nil,
                            staticOpacity: staticOpacity
                        )
                        RoundedRectangle(cornerRadius: squareDots ? 0.5 : dotSize / 2, style: .continuous)
                            .fill(color.opacity(opacity))
                            .frame(width: dotSize, height: dotSize)
                    }
                }
            }
        }
    }

    // MARK: - Style selection helpers

    /// Stable style from any string (session id) so concurrent agents show different patterns.
    static func style(forSeed seed: String) -> Style {
        let styles = Style.allCases
        let h = abs(seed.utf8.reduce(0) { ($0 &* 31) &+ Int($1) })
        return styles[h % styles.count]
    }

    /// Prefer a fixed pattern per agent family so the notch right-strip is readable at a glance.
    static func style(for source: AgentSource) -> Style {
        switch source {
        case .codex: return .square1
        case .claude: return .square2
        case .opencode: return .square3
        case .cursor: return .square4
        case .grokBuild: return .square5
        case .kimi, .agy, .unknown:
            return style(forSeed: source.rawValue)
        }
    }

    static func style(for activity: SessionActivity) -> Style {
        switch activity.kind {
        case .tool: return .square2
        case .turn: return .square3
        case .session: return .square1
        case .approval, .question: return .square4
        case .notification, .unknown: return .square5
        }
    }
}

// MARK: - Math (nonisolated)

/// Pure geometry / opacity for square-1…5. Kept out of the View type so static
/// tables are not MainActor-isolated under Swift 6.
private enum DotmSquareMath {
    static let matrix = 5
    static let cellCount = 25
    static let baseCycle: TimeInterval = 1.5
    static let opacityBase: Double = 0.16
    static let opacityMid: Double = 0.32
    static let opacityPeak: Double = 1.0

    static func rowMajor(_ row: Int, _ col: Int) -> Int { row * matrix + col }

    static func phase(at date: Date?, speed: Double) -> Double {
        guard let date else { return 0 }
        let safe = max(0.05, speed)
        let period = baseCycle / safe
        let seconds = date.timeIntervalSinceReferenceDate
        let p = seconds.truncatingRemainder(dividingBy: period) / period
        return p < 0 ? p + 1 : p
    }

    static func opacity(
        style: DotmSquareLoader.Style,
        index: Int,
        row: Int,
        col: Int,
        t: Double,
        animate: Bool,
        staticOpacity: Double = 0.5
    ) -> Double {
        // Static / idle: uniform 50% matrix (not the dim uneven rest frames from
        // animation keyframes, which read as muddy black on the notch).
        if !animate {
            return min(1, max(0, staticOpacity))
        }
        switch style {
        case .square1:
            return square1(index: index, row: row, col: col, t: t)
        case .square2:
            return square2(index: index, t: t)
        case .square3:
            return square3(index: index, t: t)
        case .square4:
            return square4(index: index, row: row, col: col, t: t)
        case .square5:
            return square5(index: index, t: t)
        }
    }

    private static func square1(index: Int, row: Int, col: Int, t: Double) -> Double {
        let path = trBlPathNorm(index)
        let parity = (row + (4 - col)) % 2
        let delay = path * 0.2 + Double(parity) * 0.5
        return sampleKeyframe(diagonalAltSweep, phase: fract(t - delay))
    }

    private static func square2(index: Int, t: Double) -> Double {
        let route = square2Route
        let n = route.count
        guard n > 0 else { return opacityBase }
        let head = Int(floor(t * Double(n))) % n
        var best = opacityBase
        for (step, cell) in route.enumerated() where cell == index {
            let distance = (head - step + n) % n
            if distance < snakeTail.count {
                best = max(best, snakeTail[distance])
            }
        }
        return best
    }

    private static func square3(index: Int, t: Double) -> Double {
        let order = spiralInwardOrder[index]
        let delay = Double(order) * 0.04
        return sampleKeyframe(spiralSnake, phase: fract(t - delay))
    }

    private static func square4(index: Int, row: Int, col: Int, t: Double) -> Double {
        if row == 2, col == 2 { return 0 }
        let outer = outerRingOrder[index]
        if outer >= 0 {
            let delay = Double(outer) * 0.0625
            return sampleKeyframe(ringSnake, phase: fract(t - delay))
        }
        let middle = middleRingOrder[index]
        if middle >= 0 {
            let delay = Double(middle) * 0.125
            return sampleKeyframe(ringSnake, phase: fract(t - delay))
        }
        return 0
    }

    private static func square5(index: Int, t: Double) -> Double {
        let order = diagonalSnakeOrder[index]
        let delay = Double(order) * 0.04
        return sampleKeyframe(diagonalSnake, phase: fract(t - delay))
    }

    private static func trBlPathNorm(_ index: Int) -> Double {
        let row = index / matrix
        let col = index % matrix
        return Double(row + (matrix - 1 - col)) / Double((matrix - 1) * 2)
    }

    private static let square2Route: [Int] = {
        var path: [Int] = []
        func push(_ r: Int, _ c: Int) { path.append(rowMajor(r, c)) }
        for row in (0...4).reversed() { push(row, 0) }
        push(0, 1); push(0, 2)
        for row in 1...4 { push(row, 2) }
        push(4, 1)
        for row in (0...3).reversed() { push(row, 1) }
        push(0, 2); push(0, 3)
        for row in 1...4 { push(row, 3) }
        push(4, 2)
        for row in (0...3).reversed() { push(row, 2) }
        push(0, 3); push(0, 4)
        for row in 1...4 { push(row, 4) }
        return path
    }()

    private static let snakeTail: [Double] = [1, 0.82, 0.68, 0.54, 0.42, 0.31, 0.22, 0.14]

    private static let spiralInwardOrder: [Int] = {
        var order = Array(repeating: 0, count: cellCount)
        var top = 0, bottom = matrix - 1, left = 0, right = matrix - 1
        var t = 0
        while top <= bottom && left <= right {
            for col in left...right {
                order[rowMajor(top, col)] = t; t += 1
            }
            if top + 1 <= bottom {
                for row in (top + 1)...bottom {
                    order[rowMajor(row, right)] = t; t += 1
                }
            }
            if top < bottom {
                for col in stride(from: right - 1, through: left, by: -1) {
                    order[rowMajor(bottom, col)] = t; t += 1
                }
            }
            if left < right {
                for row in stride(from: bottom - 1, through: top + 1, by: -1) {
                    order[rowMajor(row, left)] = t; t += 1
                }
            }
            top += 1; bottom -= 1; left += 1; right -= 1
        }
        return order
    }()

    private static let outerRingOrder: [Int] = {
        var order = Array(repeating: -1, count: cellCount)
        let coords: [(Int, Int)] = [
            (0, 0), (0, 1), (0, 2), (0, 3), (0, 4),
            (1, 4), (2, 4), (3, 4), (4, 4),
            (4, 3), (4, 2), (4, 1), (4, 0),
            (3, 0), (2, 0), (1, 0),
        ]
        for (t, pair) in coords.enumerated() {
            order[rowMajor(pair.0, pair.1)] = t
        }
        return order
    }()

    private static let middleRingOrder: [Int] = {
        var order = Array(repeating: -1, count: cellCount)
        let coords: [(Int, Int)] = [
            (1, 1), (2, 1), (3, 1), (3, 2), (3, 3), (2, 3), (1, 3), (1, 2),
        ]
        for (t, pair) in coords.enumerated() {
            order[rowMajor(pair.0, pair.1)] = t
        }
        return order
    }()

    private static let diagonalSnakeOrder: [Int] = {
        var order = Array(repeating: 0, count: cellCount)
        var t = 0
        for diagonal in 0...((matrix - 1) * 2) {
            let rowStart = max(0, diagonal - (matrix - 1))
            let rowEnd = min(matrix - 1, diagonal)
            if diagonal % 2 == 0 {
                for row in stride(from: rowEnd, through: rowStart, by: -1) {
                    order[rowMajor(row, diagonal - row)] = t; t += 1
                }
            } else {
                for row in rowStart...rowEnd {
                    order[rowMajor(row, diagonal - row)] = t; t += 1
                }
            }
        }
        return order
    }()

    private struct Stop {
        var at: Double
        var opacity: Double
    }

    private static let diagonalAltSweep: [Stop] = [
        Stop(at: 0, opacity: 0.5 * opacityBase),
        Stop(at: 0.14, opacity: opacityPeak),
        Stop(at: 0.30, opacity: 0.75 * opacityBase),
        Stop(at: 1, opacity: 0.5 * opacityBase),
    ]

    private static let spiralSnake: [Stop] = [
        Stop(at: 0, opacity: 0.5 * opacityBase),
        Stop(at: 0.08, opacity: opacityPeak),
        Stop(at: 0.16, opacity: 0.5 * opacityPeak + 0.4 * opacityMid + 0.1 * opacityBase),
        Stop(at: 0.24, opacity: 0.25 * opacityPeak + 0.45 * opacityMid + 0.3 * opacityBase),
        Stop(at: 0.32, opacity: 0.5 * opacityMid + 0.5 * opacityBase),
        Stop(at: 0.40, opacity: 0.75 * opacityBase),
        Stop(at: 1, opacity: 0.5 * opacityBase),
    ]

    private static let diagonalSnake: [Stop] = spiralSnake

    private static let ringSnake: [Stop] = [
        Stop(at: 0, opacity: 0.5 * opacityBase),
        Stop(at: 0.10, opacity: opacityPeak),
        Stop(at: 0.20, opacity: 0.45 * opacityPeak + 0.45 * opacityMid + 0.1 * opacityBase),
        Stop(at: 0.30, opacity: 0.2 * opacityPeak + 0.4 * opacityMid + 0.4 * opacityBase),
        Stop(at: 0.40, opacity: 0.875 * opacityBase),
        Stop(at: 1, opacity: 0.5 * opacityBase),
    ]

    private static func sampleKeyframe(_ stops: [Stop], phase: Double) -> Double {
        let p = fract(phase)
        guard let first = stops.first, let last = stops.last else { return opacityBase }
        if p <= first.at { return first.opacity }
        if p >= last.at { return last.opacity }
        for i in 0..<(stops.count - 1) {
            let a = stops[i]
            let b = stops[i + 1]
            if p >= a.at, p <= b.at {
                let span = max(1e-6, b.at - a.at)
                let u = (p - a.at) / span
                return a.opacity + (b.opacity - a.opacity) * u
            }
        }
        return last.opacity
    }

    private static func fract(_ x: Double) -> Double {
        let f = x - floor(x)
        return f < 0 ? f + 1 : f
    }
}
