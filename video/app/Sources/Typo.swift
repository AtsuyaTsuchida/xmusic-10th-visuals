import Metal
import CoreText
import CoreGraphics
import Foundation
import ImageIO

// タイポグラフィのパート(通しの中ほど、クラップが抜けてキックだけになる区間)。
// 白い「Neuro Music Lab」を画面いっぱいに置いたまま、動かさない。書体も文字の色も変えない。
// キックが鳴るたびに、背景の色だけが変わる。
//
// 書体は Helvetica Neue Bold。候補 23 書体を実際に組んで見比べて選んだ(見比べの絵: video/out/typo_font_candidates.png):
//   - 色の面と白い文字だけの画面なので、線の太さがそろっていて、文字の中の空き(カウンター)が大きく、白い面として安定して見える書体がいい
//   - 背景が一瞬で変わっても文字の形が負けない太さが要る(Light や、線の細い Didot・Bodoni は、色の面の上で細い線が消える)
//   - 大文字と小文字が混ざる 3 語なので、小文字が大きく(x ハイトが高く)、語のかたまりが横一列にそろって見えるもの
//     (Futura は小文字が小さく N と M がとがっていて、1 行が凸凹に見える)
//   - 字間は少しだけ詰める(-0.02em)。大きく組むと、ふつうの字間ではすき間が目立つため
// 背景の色は、白い文字がはっきり読める濃い色だけにしている(黄色などの明るい色は使わない)。

final class Typo {
    static let font = "HelveticaNeue-Bold"
    static let tracking: CGFloat = -0.02
    static let text = "Neuro Music Lab"
    // 背景の色(最初は黒)。どれも白い文字とのコントラストが十分にある
    static let grounds: [(CGFloat, CGFloat, CGFloat)] = [
        (0, 0, 0), (0.93, 0.10, 0.04), (0.02, 0.14, 0.95), (0.0, 0.55, 0.30), (0.86, 0.04, 0.46), (0.40, 0.10, 0.85), (0.95, 0.36, 0.0), (0.0, 0.50, 0.62)]
    private let w: Int, h: Int
    private let tex: MTLTexture
    private var pixels: [UInt8]
    var scale = 0.7                      // ロゴの大きさ(1 = 画面の高さいっぱいに近い、最初の大きさ)
    private var lastScale = 0.0
    private var lastScene = Int.min, lastLogo = false, lastClear = false
    // アイコンの右に置く「NEUROMUSICLAB」の文字の形(もらった画像から抜き出したもの)。アプリの中の neuromusic_wordmark_mask.png
    private lazy var wordmark: CGImage? = {
        var u = Bundle.main.url(forResource: "neuromusic_wordmark_mask", withExtension: "png")
        if let e = ProcessInfo.processInfo.environment["WORDMARK_MASK"] { u = URL(fileURLWithPath: e) }
        guard let url = u, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }()
    // Neuro Music Lab のサイトのページアイコン(ヘッドホンをした横顔と波形)の形。白 = 絵。アプリの中の neuromusic_icon_mask.png
    private lazy var icon: CGImage? = {
        var u = Bundle.main.url(forResource: "neuromusic_icon_mask", withExtension: "png")
        if let e = ProcessInfo.processInfo.environment["ICON_MASK"] { u = URL(fileURLWithPath: e) }
        guard let url = u, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }()
    // ロゴの形(白 = ロゴ)。tools/logo_mask.py が元の画像から抜き出したもの。アプリの中の xmusic_logo_mask.png
    private lazy var logo: CGImage? = {
        var u = Bundle.main.url(forResource: "xmusic_logo_mask", withExtension: "png")
        if let e = ProcessInfo.processInfo.environment["LOGO_MASK"] { u = URL(fileURLWithPath: e) }
        guard let url = u, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }()
    private(set) var note = ""

