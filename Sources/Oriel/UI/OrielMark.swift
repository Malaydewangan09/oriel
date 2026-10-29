import SwiftUI

// Oriel's bird, the same outline the website uses. Drawn from its SVG path so the app, the site and the film match.
struct OrielMark: Shape {
    private static let svg =
        "M20.6 6.2c-.9-.2-1.7.2-2.2.9l-1.1-.6c.3-1.5-.4-3-1.8-3.6-.4 1.2-.3 2.4.3 3.4L8.5 9.8C6.3 7.9 4 7.2 2 7.6c1.3 2.5 3.4 4.1 5.8 4.6l-.7.6c-1.6 1.4-2.1 3.6-1.3 5.6.4 1 1.1 1.9 2 2.5l1-2.3c1.7.3 3.4-.2 4.6-1.4l3.1-3.1c1.3-1.3 2-3 2-4.8l.9-.5 2.1.4-.9-2.8z"

    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 24
        let dx = rect.minX + (rect.width - 24 * k) / 2, dy = rect.minY + (rect.height - 24 * k) / 2
        let p = Self.parse(Self.svg)
        return p.applying(CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: dx, ty: dy))
    }

    // Handles the commands this path uses: M, L, C, l, c, z.
    private static func parse(_ d: String) -> Path {
        var path = Path()
        var nums: [CGFloat] = [], cmd: Character = "M", cur = CGPoint.zero, start = CGPoint.zero
        var token = ""
        func flushNumber() { if let v = Double(token) { nums.append(CGFloat(v)) }; token = "" }
        func run() {
            let rel = cmd.isLowercase
            switch cmd.uppercased() {
            case "M", "L":
                var i = 0
                while i + 1 < nums.count {
                    let p = CGPoint(x: nums[i] + (rel ? cur.x : 0), y: nums[i + 1] + (rel ? cur.y : 0))
                    if cmd.uppercased() == "M" && i == 0 { path.move(to: p); start = p } else { path.addLine(to: p) }
                    cur = p; i += 2
                }
            case "C":
                var i = 0
                while i + 5 < nums.count {
                    let o = rel ? cur : .zero
                    let c1 = CGPoint(x: nums[i] + o.x, y: nums[i + 1] + o.y), c2 = CGPoint(x: nums[i + 2] + o.x, y: nums[i + 3] + o.y)
                    let p = CGPoint(x: nums[i + 4] + o.x, y: nums[i + 5] + o.y)
                    path.addCurve(to: p, control1: c1, control2: c2)
                    cur = p; i += 6
                }
            case "Z":
                path.closeSubpath(); cur = start
            default: break
            }
            nums = []
        }
        for ch in d {
            if ch.isLetter { flushNumber(); run(); cmd = ch; continue }
            if ch == "-" { flushNumber(); token = "-"; continue }
            if ch == " " || ch == "," { flushNumber(); continue }
            if ch == ".", token.contains(".") { flushNumber() }
            token.append(ch)
        }
        flushNumber(); run()
        return path
    }
}
