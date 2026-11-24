import Metal
import CoreText
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

/// シェーダーに渡す値(float4 単位で並べて、Swift と Metal で並びがずれないようにする)
struct Uniforms {
    var vp = matrix_identity_float4x4
    var a = SIMD4<Float>()      // aspect, amp, dz, ymix
    var b = SIMD4<Float>()      // turn, half, fade, fog
    var c = SIMD4<Float>()      // size, d0, d1, gain
    var d = SIMD4<Float>()      // resX, resY, width, lineB
    var color = SIMD4<Float>()  // rgb
    var i = SIMD4<Int32>()      // cols, xs, row0
}

/// 動画モードでシェーダーに渡す値
struct VideoUniforms {
    var a = SIMD4<Float>()      // warpX, warpY, zoom, rgbShift
    var b = SIMD4<Float>()      // brightness, contrast, saturation, videoAspect
    var c = SIMD4<Float>()      // vpos, targetAspect, 0, 0
    var d = SIMD4<Float>()      // ライフゲームの重ね: 濃さ, 格子の点の明るさ, 1ますの大きさ(px), ますの中を明るくする量
    var e = SIMD4<Float>()      // ライフゲームのますの外の明るさ, 0, 0, rdLift(模様の色を明るくそろえる量)
    var f = SIMD4<Float>()      // rdMix(反応拡散を出す量), 0, rdDark(模様の外の明るさ), rdEmboss
    var g = SIMD4<Float>()      // depth(中へ入った深さ・階層), ratio(階層どうしの大きさの比), hue(階層ごとの色のずれ), 1階層で回る角度(rad)
    var h = SIMD4<Float>()      // 手ブレ: x, y(画面の幅・高さを 1 として), 傾き(rad), 0
}

/// ライフゲームの1世代に渡す値
struct LifeUniforms {
    var a = SIMD4<Float>()      // 世代ごとに変わる乱数の種, 波形から生まれる確率, 波形の高さ, 消える確率
    var b = SIMD4<Float>()      // 音の立ち上がりでまく場所 x, y(ます), 半径(ます), 密度
    var c = SIMD4<Float>()      // 1 = 全部消す, 0, 0, 0
}

/// 反応拡散(Gray-Scott)の1歩に渡す値
struct RDUniforms {
    var a = SIMD4<Float>()      // 暗いところの F, k / 明るいところの F, k
    var b = SIMD4<Float>()      // inject(種をまく量), seed(1 = 初期化), frameSeed, 中心に置く模様の半径(ます。0 = 置かない)
}

/// 仕上げ(ブルームと反転)に渡す値
struct PostUniforms {
    var a = SIMD4<Float>()      // 読む側の1画素の大きさ x, y(ぼかしでは進む向きを掛けたもの), 明るさの下限, 0
    var b = SIMD4<Float>()      // ブルームの量, 反転の量, 0, 0
    var c = SIMD4<Float>()      // 画素の引き伸ばし: 上の境目 y, 下の境目 y(0 = 上の端, 1 = 下の端), 掛ける量, 0
    var d = SIMD4<Float>()      // 画素の引き伸ばし(左右): 左の境目 x, 右の境目 x, 掛ける量, 0
}

struct FrameInfo { var k = 0; var g = 0.0; var dl = 0.0; var note = ""; var depth = 0.0; var shake = SIMD3<Double>(); var bloom = 0.0; var flash = 0.0; var morph = 0.0 }

