import SwiftUI

/// A snare drum from the side, with crossed sticks: the drum track's icon, since SF
/// Symbols has no drum. Drawn in a 14-point square to sit with the other track icons.
struct SnareDrumShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 14
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }

        var path = Path()

        // The head, seen a little from above
        path.addEllipse(in: CGRect(origin: p(1, 5.2), size: CGSize(width: 12 * s, height: 3.4 * s)))

        // The shell's sides and its lower rim
        path.move(to: p(1, 6.9))
        path.addLine(to: p(1, 11.3))
        path.move(to: p(13, 6.9))
        path.addLine(to: p(13, 11.3))
        path.addArc(center: p(7, 11.3), radius: 6 * s, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false,
                    transform: CGAffineTransform(translationX: p(7, 11.3).x, y: p(7, 11.3).y)
                        .scaledBy(x: 1, y: 1.7 / 6)
                        .translatedBy(x: -p(7, 11.3).x, y: -p(7, 11.3).y))

        // Two lugs on the front
        path.move(to: p(4.5, 8.5))
        path.addLine(to: p(4.5, 12.4))
        path.move(to: p(9.5, 8.5))
        path.addLine(to: p(9.5, 12.4))

        // Crossed sticks resting on the head, one steep and one shallow, so they
        // don't read as a V
        path.move(to: p(4.2, 0.4))
        path.addLine(to: p(8.4, 5.3))
        path.move(to: p(13.2, 2.2))
        path.addLine(to: p(5.2, 5.3))

        return path
    }
}

struct SnareDrumIcon: View {
    var size: CGFloat = 14
    var body: some View {
        SnareDrumShape()
            .stroke(style: StrokeStyle(lineWidth: max(1, size / 12), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}