    init?(device: MTLDevice, width: Int, height: Int) {
        w = width; h = height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        tex = t
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// scene 番目の場面(= 区間の中で何回目のキックか)の背景の色。最初は黒で、続けて同じ色にはしない
    static func ground(_ scene: Int, seed: UInt64 = 20261122) -> Int {
        if scene <= 0 { return 0 }
        var prev = 0
        var rng = SplitMix(s: seed)
        var cur = 0
        for _ in 1...scene {
            cur = Int(rng.next() * Double(grounds.count - 1))
            if cur >= prev { cur += 1 }             // 直前の色を飛ばして選ぶ
            prev = cur
        }
        return cur
    }

    /// logo = true なら、文字のかわりにロゴ(x-Music Laboratory)を白で置く。背景の替わり方は同じ(色の順番は別)
    /// clear = true なら、背景を塗らずに透明のままにする(うしろに別の絵を映すとき)
    func texture(scene: Int, logo useLogo: Bool = false, clear: Bool = false) -> MTLTexture {
        if scene == lastScene, useLogo == lastLogo, clear == lastClear, scale == lastScale { return tex }
        lastScene = scene; lastLogo = useLogo; lastClear = clear; lastScale = scale
        let W = CGFloat(w), H = CGFloat(h)
        let gi = useLogo ? Typo.ground(scene, seed: 4242) : Typo.ground(scene), g = Typo.grounds[gi]
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            if clear { ctx.clear(CGRect(x: 0, y: 0, width: W, height: H)) }
            else { ctx.setFillColor(red: g.0, green: g.1, blue: g.2, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H)) }
            // 前半は Neuro Music Lab のアイコン、後半は x-Music Laboratory のロゴ。どちらも白 1 色で、中央に置いて動かさない。
            // アイコンの形が読めなかったときだけ、下の文字(Helvetica Neue Bold)に戻る
            if let lg = useLogo ? logo : icon {
                // 上下に余白を取って、高さに合わせて中央に置く。形を型紙にして白で塗る
                let lh = H * (useLogo ? 0.72 : 0.86) * CGFloat(scale), lw = lh * CGFloat(lg.width) / CGFloat(lg.height)
                var rect = CGRect(x: (W - lw) / 2, y: (H - lh) / 2, width: lw, height: lh)
                if !useLogo, let wm = wordmark {
                    // アイコンの右横に「NEUROMUSICLAB」を置く。2 つをひとかたまりとして中央に置き、文字は上下の中央にそろえる
                    let ww = W * 0.56 * CGFloat(scale), wh = ww * CGFloat(wm.height) / CGFloat(wm.width), gap = W * 0.035 * CGFloat(scale)
                    let x0 = (W - (lw + gap + ww)) / 2
                    rect.origin.x = x0
                    let wr = CGRect(x: x0 + lw + gap, y: (H - wh) / 2, width: ww, height: wh)
                    ctx.saveGState()
                    ctx.clip(to: wr, mask: wm)
                    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(wr)
                    ctx.restoreGState()
                }
                ctx.saveGState()
                ctx.clip(to: rect, mask: lg)
                ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(rect)
                ctx.restoreGState()
                return
            }
            func line(_ size: CGFloat) -> CTLine {
                let a: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(Typo.font as CFString, size, nil),
                    NSAttributedString.Key(kCTKernAttributeName as String): Typo.tracking * size,
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
                return CTLineCreateWithAttributedString(NSAttributedString(string: Typo.text, attributes: a))
            }
            // 左右の余白を画面の幅の 4% ずつ取って、幅いっぱいに組む。上下は、大文字の高さの真ん中を画面の真ん中に合わせる
            let m = W * 0.04
            let ink = CTLineGetBoundsWithOptions(line(100), .useGlyphPathBounds)
            let size = 100 * (W - 2 * m) / ink.width
            let cap = CTFontGetCapHeight(CTFontCreateWithName(Typo.font as CFString, size, nil))
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.textPosition = CGPoint(x: m - ink.minX * size / 100, y: (H - cap) / 2)
            CTLineDraw(line(size), ctx)
        }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 4)
        note = (useLogo ? "ロゴ " : "アイコン ") + "背景 \(gi)"
        return tex
    }
}

/// 終盤に重ねる日付の文字。細い書体(Helvetica Neue UltraLight)で、画面の中央に 1 行。地は透明
final class DateStamp {
    static let from = (2016, 9, 1), to = (2026, 11, 22)        // 数え始めと数え終わり(10 年前の 9 月 1 日 → 2026/11/22)
    private let w: Int, h: Int
    private let tex: MTLTexture
    private var pixels: [UInt8]
    private(set) var text = ""
    private let cal = Calendar(identifier: .gregorian)
    private let start: Date, days: Int

    init?(device: MTLDevice, width: Int, height: Int) {
        w = width; h = height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d),
              let a = cal.date(from: DateComponents(year: DateStamp.from.0, month: DateStamp.from.1, day: DateStamp.from.2)),
              let b = cal.date(from: DateComponents(year: DateStamp.to.0, month: DateStamp.to.1, day: DateStamp.to.2)) else { return nil }
        tex = t; start = a
        days = cal.dateComponents([.day], from: a, to: b).day ?? 0
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// progress 0 = 数え始めの日、1 = 数え終わりの日
    func texture(progress x: Double) -> MTLTexture {
        let n = min(days, max(0, Int((x * Double(days)).rounded(.down)) + (x >= 1 ? 0 : 0)))
        let date = cal.date(byAdding: .day, value: x >= 1 ? days : n, to: start) ?? start
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let s = String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        if s == text { return tex }
        text = s
        let W = CGFloat(w), H = CGFloat(h)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
            let size = H * 0.24
            let font = CTFontCreateWithName("HelveticaNeue-UltraLight" as CFString, size, nil)
            // 数字が変わっても位置が動かないよう、1 字ずつ同じ幅のますに置く(数字は 0 の幅、/ はその半分強)
            func width(_ ch: String) -> CGFloat {
                let a: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
                return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: ch, attributes: a)), nil, nil, nil))
            }
            let dw = width("0") * 1.06, sw = width("/") * 1.5
            let total = s.reduce(CGFloat(0)) { $0 + ($1 == "/" ? sw : dw) }
            var x0 = (W - total) / 2
            let base = (H - CTFontGetCapHeight(font)) / 2
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            for ch in s {
                let str = String(ch), cell = ch == "/" ? sw : dw
                let a: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
                ctx.textPosition = CGPoint(x: x0 + (cell - width(str)) / 2, y: base)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: str, attributes: a)), ctx)
                x0 += cell
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 4)
        return tex
    }
}
