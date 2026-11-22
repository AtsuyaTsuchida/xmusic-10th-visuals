import AVFoundation
import simd

/// 音源を読み込み、左右を足した波形(絵の元)を持つ
final class Track {
    let url: URL
    let file: AVAudioFile
    let sampleRate: Double
    let length: Int             // 音の点数(1チャンネルあたり)
    let S: Int                  // 1コマぶんの音の点数 = 横の波の点数(48kHz なら 1600)
    let frames: Int             // 曲のコマ数
    let mono: [Float]           // 左右を足した波形(後ろに余白つき)
    // コマごとの解析(動画モード用)。音は変えない、読むだけ
    let onset: [Float]          // 低音の立ち上がりの強さ(0..1)。キックの位置で大きくなる
    let kick: [Float]           // onset に余韻をつけたもの(0..1)。キックで跳ねて、すっと下がる
    let level: [Float]          // 音量(0..1)
    let firstKick: Double       // 最初のキックが入る時刻(秒)。見つからなければ曲の長さ
    let denseCum: [Float]       // キックの多さ(4打/秒で 1、上限 2)を頭から足し合わせたもの(秒)。多い区間ほど早く増える
    let levelSmooth: [Float]    // 音量をなだらかにしたもの(0..1)。手ブレの大きさに使う
    let lastHit: [Int32]        // そのコマ以前でいちばん近いキックのコマ番号(なければ -1)
    // ドラムが鳴る時刻の一覧(音源と同じ名前の .cues.json。tools/cues.py が Live セットから作る)。なければ空
    let cueKick: [(t: Double, v: Double)]   // キック: 時刻(秒)と強さ(0..1)
    let cueClap: [(t: Double, v: Double)]   // クラップ
    let cueHat: [(t: Double, v: Double)]    // 1分あたりから入る、オープンハイハットのような音
    let cueMetal: [(t: Double, v: Double)]  // 金物のついたハイハット
    let hasCues: Bool
    var duration: Double { Double(length) / sampleRate }
    /// 一発目のキックの時刻(秒)。時刻の一覧があればその最初のキック、なければ音から測った値
    var firstHit: Double { cueKick.first?.t ?? firstKick }

    /// コマごとの値を、コマの間もなめらかにつないで読む(カメラの動きを 30 コマ/秒より細かく出すため)
    func at(_ a: [Float], _ t: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let x = min(max(0, t * Double(FPS)), Double(a.count - 1))
        let i = Int(x), f = x - Double(i)
        return Double(a[i]) * (1 - f) + Double(a[min(i + 1, a.count - 1)]) * f
    }

    /// キックの跳ね(0..1 くらい)。鳴った瞬間に強さぶん跳ねて、decay 秒で 1/e に下がる。続けて鳴ると少し積み上がる。
    /// 時刻の一覧がない音源では、音から測った低音の立ち上がり(kick)を使う
    func kickPulse(_ t: Double, decay: Double) -> Double {
        guard hasCues else { return at(kick, t) }
        let d = max(0.01, decay)
        var lo = 0, hi = cueKick.count                     // t 以前の最後のキックを探す
        while lo < hi { let m = (lo + hi) / 2; if cueKick[m].t <= t { lo = m + 1 } else { hi = m } }
        var e = 0.0, i = lo - 1
        while i >= 0, t - cueKick[i].t < 6 * d { e += cueKick[i].v * exp(-(t - cueKick[i].t) / d); i -= 1 }
        return min(1.5, e)
    }

    /// 時刻 t に、ハイハット(Hihat Code)が鳴っている最中か。鳴り始めから len 秒のあいだを「鳴っている」とする
    /// 波形のあいだ、ハイハットが鳴っている最中の色の組(波形の色, 背景の色)。鳴るたびに次の組へ替わる。鳴っていなければ nil
    static let hatColors: [(fg: SIMD3<Float>, bg: SIMD3<Float>)] = [
        (SIMD3(1.00, 0.06, 0.04), SIMD3(0.00, 0.06, 0.85)),   // 赤 × 青(最初)
        (SIMD3(1.00, 0.92, 0.00), SIMD3(0.55, 0.00, 0.75)),   // 黄 × 紫
        (SIMD3(0.00, 0.95, 0.85), SIMD3(0.85, 0.05, 0.10)),   // 水色 × 赤
        (SIMD3(1.00, 1.00, 1.00), SIMD3(0.95, 0.30, 0.00)),   // 白 × オレンジ
        (SIMD3(1.00, 0.20, 0.70), SIMD3(0.00, 0.45, 0.25)),   // ピンク × 緑
        (SIMD3(0.05, 0.10, 1.00), SIMD3(1.00, 0.90, 0.00)),   // 青 × 黄
        (SIMD3(0.20, 1.00, 0.30), SIMD3(0.10, 0.05, 0.60)),   // 黄緑 × 紺
        (SIMD3(1.00, 0.55, 0.00), SIMD3(0.00, 0.50, 0.65)),   // オレンジ × 青緑
        (SIMD3(0.00, 0.10, 1.00), SIMD3(0.95, 0.95, 0.92)),   // 青 × 白
        (SIMD3(1.00, 1.00, 1.00), SIMD3(0.90, 0.00, 0.45)),   // 白 × マゼンタ
        (SIMD3(1.00, 0.06, 0.04), SIMD3(0.00, 0.00, 0.00)),   // 赤 × 黒
        (SIMD3(1.00, 0.10, 0.05), SIMD3(0.00, 0.90, 0.80))]   // 赤 × 水色
    func hatColor(_ t: Double, len: Double) -> (fg: SIMD3<Float>, bg: SIMD3<Float>)? {
        var lo = 0, hi = cueHat.count
        while lo < hi { let m = (lo + hi) / 2; if cueHat[m].t <= t { lo = m + 1 } else { hi = m } }
        guard lo > 0, t - cueHat[lo - 1].t < len else { return nil }
        return Track.hatColors[(lo - 1) % Track.hatColors.count]
    }

