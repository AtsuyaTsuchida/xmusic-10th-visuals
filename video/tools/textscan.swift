// 動画を一定間隔で見て、映っている文字を書き出す(読むだけ)。
// usage: textscan 動画 間隔秒 出力.jsonl
// 1行 = 1時刻。items の座標は画面に対する割合(左上が原点)。
import AVFoundation
import Foundation
import Vision

let args = CommandLine.arguments
guard args.count >= 4, let interval = Double(args[2]) else {
    FileHandle.standardError.write("usage: textscan video interval out.jsonl\n".data(using: .utf8)!)
    exit(2)
}
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
guard let track = try await asset.loadTracks(withMediaType: .video).first else { exit(1) }
let reader = try AVAssetReader(asset: asset)
let out = AVAssetReaderTrackOutput(
    track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
out.alwaysCopiesSampleData = false
reader.add(out)
reader.startReading()
FileManager.default.createFile(atPath: args[3], contents: nil)
let fh = FileHandle(forWritingAtPath: args[3])!
var next = 0.0
func r(_ v: CGFloat) -> Double { (Double(v) * 10000).rounded() / 10000 }
while let sb = out.copyNextSampleBuffer() {
    try autoreleasepool {
        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        if t + 1e-6 < next { return }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        next = (floor(t / interval) + 1) * interval
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["ja-JP", "en-US"]
        req.usesLanguageCorrection = false
        req.minimumTextHeight = 0.012
        try VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([req])
        var items: [[String: Any]] = []
        for o in req.results ?? [] {
            guard let c = o.topCandidates(1).first else { continue }
            let b = o.boundingBox
            items.append(["s": c.string, "c": Double(c.confidence), "x": r(b.minX), "y": r(1 - b.maxY),
                          "w": r(b.width), "h": r(b.height)])
        }
        let line = try JSONSerialization.data(withJSONObject: ["t": (t * 1000).rounded() / 1000, "items": items])
        fh.write(line)
        fh.write("\n".data(using: .utf8)!)
    }
}
if reader.status == .failed {
    FileHandle.standardError.write("reader failed: \(String(describing: reader.error))\n".data(using: .utf8)!)
    exit(1)
}
