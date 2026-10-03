#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// The PicShop mark, "Frame + Light": two opposing crop corners (editing) and
/// a small spectral orb (the Live orb, the AI) on the upper-right third. Paths
/// and a 3 × 3 MeshGradient, no blur, so it is crisp at 16 points and costs
/// nothing to draw. Monochrome draws the orb as a solid disc.
struct PSMark: View {
    var size: CGFloat = PSMetrics.lockupMark
    var monochrome = false

    var body: some View {
        let stroke = max(1.5, size * 0.1)
        ZStack(alignment: .topLeading) {
            PSMarkBracket(corner: .topLeading)
                .stroke(Color.psTextPrimary, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
            PSMarkBracket(corner: .bottomTrailing)
                .stroke(Color.psTextPrimary, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
            orb
                .frame(width: size * 0.38, height: size * 0.38)
                .offset(x: size * 0.47, y: size * 0.15)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var orb: some View {
        if monochrome {
            Circle().fill(Color.psTextPrimary)
        } else {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                PSTheme.intelligence[0], PSTheme.intelligence[1], PSTheme.intelligence[2],
                PSTheme.intelligence[1], PSTheme.intelligence[2], PSTheme.intelligence[3],
                PSTheme.intelligence[2], PSTheme.intelligence[3], PSTheme.intelligence[3],
            ], smoothsColors: true, colorSpace: .perceptual)
            .clipShape(Circle())
        }
    }
}

/// An L-shaped crop corner, its arms 42 % of the box, inset by half the
/// stroke so the round caps stay inside.
struct PSMarkBracket: Shape {
    enum Corner { case topLeading, bottomTrailing }
    let corner: Corner

    func path(in rect: CGRect) -> Path {
        let inset = rect.width * 0.05
        let box = rect.insetBy(dx: inset, dy: inset)
        let arm = rect.width * 0.42
        var path = Path()
        switch corner {
        case .topLeading:
            path.move(to: CGPoint(x: box.minX, y: box.minY + arm))
            path.addLine(to: CGPoint(x: box.minX, y: box.minY))
            path.addLine(to: CGPoint(x: box.minX + arm, y: box.minY))
        case .bottomTrailing:
            path.move(to: CGPoint(x: box.maxX, y: box.maxY - arm))
            path.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
            path.addLine(to: CGPoint(x: box.maxX - arm, y: box.maxY))
        }
        return path
    }
}

/// The lockup: the mark, an 8-point gap, then the wordmark in SF Pro Expanded
/// semibold, white at 95 %, tracking −0.4. 22-point mark, 28-point word on Home.
struct PSLockup: View {
    var markSize: CGFloat = PSMetrics.lockupMark
    var font: Font = PSFontRole.wordmark

    var body: some View {
        HStack(spacing: PSSpacing.small) {
            PSMark(size: markSize)
            Text(verbatim: "PicShop")
                .font(font)
                .tracking(PSFontRole.wordmarkTracking)
                .foregroundStyle(Color.psTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "PicShop"))
        .accessibilityAddTraits(.isHeader)
    }
}

#if DEBUG
#Preview("PSMark") {
    VStack(spacing: 24) {
        PSLockup()
        HStack(spacing: 20) {
            PSMark(size: 16)
            PSMark(size: 22)
            PSMark(size: 44)
            PSMark(size: 44, monochrome: true)
        }
    }
    .padding()
    .background(Color.psBase)
}
#endif
#endif
