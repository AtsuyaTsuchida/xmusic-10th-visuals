import Cocoa
import MetalKit

// WaveMesh — 音の波形を点のメッシュで描く(Swift + Metal)。
//   WaveMesh [--audio 音源] [--scale 倍率] [--set 名前=値 ...] [--play] [--mute] [--output] [--fullscreen]
//   WaveMesh --shot 秒:出力.png [--shot ...]    その時刻の絵を書き出して終わる(確認用)
//   --video 動画かフォルダ  動画モードの素材。--set mode=1 で動画モード
//   --set mode=2 で脳のシーン。--particles 個数 で粒子の数(既定 4194304)
// 音源を指定しなければ、アプリの中に入れてある audio.wav を使う。

struct Options {
    var audio: String?
    var scale: Int?
    var shots: [(Double, String)] = []
    var sets: [(String, Double)] = []
    var videos: [String] = []   // 動画モードの素材(ファイルかフォルダ。何度でも指定できる)
    var describe = false        // 切り替え位置のまとめを出して終わる(確認用)
    var play = false, mute = false, fullscreen = false
    var output = false          // 起動してすぐ外部ディスプレイに出す
    var quitAfter: Double?      // 確認用: この秒数たったら終了し、進み具合を標準出力に出す
    var start = 0.0             // 起動時の位置(秒)
    var exportFrames: Int?      // 頭からこのコマ数を、生の画素(RGBA)で標準出力へ流す(ffmpeg へ渡して動画にする)
    var warm = 0.0              // --shot の前に、この秒数だけ前から1コマずつ進めておく

    init(_ args: [String]) {
        var i = 1
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--audio": audio = next()
            case "--scale": scale = next().flatMap { Int($0) }
            case "--shot":
                if let v = next(), let c = v.firstIndex(of: ":"), let t = Double(v[..<c]) { shots.append((t, String(v[v.index(after: c)...]))) }
            case "--set":
                if let v = next(), let c = v.firstIndex(of: "="), let x = Double(v[v.index(after: c)...]) { sets.append((String(v[..<c]), x)) }
            case "--video": if let v = next() { videos.append(v) }
            case "--describe": describe = true
            case "--play": play = true
            case "--start": start = next().flatMap { Double($0) } ?? 0
            case "--warm": warm = next().flatMap { Double($0) } ?? 0
            case "--export-raw": exportFrames = next().flatMap { Int($0) }
            case "--particles": if let n = next().flatMap({ Int($0) }), n > 0 { BRAIN_PARTICLES = n }
            case "--mute": mute = true
            case "--fullscreen": fullscreen = true
            case "--output": output = true
            case "--quit-after": quitAfter = next().flatMap { Double($0) }
            default:
                if !args[i].hasPrefix("-") && audio == nil { audio = args[i] }
            }
            i += 1
        }
    }

    func apply(to p: Params) {
        for (k, v) in sets {
            if let info = PARAMS.first(where: { $0.key == k }) { p[keyPath: info.path] = v }
            else { FileHandle.standardError.write("知らない名前: \(k)\n".data(using: .utf8)!) }
        }
    }

    func audioURL() -> URL? {
        if let a = audio { return URL(fileURLWithPath: a) }
        return Bundle.main.url(forResource: "audio", withExtension: "wav")
    }
}

let options = Options(CommandLine.arguments)

if let n = options.exportFrames {                 // 動画への書き出し: 生の画素を標準出力へ。進み具合は標準エラーへ
    do {
        guard let device = MTLCreateSystemDefaultDevice() else { throw err("Metal が使えません") }
        guard let url = options.audioURL() else { throw err("音源がありません(--audio で指定)") }
        let params = Params(); options.apply(to: params)
        let r = try Renderer(device: device, track: try Track(url: url), params: params, scale: options.scale ?? 1, drawableFormat: .bgra8Unorm)
        let out = FileHandle.standardOutput
        let t0 = Date()
        try r.exportFrames(n, { p, len in out.write(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: p), count: len, deallocator: .none)) },
                           progress: { k in FileHandle.standardError.write(String(format: "frame %d / %d  (%.0f 秒経過)\n", k, n, Date().timeIntervalSince(t0)).data(using: .utf8)!) })
        exit(0)
    } catch {
        FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

if !options.shots.isEmpty || options.describe {   // 画面を出さずに絵だけ書き出す
    do {
        guard let device = MTLCreateSystemDefaultDevice() else { throw err("Metal が使えません") }
        guard let url = options.audioURL() else { throw err("音源がありません(--audio で指定)") }
        let params = Params(); options.apply(to: params)
        let r = try Renderer(device: device, track: try Track(url: url), params: params, scale: options.scale ?? 1, drawableFormat: .bgra8Unorm)
        if options.describe {
            print(r.track.hasCues ? "cues: kick=\(r.track.cueKick.count) clap=\(r.track.cueClap.count)" : "cues: なし(キックは音から測る。クラップの反転は出ない)")
        }
        if !options.videos.isEmpty {
            let v = VideoSource(device: device)
            v.load(options.videos.map { URL(fileURLWithPath: $0) })
            r.video = v
            print(v.describe(track: r.track, params: params))
        }
        for (t, path) in options.shots {
            let info = try r.shot(time: t, to: URL(fileURLWithPath: path), warm: options.warm)
            print(String(format: "shot t=%.3f k=%d grow=%.3f dolly=%.3f depth=%.3f shake=(%.1fpx, %.1fpx, %.2fdeg) bloom=%.3f flash=%.2f morph=%.3f note=%@ -> %@", t, info.k, info.g, info.dl,
                         info.depth, info.shake.x * Double(W), info.shake.y * Double(H), info.shake.z * 180 / .pi, info.bloom, info.flash, info.morph, info.note, path))
        }
        exit(0)
    } catch {
        FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate(options)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