func shaderSource(S: Int) -> String {
    return """
#include <metal_stdlib>
using namespace metal;
struct U { float4x4 vp; float4 a; float4 b; float4 c; float4 d; float4 color; int4 i; };
constant int S = \(S);
constant float JC = \(String(format: "%.1f", JC));

// si: 横の位置(音の点)、j: 奥行きの列。高さ = 横の波 X(si) + 奥行きの波 Y(j)
static float3 meshPoint(texture2d<float> h, constant U &u, int si, int j) {
    float hh = h.read(uint2(si, 0)).r + u.a.w * h.read(uint2(j, 1)).r;
    float3 p = float3((float(si) / float(S - 1) * 2.0 - 1.0) * u.a.x, hh * u.a.y, (JC - float(j)) * u.a.z);
    float c = cos(u.b.x), s = sin(u.b.x);       // 面を縦軸まわりに回す
    return float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

// 頂点を点で描く(drawVertices)
struct PtOut { float4 pos [[position]]; float size [[point_size]]; float vB; };
vertex PtOut pt_vs(uint vid [[vertex_id]], texture2d<float> h [[texture(0)]], constant U &u [[buffer(0)]]) {
    PtOut o;
    int cols = u.i.x, xs = u.i.y, row0 = u.i.z;
    int j = row0 + int(vid) / cols, i = int(vid) % cols;
    int si = min(i * xs, S - 1);
    float dj = abs(float(j) - JC);
    float b = clamp((u.b.y - dj) / u.b.z, 0.0, 1.0);
    if (b <= 0.0) { o.pos = float4(2.0, 2.0, 2.0, 1.0); o.size = 1.0; o.vB = 0.0; return o; }
    float4 p = u.vp * float4(meshPoint(h, u, si, j), 1.0);
    b *= mix(1.0, 1.0 - u.b.w, clamp((p.w - u.c.y) / (u.c.z - u.c.y), 0.0, 1.0));
    p.z = (p.z + p.w) * 0.5;                    // OpenGL の奥行き範囲(-w..w)を Metal の範囲(0..w)へ
    o.pos = p; o.size = u.c.x + 1.5; o.vB = b * u.c.w;
    return o;
}
fragment float4 pt_fs(PtOut in [[stage_in]], float2 pc [[point_coord]], constant U &u [[buffer(0)]]) {
    float d = length(pc - 0.5) * (u.c.x + 1.5);
    float a = clamp(u.c.x * 0.5 + 0.5 - d, 0.0, 1.0) * in.vB;
    if (a < 0.004) discard_fragment();
    return float4(u.color.rgb * a, 1.0);
}

// 中央の列をつないだ線(最初の横一本の波形)
struct LnOut { float4 pos [[position]]; float2 uv; float len; };
vertex LnOut ln_vs(uint vid [[vertex_id]], uint iid [[instance_id]], texture2d<float> h [[texture(0)]], constant U &u [[buffer(0)]]) {
    int col = int(iid), j = int(JC);
    float4 ca = u.vp * float4(meshPoint(h, u, col, j), 1.0), cb = u.vp * float4(meshPoint(h, u, col + 1, j), 1.0);
    float2 res = u.d.xy;
    float2 sa = ca.xy / ca.w * res * 0.5, sb = cb.xy / cb.w * res * 0.5;
    float2 dd = sb - sa; float len = length(dd);
    float2 dir = len > 1e-4 ? dd / len : float2(1.0, 0.0), n = float2(-dir.y, dir.x);
    float e = float(vid >> 1), s = float(vid & 1) * 2.0 - 1.0;
    float hw = u.d.z * 0.5 + 1.0;
    float uu = mix(-hw, len + hw, e);
    LnOut o;
    o.pos = float4((sa + dir * uu + n * s * hw) / (res * 0.5), 0.0, 1.0);
    o.uv = float2(uu, s * hw); o.len = len;
    return o;
}
fragment float4 ln_fs(LnOut in [[stage_in]], constant U &u [[buffer(0)]]) {
    float dx = max(max(-in.uv.x, in.uv.x - in.len), 0.0);
    float a = clamp(u.d.z * 0.5 + 0.5 - length(float2(dx, in.uv.y)), 0.0, 1.0) * u.d.w;
    if (a < 0.004) discard_fragment();
    return float4(u.color.rgb * a, 1.0);
}

// 動画モード: 動画の絵を、いまの波形でゆらして出す
struct VU { float4 a; float4 b; float4 c; float4 d; float4 e; float4 f; float4 g; float4 h; };
struct RU { float4 a; float4 b; };
struct LU { float4 a; float4 b; float4 c; };
struct BlitOut { float4 pos [[position]]; float2 uv; };
vertex BlitOut blit_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    BlitOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0 - p.y);
    return o;
}
// 動画を 32:9 いっぱいに敷く(はみ出すぶんは切る)ときの、画面の位置 -> 動画の位置
static float2 coverScale(constant VU &u) {               // 動画のうち、画面に出る割合(横, 縦)
    float va = u.b.w, ta = u.c.y;
    return va > ta ? float2(ta / va, 1.0) : float2(1.0, va / ta);
}
static float2 coverUV(float2 uv, constant VU &u) {
    float2 sc = coverScale(u);
    float2 center = float2(0.5, mix(0.5 * sc.y, 1.0 - 0.5 * sc.y, u.c.x));
    return (uv - 0.5) * sc + center;
}
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
// ライフゲームの1世代(誕生は周り3個、生存は2個か3個)。端は反対側へつながる。
// 音から生まれる: そのコマの波形の線の上と、音の立ち上がりのたびに決まる場所に、新しいますが生まれる
fragment float4 life_fs(BlitOut in [[stage_in]], texture2d<float> prev [[texture(0)]], texture2d<float> h [[texture(1)]], constant LU &l [[buffer(2)]]) {
    int2 size = int2(prev.get_width(), prev.get_height());
    int2 p = int2(in.pos.xy);
    if (l.c.x > 0.5) return float4(0.0, 0.0, 0.0, 1.0);
    int n = 0;
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        if (x == 0 && y == 0) continue;
        n += prev.read(uint2((p + int2(x, y) + size) % size)).r > 0.5 ? 1 : 0;
    }
    bool alive = prev.read(uint2(p)).r > 0.5;
    bool next = alive ? (n == 2 || n == 3) : (n == 3);
    if (next && hash21(float2(p) + l.a.x) < l.a.w) next = false;          // 少しずつ消えて、止まった形がたまらないようにする
    // 波形の線の上に生まれる(左から右へ、このコマの音の形)
    int si = clamp(int((float(p.x) + 0.5) / float(size.x) * float(S)), 0, S - 1);
    float row = (0.5 - 0.5 * h.read(uint2(si, 0)).r * l.a.z) * float(size.y);
    if (abs(float(p.y) + 0.5 - row) < 0.75 && hash21(float2(float(p.x), l.a.x * 7.0)) < l.a.y) next = true;
    // 音の立ち上がりで、まとまってまく
    if (l.b.w > 0.0 && length(float2(p) - l.b.xy) < l.b.z && hash21(float2(p) * 1.7 + l.a.x) < l.b.w) next = true;
    return float4(next ? 1.0 : 0.0, 0.0, 0.0, 1.0);
}
// 反応拡散の計算は、端のない正方形の領域で行う(上下左右がつながっていて、どこまでも敷き詰められる)。
// 画面に出るのは、その中央の横長の帯(32:9)。正方形の中の位置 -> 画面の位置(帯の外は 0..1 をはみ出す)
static float2 bandUV(float2 suv, constant VU &u) {
    return float2(suv.x, (suv.y - 0.5) * u.c.y + 0.5);
}
// 反応拡散(Gray-Scott)の1歩。r = U、g = V。動画の明るさで模様の性質(F と k)が場所ごとに変わるので、
// 動画の絵に沿って模様の出方が変わる。種(V のかたまり)も、動画の明るいところに多くまく
fragment float4 rd_fs(BlitOut in [[stage_in]], texture2d<float> prev [[texture(0)]], texture2d<float> vid [[texture(1)]], constant VU &u [[buffer(1)]], constant RU &r [[buffer(2)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::mirrored_repeat);
    int2 size = int2(prev.get_width(), prev.get_height());
    int2 p = int2(in.pos.xy);
    float lum = dot(vid.sample(s, coverUV(bandUV(in.uv, u), u), bias(1.0)).rgb, float3(0.2126, 0.7152, 0.0722));
    float2 cell = floor(float2(p) / 6.0);                 // 種は 6 ますのかたまりでまく(1 ますだけでは消えてしまう)
    // 領域の中心には、いつも模様を1つ置く(カメラが入っていく入口。ほかの点と同じくらいの大きさ)
    float core = r.b.w > 0.0 ? 1.0 - smoothstep(r.b.w - 1.5, r.b.w, length(float2(p) + 0.5 - float2(size) * 0.5)) : 0.0;
    if (r.b.y > 0.5) {                                   // 初期化: 全体に U = 1、ところどころに V の種
        float v = max(step(1.0 - 0.012 * (0.4 + 2.0 * lum), hash21(cell + r.b.z)), core);
        return float4(1.0 - 0.5 * v, v, 0.0, 1.0);
    }
    float2 c = prev.read(uint2(p)).rg;
    float2 lap = -c;
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        if (x == 0 && y == 0) continue;
        float w = (x == 0 || y == 0) ? 0.2 : 0.05;
        lap += w * prev.read(uint2((p + int2(x, y) + size) % size)).rg;     // 端は反対側へつながる
    }
    float l = smoothstep(0.04, 0.75, lum);
    float F = mix(r.a.x, r.a.z, l), K = mix(r.a.y, r.a.w, l);
    float uvv = c.x * c.y * c.y;
    float U = c.x + (1.0 * lap.x - uvv + F * (1.0 - c.x));
    float V = c.y + (0.5 * lap.y + uvv - (F + K) * c.y);
    if (r.b.x > 0.0) {                                   // キックで種をまく
        float v = step(1.0 - 0.02 * r.b.x * (0.25 + 2.0 * lum), hash21(cell + r.b.z));
        V = max(V, v * 0.9); U = min(U, 1.0 - 0.5 * v);
    }
    V = max(V, core * 0.55); U = mix(U, min(U, 0.35), core);
    return float4(saturate(U), saturate(V), 0.0, 1.0);
}
// 反応拡散の V を、ますの間もなめらかに読む(大きく拡大しても、ますの形が見えない)。端は反対側へつながる
static float rdSmooth(texture2d<float> t, float2 uv) {
    int2 isz = int2(t.get_width(), t.get_height());
    float2 p = uv * float2(isz) - 0.5, i = floor(p), f = p - i;
    float2 w[4] = { (1.0 - f) * (1.0 - f) * (1.0 - f) / 6.0, (3.0 * f * f * f - 6.0 * f * f + 4.0) / 6.0,
                    (-3.0 * f * f * f + 3.0 * f * f + 3.0 * f + 1.0) / 6.0, f * f * f / 6.0 };
    float v = 0.0;
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
        int2 q = ((int2(i) + int2(x - 1, y - 1)) % isz + isz) % isz;
        v += t.read(uint2(q)).g * w[x].x * w[y].y;
    }
    return v;
}
static float3 hueTurn(float3 c, float turns) {            // 色相を回す
    float a = turns * 6.2831853, cs = cos(a), sn = sin(a);
    float3 k = float3(0.57735);
    return c * cs + cross(k, c) * sn + k * dot(k, c) * (1.0 - cs);
}
// 反応拡散の1階層ぶん。suv = その階層の中の位置(0..1)、scale = 画面上での拡大率
struct RDLevel { float m; float relief; float3 inside; float3 outside; };   // 模様の濃さ、陰影、模様の中の色、外の色
static RDLevel rdLevel(texture2d<float> rd, texture2d<float> vid, constant VU &u,
                       float2 suv, float2 dw, float scale, float level) {
    constexpr sampler rs(filter::linear, mip_filter::linear, address::repeat);
    constexpr sampler ms(filter::linear, mip_filter::linear, address::mirrored_repeat);
    float2 px = 1.0 / float2(rd.get_width(), rd.get_height());
    RDLevel o;
    float v = mix(rd.sample(rs, suv).g, rdSmooth(rd, suv), smoothstep(1.0, 2.0, scale));
    o.m = smoothstep(0.06, 0.26, v);
    o.relief = (rd.sample(rs, suv + px).g - rd.sample(rs, suv - px).g) * u.f.w;   // 斜めから光を当てたような陰影
    // 色は動画から。領域のくり返しの境目では折り返して読む(境目に段差が出ない)
    float3 vc = hueTurn(vid.sample(ms, coverUV(bandUV(suv, u) + dw, u)).rgb, level * u.g.z);
    // 暗い素材でも模様が見えるよう、色味はそのままに明るさだけ持ち上げる
    float top = max(max(vc.r, vc.g), max(vc.b, 0.08));
    o.inside = mix(vc, vc / top * 0.95, u.e.w);
    o.outside = vc * u.f.z;
    return o;
}
// 動画モードの絵: 動画を、いまの波形でゆらして出す。キックが入ってからは反応拡散の模様に移る
fragment float4 vid_fs(BlitOut in [[stage_in]], texture2d<float> vid [[texture(0)]], texture2d<float> h [[texture(1)]], texture2d<float> life [[texture(2)]], texture2d<float> rd [[texture(3)]], constant U &gu [[buffer(0)]], constant VU &u [[buffer(1)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::mirrored_repeat);
    // 手ブレ: 画面全体を少しずらし、少し傾ける(縦横比を保って回す)
    float ta = u.c.y, cr = cos(u.h.z), sr = sin(u.h.z);
    float2 d0 = (in.uv - 0.5) * float2(ta, 1.0);
    float2 cam = float2(cr * d0.x - sr * d0.y, sr * d0.x + cr * d0.y) / float2(ta, 1.0) + 0.5 + u.h.xy;
    float2 uv = cam;                                     // 左上が (0,0)
    float2 ruv = (cam - 0.5) / u.a.z + 0.5;              // 反応拡散の模様は、ゆらさずに読む(キックで寄るだけ)
    // 波形(このコマの音)を、画面の縦位置と横位置に当てる
    float wy = h.read(uint2(clamp(int(uv.y * float(S - 1)), 0, S - 1), 0)).r;
    float wx = h.read(uint2(clamp(int(uv.x * float(S - 1)), 0, S - 1), 0)).r;
    uv.x += u.a.x * wy;                                  // 行ごとに横へずらす
    uv.y += u.a.y * wx;                                  // 列ごとに縦へずらす(波形の線と同じ向き)
    uv = (uv - 0.5) / u.a.z + 0.5;                       // キックで寄る
    float2 vuv = coverUV(uv, u);
    float2 sh = float2(u.a.w * coverScale(u).x, 0.0);    // キックで色をずらす
    float3 c = float3(vid.sample(s, vuv + sh).r, vid.sample(s, vuv).g, vid.sample(s, vuv - sh).b);
    if (u.d.x > 0.001) {
        // ライフゲームを、細かい格子として動画に重ねる。生きているますの中にだけ動画が見え、ますの外は暗くする。
        // 格子の位置にも、ごく小さな点として動画を少しだけ見せる
        float2 cells = float2(life.get_width(), life.get_height());
        float2 lp = cam * cells;
        float2 ci = floor(lp), f = lp - ci;
        float on = (ci.x >= 0.0 && ci.y >= 0.0 && ci.x < cells.x && ci.y < cells.y) ? life.read(uint2(ci)).r : 0.0;
        float aa = 0.75 / max(u.d.z, 1.0);                    // 1ますの大きさに合わせて、ふちをなめらかに
        float sq = smoothstep(0.10 - aa, 0.10 + aa, min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y)));
        float dotm = 1.0 - smoothstep(0.10, 0.10 + 2.0 * aa, length(f - 0.5));
        // ますの中の動画は、色味を保って少し明るくする(暗い素材でも、ますが見える)
        float top = max(max(c.r, c.g), max(c.b, 0.08));
        float3 lit = mix(c, c / top * 0.95, u.d.w);
        float show = max(on * sq, dotm * u.d.y);
        c = mix(c, mix(c * u.e.x, lit, show), u.d.x);
    }
    if (u.f.x > 0.001) {
        // 反応拡散: 模様の中に動画の色、外は動画を暗くしたもの。
        // 中へ入る: どの模様の中にも、次の階層(同じ計算を小さく敷き詰めた「中の世界」)がある。
        // カメラは画面の中心の模様へ寄っていき、その模様が画面を覆うころ、中の世界がちょうど元の大きさになる。
        // 深さが 1 進むたびに同じことをくり返す。計算は端のない領域なので、中の世界に端や枠は出ない
        float z = max(u.g.x, 0.0), ratio = u.g.y;
        float L0 = floor(z), fz = z - L0, L1 = L0 + 1.0;
        float2 dw = uv - ruv;                            // 波形によるずれ(動画の色を読むとき、各階層に同じだけ足す)
        float s0 = pow(ratio, fz), s1 = s0 / ratio;      // 外の階層と、中の階層の拡大率
        // 階層ごとに左右・上下を裏返して、同じ並びに見えないようにする
        float2 f0 = float2(fmod(L0, 2.0) < 0.5 ? 1.0 : -1.0, fmod(floor(L0 * 0.5), 2.0) < 0.5 ? 1.0 : -1.0);
        float2 f1 = float2(fmod(L1, 2.0) < 0.5 ? 1.0 : -1.0, fmod(floor(L1 * 0.5), 2.0) < 0.5 ? 1.0 : -1.0);
        // 画面の位置 -> 正方形の領域の中の位置(入りながら少し回すこともできる)
        float2 pc = (ruv - 0.5) * float2(1.0, 1.0 / ta);
        float a0 = -fz * u.g.w, a1 = (1.0 - fz) * u.g.w;
        float2 q0 = float2(cos(a0) * pc.x - sin(a0) * pc.y, sin(a0) * pc.x + cos(a0) * pc.y) / s0;
        float2 q1 = float2(cos(a1) * pc.x - sin(a1) * pc.y, sin(a1) * pc.x + cos(a1) * pc.y) / s1;
        RDLevel a = rdLevel(rd, vid, u, q0 * f0 + 0.5, dw, s0, L0);
        float3 rc = (1.0 - a.m) * a.outside + a.m * a.inside + a.relief;
        // 中の世界(次の階層): 外の模様の形のまま、その中にだけ見える。入り始める前は出さない
        float reveal = smoothstep(0.03, 0.10, s1) * a.m;
        if (reveal > 0.002) {
            RDLevel b = rdLevel(rd, vid, u, q1 * f1 + 0.5, dw, s1, L1);
            // はじめは、外の模様の色の中に、中の世界の模様だけが浮かんで見える。
            // 近づくにつれて、画面の中心から外へ向かって、中の世界の暗い地が広がる
            float dcen = length((ruv - 0.5) * float2(ta, 1.0)) / length(float2(ta, 1.0) * 0.5);   // 0 = 中心、1 = 画面の角
            float grow = smoothstep(0.25, 1.0, s1) * 1.7;
            float dark = smoothstep(grow, grow - 0.7, dcen);
            float3 ground = mix(a.inside, b.outside, dark);
            // 中の世界の模様を出すのは、中心のまわりの領域1枚ぶんだけ(丸く、端はぼかす)。
            // 同じ並びのくり返しが見えないようにするため。寄りきったときには画面の角まで届く
            float win = 1.0 - smoothstep(0.56, 0.72, length(q1));
            float3 inner = ground + win * (b.m * (b.inside - ground) + b.relief);
            float k = reveal / max(a.m, 0.001);
            rc = (1.0 - a.m) * a.outside + a.m * mix(a.inside, inner, k) + a.relief * (1.0 - reveal * dark);
        }
        c = mix(c, rc, u.f.x);
    }
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = mix(float3(l), c, u.b.z);
    c = (c - 0.5) * u.b.y + 0.5;
    c *= u.b.x;
    c += (hash21(in.pos.xy) - 0.5) / 255.0;              // なだらかな色の段差(縞)を目立たなくする
    return float4(saturate(c), 1.0);
}

// タイトルの文字(白黒の絵)を、色と明るさを掛けて上に足す
fragment float4 title_fs(BlitOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant U &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float a = t.sample(s, in.uv).r * u.d.w;
    if (a < 0.002) discard_fragment();
    return float4(u.color.rgb * a, 1.0);
}

// ---- 仕上げ: ブルーム(明るい所のにじみ)と、色の反転 ----
struct PU { float4 a; float4 b; float4 c; float4 d; };
// 明るい所だけを取り出しながら 1/4 に縮める(4回の読みで 4x4 画素の平均)
fragment float4 bright_fs(BlitOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant PU &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 px = p.a.xy;
    float3 c = 0.25 * (t.sample(s, in.uv + px * float2(-1.0, -1.0)).rgb + t.sample(s, in.uv + px * float2(1.0, -1.0)).rgb
                     + t.sample(s, in.uv + px * float2(-1.0, 1.0)).rgb + t.sample(s, in.uv + px * float2(1.0, 1.0)).rgb);
    float l = max(c.r, max(c.g, c.b));
    float k = p.a.z > 0.001 ? smoothstep(p.a.z * 0.5, p.a.z * 1.5 + 0.02, l) : 1.0;
    return float4(c * k, 1.0);
}
// 半分に縮める
fragment float4 down_fs(BlitOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant PU &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 px = p.a.xy * 0.5;
    float3 c = 0.25 * (t.sample(s, in.uv + px * float2(-1.0, -1.0)).rgb + t.sample(s, in.uv + px * float2(1.0, -1.0)).rgb
                     + t.sample(s, in.uv + px * float2(-1.0, 1.0)).rgb + t.sample(s, in.uv + px * float2(1.0, 1.0)).rgb);
    return float4(c, 1.0);
}
// 一方向のぼかし(横と縦に分けて2回掛ける)
fragment float4 blur_fs(BlitOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant PU &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 d = p.a.xy;
    float3 c = t.sample(s, in.uv).rgb * 0.2270270270;
    c += (t.sample(s, in.uv + d * 1.3846153846).rgb + t.sample(s, in.uv - d * 1.3846153846).rgb) * 0.3162162162;
    c += (t.sample(s, in.uv + d * 3.2307692308).rgb + t.sample(s, in.uv - d * 3.2307692308).rgb) * 0.0702702703;
    return float4(c, 1.0);
}
// 元の絵に、3段のにじみ(細かい・中くらい・広い)を足す。クラップのコマでは色を反転する
fragment float4 post_fs(BlitOut in [[stage_in]], texture2d<float> scene [[texture(0)]], texture2d<float> b0 [[texture(1)]],
                        texture2d<float> b1 [[texture(2)]], texture2d<float> b2 [[texture(3)]], constant PU &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // 画素の引き伸ばし: 境目より上は境目の画素を上へ、境目より下は境目の画素を下へ、まっすぐ引き伸ばす
    float2 suv = in.uv;
    if (p.c.z > 0.5) suv.y = clamp(suv.y, p.c.x, p.c.y);
    if (p.d.z > 0.5) suv.x = clamp(suv.x, p.d.x, p.d.y);        // 左右も同じ: 境目より外は、境目の画素を横へ引き伸ばす
    float3 c = scene.sample(s, suv).rgb;
    // 背景の色(ふだんは黒)。絵の暗い所ほど背景が見える
    float3 bg = float3(p.a.w, p.b.z, p.b.w);
    c = mix(bg, c, saturate(max(c.r, max(c.g, c.b)) * 2.5));
    if (p.b.x > 0.0005) {
        float3 g = 0.40 * b0.sample(s, suv).rgb + 0.35 * b1.sample(s, suv).rgb + 0.25 * b2.sample(s, suv).rgb;
        c += p.b.x * g;
        c += (hash21(in.pos.xy) - 0.5) / 255.0;          // にじみのなだらかな所に縞が出ないようにする
    }
    c = saturate(c);
    c = mix(c, 1.0 - c, p.b.y);
    return float4(c, 1.0);
}

// ---- 動画にかけるエフェクト(小田急の動画のパート)。キック・クラップ・金物が鳴るたびに、別のエフェクトへ切り替える ----
// a = (エフェクトの番号, 乱数 1, 乱数 2, 切り替わってからの秒数)、b = (動画の横縦比, 画面の横縦比, 履歴のいちばん新しいコマ, 履歴の枚数)、c = (時刻, 明るさ, 音が鳴った切り替えなら 1, 0)
struct FU { float4 a; float4 b; float4 c; };
static float2 fxCover(float2 uv, constant FU &u) {       // 動画を画面いっぱいに敷く(はみ出すぶんは切る)
    float va = u.b.x, ta = u.b.y;
    float2 sc = va > ta ? float2(ta / va, 1.0) : float2(1.0, va / ta);
    return (uv - 0.5) * sc + 0.5;
}
// 履歴に 1 コマ足す(画面と同じ切り出しで、小さくしてしまっておく)
fragment float4 ring_fs(BlitOut in [[stage_in]], texture2d<float> vid [[texture(0)]], constant FU &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(vid.sample(s, fxCover(in.uv, u)).rgb, 1.0);
}
// d コマ前の絵(d = 0 はいまの絵)
static float3 fxS(texture2d<float> vid, texture2d_array<float> ring, float2 uv, float d, constant FU &u) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    uv = clamp(uv, 0.0, 1.0);
    if (d < 0.5) return vid.sample(s, fxCover(uv, u)).rgb;
    float n = u.b.w;
    return ring.sample(s, uv, uint(fmod(u.b.z - min(d, n - 1.0) + n * 4.0, n))).rgb;
}
fragment float4 fx_fs(BlitOut in [[stage_in]], texture2d<float> vid [[texture(0)]], texture2d_array<float> ring [[texture(1)]], constant FU &u [[buffer(0)]]) {
    float2 uv = in.uv;
    int e = int(u.a.x);
    float r1 = u.a.y, r2 = u.a.z, age = u.a.w, t = u.c.x, n = u.b.w, hit = u.c.z;
    float punch = exp(-age * 26.0);                      // 鳴った瞬間だけ強く、2〜3 コマで引く
    float fr = floor(t * 30.0);                          // コマ番号。模様は 1 コマごとに変わる
    float ta = u.b.y;
    // どのエフェクトにも重ねる細かい乱れ: 鳴った直後の 2〜3 コマだけ、細い横の帯が左右にずれる
    {
        float row = floor(uv.y * 270.0);
        float on = step(0.80 - 0.35 * hit, hash21(float2(row * 0.37, fr * 1.3 + 9.0)));
        uv.x += (hash21(float2(row, fr + 4.0)) - 0.5) * 0.09 * on * punch;
    }
    float3 c;
    if (e == 0) {            // スリットスキャン(横): 細い縦の帯ごとに、前の時刻の絵を出す。帯の幅と時刻のずれは毎回ちがう
        float strips = 60.0 + 260.0 * r1;
        float sx = floor(uv.x * strips);
        float d = r2 < 0.45 ? floor(hash21(float2(sx, 3.0)) * (n - 1.0)) : floor(fract(uv.x * (1.0 + floor(r2 * 5.0))) * (n - 1.0));
        c = fxS(vid, ring, uv, d, u);
    } else if (e == 1) {     // スリットスキャン(縦): 細い横の帯ごとに
        float strips = 40.0 + 160.0 * r1;
        float sy = floor(uv.y * strips);
        float d = r2 < 0.45 ? floor(hash21(float2(sy, 5.0)) * (n - 1.0)) : floor(fract(uv.y * (1.0 + floor(r2 * 4.0))) * (n - 1.0));
        c = fxS(vid, ring, uv, d, u);
    } else if (e == 2) {     // 帯のノイズ: 細い横の帯が、色を反転したり、粗い階調になったり、横にずれたりする(1 コマごとに入れ替わる)
        float row = floor(uv.y * (60.0 + 200.0 * r1));
        float h = hash21(float2(row, fr * 0.71 + 1.0));
        if (h < 0.30) uv.x = fract(uv.x + (hash21(float2(row, fr)) - 0.5) * 0.5);
        c = fxS(vid, ring, uv, 0.0, u);
        if (h > 0.78) c = 1.0 - c;
        else if (h > 0.60) c = floor(c * 3.0 + 0.5) / 3.0;
    } else if (e == 3) {     // 色ずれ: 細い帯ごとに、赤と青を左右にずらす量が変わる
        float row = floor(uv.y * (30.0 + 150.0 * r1));
        float sh = (0.004 + 0.05 * hash21(float2(row, fr))) * (0.3 + 1.2 * punch) * step(0.35, hash21(float2(row, fr + 2.0)));
        c = float3(fxS(vid, ring, uv + float2(sh, 0.0), 0.0, u).r, fxS(vid, ring, uv, 0.0, u).g, fxS(vid, ring, uv - float2(sh, 0.0), 0.0, u).b);
    } else if (e == 4) {     // ブロックのずれ: 細かいます目の一部が横にずれ、一部は前のコマになる(1 コマごとに入れ替わる)
        float m = 14.0 + 40.0 * r1;
        float2 cell = floor(uv * float2(m * ta * 0.6, m));
        float h = hash21(cell + fr * 0.37 + 3.0);
        float d = 0.0;
        if (h < 0.30) uv.x += (hash21(cell + 7.0 + fr) - 0.5) * 0.18;
        if (h < 0.12) d = floor(hash21(cell + 11.0) * (n - 1.0));
        c = fxS(vid, ring, uv, d, u);
        if (h > 0.94) c = 1.0 - c;
    } else if (e == 5) {     // 横線のずれ: 1〜2 画素の細い線ごとに横へ裂ける
        float row = floor(uv.y * (270.0 + 270.0 * r1));
        float on = step(0.45, hash21(float2(floor(row / (1.0 + floor(r2 * 6.0))) * 0.13, fr + 2.0)));
        uv.x += (hash21(float2(row, fr)) - 0.5) * (0.04 + 0.22 * punch) * on;
        c = fxS(vid, ring, uv, 0.0, u);
    } else if (e == 6) {     // 鏡: 細かく何度も折り返す
        float folds = 1.0 + floor(r1 * 7.0);
        float x = fract(uv.x * folds);
        uv.x = (floor(uv.x * folds) + (fmod(floor(uv.x * folds), 2.0) < 0.5 ? x : 1.0 - x)) / folds;
        if (r2 > 0.5) uv.y = 0.5 - abs(uv.y - 0.5);
        c = fxS(vid, ring, uv, 0.0, u);
    } else if (e == 7) {     // モザイク: 帯ごとに、ますの細かさが変わる
        float band = floor(uv.y * (3.0 + floor(r2 * 9.0)));
        float m = 20.0 + 160.0 * hash21(float2(band, fr * 0.5 + r1 * 9.0));
        float2 g = float2(m * ta, m);
        c = fxS(vid, ring, (floor(uv * g) + 0.5) / g, 0.0, u);
    } else if (e == 8) {     // 白黒の 2 階調 + 細い走査線
        c = fxS(vid, ring, uv, 0.0, u);
        c = float3(step(0.2 + 0.3 * r1, dot(c, float3(0.2126, 0.7152, 0.0722))));
        c *= 0.55 + 0.45 * step(0.5, fract(uv.y * 135.0));
    } else if (e == 9) {     // 分割: 画面を細かい画面に割り、ますごとに違う時刻を出す
        float m = 3.0 + floor(r1 * 9.0);
        float2 g = float2(m * 3.0, m), cell = floor(uv * g);
        c = fxS(vid, ring, fract(uv * g), floor(hash21(cell + 2.0) * (n - 1.0)), u);
    } else if (e == 10) {    // 縦ずれ: 縦の帯ごとに、絵が上下へ別々の速さで流れる
        float col = floor(uv.x * (12.0 + 80.0 * r1));
        uv.y = fract(uv.y + (hash21(float2(col, 8.0)) - 0.5) * (0.3 + age * 9.0));
        c = fxS(vid, ring, uv, 0.0, u);
    } else if (e == 11) {    // 色の入れ替え: 細い帯ごとに色の並びを替える
        c = fxS(vid, ring, uv, 0.0, u);
        float h = hash21(float2(floor(uv.y * (20.0 + 120.0 * r1)), fr));
        c = h < 0.33 ? c.gbr : (h < 0.66 ? c.brg : c);
    } else if (e == 12) {    // 止め絵: 少し前のコマで止まり、細い帯が震える
        float d = floor(2.0 + r1 * (n - 3.0));
        float row = floor(uv.y * 180.0);
        uv.x += (hash21(float2(row, fr)) - 0.5) * 0.02;
        c = float3(fxS(vid, ring, uv + float2(0.006, 0.0), d, u).r, fxS(vid, ring, uv, d, u).g, fxS(vid, ring, uv - float2(0.006, 0.0), 0.0, u).b);
    } else if (e == 13) {    // 横の筋: 明るい所から、画素が横へ細い筋になって伸びる
        float row = floor(uv.y * 540.0);
        float len = (0.03 + 0.25 * r1) * hash21(float2(row, floor(fr / 2.0)));
        float3 a = fxS(vid, ring, uv, 0.0, u);
        float x0 = floor(uv.x / len) * len;
        float3 b = fxS(vid, ring, float2(x0, uv.y), 0.0, u);
        c = dot(b, float3(0.2126, 0.7152, 0.0722)) > 0.35 + 0.3 * r2 ? b : a;
    } else if (e == 14) {    // 寄り: 鳴った瞬間に大きく寄って、すぐ戻る
        float z = 1.0 + (0.5 + 1.5 * r1) * punch;
        c = fxS(vid, ring, (uv - float2(0.3 + 0.4 * r2, 0.5)) / z + float2(0.3 + 0.4 * r2, 0.5), 0.0, u);
    } else {                 // 残像: いまの絵と、前の何コマかを少しずつずらして重ねる
        c = fxS(vid, ring, uv, 0.0, u) * 0.4;
        for (int i = 1; i <= 5; i++) c += fxS(vid, ring, uv + float2(float(i) * 0.004 * (r2 - 0.5), 0.0), float(i) * (1.0 + floor(r1 * 4.0)), u) * 0.12;
    }
    return float4(saturate(c * u.c.y), 1.0);
}

// 地が透明な絵(色に不透明度を掛けてあるもの)を、そのまま返す
fragment float4 over_fs(BlitOut in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return t.sample(s, in.uv);
}

// 日付の文字(k.x = 濃さ)と、画面の中央のぼやけた淡い光(k.y = 明るさ。k.z = 画面の横縦比)
fragment float4 date_fs(BlitOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant float4 &k [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = t.sample(s, in.uv) * k.x;
    float2 q = (in.uv - 0.5) * float2(k.z, 1.0);
    // 中心がいちばん明るく、なだらかに消える。下へは長く伸ばす(画面の下の端まで、うっすら届く)
    float sy = q.y > 0.0 ? 0.55 : 0.07;
    float g = exp(-(q.x * q.x / (0.10 + 0.25 * max(q.y, 0.0)) + q.y * q.y / sy)) * k.y;
    g += (hash21(in.pos.xy) - 0.5) / 255.0 * step(0.0005, k.y);   // 縞が出ないように
    return float4(c.rgb + float3(g), max(c.a, saturate(g)));
}

// 描いた絵を画面へ写す
fragment float4 blit_fs(BlitOut in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(t.sample(s, in.uv).rgb, 1.0);
}
"""
}

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let track: Track
    let params: Params
    let scale: Int                      // 何倍の大きさで描くか(1 = 1920x540)
    let target: MTLTexture              // 仕上がりの絵(W*scale x H*scale)。画面に写すのも書き出すのもこれ
    private let scene: MTLTexture       // 仕上げ(ブルームと反転)を掛ける前の絵
    private var glow: [[MTLTexture]] = []   // にじみ用の小さい絵。1/4, 1/8, 1/16 の3段、段ごとに2枚
    private let brightPipe: MTLRenderPipelineState
    private let downPipe: MTLRenderPipelineState
    private let blurPipe: MTLRenderPipelineState
    private let postPipe: MTLRenderPipelineState
    private let heights: MTLTexture     // 0行目 = 横の波 X、1行目 = 奥行きの波 Y
    private let ptPipe: MTLRenderPipelineState
    private let lnPipe: MTLRenderPipelineState
    private let blitPipe: MTLRenderPipelineState
    private let vidPipe: MTLRenderPipelineState
    private let rdPipe: MTLRenderPipelineState
    private let lifePipe: MTLRenderPipelineState
    private let titlePipe: MTLRenderPipelineState
    private var titleTex: MTLTexture?, titleKey = ""
    // ライフゲームの状態(2枚を交互に使う)
    private var life: [MTLTexture] = [], lifeCur = 0, lastLifeK = Int.min, lifeValid = false, lifePhase = 0.0
    // 反応拡散の状態(2枚を交互に使う)
    private var rd: [MTLTexture] = [], rdCur = 0, lastRDK = Int.min, rdValid = false
    // 動画を縮小版つきで写したもの(反応拡散で、ならした明るさや小さく置いた絵を読むため)
    private var lastMipK = Int.min
    private var vmip: MTLTexture?
    var video: VideoSource?             // 動画モードの素材
    private(set) var brain: BrainScene? // 脳のシーン(初めてそのモードにしたときに作る)
    private var brainFailed = false
    private var reel: VideoSource?      // 通しの終盤に流す、前もって 1 本に組んだ動画(tools/kickreel.py が作る。アプリの中の kickreel.mp4)
    private var reelTried = false
    private var odakyu: VideoSource?    // x-Music のロゴのうしろに流す動画
    private var odakyuTried = false
    var endFade = 0.0                   // 最後のフェードアウトの進み具合(0 = まだ, 1 = 消えきった)。音量に使う
    private var stamp: DateStamp?       // 終盤に重ねる日付の文字
    private var cycle: VideoSource?     // 金物が入る所から流す、キックごとに素材を順番に回す動画
    private var cycleTried = false
    // 動画のエフェクト用: 直前 48 コマぶんの絵の履歴(スリットスキャンなど、前の時刻の絵を使うエフェクトのため)
    static let RING = 48
    private var ring: MTLTexture?, ringHead = 0, lastRingK = Int.min
    private let ringPipe: MTLRenderPipelineState, fxPipe: MTLRenderPipelineState
    private var fxEvents: [Double] = [], fxKey = "", fxHits = Set<Int>()
    private var typo: Typo?             // タイポグラフィのパートの絵(初めて使うときに作る)
    private let typoPipe: MTLRenderPipelineState
    private let typoOverPipe: MTLRenderPipelineState
    private let datePipe: MTLRenderPipelineState
    private var ybuf: [Float]
    private var lastKey = ""
    private var enterKey = -1.0, enterT = Double.infinity

    init(device: MTLDevice, track: Track, params: Params, scale: Int, drawableFormat: MTLPixelFormat) throws {
        self.device = device; self.track = track; self.params = params; self.scale = max(1, scale)
        guard let q = device.makeCommandQueue() else { throw err("Metal のキューを作れません") }
        queue = q
        let lib = try device.makeLibrary(source: shaderSource(S: track.S), options: nil)

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: W * self.scale, height: H * self.scale, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        let hd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: track.S, height: 2, mipmapped: false)
        hd.usage = [.shaderRead]; hd.storageMode = .shared
        guard let t = device.makeTexture(descriptor: td), let sc0 = device.makeTexture(descriptor: td), let h = device.makeTexture(descriptor: hd) else { throw err("テクスチャを作れません") }
        target = t; scene = sc0; heights = h
        for div in [4, 8, 16] {
            let gd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(1, (t.width + div - 1) / div),
                                                              height: max(1, (t.height + div - 1) / div), mipmapped: false)
            gd.usage = [.renderTarget, .shaderRead]; gd.storageMode = .private
            guard let a = device.makeTexture(descriptor: gd), let b = device.makeTexture(descriptor: gd) else { throw err("テクスチャを作れません") }
            glow.append([a, b])
        }
        ybuf = [Float](repeating: 0, count: track.S)

        func pipe(_ vs: String, _ fs: String, _ format: MTLPixelFormat, additive: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs); d.fragmentFunction = lib.makeFunction(name: fs)
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = format
            if additive {               // 加算で重ねる
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add; ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .one
                ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        ptPipe = try pipe("pt_vs", "pt_fs", .rgba8Unorm, additive: true)
        lnPipe = try pipe("ln_vs", "ln_fs", .rgba8Unorm, additive: true)
        blitPipe = try pipe("blit_vs", "blit_fs", drawableFormat, additive: false)
        typoPipe = try pipe("blit_vs", "blit_fs", .rgba8Unorm, additive: false)
        ringPipe = try pipe("blit_vs", "ring_fs", .rgba8Unorm, additive: false)
        fxPipe = try pipe("blit_vs", "fx_fs", .rgba8Unorm, additive: false)
        let od = MTLRenderPipelineDescriptor()           // 地が透明な絵を、上に重ねる
        od.vertexFunction = lib.makeFunction(name: "blit_vs"); od.fragmentFunction = lib.makeFunction(name: "over_fs")
        let oc = od.colorAttachments[0]!
        oc.pixelFormat = .rgba8Unorm; oc.isBlendingEnabled = true
        oc.rgbBlendOperation = .add; oc.alphaBlendOperation = .add
        oc.sourceRGBBlendFactor = .one; oc.destinationRGBBlendFactor = .oneMinusSourceAlpha
        oc.sourceAlphaBlendFactor = .one; oc.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        typoOverPipe = try device.makeRenderPipelineState(descriptor: od)
        od.fragmentFunction = lib.makeFunction(name: "date_fs")
        datePipe = try device.makeRenderPipelineState(descriptor: od)
        vidPipe = try pipe("blit_vs", "vid_fs", .rgba8Unorm, additive: false)
        rdPipe = try pipe("blit_vs", "rd_fs", .rgba16Float, additive: false)
        lifePipe = try pipe("blit_vs", "life_fs", .r8Unorm, additive: false)
        titlePipe = try pipe("blit_vs", "title_fs", .rgba8Unorm, additive: true)
        brightPipe = try pipe("blit_vs", "bright_fs", .rgba16Float, additive: false)
        downPipe = try pipe("blit_vs", "down_fs", .rgba16Float, additive: false)
        blurPipe = try pipe("blit_vs", "blur_fs", .rgba16Float, additive: false)
        postPipe = try pipe("blit_vs", "post_fs", .rgba8Unorm, additive: false)
    }

    /// 時刻 t(秒)の絵を target に描く命令を cb に積む
    /// playing: 音を再生中か(動画の再生機を動かすかどうか)。still: 1枚だけ取り出す(書き出し用)
    /// continuous: still でも、前のコマの続きとして扱う(書き出しの前に数秒ぶん進めておくとき)
    @discardableResult
    func encode(_ cb: MTLCommandBuffer, time t: Double, playing: Bool = false, still: Bool = false, continuous: Bool = false) -> FrameInfo {
        let jump = still && !continuous                  // 単発の1枚: 前のコマの続きではない
        let P = params, S = track.S
        let k = min(max(0, Int((t * Double(FPS) + 1e-6).rounded(.down))), max(0, track.frames - 1))
        let sy = max(1, min(YMAX, Int(P.ytime.rounded())))
        let key = "\(k):\(sy)"
        if lastKey != key {
            // 横の波 X = このコマの音そのもの。奥行きの波 Y = 同じ位置から sy 点ずつの平均を列の数だけ
            let base = k * S
            track.mono.withUnsafeBufferPointer { m in
                for j in 0..<ROWS {
                    var s: Float = 0
                    let a = base + j * sy
                    for n in 0..<sy { s += m[a + n] }
                    ybuf[j] = s / Float(sy)
                }
                heights.replace(region: MTLRegionMake2D(0, 0, S, 1), mipmapLevel: 0, withBytes: m.baseAddress! + base, bytesPerRow: S * 4)
            }
            ybuf.withUnsafeBufferPointer { y in
                heights.replace(region: MTLRegionMake2D(0, 1, S, 1), mipmapLevel: 0, withBytes: y.baseAddress!, bytesPerRow: S * 4)
            }
            lastKey = key
        }
        let tk = Double(k) / Double(FPS)
        let aspect = Double(W) / Double(H)
        // 通し(モード 3): 波形メッシュで始まり、seqCut 秒あたりの最初のクラップが鳴るコマで、脳のシーン(Curl noise の粒子)へ一瞬で切り替わる
        let seqMode = P.mode >= 2.5
        var seqBrain = false, cutT = -Double.infinity
        if seqMode {
            cutT = track.cueClap.first { $0.t >= P.seqCut - 0.05 }?.t ?? P.seqCut
            seqBrain = Double(k + 1) / Double(FPS) > cutT
        }
        // 通しの終盤: クラップが終わってキックだけが続く区間(最後のクラップのあとの最初のキック 〜 最後のキック)は、
        // エフェクトを何も掛けず、キックのたびに動画素材のランダムな場所へ切り替えるだけにする
        var seqVideo = false
        // 日付のカウント: 終盤のキックのパートの頭から終わりまでを 0..1 に直したもの。終わったあとは 1 のまま(黒地に日付だけ)
        var dateOn = false, dateOnly = false, dateX = 0.0, dateEnd = Double.infinity
        endFade = 0
        if seqMode, P.seqDate >= 0.5, let lastClap = track.cueClap.last?.t, let lastKick = track.cueKick.last?.t,
           let firstKick = track.cueKick.first(where: { $0.t > lastClap + 0.05 })?.t {
            let d0 = floor(firstKick * Double(FPS) + 1e-6) / Double(FPS), d1 = lastKick + P.seqVideoHold
            if tk >= d0 - 1e-6 {
                dateOn = true
                dateX = min(1, max(0, ((still ? tk : t) - d0) / max(0.1, d1 - d0 - 1 / Double(FPS))))
                dateOnly = tk >= d1 - 1e-6; dateEnd = d1
            }
        }
        if seqMode, !reelTried {
            reelTried = true
            var u = Bundle.main.url(forResource: "kickreel", withExtension: "mp4")
            if let e = ProcessInfo.processInfo.environment["KICKREEL"] { u = URL(fileURLWithPath: e) }
            if let u = u { let v = VideoSource(device: device); v.load([u]); if !v.clips.isEmpty { reel = v } }
        }
        if seqMode, P.seqVideo >= 0.5, let r = reel, let lastClap = track.cueClap.last?.t, let lastKick = track.cueKick.last?.t,
           let firstKick = track.cueKick.first(where: { $0.t > lastClap + 0.05 })?.t {
            let f0 = floor(firstKick * Double(FPS) + 1e-6) / Double(FPS)
            seqVideo = tk >= f0 - 1e-6 && tk < lastKick + P.seqVideoHold
            r.linearFrom = f0
        }
        // 通しの中ほど: クラップがいちばん長く抜ける区間(キックだけになる所。v9 では 147.0〜172.8 秒)は、タイポグラフィのパートにする。
        // クラップが抜けたあとの最初のキックのコマから、クラップが戻るコマの手前まで
        var typoMode = false, typoScene = 0, typoLogo = false, logoT = 0.0, typoEnd = Double.infinity
        if seqMode, P.seqTypo >= 0.5, track.cueClap.count > 2 {
            var g0 = 0.0, g1 = 0.0
            for (a, b) in zip(track.cueClap, track.cueClap.dropFirst()) where b.t - a.t > g1 - g0 { g0 = a.t; g1 = b.t }
            if g1 - g0 > 4, let k0t = track.cueKick.first(where: { $0.t > g0 + 0.05 })?.t {
                let f0 = Int(k0t * Double(FPS) + 1e-6), f1 = Int(g1 * Double(FPS) + 1e-6)
                typoMode = k >= f0 && k < f1
                typoEnd = Double(f1) / Double(FPS)
                let ks = track.cueKick.map { $0.t }.filter { $0 >= k0t - 0.01 && $0 < g1 }
                if P.seqLogo >= 0.5, let li = ks.firstIndex(where: { $0 >= P.logoFrom - 0.05 }) { logoT = floor(ks[li] * Double(FPS) + 1e-6) / Double(FPS) }
                if typoMode {
                    // 何回目のキックか。キックが鳴るコマで背景の色が替わる
                    let frameEnd = Double(k + 1) / Double(FPS)
                    var lo = 0, hi = ks.count
                    while lo < hi { let m = (lo + hi) / 2; if ks[m] < frameEnd { lo = m + 1 } else { hi = m } }
                    typoScene = max(0, lo - 1)
                    // 区間の後半、シンセパッドが入る所(logoFrom 秒あたりの最初のキック)からは、文字のかわりにロゴを置く。何回目かは、そこから数え直す
                    if P.seqLogo >= 0.5, let li = ks.firstIndex(where: { $0 >= P.logoFrom - 0.05 }), typoScene >= li {
                        typoLogo = true; typoScene -= li
                    }
                }
            }
        }
        // x-Music のロゴのうしろは、小田急のドラムセッションの動画(アプリの中の odakyu.mp4)を、ロゴが出た時刻から頭出しして流す
        if seqMode, P.logoVideo >= 0.5, !odakyuTried {
            odakyuTried = true
            var u = Bundle.main.url(forResource: "odakyu", withExtension: "mp4")
            if let e = ProcessInfo.processInfo.environment["ODAKYU"] { u = URL(fileURLWithPath: e) }
            if let u = u { let v = VideoSource(device: device); v.load([u]); if !v.clips.isEmpty { odakyu = v } }
        }
        let logoVideo = typoLogo && P.logoVideo >= 0.5 && odakyu != nil
        // ロゴが消えたあと(クラップが戻る所)も、同じ動画をそのまま流し続けて、エフェクトをかける
        let fxVideo = seqMode && P.seqFx >= 0.5 && P.logoVideo >= 0.5 && odakyu != nil && logoT > 0 && tk >= typoEnd - 1e-6 && tk < P.fxTo
        if logoVideo || fxVideo { odakyu?.linearFrom = logoT }
        // 金物が入る所(そのあたりの最初のキック)からは、キックごとに素材を順番に回す動画(前もって組んだ cyclereel.mp4)に替える
        var cycleNow = false
        if fxVideo, P.seqCycle >= 0.5 {
            if !cycleTried {
                cycleTried = true
                var u = Bundle.main.url(forResource: "cyclereel", withExtension: "mp4")
                if let e = ProcessInfo.processInfo.environment["CYCLEREEL"] { u = URL(fileURLWithPath: e) }
                if let u = u { let v = VideoSource(device: device); v.load([u]); if !v.clips.isEmpty { cycle = v } }
            }
            if let cy = cycle, let m0 = track.cueMetal.first(where: { $0.t >= typoEnd })?.t, let k0 = track.cueKick.first(where: { $0.t >= m0 - 0.05 })?.t {
                let c0 = floor(k0 * Double(FPS) + 1e-6) / Double(FPS)
                cy.linearFrom = c0
                cycleNow = tk >= c0 - 1e-6
            }
        }
        let videoMode = (P.mode >= 0.5 && P.mode < 1.5) || seqVideo || logoVideo || fxVideo
        let typoSim = typoMode && !logoVideo && P.typoSim >= 0.5        // ロゴのうしろに、ドラマーのモデルのシミュレーションをそのまま続けて映す
        let brainMode = (seqMode && !seqVideo && !fxVideo && !dateOnly && (!typoMode || typoSim)) || (P.mode >= 1.5 && P.mode < 2.5)   // 通しは、終盤の動画の区間のほかは脳のシーンの粒子で描く
        // 動画モードでは、面は出さず最初の線だけを重ねる(広がり 0、前進 0 と同じ扱い)
        let g = (videoMode || brainMode) ? 0 : (P.grow >= 0 ? P.grow : curve(GROW, tk))
        let half = 1 + g * JC                              // 中央から前後に見せる列数
        let dz = P.depth / Double(ROWS - 1)
        let pitch = max(-1.55, min(1.55, P.tilt * .pi / 180 * smooth(0, 0.08, g) + P.pitch))
        let fov = P.fov * .pi / 180
        let dist = P.zoom / tan(fov / 2)                   // 中央の列が画面の幅ちょうどになる距離
        let eye0 = SIMD3(dist * sin(P.yaw) * cos(pitch), dist * sin(pitch), dist * cos(P.yaw) * cos(pitch))
        // 前進: 高さはそのまま、水平に面の中心へ。向きは変えないので注視点も同じだけ動かす
        let dl = (videoMode || brainMode) ? 0 : (P.dolly >= 0 ? P.dolly : curve(dollyKeys(track), tk))
        let eye = SIMD3(eye0.x * (1 - dl), eye0.y, eye0.z * (1 - dl))
        let look = SIMD3(eye.x - eye0.x, 0, eye.z - eye0.z)
        let dcen = dist - dl * dist * cos(pitch) * cos(pitch)   // 視線方向に測った中心までの距離
        let reach = max(P.depth, 2 * aspect)
        let vp = perspective(fovy: fov, aspect: aspect, near: max(0.05, dist - reach - 3), far: dist + reach + 6)
            * lookAt(eye: eye, center: look, up: SIMD3(0, 1, 0))
        let amp = P.amp + (P.ampMesh - P.amp) * smooth(0, 0.3, g)
        let ymix = P.ymix * smooth(0, 0.3, g)
        if enterKey != dist { enterKey = dist; enterT = enterTime(dist: dist, keys: dollyKeys(track)) }
        let turn = (P.turn * smooth(0.02, P.turnEnd, g) + spinAt(tk, enter: enterT, spin: P.spin)) * .pi / 180
        let xs = max(1, Int(P.xs.rounded())), cols = Int((Double(S) / Double(xs)).rounded(.up))
        let row0 = max(0, Int((JC - half).rounded(.down))), row1 = min(ROWS - 1, Int((JC + half).rounded(.up)))
        let sc = Double(scale) * PX
        let r = max(P.depth * 0.5, aspect) * 0.8
        // タイトルが出ている間は、ほかの絵を出さない(タイトルが消えるのに合わせて現れる)
        let tShow = still ? tk : t
        let reveal = P.tTitle > 0.002 ? 1 - P.tBlack * (1 - smooth(P.tOut, P.tOut + max(0.1, P.tOutLen), tShow)) : 1.0
        let lb = (brainMode || typoMode || dateOnly) ? 0 : (videoMode ? P.vLine : 1 - smooth(0.02, P.lineEnd, g)) * reveal

        var u = Uniforms()
        u.vp = simd_float4x4(columns: (SIMD4<Float>(vp.columns.0), SIMD4<Float>(vp.columns.1), SIMD4<Float>(vp.columns.2), SIMD4<Float>(vp.columns.3)))
        u.a = SIMD4(Float(aspect), Float(amp), Float(dz), Float(ymix))
        // 広がっている間は端をぼかし、広がりきったらぼかさない(面が端まで同じ明るさの正方形になる)
        u.b = SIMD4(Float(turn), Float(half), Float(max(1, half * 0.15 * (1 - smooth(0.6, 1, g)))), Float(P.fog * smooth(0, 0.3, g)))
        u.c = SIMD4(Float(P.size * sc), Float(dcen - r), Float(dcen + r), Float((1 + (P.gain - 1) * smooth(0, 0.3, g)) * reveal))
        u.d = SIMD4(Float(Double(W) * sc), Float(Double(H) * sc), Float(P.width * sc), Float(lb))
        u.color = SIMD4(P.color, 1)
        // 波形メッシュ: ハイハットが鳴っている最中だけ赤くする(1 枚だけ取り出すときは、コマの終わりの時刻で見る)
        if !videoMode, !brainMode, P.hatRed >= 0.5, let hc = track.hatColor(still ? tk + 1 / Double(FPS) : t, len: P.bScanDur) { u.color = SIMD4(hc.fg, 1) }
        u.i = SIMD4(Int32(cols), Int32(xs), Int32(row0), 0)

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = scene
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        // 脳のシーン: 粒子を進めて、別の絵(明るさの上限なし)に描いておく
        var morphOut = 0.0, note = ""
        if brainMode || seqMode {                        // 通しのときは、切り替わりで待たせないよう先に用意しておく
            if brain == nil, !brainFailed {
                do {
                    guard let meshes = BrainScene.meshURLs() else { throw err("脳のメッシュ(lh-nih3d.stl / rh-nih3d.stl)が見つかりません") }
                    brain = try BrainScene(device: device, width: target.width, height: target.height, count: BRAIN_PARTICLES, meshes: meshes)
                } catch {
                    brainFailed = true
                    FileHandle.standardError.write("脳のシーンを作れません: \(error.localizedDescription)\n".data(using: .utf8)!)
                }
            }
            brain?.camFrom = seqMode ? cutT : -Double.infinity
            // 通し: 切り替わるまでは、同じ粒子を波形メッシュの形に並べて描く(脳のパートと同じ粒の見え方になる)。
            // 切り替わったコマからは、並べるのをやめるだけ。粒は持たされていた速さで弾け飛び、Curl noise の流れに乗る
            var wave: BrainScene.Wave? = nil
            if seqMode, !seqBrain {
                let gM = P.grow >= 0 ? P.grow : curve(GROW, tk)
                let dlM = P.dolly >= 0 ? P.dolly : curve(dollyKeys(track), tk)
                wave = BrainScene.Wave(amp: P.amp + (P.ampMesh - P.amp) * smooth(0, 0.3, gM), ymix: P.ymix * smooth(0, 0.3, gM),
                                       dz: P.depth / Double(ROWS - 1), half: 1 + gM * JC,
                                       zShift: (P.zoom / tan(P.fov * .pi / 360)) * dlM,      // 波形メッシュのカメラは前へ出ているので、そのぶん手前へ寄せる
                                       aspect: aspect, burst: P.seqBurst)
            }
            if brainMode || wave != nil, let b = brain { morphOut = b.encode(cb, time: still ? tk : t, fixedStep: still, track: track, params: P, heights: heights, scale: scale, wave: wave); note = b.camNote }
        }
        // 動画モード: 先に動画の絵を取ってくる(描画の命令を積む前に)
        var vtex: MTLTexture?, vu = VideoUniforms()
        var depthOut = 0.0, shakeOut = SIMD3<Double>()
        if videoMode, let v = (seqVideo ? reel : (cycleNow ? cycle : ((logoVideo || fxVideo) ? odakyu : video))) {
            let (tex, va) = still ? v.still(time: tk, track: track, params: P) : v.frame(time: t, playing: playing, track: track, params: P)
            let kick = Double(track.kick[min(k, track.kick.count - 1)])
            vtex = tex; note = v.note
            vu.a = SIMD4(Float(P.vWarpX), Float(P.vWarpY), Float(1 + P.vZoom * kick), Float(P.vShift * kick))
            vu.b = SIMD4(Float(P.vBright * (1 + P.vFlash * kick) * reveal), Float(P.vContrast), Float(P.vSat), Float(va))
            vu.c = SIMD4(Float(P.vPos), Float(aspect), 0, 0)
            vu.e = SIMD4(Float(P.vLifeDim), 0, 0, Float(P.vRDLift))
            // 反応拡散を出す量: 最初のキックが入った時刻から立ち上がる(手で決めることもできる)
            let rdStart = P.vRDStart >= 0 ? P.vRDStart : track.firstKick
            let rdMix = P.vRD >= 0 ? P.vRD : (P.vRDFade > 0.01 ? smooth(rdStart, rdStart + P.vRDFade, tk) : (tk >= rdStart ? 1 : 0))
            let rdOn = P.vRD >= 0 ? P.vRD > 0.001 : tk >= rdStart
            vu.f = SIMD4(Float(rdMix), 0, Float(P.vRDDark), Float(P.vRDEmboss))
            // 中へ入る深さ(階層)。カメラの動きは 30 コマ/秒に区切らず、いまの時刻 t でなめらかに出す
            // 階層どうしの大きさの比。中の世界は外の 1/128。入口はふつうの点の大きさ(半径 4〜5 ます)で、
            // それが画面を覆うまで寄る(横 960 ますなら 128 倍)と、中の世界がちょうど 1 倍になる
            let ratio = 128.0
            let tc = still ? tk : t
            let dive0 = rdStart + P.vDiveDelay
            var depth = P.vDepth >= 0 ? P.vDepth : 0
            if P.vDepth < 0, tc > dive0 {
                let boost = track.at(track.denseCum, tc) - track.at(track.denseCum, dive0)
                depth = ((tc - dive0) + P.vDiveBoost * boost) / max(0.1, P.vDiveSec)
            }
            if rdOn { depth += P.vDivePunch * track.at(track.kick, tc) } else { depth = 0 }   // 中へ入るのは反応拡散の中だけ
            vu.g = SIMD4(Float(depth), Float(ratio), Float(P.vHue), Float(P.vDiveTurn * .pi / 180))
            depthOut = depth
            // 手ブレ: いくつかの遅い揺れを重ねたもの。音量が上がると大きくなり、キックのたびに決まった向きへ小さく突かれる
            func sway(_ seed: Double) -> Double {
                let f = [0.37, 0.83, 1.31, 2.17, 3.43], a = [1.0, 0.6, 0.4, 0.22, 0.12]
                var v = 0.0
                for i in 0..<5 { v += a[i] * sin(2 * .pi * f[i] * tc + seed * Double(i + 1) * 1.7) }
                return v / 2.34
            }
            let amp = P.vShake * (0.25 + 1.2 * track.at(track.levelSmooth, tc))
            let hit = Double(track.lastHit[min(k, track.lastHit.count - 1)])
            let ang = (hit * 0.61803398875).truncatingRemainder(dividingBy: 1) * 2 * .pi
            let jolt = P.vShake * P.vShakeKick * track.at(track.kick, tc) * 0.006
            vu.h = SIMD4(Float(amp * 0.007 * sway(1.0) + jolt * cos(ang)), Float(amp * 0.016 * sway(2.3) + jolt * 2.5 * sin(ang)),
                         Float(amp * 0.010 * sway(4.1)), 0)
            shakeOut = SIMD3(Double(vu.h.x), Double(vu.h.y), Double(vu.h.z))
            // ライフゲーム: 反応拡散が始まるまで、動画の上に重ねる。世代は音量に合わせて進む
            let lifeAlpha = P.vLife * (1 - rdMix)
            // ライフゲームの間は、波形で絵をずらさない(反応拡散へ移るのに合わせて戻る)
            let warpK = Float(P.vLife > 0.001 ? rdMix : 1)
            vu.a.x *= warpK; vu.a.y *= warpK
            if lifeAlpha > 0.001 {
                let lc = max(64, min(1920, Int((P.vLifeCols / 16).rounded()) * 16)), lr = max(8, lc * H / W)
                if life.count != 2 || life[0].width != lc || life[0].height != lr {
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: lc, height: lr, mipmapped: false)
                    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
                    life = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
                    lifeValid = false
                }
                if life.count == 2 {
                    let lev = Double(track.levelSmooth[min(k, track.levelSmooth.count - 1)])
                    let on = Double(track.onset[min(k, track.onset.count - 1)])
                    var lu = LifeUniforms()
                    var gen = 0
                    func run(_ count: Int, clear: Bool, burst: Bool) {
                        for i in 0..<count {
                            func r(_ salt: Int) -> Float {             // コマと世代から決まる乱数(0..1)
                                var z = UInt64(truncatingIfNeeded: k &* 131 &+ gen &* 17 &+ salt) &* 0x9E3779B97F4A7C15
                                z = (z ^ (z >> 29)) &* 0xBF58476D1CE4E5B9; z ^= z >> 32
                                return Float(z % 100000) / 100000
                            }
                            lu.a = SIMD4(r(1) * 500, Float(P.vLifeWave * min(1, lev * 3)), Float(P.amp), 0.004)
                            // 音の立ち上がり(ドローンの中の粒など)のたびに、どこか1か所へまとめてまく
                            lu.b = (burst && i == 0) ? SIMD4(r(2) * Float(lc), r(3) * Float(lr), Float(4 + 26 * min(1, on * 2)), Float(0.45 * P.vLifeBurst))
                                                     : SIMD4(0, 0, 0, 0)
                            lu.c = SIMD4((clear && i == 0) ? 1 : 0, 0, 0, 0)
                            let pass = MTLRenderPassDescriptor()
                            pass.colorAttachments[0].texture = life[1 - lifeCur]
                            pass.colorAttachments[0].loadAction = .dontCare
                            pass.colorAttachments[0].storeAction = .store
                            guard let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
                            e.setRenderPipelineState(lifePipe)
                            e.setFragmentBytes(&lu, length: MemoryLayout<LifeUniforms>.stride, index: 2)
                            e.setFragmentTexture(life[lifeCur], index: 0)
                            e.setFragmentTexture(heights, index: 1)
                            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                            e.endEncoding()
                            lifeCur = 1 - lifeCur
                            gen += 1
                        }
                    }
                    if !lifeValid || k < lastLifeK || k > lastLifeK + 8 || jump {
                        run(1 + (jump ? 60 : 20), clear: true, burst: false)      // 離れた位置へ飛んだとき: 消して、少し進めた状態から
                        lifeValid = true; lifePhase = 0
                    } else if k > lastLifeK {
                        // 世代の進む速さ: 静かなときはゆっくり、音が大きいほど速く
                        lifePhase += Double(k - lastLifeK) * P.vLifeRate * (0.3 + 2.0 * lev) / Double(FPS)
                        var n = min(4, Int(lifePhase)); lifePhase -= Double(n)
                        let burst = on > 0.15 && P.vLifeBurst > 0
                        if burst && n == 0 { n = 1 }
                        run(n, clear: false, burst: burst)
                    }
                    lastLifeK = k
                    vu.d = SIMD4(Float(lifeAlpha), Float(P.vLifeGrid), Float(Double(W * scale) / Double(lc)), Float(P.vLifeLift))
                }
            } else {
                lifeValid = false
            }
            var vm: MTLTexture?
            if rdOn, k != lastMipK {
                // 動画を、縮小版つきの写しに取る
                if vmip == nil || vmip!.width != tex.width || vmip!.height != tex.height || vmip!.pixelFormat != tex.pixelFormat {
                    let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: tex.pixelFormat, width: tex.width, height: tex.height, mipmapped: true)
                    md.usage = [.shaderRead, .renderTarget]; md.storageMode = .private
                    vmip = device.makeTexture(descriptor: md)
                }
                if let m = vmip, let bl = cb.makeBlitCommandEncoder() {
                    bl.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                            sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1),
                            to: m, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    if m.mipmapLevelCount > 1 { bl.generateMipmaps(for: m) }
                    bl.endEncoding()
                    vm = m; lastMipK = k
                }
            }
            // 反応拡散を進める
            if rdOn {
                let rw = max(160, min(2560, Int((P.vRDSize / 16).rounded()) * 16)), rh = rw     // 正方形(端のない領域)。画面にはその中央の帯が出る
                if rd.count != 2 || rd[0].width != rw || rd[0].height != rh {
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: rw, height: rh, mipmapped: true)   // 縮小版つき(中の世界を小さく置くとき用)
                    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
                    rd = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
                    rdValid = false
                }
                if rd.count == 2, let vm = vm ?? vmip {
                    let iters = max(1, Int(P.vRDIters.rounded()))
                    var ru = RDUniforms()
                    ru.a = SIMD4(0.0367, 0.0649, 0.0545, 0.0620)      // 暗いところ: 分かれて増える点 / 明るいところ: 珊瑚のように伸びる筋
                    func run(_ count: Int, seed: Bool, inject: Double) {
                        for i in 0..<count {
                            // 中心の入口の半径: 中の世界(外の 1/ratio の大きさ)がすっぽり入る大きさ
                            // 入口の点が、ratio 倍に寄ったときに画面(横 rw ます、縦はその 9/32)の角まで覆う大きさ
                            let coreR = 0.5 * Double(rw) * (1 + pow(Double(H) / Double(W), 2)).squareRoot() / ratio * P.vCore
                            ru.b = SIMD4(i == 0 ? Float(inject) : 0, (seed && i == 0) ? 1 : 0, Float(k % 4096) * 0.37 + Float(i), Float(coreR))
                            let pass = MTLRenderPassDescriptor()
                            pass.colorAttachments[0].texture = rd[1 - rdCur]
                            pass.colorAttachments[0].loadAction = .dontCare
                            pass.colorAttachments[0].storeAction = .store
                            guard let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
                            e.setRenderPipelineState(rdPipe)
                            e.setFragmentBytes(&vu, length: MemoryLayout<VideoUniforms>.stride, index: 1)
                            e.setFragmentBytes(&ru, length: MemoryLayout<RDUniforms>.stride, index: 2)
                            e.setFragmentTexture(rd[rdCur], index: 0)
                            e.setFragmentTexture(vm, index: 1)
                            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                            e.endEncoding()
                            rdCur = 1 - rdCur
                        }
                    }
                    let startK = Int((rdStart * Double(FPS)).rounded())
                    if !rdValid || k < lastRDK || k > lastRDK + 8 || jump {
                        // 始まり、または離れた位置へ飛んだとき: 種をまき直す。始まりの瞬間以外は、少し育った状態から
                        let grown = (P.vRD >= 0 || k > startK + 2) ? (jump ? 700 : 300) : 0
                        run(1 + grown, seed: true, inject: 0)
                        rdValid = true
                    } else if k > lastRDK {
                        run((k - lastRDK) * iters, seed: false, inject: P.vRDInject * kick)
                    }
                    lastRDK = k
                    if rd[rdCur].mipmapLevelCount > 1, let bl = cb.makeBlitCommandEncoder() {
                        bl.generateMipmaps(for: rd[rdCur]); bl.endEncoding()
                    }
                }
            } else {
                rdValid = false
            }
        }
        // 動画のエフェクト: いまの絵を履歴に足し(コマが進んだときだけ)、いまかけるエフェクトを決める
        var fu = (a: SIMD4<Float>(), b: SIMD4<Float>(), c: SIMD4<Float>())
        if (fxVideo || logoVideo), let vtex = vtex {
            if ring == nil {
                let d = MTLTextureDescriptor()
                d.textureType = .type2DArray; d.pixelFormat = .rgba8Unorm; d.width = W / 2; d.height = H / 2; d.arrayLength = Renderer.RING
                d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
                ring = device.makeTexture(descriptor: d)
            }
            fu.b = SIMD4(vu.b.w, Float(aspect), Float(ringHead), Float(Renderer.RING))
            if let rg = ring, k != lastRingK {
                lastRingK = k; ringHead = (ringHead + 1) % Renderer.RING
                fu.b.z = Float(ringHead)
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = rg; rpd.colorAttachments[0].slice = ringHead
                rpd.colorAttachments[0].loadAction = .dontCare; rpd.colorAttachments[0].storeAction = .store
                if let re = cb.makeRenderCommandEncoder(descriptor: rpd) {
                    var f = fu
                    re.setRenderPipelineState(ringPipe)
                    re.setFragmentBytes(&f, length: MemoryLayout.stride(ofValue: f), index: 0)
                    re.setFragmentTexture(vtex, index: 0)
                    re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    re.endEncoding()
                }
            }
        }
        if fxVideo {
            // キック・クラップ・金物の時刻をひとまとめにした一覧。鳴るコマごとに、直前と違うエフェクトを選ぶ
            let key = "\(track.cueKick.count)|\(track.cueClap.count)|\(track.cueMetal.count)|\(typoEnd)|\(P.fxTo)|\(P.fxGrid)"
            if key != fxKey {
                fxKey = key
                var fs = Set<Int>()
                for lane in [track.cueKick, track.cueClap, track.cueMetal] { for c in lane where c.t >= typoEnd - 0.02 && c.t < P.fxTo { fs.insert(Int(c.t * Double(FPS) + 1e-6)) } }
                fxHits = fs
                // 音が鳴らないあいだも止まらないよう、16 分音符(0.1 秒 = 3 コマ)ごとにも切り替える
                if P.fxGrid >= 0.5 { var f = Int(typoEnd * Double(FPS) + 1e-6); let f1 = Int(P.fxTo * Double(FPS)); while f < f1 { fs.insert(f); f += 3 } }
                fxEvents = fs.sorted().map { Double($0) / Double(FPS) }
            }
            var lo = 0, hi = fxEvents.count
            while lo < hi { let m = (lo + hi) / 2; if fxEvents[m] <= tk + 1e-6 { lo = m + 1 } else { hi = m } }
            func pickFx(_ i: Int) -> Int {                 // 16 種類。スリットスキャン(0〜2)は多めに出す
                var r = SplitMix(s: UInt64(truncatingIfNeeded: i &* 9973 &+ 77))
                let v = Int(r.next() * 20)
                return v < 16 ? v : v - 16
            }
            var e = 0, r1 = 0.5, r2 = 0.5, age = 0.0, isHit = false
            if lo > 0 {
                e = pickFx(lo); if lo > 1, e == pickFx(lo - 1) { e = (e + 5) % 16 }
                var r = SplitMix(s: UInt64(truncatingIfNeeded: lo &* 31337 &+ 5)); r1 = r.next(); r2 = r.next()
                age = (still ? tk : t) - fxEvents[lo - 1]
                isHit = fxHits.contains(Int(fxEvents[lo - 1] * Double(FPS) + 1e-6))
                if !isHit { age += 0.05 }                  // 音が鳴っていない切り替えでは、強い乱れは出さない
            }
            fu.a = SIMD4(Float(e), Float(r1), Float(r2), Float(max(0, age)))
            fu.c = SIMD4(Float(still ? tk : t), Float(reveal), isHit ? 1 : 0, 0)
            note = (cycleNow ? "順番 " : "") + "エフェクト \(e)  " + ["スリット横", "スリット縦", "帯ノイズ", "色ずれ", "ブロック", "横線", "鏡", "モザイク", "2階調", "分割", "縦ずれ", "色替え", "止め絵", "横の筋", "寄り", "残像"][e]
        }
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return FrameInfo(k: k, g: g, dl: dl, note: note) }
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setVertexTexture(heights, index: 0)
        // ロゴのパート。うしろに別の絵(シミュレーションか動画)があるときは、ここではうしろだけを描き、ロゴは仕上げ(ブルーム)のあとで重ねる
        let logoOver = typoMode && (typoSim || logoVideo)
        if typoMode, !logoVideo {
            if typoSim {
                brain?.drawTone(enc, exposure: P.bExposure * reveal * P.typoSimDim, params: P, scale: scale)   // うしろはシミュレーション
                note = "ロゴ(うしろはモデル)"
            } else {
                if typo == nil { typo = Typo(device: device, width: W, height: H) }; typo?.scale = P.logoScale
                if let ty = typo {
                    enc.setRenderPipelineState(typoPipe)
                    enc.setFragmentTexture(ty.texture(scene: typoScene, logo: typoLogo), index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    note = "タイポ \(typoScene) 回目のキック " + ty.note
                }
            }
        } else if fxVideo {                                // エフェクトをかけた動画
            if let vtex = vtex, let rg = ring {
                var f = fu
                enc.setRenderPipelineState(fxPipe)
                enc.setFragmentBytes(&f, length: MemoryLayout.stride(ofValue: f), index: 0)
                enc.setFragmentTexture(vtex, index: 0); enc.setFragmentTexture(rg, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        } else if videoMode {
            if let vtex = vtex {                           // 動画の絵
                if seqVideo || logoVideo {                 // 通しの終盤とロゴのうしろ: 何も掛けない(ゆらし・寄り・色ずれ・明るさの変化・手ブレ・重ねる絵、すべてなし)
                    var plain = VideoUniforms()
                    plain.a = SIMD4(0, 0, 1, 0); plain.b = SIMD4(Float(reveal), 1, 1, vu.b.w); plain.c = vu.c
                    vu = plain
                }
                enc.setRenderPipelineState(vidPipe)
                enc.setFragmentBytes(&vu, length: MemoryLayout<VideoUniforms>.stride, index: 1)
                enc.setFragmentTexture((vmip != nil && vmip!.width == vtex.width && lastMipK == k) ? vmip! : vtex, index: 0)   // 縮小版つきの写しがあればそれを使う
                enc.setFragmentTexture(heights, index: 1)
                enc.setFragmentTexture(life.count == 2 ? life[lifeCur] : vtex, index: 2)
                enc.setFragmentTexture(rd.count == 2 ? rd[rdCur] : vtex, index: 3)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        } else if dateOnly {
            // 黒地のまま(日付は仕上げのあとで重ねる)
        } else if brainMode {
            brain?.drawTone(enc, exposure: P.bExposure * reveal, params: P, scale: scale)
        } else {
            enc.setRenderPipelineState(ptPipe)             // 頂点(点)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: (row1 - row0 + 1) * cols)
        }
        if lb > 0 {                                        // 中央の列の線(広がるにつれて消える)
            enc.setRenderPipelineState(lnPipe)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: S - 1)
        }
        // タイトル: ゆっくり浮かび上がって、ゆっくり消える(時刻はコマに区切らず、なめらかに)
        let tt = still ? tk : t
        let ta = P.tTitle * smooth(P.tIn, P.tIn + max(0.1, P.tInLen), tt) * (1 - smooth(P.tOut, P.tOut + max(0.1, P.tOutLen), tt))
        if ta > 0.002, let tex = titleTexture() {
            var tu = u
            tu.d.w = Float(ta)
            enc.setRenderPipelineState(titlePipe)
            enc.setFragmentBytes(&tu, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()

        // 仕上げ: キックでブルーム、クラップのコマで色を反転
        let tp = still ? tk + 1 / Double(FPS) : t       // 1枚だけ取り出すときは、そのコマの中で鳴るキックも入るようコマの終わりで見る
        let bloomAmt = max(0, P.bloomBase + P.bloom * track.kickPulse(tp, decay: P.bloomDecay)) * (brainMode ? P.bBloom : (fxVideo ? P.fxBloom : 1)) * ((seqVideo || (typoMode && !typoSim) || logoVideo || dateOnly) ? 0 : 1)
        let clap = track.clapIn(frame: k)
        var flashAmt = (clap > 0 && clap >= P.flashVel) ? P.flash : 0
        if seqVideo || typoMode || dateOnly { flashAmt = 0 }           // 終盤の動画とタイポグラフィには、反転もブルームも掛けない
        // 脳のシーンで、写真を出す区間のクラップは、色を反転しない(かわりに CT 画像が出る)
        if brainMode, P.bPhoto > 0.001, tk + 1 / Double(FPS) > P.photoFrom, tk < P.photoTo, !(seqMode && !seqBrain) { flashAmt = 0 }
        // 波形が赤くなっている間(ハイハットが鳴っている最中)だけ、背景を青にする
        let waveNow = (!videoMode && !brainMode && !typoMode) || (seqMode && !seqBrain)
        let hatBg = (waveNow && P.hatRed >= 0.5 && P.hatBlue > 0.001) ? track.hatColor(tp, len: P.bScanDur)?.bg : nil
        // キックとクラップの区間(脳のシーン): クラップが鳴った瞬間、画面の真ん中の細い帯を残して、その上下の画素を端まで引き伸ばす。
        // 帯はすぐに上下へ広がって、bStretchDur 秒で元の絵に戻る。帯の最初の細さは回ごとに変わる
        var stretch = SIMD3<Float>(0, 1, 0)
        if brainMode, P.bStretch >= 0.5, tk + 1 / Double(FPS) > P.bDissolveFrom, tk < P.bDissolveTo, !(seqMode && !seqBrain) {
            var lo = 0, hi = track.cueClap.count
            let frameEnd = Double(k + 1) / Double(FPS)
            while lo < hi { let m = (lo + hi) / 2; if track.cueClap[m].t < frameEnd { lo = m + 1 } else { hi = m } }
            if lo > 0, track.cueClap[lo - 1].t >= P.bDissolveFrom - 0.05 {
                let c0 = floor(track.cueClap[lo - 1].t * Double(FPS) + 1e-6) / Double(FPS)
                let x = ((still ? tk : t) - c0) / max(0.03, P.bStretchDur)
                if x >= 0, x < 1 {
                    var r = SplitMix(s: UInt64(truncatingIfNeeded: lo &* 7717 &+ 3))
                    let h0 = 0.02 + 0.16 * r.next(), cy = 0.5 + (r.next() - 0.5) * 0.12      // 帯の最初の半分の高さと、中心の位置
                    let half = h0 + (0.62 - h0) * x * x                                      // はじめゆっくり、あとは速く広がる
                    stretch = SIMD3(Float(max(0, cy - half)), Float(min(1, cy + half)), 1)
                }
            }
        }
        // ハイハットのスキャンの区間のキック: 画面の真ん中の縦の帯を残して、その左右の画素を端まで引き伸ばす(脳の左右に、横の筋が走る)
        var stretchX = SIMD3<Float>(0, 1, 0)
        if brainMode, P.bStretchKick >= 0.5, tk + 1 / Double(FPS) > P.bStretchKickFrom, tk < P.bStretchKickTo, !(seqMode && !seqBrain) {
            var lo = 0, hi = track.cueKick.count
            let frameEnd = Double(k + 1) / Double(FPS)
            while lo < hi { let m = (lo + hi) / 2; if track.cueKick[m].t < frameEnd { lo = m + 1 } else { hi = m } }
            if lo > 0, track.cueKick[lo - 1].t >= P.bStretchKickFrom - 0.05 {
                let c0 = floor(track.cueKick[lo - 1].t * Double(FPS) + 1e-6) / Double(FPS)
                let x = ((still ? tk : t) - c0) / max(0.03, P.bStretchKickDur)
                if x >= 0, x < 1 {
                    var r = SplitMix(s: UInt64(truncatingIfNeeded: lo &* 9151 &+ 11))
                    let w0 = 0.01 + 0.07 * r.next(), cx = 0.5 + (r.next() - 0.5) * 0.08      // 帯の最初の半分の幅(画面は横長なので、縦より細く)と、中心の位置
                    let half = w0 + (0.60 - w0) * x * x
                    stretchX = SIMD3(Float(max(0, cx - half)), Float(min(1, cx + half)), 1)
                }
            }
        }
        post(cb, bloom: bloomAmt, flash: flashAmt, bg: hatBg.map { $0 * Float(P.hatBlue * reveal) } ?? SIMD3<Float>(0, 0, 0), stretch: stretch, stretchX: stretchX)
        // 終盤のキックのパート: 画面の中央に、細い文字の日付を重ねる。パートの頭で 2016/04/01、終わりで 2026/11/22 になるよう、一定の速さで数える。
        // パートが終わったあとは、黒地にその日付だけを残す
        if dateOn {
            if stamp == nil { stamp = DateStamp(device: device, width: W, height: H) }
            let op = MTLRenderPassDescriptor()
            op.colorAttachments[0].texture = target
            op.colorAttachments[0].loadAction = .load; op.colorAttachments[0].storeAction = .store
            if let st = stamp, let oe = cb.makeRenderCommandEncoder(descriptor: op) {
                // 今日の日付が出てから dateGlowAfter 秒たったら、日付が消えていき、かわりに中央のぼやけた淡い光が浮かぶ(ディゾルブ)
                let gx = smooth(dateEnd + P.dateGlowAfter, dateEnd + P.dateGlowAfter + max(0.1, P.dateGlowLen), still ? tk : t)
                var dk = SIMD4<Float>(Float(1 - gx), Float(gx * P.dateGlow), Float(Double(W) / Double(H)), 0)
                endFade = gx                               // 音も同じ割合で下げる(再生側が読む)
                oe.setRenderPipelineState(datePipe)
                oe.setFragmentBytes(&dk, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                oe.setFragmentTexture(st.texture(progress: dateX), index: 0)
                oe.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                oe.endEncoding()
                note += "  " + st.text
            }
        }
        // ロゴと名前は、ブルームを掛け終わった絵の上に重ねる(ロゴ自体は光らせない)
        if logoOver {
            if typo == nil { typo = Typo(device: device, width: W, height: H) }; typo?.scale = P.logoScale
            let op = MTLRenderPassDescriptor()
            op.colorAttachments[0].texture = target
            op.colorAttachments[0].loadAction = .load; op.colorAttachments[0].storeAction = .store
            if let ty = typo, let oe = cb.makeRenderCommandEncoder(descriptor: op) {
                oe.setRenderPipelineState(typoOverPipe)
                oe.setFragmentTexture(ty.texture(scene: typoScene, logo: typoLogo, clear: true), index: 0)
                oe.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                oe.endEncoding()
            }
        }
        return FrameInfo(k: k, g: g, dl: dl, note: note, depth: depthOut, shake: shakeOut, bloom: bloomAmt, flash: flashAmt, morph: morphOut)
    }

    /// scene にブルームと反転を掛けて target に描く
    private func post(_ cb: MTLCommandBuffer, bloom: Double, flash: Double, bg: SIMD3<Float>, stretch: SIMD3<Float> = SIMD3(0, 1, 0), stretchX: SIMD3<Float> = SIMD3(0, 1, 0)) {
        let P = params
        func pass(_ pipe: MTLRenderPipelineState, to dst: MTLTexture, from src: [MTLTexture], _ pu: PostUniforms) {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = dst
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
            var u = pu
            enc.setRenderPipelineState(pipe)
            enc.setFragmentBytes(&u, length: MemoryLayout<PostUniforms>.stride, index: 0)
            for (i, t) in src.enumerated() { enc.setFragmentTexture(t, index: i) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        func texel(_ t: MTLTexture) -> SIMD2<Float> { SIMD2(1 / Float(t.width), 1 / Float(t.height)) }
        if bloom > 0.0005 {
            let size = Float(max(0.1, P.bloomSize) * PX)
            for (i, lv) in glow.enumerated() {
                if i == 0 {
                    let px = texel(scene)
                    pass(brightPipe, to: lv[0], from: [scene], PostUniforms(a: SIMD4(px.x, px.y, Float(P.bloomThresh), 0)))
                } else {
                    let px = texel(glow[i - 1][0])
                    pass(downPipe, to: lv[0], from: [glow[i - 1][0]], PostUniforms(a: SIMD4(px.x, px.y, 0, 0)))
                }
                let px = texel(lv[0])
                pass(blurPipe, to: lv[1], from: [lv[0]], PostUniforms(a: SIMD4(px.x * size, 0, 0, 0)))
                pass(blurPipe, to: lv[0], from: [lv[1]], PostUniforms(a: SIMD4(0, px.y * size, 0, 0)))
            }
        }
        pass(postPipe, to: target, from: [scene, glow[0][0], glow[1][0], glow[2][0]],
             PostUniforms(a: SIMD4(0, 0, 0, bg.x), b: SIMD4(Float(bloom), Float(flash), bg.y, bg.z), c: SIMD4(stretch.x, stretch.y, stretch.z, 0), d: SIMD4(stretchX.x, stretchX.y, stretchX.z, 0)))
    }

    /// タイトルの文字を、描く先と同じ大きさの白黒の絵にする(文字や大きさが変わったときだけ作り直す)
    private func titleTexture() -> MTLTexture? {
        let P = params
        let key = "\(P.titleLine1)|\(P.titleLine2)|\(P.tSize)|\(P.tTrack)"
        if key == titleKey { return titleTex }
        titleKey = key
        let w = target.width, h = target.height, sc = CGFloat(scale) * CGFloat(UNIT) / 540   // 16:9 では、画面の高さに見合うよう少し大きく
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            func line(_ text: String, size: CGFloat, track: CGFloat, centerY: CGFloat) {
                let font = CTFontCreateWithName("Futura-Medium" as CFString, size, nil)
                let attrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTKernAttributeName as String): track * size,
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
                let ln = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
                let width = CGFloat(CTLineGetTypographicBounds(ln, nil, nil, nil)) - track * size      // 最後の字のうしろの字間は数えない
                let cap = CTFontGetCapHeight(font)
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.textPosition = CGPoint(x: (CGFloat(w) - width) / 2, y: centerY - cap / 2)
                CTLineDraw(ln, ctx)
            }
            // 2行: 名前を大きく、その下に小さく。全体が画面の上下の中央に来るように置く(座標は左下が原点)
            let s1 = CGFloat(P.tSize) * sc, s2 = s1 * 0.5, gap = s1 * 0.62
            let mid = CGFloat(h) / 2
            if P.titleLine2.isEmpty {
                line(P.titleLine1, size: s1, track: CGFloat(P.tTrack), centerY: mid)
            } else {
                line(P.titleLine1, size: s1, track: CGFloat(P.tTrack), centerY: mid + gap * 0.5 + s2 * 0.18)
                line(P.titleLine2, size: s2, track: CGFloat(P.tTrack) * 1.6, centerY: mid - gap * 0.5 - s1 * 0.18)
            }
            return true
        }
        guard ok else { titleTex = nil; return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: d) else { titleTex = nil; return nil }
        // CGContext は下の行が先頭ではなく、上の行から並ぶ(行 0 = 絵のいちばん上)ので、そのまま渡せる
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: w)
        titleTex = tex
        return tex
    }

    /// target を画面(drawable)へ、32:9 を保って写す
    func blit(_ cb: MTLCommandBuffer, to pass: MTLRenderPassDescriptor, drawableSize: CGSize) {
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let dw = Double(drawableSize.width), dh = Double(drawableSize.height)
        let aspect = Double(W) / Double(H)
        var vw = dw, vh = dw / aspect
        if vh > dh { vh = dh; vw = dh * aspect }
        enc.setViewport(MTLViewport(originX: (dw - vw) / 2, originY: (dh - vh) / 2, width: vw, height: vh, znear: 0, zfar: 1))
        enc.setRenderPipelineState(blitPipe)
        enc.setFragmentTexture(target, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// 頭から frames コマを順に描いて、1 コマずつ生の画素(RGBA、上の行から)を渡す。動画への書き出し用。
    /// 再生と同じく前のコマの続きとして描くので、粒子の動きも通しで正しく出る
    func exportFrames(_ frames: Int, _ put: (UnsafeRawPointer, Int) -> Void, progress: (Int) -> Void) throws {
        let w = target.width, h = target.height
        guard let buf = device.makeBuffer(length: w * h * 4, options: .storageModeShared) else { throw err("書き出しの準備に失敗") }
        for k in 0..<frames {
            try autoreleasepool {
                guard let cb = queue.makeCommandBuffer() else { throw err("書き出しの準備に失敗") }
                encode(cb, time: (Double(k) + 0.25) / Double(FPS), still: true, continuous: k > 0)
                guard let bl = cb.makeBlitCommandEncoder() else { throw err("書き出しの準備に失敗") }
                bl.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                        destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
                bl.endEncoding()
                cb.commit(); cb.waitUntilCompleted()
                if let e = cb.error { throw e }
                put(UnsafeRawPointer(buf.contents()), w * h * 4)
                if k % 300 == 0 { progress(k) }
            }
        }
    }

    /// 時刻 t の絵を PNG に書き出す(確認用)
    /// warm: その秒数だけ前から 1コマずつ進めてから書き出す(色の追従や反応拡散を、再生中と同じ状態にする)
    func shot(time t: Double, to url: URL, warm: Double = 0) throws -> FrameInfo {
        let w = target.width, h = target.height
        if warm > 0 {
            var first = true
            var tt = max(0, t - warm)
            while tt < t - 0.5 / Double(FPS) {
                guard let c = queue.makeCommandBuffer() else { break }
                encode(c, time: tt, still: true, continuous: !first)
                c.commit(); c.waitUntilCompleted()
                first = false; tt += 1 / Double(FPS)
            }
        }
        guard let cb = queue.makeCommandBuffer(), let buf = device.makeBuffer(length: w * h * 4, options: .storageModeShared) else { throw err("書き出しの準備に失敗") }
        let info = encode(cb, time: t, still: true, continuous: warm > 0)
        guard let bl = cb.makeBlitCommandEncoder() else { throw err("書き出しの準備に失敗") }
        bl.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        bl.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        if let e = cb.error { throw e }
        let data = Data(bytes: buf.contents(), count: w * h * 4) as CFData
        guard let prov = CGDataProvider(data: data),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw err("PNG を作れません") }
        CGImageDestinationAddImage(dst, img, nil)
        if !CGImageDestinationFinalize(dst) { throw err("PNG を書けません: \(url.path)") }
        return info
    }
}

func err(_ s: String) -> NSError {
    NSError(domain: "WaveMesh", code: 1, userInfo: [NSLocalizedDescriptionKey: s])
}
