import Foundation

/// Palette matching for `color:` searches and smart rules. Hex targets use CIEDE2000; names use hue buckets.
public enum ColorMath {
    public struct Lab: Equatable, Sendable { public var l, a, b: Double }
    /// The bucket names the image classifier emits as color tags.
    public static let buckets = ["red","orange","yellow","green","teal","blue","purple","pink","black","white","gray"]
    static let aliases = ["grey":"gray","cyan":"teal","turquoise":"teal","aqua":"teal","violet":"purple","magenta":"pink",
                          "brown":"#8b5a2b","beige":"#e8dcc4","navy":"#1f2a5c","gold":"#d4af37","maroon":"#7b1e2b","olive":"#7a7a2e",
                          "cream":"#f6efdc","silver":"#c0c0c0","lime":"#9acd32","indigo":"#4b3c9a","coral":"#ff7f60","mint":"#a8e6c8"]
    public static let threshold = 15.0

    /// Lowercase `#rrggbb`, from `#rgb`, `#rrggbb` or the same without `#`.
    public static func hex(_ value: String) -> String? {
        var s = value.trimmingCharacters(in:.whitespaces).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 3 || s.count == 6, s.allSatisfy(\.isHexDigit) else { return nil }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        return "#" + s
    }
    /// The colours written in pasted text, in order and without repeats: `#rgb` or `#rrggbb` anywhere (a palette copied
    /// from a design tool), or a bare `rrggbb` when that is all the text is.
    public static func colors(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in:.whitespacesAndNewlines)
        if trimmed.count == 6, let bare = hex(trimmed) { return [bare] }
        guard let pattern = try? NSRegularExpression(pattern:"(?<![0-9A-Za-z&/])#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![0-9A-Za-z])") else { return [] }
        var seen = Set<String>()
        return pattern.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap { match in
            Range(match.range,in:text).flatMap { hex(String(text[$0])) }.flatMap { seen.insert($0).inserted ? $0 : nil }
        }
    }
    /// A query value as `#rrggbb` or a bucket name; nil when it isn't a color.
    /// The colours a word in a description names: a colour's name, or a feeling of colour ("warm", "dark").
    /// Unlike `target`, words that only happen to look like hex codes name nothing.
    public static func named(_ word: String) -> [String] {
        let w = word.lowercased()
        switch w {
        case "warm": return ["red","orange","yellow"]
        case "cool", "cold", "icy": return ["blue","teal"]
        case "dark", "night", "moody", "noir": return ["black"]
        case "pale", "bright", "airy": return ["white"]
        default: return buckets.contains(w) ? [w] : aliases[w].map { [$0] } ?? []
        }
    }
    public static func target(_ value: String) -> String? {
        let s = value.trimmingCharacters(in:.whitespaces).lowercased()
        if buckets.contains(s) { return s }
        if let alias = aliases[s] { return alias }
        return hex(s)
    }
    static func rgb(_ hex: Substring) -> (Double,Double,Double)? {
        var s = hex; if s.first == "#" { s = s.dropFirst() }
        guard s.count == 6, let v = UInt32(s, radix:16) else { return nil }
        return (Double(v >> 16 & 255)/255, Double(v >> 8 & 255)/255, Double(v & 255)/255)
    }
    public static func bucket(r: Double, g: Double, b: Double) -> String {
        let high = max(r,g,b), low = min(r,g,b), delta = high-low, saturation = high == 0 ? 0 : delta/high
        if high < 0.18 { return "black" }
        if saturation < 0.12 { return high > 0.87 ? "white" : "gray" }
        var hue = high == r ? (g-b)/delta : high == g ? 2+(b-r)/delta : 4+(r-g)/delta
        hue *= 60; if hue < 0 { hue += 360 }
        return hue < 15 || hue >= 345 ? "red" : hue < 45 ? "orange" : hue < 70 ? "yellow" : hue < 160 ? "green"
            : hue < 195 ? "teal" : hue < 255 ? "blue" : hue < 290 ? "purple" : "pink"
    }
    public static func lab(r: Double, g: Double, b: Double) -> Lab {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c/12.92 : pow((c+0.055)/1.055,2.4) }
        let (lr,lg,lb) = (linear(r),linear(g),linear(b))
        let x = (0.4124564*lr + 0.3575761*lg + 0.1804375*lb)/0.95047
        let y = 0.2126729*lr + 0.7151522*lg + 0.0721750*lb
        let z = (0.0193339*lr + 0.1191920*lg + 0.9503041*lb)/1.08883
        func f(_ t: Double) -> Double { t > 216.0/24389 ? cbrt(t) : (24389.0/27*t+16)/116 }
        return Lab(l:116*f(y)-16, a:500*(f(x)-f(y)), b:200*(f(y)-f(z)))
    }
    /// CIEDE2000 colour difference.
    public static func deltaE(_ x: Lab, _ y: Lab) -> Double {
        let rad = Double.pi/180, p7 = 6103515625.0
        let cBar = (hypot(x.a,x.b)+hypot(y.a,y.b))/2
        let g = 0.5*(1-sqrt(pow(cBar,7.0)/(pow(cBar,7.0)+p7)))
        let a1 = (1+g)*x.a, a2 = (1+g)*y.a
        let c1 = hypot(a1,x.b), c2 = hypot(a2,y.b)
        func hue(_ b: Double, _ a: Double) -> Double { if a == 0 && b == 0 { return 0 }; let h = atan2(b,a)/rad; return h < 0 ? h+360 : h }
        let h1 = hue(x.b,a1), h2 = hue(y.b,a2)
        var dh = 0.0
        if c1*c2 != 0 { dh = h2-h1; if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 } }
        let dL = y.l-x.l, dC = c2-c1, dH = 2*sqrt(c1*c2)*sin(dh/2*rad)
        let lBar = (x.l+y.l)/2, cBar2 = (c1+c2)/2
        var hBar = h1+h2
        if c1*c2 != 0 { hBar = abs(h1-h2) <= 180 ? (h1+h2)/2 : h1+h2 < 360 ? (h1+h2+360)/2 : (h1+h2-360)/2 }
        let t = 1-0.17*cos((hBar-30)*rad)+0.24*cos(2*hBar*rad)+0.32*cos((3*hBar+6)*rad)-0.20*cos((4*hBar-63)*rad)
        let theta = 30*exp(-pow((hBar-275)/25,2))
        let rc = 2*sqrt(pow(cBar2,7.0)/(pow(cBar2,7.0)+p7))
        let sl = 1+0.015*pow(lBar-50,2)/sqrt(20+pow(lBar-50,2)), sc = 1+0.045*cBar2, sh = 1+0.015*cBar2*t
        let rt = -sin(2*theta*rad)*rc
        return sqrt(pow(dL/sl,2)+pow(dC/sc,2)+pow(dH/sh,2)+rt*(dC/sc)*(dH/sh))
    }
    /// True when any colour in a space-separated `#rrggbb` palette is close to `target` (see `target(_:)`).
    /// How strongly a palette shows the target, lower first: palettes are stored largest colour first, so a match
    /// in first place means the picture is mostly that colour. Close shades of a hex colour beat far ones within a
    /// place. No match sorts last.
    public static func rank(palette: String, target: String) -> Double {
        let goal = target.hasPrefix("#") ? rgb(Substring(target)).map { lab(r:$0.0,g:$0.1,b:$0.2) } : nil
        for (place,hex) in palette.split(separator:" ").enumerated() {
            guard let c = rgb(hex) else { continue }
            if let goal {
                let distance = deltaE(goal,lab(r:c.0,g:c.1,b:c.2))
                if distance <= threshold { return Double(place) * 100 + distance }
            } else if bucket(r:c.0,g:c.1,b:c.2) == target { return Double(place) * 100 }
        }
        return 1_000_000
    }
    public static func matches(palette: String, target: String) -> Bool {
        if target.hasPrefix("#") {
            guard let t = rgb(Substring(target)) else { return false }
            let goal = lab(r:t.0,g:t.1,b:t.2)
            return palette.split(separator:" ").contains { hex in
                guard let c = rgb(hex) else { return false }
                return deltaE(goal,lab(r:c.0,g:c.1,b:c.2)) <= threshold
            }
        }
        return palette.split(separator:" ").contains { hex in
            guard let c = rgb(hex) else { return false }
            return bucket(r:c.0,g:c.1,b:c.2) == target
        }
    }
}