    func hatOn(_ t: Double, len: Double) -> Bool {
        var lo = 0, hi = cueHat.count
        while lo < hi { let m = (lo + hi) / 2; if cueHat[m].t <= t { lo = m + 1 } else { hi = m } }
        return lo > 0 && t - cueHat[lo - 1].t < len
    }

    /// コマ k(1/30秒)の間にクラップが鳴るなら、その強さ(0..1)。鳴らなければ 0
    func clapIn(frame k: Int) -> Double {
        let a = Double(k) / Double(FPS), b = Double(k + 1) / Double(FPS)
        var lo = 0, hi = cueClap.count
        while lo < hi { let m = (lo + hi) / 2; if cueClap[m].t < a { lo = m + 1 } else { hi = m } }
        var v = 0.0
        while lo < cueClap.count, cueClap[lo].t < b { v = max(v, cueClap[lo].v); lo += 1 }
        return v
    }

    init(url: URL) throws {
        self.url = url
        // 時刻の一覧: 曲.wav → 曲.cues.json
        var lanes: [String: [(t: Double, v: Double)]] = [:]
        let cueURL = url.deletingPathExtension().appendingPathExtension("cues.json")
        if let data = try? Data(contentsOf: cueURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ls = obj["lanes"] as? [String: Any] {
            for (name, raw) in ls {
                guard let rows = raw as? [[Double]] else { continue }
                lanes[name] = rows.filter { $0.count >= 2 }.map { (t: $0[0], v: $0[1]) }.sorted { $0.t < $1.t }
            }
        }
        cueKick = lanes["kick"] ?? []; cueClap = lanes["clap"] ?? []; cueHat = lanes["hat"] ?? []; cueMetal = lanes["metal"] ?? []
        hasCues = !lanes.isEmpty
        file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        sampleRate = fmt.sampleRate
        length = Int(file.length)
        S = Int((sampleRate / Double(FPS)).rounded())
        frames = Int((Double(length) / Double(S)).rounded(.up))
        guard length > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(length)) else {
            throw NSError(domain: "WaveMesh", code: 1, userInfo: [NSLocalizedDescriptionKey: "音源が空です"])
        }
        try file.read(into: buf)
        var m = [Float](repeating: 0, count: (frames + 1) * S + ROWS * YMAX)
        let n = Int(buf.frameLength), ch = Int(fmt.channelCount)
        guard let data = buf.floatChannelData else {
            throw NSError(domain: "WaveMesh", code: 2, userInfo: [NSLocalizedDescriptionKey: "音源を読めません"])
        }
        let L = data[0], R = data[ch > 1 ? 1 : 0]
        for i in 0..<n { m[i] = 0.5 * (L[i] + R[i]) }
        mono = m
        file.framePosition = 0

        // 低音(250Hz より下。キックの胴鳴りまで入る)と全体の音量を、コマ(1/30秒)ごとに測る
        let nf = frames, step = S
        var low = [Float](repeating: 0, count: nf), lev = [Float](repeating: 0, count: nf)
        let a = Float(exp(-2 * Double.pi * 250 / sampleRate))
        var y1: Float = 0, y2: Float = 0
        m.withUnsafeBufferPointer { p in
            for k in 0..<nf {
                var sl: Float = 0, sa: Float = 0
                let base = k * step
                for i in 0..<step {
                    let x = p[base + i]
                    y1 = (1 - a) * x + a * y1; y2 = (1 - a) * y1 + a * y2      // なだらかなローパスを2回
                    sl += y2 * y2; sa += x * x
                }
                low[k] = (sl / Float(step)).squareRoot(); lev[k] = (sa / Float(step)).squareRoot()
            }
        }
        // 立ち上がり = 低音が直前に比べて何倍に跳ねたか(ドローンのゆっくりしたうねりは小さく、キックは大きく出る)。
        // 上位2%の大きさを 1 とする
        func top(_ v: [Float], _ q: Double) -> Float {
            let s = v.filter { $0 > 0 }.sorted()
            return s.isEmpty ? 1 : max(1e-6, s[min(s.count - 1, Int(Double(s.count) * q))])
        }
        let floorLow = 0.2 * top(low, 0.98)
        var on = [Float](repeating: 0, count: nf)
        for k in 2..<max(2, nf) {
            let m = max(low[k - 1], low[k - 2])
            on[k] = max(0, low[k] - m) / (m + floorLow)
        }
        let oref = top(on, 0.98), lref = top(lev, 0.98)
        var kk = [Float](repeating: 0, count: nf)
        var e: Float = 0
        for k in 0..<nf {
            on[k] = min(1, on[k] / oref)
            e = max(on[k], e * 0.78)                // 余韻: 5コマ(約0.17秒)で 3 割に
            kk[k] = e
            lev[k] = min(1, lev[k] / lref)
        }
        onset = on; kick = kk; level = lev
        // 最初のキック: 強い立ち上がりで、そのあと8秒以内にあと2回以上続く最初のもの。
        // ドローンの中の単発の粒(低い物音)は続かないので拾わない
        var fk = Double(length) / sampleRate
        let hits = (2..<max(2, nf)).filter { on[$0] > 0.65 && on[$0] >= on[$0 - 1] && ($0 + 1 >= nf || on[$0] > on[$0 + 1]) }
        for (i, k) in hits.enumerated() where hits[(i + 1)...].prefix(while: { $0 - k <= 8 * FPS }).count >= 2 {
            fk = Double(on[k - 1] > 0.3 * on[k] ? k - 1 : k) / Double(FPS); break      // 立ち上がりが2コマにまたがるときは前のコマ
        }
        firstKick = fk
        var dc = [Float](repeating: 0, count: nf), ls = [Float](repeating: 0, count: nf), lh = [Int32](repeating: -1, count: nf)
        var isHit = [Bool](repeating: false, count: nf)
        for k in 2..<max(2, nf) where on[k] > 0.35 && on[k] >= on[k - 1] && (k + 1 >= nf || on[k] > on[k + 1]) { isHit[k] = true }
        var inWin = 0, acc: Float = 0, sm: Float = 0, last: Int32 = -1
        let win = 2 * FPS
        for k in 0..<nf {
            if isHit[k] { inWin += 1; last = Int32(k) }
            if k >= win, isHit[k - win] { inWin -= 1 }
            acc += min(2, Float(inWin) / 2 / 4) / Float(FPS)       // 直近2秒の打数 → 1秒あたり → 4打/秒で 1
            dc[k] = acc
            sm += (lev[k] - sm) * 0.08                              // 約 0.4 秒でならす
            ls[k] = sm
            lh[k] = last
        }
        denseCum = dc; levelSmooth = ls; lastHit = lh
    }
}

