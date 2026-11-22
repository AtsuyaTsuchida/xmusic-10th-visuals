import AVFoundation
import CoreVideo
import Metal
import MetalKit

// 動画モードの素材。選んだ動画ファイルを、音のキックに合わせて切り替えながら再生する。
// どの時刻にどの動画のどこを出すかは、音の解析と値だけで決まる(毎回同じ)。
//   切り替え位置 = 低音の立ち上がり(キック)。ただし最短間隔より短くは切り替えず、最長間隔たったらキックなしでも切り替える
//   動画と開始位置 = 切り替えの番号から決まる乱数(同じ動画は続けて選ばない)

/// 1回の切り替えから次の切り替えまで
struct Cut {
    var t0: Double, t1: Double      // 曲の中の区間(秒)
    var clip: Int                   // 動画の番号
    var offset: Double              // 動画の中の開始位置(秒)
}

/// 再生機。2台を交互に使い、次の切り替えのぶんを先に頭出ししておく
private final class Deck {
    let player = AVPlayer()
    var output: AVPlayerItemVideoOutput?
    var cut = -1
    var ready = false, seeking = false
    var texture: MTLTexture?
    var holder: CVMetalTexture?
    init() {
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
    }
}

final class VideoSource {
    struct Clip { let url: URL; let asset: AVURLAsset; let duration: Double; let aspect: Double }
    let device: MTLDevice
    private(set) var clips: [Clip] = []
    private(set) var note = ""                  // 画面に出す説明(いま何番目の切り替えで、どの動画か)
    // 確認用の数: 切り替えた回数、切り替え後の絵がまだ届かず前の絵を出したコマ数、その最長の連続
    private(set) var switches = 0, lateFrames = 0, worstLate = 0
    private var lastIndex = -1, lateRun = 0
    private var cache: CVMetalTextureCache?
    private let decks = (0..<8).map { _ in Deck() }     // 再生機 8 台。いまのカットと、その先 6 カットぶんを先に頭出ししておく
    private var planKey = "", cuts: [Cut] = []
    private var shown: MTLTexture?, shownHolder: CVMetalTexture?, shownAspect = 16.0 / 9.0
    private let black: MTLTexture
    private var generators: [Int: AVAssetImageGenerator] = [:]
    private lazy var loader = MTKTextureLoader(device: device)

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        black = device.makeTexture(descriptor: d)!
        var px: [UInt8] = [0, 0, 0, 255]
        black.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
    }

    /// ファイルとフォルダの一覧から動画を集める(フォルダは直下の動画ファイル)
    static func expand(_ urls: [URL]) -> [URL] {
        let exts: Set<String> = ["mp4", "mov", "m4v"]
        var out: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
                out += items.filter { exts.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else if exts.contains(u.pathExtension.lowercased()) {
                out.append(u)
            }
        }
        return out
    }

    func load(_ urls: [URL]) {
        for d in decks { d.player.replaceCurrentItem(with: nil); d.cut = -1; d.ready = false; d.seeking = false; d.texture = nil; d.output = nil }
        shown = nil; generators = [:]; planKey = ""
        clips = VideoSource.expand(urls).compactMap { u in
            let asset = AVURLAsset(url: u)
            guard let tr = asset.tracks(withMediaType: .video).first else { return nil }
            let dur = asset.duration.seconds
            let size = tr.naturalSize.applying(tr.preferredTransform)
            guard dur.isFinite, dur > 0.2, size.width != 0, size.height != 0 else { return nil }
            return Clip(url: u, asset: asset, duration: dur, aspect: Double(abs(size.width) / abs(size.height)))
        }
    }

    // ---------- どの時刻に何を出すか ----------
    private func rnd(_ i: Int, _ salt: UInt64) -> Double {         // 番号から決まる 0..1 の乱数
        var z = UInt64(truncatingIfNeeded: i) &* 0x9E3779B97F4A7C15 &+ salt
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// 前もって 1 本に組んだ動画を、この時刻から頭から流すだけにする(通しの終盤)。場所を選ぶことも、途中で頭出しすることもない
    var linearFrom: Double? = nil

    /// 切り替える時刻を外から決めるとき(通しの終盤: キックの時刻そのもの)。nil なら音から測った立ち上がりで決める
    var cueTimes: [Double]? = nil
    private(set) var reused = 0     // 重ならない場所が見つからず、使った所をもう一度出すことになった回数(確認用)

    func plan(track: Track, params p: Params) -> [Cut] {
        let key = "\(ObjectIdentifier(track).hashValue):\(clips.count):\(p.vMin):\(p.vMax):\(p.vSpeed):\(cueTimes?.count ?? -1):\(cueTimes?.first ?? 0):\(linearFrom ?? -1)"
        if key == planKey { return cuts }
        planKey = key; cuts = []
        guard !clips.isEmpty else { return cuts }
        if let f0 = linearFrom {
            cuts = [Cut(t0: 0, t1: f0, clip: 0, offset: 0), Cut(t0: f0, t1: track.duration, clip: 0, offset: 0)]
            return cuts
        }
        let fps = Double(FPS)
        let minF = max(1, Int((p.vMin * fps).rounded())), maxF = max(minF, Int((p.vMax * fps).rounded()))
        var times = [0.0], last = 0
        let on = track.onset
        if let ct = cueTimes {
            // キックが鳴るコマの頭で切り替える(1 コマより詰まったものはまとめる)
            for t in ct { let f = floor(t * fps) / fps; if f > times[times.count - 1] + 0.5 / fps { times.append(f) } }
        } else {
            for k in 1..<max(1, track.frames) {
                let peak = on[k] > 0.35 && on[k] >= on[k - 1] && (k + 1 >= track.frames || on[k] > on[k + 1])
                if (peak && k - last >= minF) || k - last >= maxF { times.append(Double(k) / fps); last = k }
            }
        }
        var prev = -1
        var used: [Int: [(Double, Double)]] = [:]
        reused = 0
        for (i, t0) in times.enumerated() {
            let t1 = i + 1 < times.count ? times[i + 1] : track.duration
            var c = Int(rnd(i, 1) * Double(clips.count)) % clips.count
            if c == prev && clips.count > 1 { c = (c + 1 + Int(rnd(i, 2) * Double(clips.count - 1))) % clips.count }
            prev = c
            let need = (t1 - t0) * p.vSpeed
            var room = max(0, clips[c].duration - need - 0.3)   // 区間の途中で動画の終わりに届かない範囲から選ぶ
            var off = rnd(i, 3) * room
            if cueTimes != nil, i > 0 {
                // 一度出した所は二度と出さない: これまでに使った区間と重ならない場所が見つかるまで、素材と場所を選び直す
                func free(_ c: Int, _ o: Double) -> Bool { !(used[c] ?? []).contains { o < $0.1 && o + need > $0.0 } }
                var tries = 0
                while !free(c, off), tries < 400 {
                    tries += 1
                    c = Int(rnd(i * 1000 + tries, 4) * Double(clips.count)) % clips.count
                    if c == prev && clips.count > 1 { c = (c + 1) % clips.count }
                    room = max(0, clips[c].duration - need - 0.3)
                    off = rnd(i * 1000 + tries, 5) * room
                }
                if !free(c, off) { reused += 1 }
                used[c, default: []].append((off, off + need))
                prev = c
            }
            cuts.append(Cut(t0: t0, t1: t1, clip: c, offset: off))
        }
        return cuts
    }

    private func locate(_ t: Double, track: Track, params p: Params) -> (Int, Cut, Double)? {
        let cs = plan(track: track, params: p)
        guard !cs.isEmpty else { return nil }
        var lo = 0, hi = cs.count - 1
        while lo < hi { let m = (lo + hi + 1) / 2; if cs[m].t0 <= t { lo = m } else { hi = m - 1 } }
        let cut = cs[lo]
        let dur = max(0.1, clips[cut.clip].duration - 0.1)
        let tau = linearFrom != nil ? min(dur, max(0, t - cut.t0))
                                    : (cut.offset + max(0, t - cut.t0) * p.vSpeed).truncatingRemainder(dividingBy: dur)
        note = "切り替え \(lo + 1)/\(cs.count)  " + clips[cut.clip].url.deletingPathExtension().lastPathComponent.prefix(24)
        if cueTimes != nil { note += "  くり返し \(reused)  遅れ \(lateFrames)コマ" }
        if linearFrom != nil { note = String(format: "終盤の動画 %.2f 秒", tau) }
        return (lo, cut, tau)
    }

    // ---------- 再生しながら使うとき ----------
    private func assign(_ d: Deck, _ index: Int, _ cut: Cut, _ tau: Double) {
        d.cut = index; d.ready = false; d.seeking = true; d.texture = nil; d.holder = nil
        let item = AVPlayerItem(asset: clips[cut.clip].asset)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        item.add(out)
        d.output = out
        d.player.pause()
        d.player.replaceCurrentItem(with: item)
        d.player.seek(to: CMTime(seconds: tau, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak d] _ in
            DispatchQueue.main.async { if let d = d, d.cut == index { d.ready = true; d.seeking = false } }
        }
    }

    private func seek(_ d: Deck, _ tau: Double) {
        let index = d.cut
        d.seeking = true
        d.player.seek(to: CMTime(seconds: tau, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak d] _ in
            DispatchQueue.main.async { if let d = d, d.cut == index { d.seeking = false } }
        }
    }

    /// 時刻 t に出す絵(テクスチャ)と、その縦横比。まだ届いていなければ直前の絵を返す
    func frame(time t: Double, playing: Bool, track: Track, params p: Params) -> (MTLTexture, Double) {
        guard let (index, cut, tau) = locate(t, track: track, params: p) else { note = "動画が選ばれていません"; return (black, 16.0 / 9.0) }
        let nd = decks.count
        let cur = decks[index % nd]
        if cur.cut != index {
            assign(cur, index, cut, tau)
        } else if cur.ready && !cur.seeking {
            let ct = cur.player.currentTime().seconds
            if playing {
                let rate = linearFrom != nil ? 1.0 : p.vSpeed
                if abs(Double(cur.player.rate) - rate) > 0.01 { cur.player.playImmediately(atRate: Float(rate)) }
                if abs(ct - tau) > 0.15 { seek(cur, tau) }              // 音とずれたら合わせ直す
            } else {
                if cur.player.rate != 0 { cur.player.pause() }
                if abs(ct - tau) > 0.02 { seek(cur, tau) }
            }
        }
        // 次の切り替えのぶんを、もう1台で先に頭出ししておく(切り替えの瞬間に待たない)
        // 切り替えが細かい所(0.1 秒おきなど)では、1 つ先だけだと頭出しが間に合わず前の絵が残るので、2.5 秒先までの数カットぶんを用意する
        if playing, linearFrom == nil {
            var j = index + 1
            while j < cuts.count, j <= index + nd - 2, cuts[j].t0 - t < 2.5 {
                let d = decks[j % nd]
                if d.cut != j { assign(d, j, cuts[j], cuts[j].offset) }
                j += 1
            }
        }
        if index != lastIndex { lastIndex = index; switches += 1 }
        if cur.ready, let out = cur.output, let cache = cache {
            let it = out.itemTime(forHostTime: CACurrentMediaTime())
            if out.hasNewPixelBuffer(forItemTime: it), let pb = out.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: nil) {
                var cv: CVMetalTexture?
                CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &cv)
                if let cv = cv, let tx = CVMetalTextureGetTexture(cv) { cur.texture = tx; cur.holder = cv }
            }
            if let tx = cur.texture { shown = tx; shownHolder = cur.holder; shownAspect = clips[cut.clip].aspect }
        }
        if cur.texture == nil { lateFrames += 1; lateRun += 1; worstLate = max(worstLate, lateRun) } else { lateRun = 0 }
        return (shown ?? black, shownAspect)
    }

    // ---------- 1枚だけ取り出すとき(確認用の書き出し) ----------
    func still(time t: Double, track: Track, params p: Params) -> (MTLTexture, Double) {
        guard let (_, cut, tau) = locate(t, track: track, params: p) else { return (black, 16.0 / 9.0) }
        let gen: AVAssetImageGenerator
        if let g = generators[cut.clip] { gen = g } else {
            gen = AVAssetImageGenerator(asset: clips[cut.clip].asset)
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            gen.appliesPreferredTrackTransform = true
            generators[cut.clip] = gen
        }
        guard let img = try? gen.copyCGImage(at: CMTime(seconds: tau, preferredTimescale: 600), actualTime: nil),
              let tx = try? loader.newTexture(cgImage: img, options: [.SRGB: false]) else { return (black, 16.0 / 9.0) }
        return (tx, clips[cut.clip].aspect)
    }

    /// 切り替え位置の一覧(確認用)
    func describe(track: Track, params p: Params) -> String {
        let cs = plan(track: track, params: p)
        if cs.isEmpty { return "clips=\(clips.count) cuts=0" }
        let gaps = cs.map { $0.t1 - $0.t0 }
        func count(_ a: Double, _ b: Double) -> Int { cs.filter { $0.t0 >= a && $0.t0 < b }.count }
        print(String(format: "firstKick=%.3f", track.firstKick))
        if cueTimes != nil { print("reused=\(reused)") }
        return String(format: "clips=%d cuts=%d gap(min/median/max)=%.2f/%.2f/%.2f  0-77s:%d 77-154s:%d 154-205s:%d 205-275s:%d 275-300s:%d",
                      clips.count, cs.count, gaps.min() ?? 0, gaps.sorted()[gaps.count / 2], gaps.max() ?? 0,
                      count(0, 76.8), count(76.8, 153.6), count(153.6, 204.8), count(204.8, 275.2), count(275.2, 301))
    }
}