/// 再生と、いま鳴っている位置(秒)
final class Player {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var track: Track?
    private var startFrame = 0
    private var attached = false
    private(set) var playing = false
    var pos = 0.0               // 止まっているときの位置(秒)
    var muted = false { didSet { engine.mainMixerNode.outputVolume = muted ? 0 : 1 } }
    var duration: Double { track?.duration ?? 0 }

    func load(_ t: Track) {
        node.stop(); playing = false; pos = 0
        if attached { engine.disconnectNodeOutput(node) } else { engine.attach(node); attached = true }
        engine.connect(node, to: engine.mainMixerNode, format: t.file.processingFormat)
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
        track = t
    }

    func play(from sec: Double) {
        guard let t = track else { return }
        node.stop()
        pos = min(max(0, sec), t.duration - 0.01)
        startFrame = Int(pos * t.sampleRate)
        let count = t.length - startFrame
        guard count > 0 else { return }
        node.scheduleSegment(t.file, startingFrame: AVAudioFramePosition(startFrame),
                             frameCount: AVAudioFrameCount(count), at: nil, completionHandler: nil)
        if !engine.isRunning {
            do { try engine.start() } catch { NSLog("音を出せません: \(error)"); return }
        }
        node.play()
        playing = true
    }

    func stop() {
        if playing { pos = now() }
        node.stop()
        playing = false
    }

    func toggle() { if playing { stop() } else { play(from: pos) } }

    func seek(to sec: Double) {
        let v = min(max(0, sec), max(0, duration - 0.01))
        if playing { play(from: v) } else { pos = v }
    }

    /// いま耳に届いている位置(秒)。出力の遅れを引いてある
    func now() -> Double {
        guard playing, let t = track else { return pos }
        guard let nt = node.lastRenderTime, nt.isSampleTimeValid, nt.isHostTimeValid,
              let pt = node.playerTime(forNodeTime: nt) else { return pos }
        let dt = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: nt.hostTime)
        let latency = engine.outputNode.presentationLatency
        let sec = (Double(startFrame) + Double(pt.sampleTime)) / t.sampleRate + dt - latency
        if sec >= t.duration {          // 終わったら頭に戻して止める
            node.stop(); playing = false; pos = 0
            return 0
        }
        return max(Double(startFrame) / t.sampleRate, sec)
    }
}
