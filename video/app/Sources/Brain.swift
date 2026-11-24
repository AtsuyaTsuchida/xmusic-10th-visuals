import Metal
import simd
import Foundation
import CoreGraphics
import ImageIO
import CoreText

// 脳のシーン(モード 3): 3次元の空間を Curl noise の流れで漂う粒子が、脳の表面に集まっていく。
//   - 粒子の動きは GPU(コンピュートシェーダー)で毎コマ計算する。粒子ごとに位置と速度を持つ。
//   - 流れ = 4 段重ねたノイズを「回転(curl)」にしたもの(湧き出しも吸い込みもない流れ = 煙のように渦を巻く)
//           + ノイズの面へ寄せる力(粒子が膜や筋にまとまる)
//   - 粒子ごとに、脳の表面の行き先(面積に比例してまいた点)と、その場所の面の向きを持つ。
//     「脳になる量」が上がると、粒子は順番に(場所ごとにずれて)行き先へ引かれ、渦を巻きながら着く。
//   - 着いた粒子は、手前の面に隠れるものを描かず、面の向きで陰影をつける(しわが見える)。
//   - 音: キックで流れが強まり、脳の表面の粒子が外へ跳ねる。いまの波形で表面が細かく波打つ。

var BRAIN_PARTICLES = 1 << 22        // 粒子の数(--particles で変えられる)

/// シェーダーに渡す値(float4 単位。Metal 側の BU と同じ並び)
struct BrainUniforms {
    var vp = matrix_identity_float4x4
    var rot0 = SIMD4<Float>(), rot1 = SIMD4<Float>(), rot2 = SIMD4<Float>()   // 脳を回す行列(列)
    var a = SIMD4<Float>()      // 1歩の時間, 流れの時刻, 脳になる量, キック
    var b = SIMD4<Float>()      // 流れの速さ, ノイズの細かさ, ノイズの変わる速さ, 膜にまとまる強さ
    var c = SIMD4<Float>()      // キックで流れが強まる量, キックで外へ跳ねる量, 波形で波打つ量, 脳の大きさ
    var d = SIMD4<Float>()      // 漂う範囲(箱の半分の大きさ x, y, z), 粒子ごとの移り変わりの幅
    var e = SIMD4<Float>()      // 点の大きさ(px), 基準の距離, 漂う粒子の明るさ, 脳の粒子の明るさ
    var f = SIMD4<Float>()      // 視点 x, y, z, 隠す側の点の大きさ(px)
    var g = SIMD4<Float>()      // 光の向き x, y, z, 奥行きの比較で手前へ寄せる量
    var h = SIMD4<Float>()      // 引き寄せる強さ, 漂うときの抵抗, 着いたあとの抵抗, 波形の点数
    var s = SIMD4<Float>()      // スキャン: 面の高さ, 帯が光る強さ, 帯の幅, 脳の粒を描く割合
    var w = SIMD4<Float>()      // 波形に並べる: 1 = 並べる, 波の高さ, 奥行きの波の強さ, 列の間隔
    var mz = SIMD4<Float>()     // 面で描く脳: 出す量(0 = 粒子だけ, 1 = 面), 音で膨らむ量, 細かい凸凹の量, 0
    var w2 = SIMD4<Float>()     // 波形に並べる: 見せる列数(片側), 手前へ寄せる量, 画面の横幅の半分, 離したときに弾け飛ぶ速さ
    var color = SIMD4<Float>()
}

func brainShaderSource() -> String {
    return """
#include <metal_stdlib>
using namespace metal;
struct BU { float4x4 vp; float4 rot0; float4 rot1; float4 rot2; float4 a; float4 b; float4 c; float4 d; float4 e; float4 f; float4 g; float4 h; float4 s; float4 w; float4 mz; float4 w2; float4 color; };

// 格子点 → 0..1 の乱数
static float hash31(float3 p) {
    int3 i = int3(p);
    uint h = uint(i.x) * 0x8da6b343u ^ uint(i.y) * 0xd8163841u ^ uint(i.z) * 0xcb1ab31fu;
    h ^= h >> 15; h *= 0x2c1b3c6du; h ^= h >> 12; h *= 0x297a2d39u; h ^= h >> 15;
    return float(h >> 8) * (1.0 / 16777216.0);
}
// なめらかなノイズ(-1..1)と、その傾き(式で直接求める)。返り値 = (値, d/dx, d/dy, d/dz)
static float4 noised(float3 x) {
    float3 p = floor(x), w = x - p;
    float3 u = w * w * w * (w * (w * 6.0 - 15.0) + 10.0);
    float3 du = 30.0 * w * w * (w * (w - 2.0) + 1.0);
    float a = hash31(p), b = hash31(p + float3(1, 0, 0)), c = hash31(p + float3(0, 1, 0)), d = hash31(p + float3(1, 1, 0));
    float e = hash31(p + float3(0, 0, 1)), f = hash31(p + float3(1, 0, 1)), g = hash31(p + float3(0, 1, 1)), h = hash31(p + float3(1, 1, 1));
    float k0 = a, k1 = b - a, k2 = c - a, k3 = e - a;
    float k4 = a - b - c + d, k5 = a - c - e + g, k6 = a - b - e + f, k7 = -a + b + c - d + e - f - g + h;
    return float4(-1.0 + 2.0 * (k0 + k1 * u.x + k2 * u.y + k3 * u.z + k4 * u.x * u.y + k5 * u.y * u.z + k6 * u.z * u.x + k7 * u.x * u.y * u.z),
                  2.0 * du * float3(k1 + k4 * u.y + k6 * u.z + k7 * u.y * u.z,
                                    k2 + k5 * u.z + k4 * u.x + k7 * u.z * u.x,
                                    k3 + k6 * u.x + k5 * u.y + k7 * u.x * u.y));
}
// Curl noise: 3 つのノイズを成分にした場の「回転」。4 段(だんだん細かく、向きを変えて)重ねる。
// 回転をとった流れは、粒子をどこにも溜めず、どこからも湧かせない(渦だけが残る)
static float3 curlNoise(float3 p, float t) {
    const float3x3 R = float3x3(float3(0.00, 0.80, 0.60), float3(-0.80, 0.36, -0.48), float3(-0.60, -0.48, 0.64));
    float3x3 M = float3x3(float3(1, 0, 0), float3(0, 1, 0), float3(0, 0, 1));
    float3 v = float3(0.0);
    float amp = 1.0;
    for (int o = 0; o < 4; o++) {
        float3 q = M * p;
        float tt = t * (1.0 + 0.6 * float(o));
        float4 n1 = noised(q + float3(17.3, 0.0, tt));
        float4 n2 = noised(q + float3(0.0, 41.7 + tt, 9.1));
        float4 n3 = noised(q + float3(5.2 + tt, 73.1, 31.4));
        float3 g1 = n1.yzw * M, g2 = n2.yzw * M, g3 = n3.yzw * M;      // 傾きを元の座標へ戻す
        v += amp * float3(g3.y - g2.z, g1.z - g3.x, g2.x - g1.y);
        M = 2.0 * (R * M);
        amp *= 0.45;
    }
    return v;
}

// 粒子を 1 歩進める
kernel void brain_step(device float4 *pos [[buffer(0)]], device float4 *vel [[buffer(1)]],
                       const device float4 *tgt [[buffer(2)]], const device float4 *nrm [[buffer(3)]],
                       constant BU &u [[buffer(4)]], texture2d<float, access::read> hts [[texture(0)]],
                       uint id [[thread_position_in_grid]]) {
    // 波形に並べる(通しのモードの前半): 粒を波形メッシュの面の上に置く。高さ = 横の波 X + 奥行きの波 Y(波形メッシュと同じ式)。
    // 粒ごとに決まった場所(横の位置と列)へ毎コマ置き直し、離されたときのための速さ(ばらばらの向き)も持たせておく
    if (u.w.x > 0.5 && u.w.x < 1.5) {
        float3 key = float3(float(id & 0xffffu), float(id >> 16), 1.0);
        float r1 = hash31(key), r2 = hash31(key + float3(0, 0, 1)), r3 = hash31(key + float3(0, 0, 2));
        float r4 = hash31(key + float3(0, 0, 3)), r5 = hash31(key + float3(0, 0, 4));
        int SS = int(u.h.w);
        int si = clamp(int(r1 * float(SS - 1) + 0.5), 0, SS - 1);
        int j = clamp(int(200.0 + (r2 * 2.0 - 1.0) * u.w2.x + 0.5), 0, 400);           // 列は 401 本、中央が 200
        float hh = hts.read(uint2(uint(si), 0)).r + u.w.z * hts.read(uint2(uint(j), 1)).r;
        float3 q = float3((float(si) / float(SS - 1) * 2.0 - 1.0) * u.w2.z, hh * u.w.y, (200.0 - float(j)) * u.w.w + u.w2.y);
        float3 d = normalize(float3(r3, r4, r5) * 2.0 - 1.0 + 1e-4);
        float sp = u.w2.w * (0.15 + 1.85 * r2 * r2);                                   // 速く飛ぶのは一部の粒だけ
        pos[id] = float4(q + d * 0.004, pos[id].w);
        vel[id] = float4(d.x * sp * 0.6, d.y * sp * 1.4, d.z * sp, 0.0);
        return;
    }
    // ドラマーの両手協調のモデル(Fujii, Kudo, Ohtsuki, Oda 2010 の式(6))。粒子 1 個が、相対位相 φ の時系列 1 本。
    //   dφ/dt = −a sin φ − 2b sin 2φ − c sin(φ − ψ) + Δω + d cos φ + √Q ξ   (a = 1, b = 0, c = 2, ψ = 180°, d = kΔω)
    // 置き場所は、横 = φ(0〜360°)、奥行き = Δω(粒子ごとに決まった値)、高さ = ポテンシャル V(φ)(式(A2))。
    // 谷(φ = 180° のあたり)に粒がたまり、Δω が大きい側では谷が消えて、粒が坂を流れ落ち続ける(位相の迷走)
    if (u.w.x > 1.5) {
        float3 key = float3(float(id & 0xffffu), float(id >> 16), 9.0);
        float uu = hash31(key);
        float4 st = vel[id];
        bool has = st.z < -700.0;                                   // すでにこのモデルの状態を持っているか
        float phi = has ? st.x : hash31(key + float3(0, 0, 1)) * 6.2831853;
        float heat = has ? st.y : 0.0;
        float dw = uu * u.w2.y, k = u.w2.z, sig = u.w2.w;
        for (int s = 0; s < 6; s++) {
            float base = u.w2.x * 6.0 + float(s);
            float r1 = max(1e-6, hash31(float3(key.x, key.y, base * 2.0 + 50.0))), r2 = hash31(float3(key.x, key.y, base * 2.0 + 51.0));
            float g = sqrt(-2.0 * log(r1)) * cos(6.2831853 * r2);
            float f = -sin(phi) - 2.0 * sin(phi - 3.14159265) + dw + k * dw * cos(phi);
            phi += f * 0.01 + sig * 0.1 * g;
            if (phi >= 6.2831853) { phi -= 6.2831853; heat = 1.0; }
            else if (phi < 0.0) { phi += 6.2831853; heat = 1.0; }
            heat *= 0.9965;                                   // 迷走の印(赤)は 2 時間単位ほどで半分になる
        }
        float V = -cos(phi) - 2.0 * cos(phi - 3.14159265) - k * dw * sin(phi) - dw * phi;
        // φ = 0 の縁を高さ 0 にそろえる
        float3 dst = float3((phi / 6.2831853 - 0.5) * u.w.z, u.w.y * (V - 1.0), (uu - 0.5) * u.w.w);
        // 入った直後は、いまいる場所(Curl noise の雲)から行き先へ、目で追える速さで寄っていく(u.a.w = 1 歩で縮める割合)。そのあとは行き先にぴったり置く
        pos[id] = float4(u.a.z >= 0.999 ? dst : mix(pos[id].xyz, dst, u.a.w), pos[id].w);     // 元の地形アプリと同じ置き方(Δω が大きい行ほど右下がりの坂)
        vel[id] = float4(phi, heat, -777.0, 0.0);
        return;
    }
    float3 p = pos[id].xyz, v = vel[id].xyz;
    if (vel[id].z < -700.0) v = float3(0.0);                        // モデルの状態が残っていたら、止まった所から流れに乗せる
    float dt = u.a.x, t = u.a.y, kick = u.a.w;
    float rnd = tgt[id].w, delay = nrm[id].w;
    // この粒子が脳へ向かう度合い(0 = 漂う, 1 = 脳)。粒子ごとに始まりがずれている
    float mi = smoothstep(delay, delay + u.d.w, u.a.z);
    float3x3 R = float3x3(u.rot0.xyz, u.rot1.xyz, u.rot2.xyz);
    float3 n = R * nrm[id].xyz;
    float3 q = R * tgt[id].xyz * u.c.w;
    // 音: キックで外へ跳ねる(大きく跳ねるのは一部の粒子だけ)。いまの波形で、高さごとに表面が波打つ
    float pop = rnd * rnd; pop *= pop;
    int S = int(u.h.w);
    float wave = hts.read(uint2(uint(clamp(int((tgt[id].y * 0.72 + 0.5) * float(S)), 0, S - 1)), 0)).r;
    q += n * (u.c.y * kick * (0.12 + 0.88 * pop) + u.c.z * wave);

    // 流れ: Curl noise + ノイズの面へ寄せる力(粒子が膜や筋にまとまる)
    float3 fp = p * u.b.y;
    float3 fl = curlNoise(fp, t * u.b.z) * u.b.x * (1.0 + u.c.x * kick);
    float4 sh = noised(fp * 0.8 + float3(31.0, t * u.b.z * 0.5, 7.0));
    fl -= u.b.w * sh.x * sh.yzw;
    fl -= 2.5 * max(abs(p) - u.d.xyz, 0.0) * sign(p);        // 漂う範囲の外へ出たら引き戻す

    // 脳に着いた粒子には、表面に沿った流れだけを少し残す(止まりきらず、表面がゆらぐ)
    float3 along = fl - n * dot(n, fl);
    float3 want = mix(fl, along * 0.10, mi);
    float drag = mix(u.h.y, u.h.z, mi);
    float3 acc = drag * (want - v) + u.h.x * mi * mi * (q - p);
    v += acc * dt;
    p += v * dt;
    // 着いた度合い(描くときの陰影と、隠す・隠さないに使う)
    float arr = mi * (1.0 - smoothstep(0.03, 0.30, length(q - p)));
    pos[id] = float4(p, pos[id].w);
    vel[id] = float4(v, arr);
}

struct BOut { float4 pos [[position]]; float size [[point_size]]; float3 col; };
// 奥行きを Metal の範囲(0..1)にした値
static float depth01(float4 c) { return (c.z + c.w) * 0.5 / c.w; }

// 着いた粒子を、奥行きだけ先に描く(うしろの粒子を隠すため)。
// 置く場所は粒子のいまの位置ではなく、行き先(跳ねたり波打ったりする前の表面)。少し奥へ下げて、表面の粒子自身は隠さない
vertex BOut brain_occ_vs(uint vid [[vertex_id]], const device float4 *pos [[buffer(0)]], const device float4 *vel [[buffer(1)]],
                         const device float4 *tgt [[buffer(2)]], constant BU &u [[buffer(4)]]) {
    BOut o; o.col = float3(0.0);
    // 隠す側は粒子の半分で足りる(面はそれでも埋まる)。四角のまま描く(丸く切り抜くより軽い)
    if (vel[vid].w < 0.72 || (vid & 1u) != 0u) { o.pos = float4(2.0, 2.0, 2.0, 1.0); o.size = 1.0; return o; }
    float3x3 R = float3x3(u.rot0.xyz, u.rot1.xyz, u.rot2.xyz);
    float3 q = R * tgt[vid].xyz * u.c.w;
    q -= normalize(u.f.xyz - q) * u.g.w * 0.5;
    float4 cp = u.vp * float4(q, 1.0);
    cp.z = depth01(cp) * cp.w;
    o.pos = cp; o.size = max(2.0, u.f.w * u.e.y / cp.w);
    return o;
}
fragment float4 brain_occ_fs(BOut in [[stage_in]]) {
    return float4(0.0);
}

// 粒子を光の点として足し込む
vertex BOut brain_vs(uint vid [[vertex_id]], const device float4 *pos [[buffer(0)]], const device float4 *vel [[buffer(1)]],
                     const device float4 *nrm [[buffer(3)]], constant BU &u [[buffer(4)]]) {
    BOut o;
    float3 p = pos[vid].xyz;
    float arr = vel[vid].w;
    float4 cp = u.vp * float4(p, 1.0);
    float3x3 R = float3x3(u.rot0.xyz, u.rot1.xyz, u.rot2.xyz);
    float3 n = R * nrm[vid].xyz;
    float3 toEye = normalize(u.f.xyz - p);
    // 脳の粒子: 面の向きで陰影(光の当たる面は明るく、ふちは淡く光る)
    float lit = max(dot(n, u.g.xyz), 0.0);
    float rim = 1.0 - abs(dot(n, toEye));
    float shade = 0.07 + 0.9 * lit * lit + 0.45 * rim * rim * rim;
    // 漂う粒子: 速いものほど明るい。奥のものは少し暗い
    float speed = length(vel[vid].xyz);
    float cloud = u.e.z * (0.30 + 0.70 * saturate(speed / max(1e-3, u.b.x * 1.6))) * mix(1.0, 0.45, saturate((cp.w - u.e.y) / u.d.z * 0.5 + 0.5));
    if (u.w.x > 1.5) {      // モデルの地形: 迷走した(360° を越えた)直後の粒を明るくする。360° → 0° に戻る両端は薄くして、飛びを目立たせない
        float phi = vel[vid].x;
        cloud = mix(cloud, u.e.z * 0.30 * (1.0 + 3.0 * saturate(vel[vid].y)) * smoothstep(0.0, 0.14, phi) * smoothstep(0.0, 0.14, 6.2831853 - phi), u.a.z);
    }
    // 脳へ向かっている途中の粒子は明るくする(集まっていく筋が見える)
    float mi = smoothstep(nrm[vid].w, nrm[vid].w + u.d.w, u.a.z);
    cloud *= 1.0 + 1.0 * mi * (1.0 - arr);
    // 脳に着いた粒子は、一部だけを残して描く(面ではなく、1 粒ずつ見える粒の集まりにする)。残した粒は、減らしたぶんを少し明るくする
    float keep = max(u.s.w, 0.002);
    float h = fract(float(vid) * 0.6180339887 + pos[vid].w * 7.31);
    float shown = h < keep ? 0.5 / sqrt(keep) : 0.0;    // 全部は取り戻さない(隠さずに描くので、手前と奥の粒が重なって明るくなるぶんを引く)
    float b = mix(cloud, u.e.w * shade * shown * (1.0 - u.mz.x), arr);     // 面で描いている間は、脳に着いた粒は出さない
    // スキャン: 面が通っている高さの粒子が、帯になって光る
    float sd = (p.y - u.s.x) / u.s.z;
    b *= 1.0 + u.s.y * exp(-sd * sd);
    // 大きさは遠いほど小さく。1px より小さくなるぶんは明るさで合わせる
    float s = u.e.x * u.e.y / cp.w, sz = max(s, 1.0);
    b *= (s * s) / (sz * sz);
    // 奥行きの比較では少し手前へ寄せる(表面の粒子が、自分のまわりの面に隠されないように)
    float4 cb = u.vp * float4(p + toEye * u.g.w, 1.0);
    cp.z = depth01(cb) * cp.w;
    float3 tint = u.color.rgb;
    if (u.w.x > 1.5) {      // 元の地形アプリと同じ色: 落ち着いている粒は青、迷走した直後の粒は桃色がかった赤
        tint = mix(tint, mix(float3(0.20, 0.62, 1.00), float3(1.00, 0.32, 0.50), saturate(vel[vid].y)), u.a.z);
    }
    o.pos = cp; o.size = sz + 1.0; o.col = tint * b;
    return o;
}
fragment float4 brain_fs(BOut in [[stage_in]], float2 pc [[point_coord]]) {
    float d = length(pc - 0.5) * 2.0;
    float a = exp(-d * d * 3.2) * (1.0 - smoothstep(0.75, 1.0, d));
    return float4(in.col * a, 1.0);
}

// 脳を、粒子ではなく「面」で描く(3DCG らしい、陰影のついた立体)。頂点 = メッシュの三角形の角、面の向きはなめらかにつないである。
// 音に合わせて、面の向き(外向き)へ膨らむ
struct SOut { float4 pos [[position]]; float3 n; float3 w; float lift; };
vertex SOut brain_solid_vs(uint vid [[vertex_id]], const device float4 *vp [[buffer(0)]], const device float4 *vn [[buffer(1)]], constant BU &u [[buffer(4)]]) {
    float3x3 R = float3x3(u.rot0.xyz, u.rot1.xyz, u.rot2.xyz);
    float3 p0 = vp[vid].xyz, n = R * vn[vid].xyz;
    // 膨らみ: 全体が外へふくらむ + 場所ごとのむら(しわの山がより出る)
    float bump = noised(p0 * 9.0 + float3(0.0, u.a.y * 0.8, 0.0)).x;
    float lift = u.mz.y * (0.75 + 0.25 * bump) + u.mz.z * bump;
    float3 w = R * p0 * u.c.w * (1.0 + u.mz.y * 0.35) + n * lift;
    float4 cp = u.vp * float4(w, 1.0);
    cp.z = depth01(cp) * cp.w;
    SOut o; o.pos = cp; o.n = n; o.w = w; o.lift = u.mz.y;
    return o;
}
fragment float4 brain_solid_fs(SOut in [[stage_in]], constant BU &u [[buffer(4)]]) {
    float3 n = normalize(in.n), v = normalize(u.f.xyz - in.w), l = normalize(u.g.xyz);
    if (dot(n, v) < 0.0) n = -n;
    float diff = max(dot(n, l), 0.0);
    float fill = max(dot(n, normalize(float3(0.6, -0.2, 0.5))), 0.0);          // 反対側からの弱い光
    float spec = pow(max(dot(n, normalize(l + v)), 0.0), 48.0);
    float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0);
    float3 base = float3(0.80, 0.78, 0.76);                                      // わずかに温かい灰色
    float3 c = base * (0.06 + 0.95 * diff + 0.16 * fill) + float3(0.55) * spec + float3(0.30, 0.34, 0.42) * rim;
    c *= 1.0 + 1.6 * in.lift;                                                    // 膨らんだ瞬間は、少し明るくなる
    // スキャン: 面が通っている高さが帯になって光る
    float sd = (in.w.y - u.s.x) / max(u.s.z, 0.005);
    c += float3(0.9, 0.95, 1.0) * min(u.s.y, 3.0) * exp(-sd * sd);
    return float4(c * u.mz.x * 0.62, 1.0);                                      // キックのブルームが乗っても白く飛ばない明るさ
}

// 線分(マス目の面と、原点の赤い線)。両端のあいだを、画面の上で太さのある四角にして描く
// seg[2i] = (始点 xyz, 明るさ)、seg[2i+1] = (終点 xyz, 色: 0 = 絵の色, 1 = 赤)。k = (画面の幅 px, 高さ px, 線の太さ px, 0)
struct LOut { float4 pos [[position]]; float2 uv; float len; float hw; float3 col; };
vertex LOut brain_line_vs(uint vid [[vertex_id]], uint iid [[instance_id]], const device float4 *seg [[buffer(0)]],
                          constant BU &u [[buffer(4)]], constant float4 &k [[buffer(5)]]) {
    LOut o; o.uv = float2(0.0); o.len = 0.0; o.hw = 1.0; o.col = float3(0.0);
    float4 A = seg[2 * iid], B = seg[2 * iid + 1];
    float4 ca = u.vp * float4(A.xyz, 1.0), cb = u.vp * float4(B.xyz, 1.0);
    // 視点のうしろへ回る線は、視点の少し手前で切る
    const float nearW = 0.25;
    if (ca.w < nearW && cb.w < nearW) { o.pos = float4(2.0, 2.0, 2.0, 1.0); return o; }
    if (ca.w < nearW) ca = mix(ca, cb, (nearW - ca.w) / (cb.w - ca.w));
    else if (cb.w < nearW) cb = mix(cb, ca, (nearW - cb.w) / (ca.w - cb.w));
    float2 hres = k.xy * 0.5;
    float2 sa = ca.xy / ca.w * hres, sb = cb.xy / cb.w * hres;
    float2 dd = sb - sa; float len = length(dd);
    float2 dir = len > 1e-4 ? dd / len : float2(1.0, 0.0), n = float2(-dir.y, dir.x);
    float e = float(vid >> 1), s = float(vid & 1) * 2.0 - 1.0;
    float hw = k.z * 0.5 + 1.0;
    float uu = mix(-hw, len + hw, e);
    float tt = clamp(uu / max(len, 1e-4), 0.0, 1.0);
    // 奥行き(0..1)は画面の上ではまっすぐ変わるので、両端のあいだをそのままとる
    o.pos = float4((sa + dir * uu + n * s * hw) / hres, mix(depth01(ca), depth01(cb), tt), 1.0);
    o.uv = float2(uu, s * hw); o.len = len; o.hw = k.z * 0.5;
    // 遠い所は暗くする(奥で線が込み合って白く固まらないように)
    float far = mix(ca.w, cb.w, tt);
    float fade = mix(1.0, 0.18, saturate((far - u.e.y * 0.6) / (u.e.y * 1.6)));
    o.col = (B.w > 0.5 ? float3(1.0, 0.05, 0.03) : mix(u.color.rgb, float3(1.0), k.w) * fade) * A.w;     // k.w = 1 なら、粒子の色に関係なく白い線
    return o;
}
fragment float4 brain_line_fs(LOut in [[stage_in]]) {
    float dx = max(max(-in.uv.x, in.uv.x - in.len), 0.0);
    float a = clamp(in.hw + 0.5 - length(float2(dx, in.uv.y)), 0.0, 1.0);
    return float4(in.col * a, a);
}

// 神経細胞の網: 脳の中の点どうしをつなぐ、ゆるく曲がった線。脳と一緒に回る。
// seg[2i] = (始点 xyz(脳の座標), 伸びる順番 0..1)、seg[2i+1] = (終点 xyz, 線ごとの乱数)
// k = (画面の幅 px, 高さ px, 線の太さ px, 伸びた量 0..1)、k2 = (明るさ, 時刻, キック, 0)
struct NOut { float4 pos [[position]]; float2 uv; float len; float hw; float3 col; };
vertex NOut brain_neuro_vs(uint vid [[vertex_id]], uint iid [[instance_id]], const device float4 *seg [[buffer(0)]],
                           constant BU &u [[buffer(4)]], constant float4 &k [[buffer(5)]], constant float4 &k2 [[buffer(6)]]) {
    NOut o; o.uv = float2(0.0); o.len = 0.0; o.hw = 1.0; o.col = float3(0.0);
    float4 A = seg[2 * iid], B = seg[2 * iid + 1];
    float grown = k.w * 1.08 - A.w;                      // この線まで伸びてきたか
    if (grown <= 0.0) { o.pos = float4(2.0, 2.0, 2.0, 1.0); return o; }
    float3x3 R = float3x3(u.rot0.xyz, u.rot1.xyz, u.rot2.xyz);
    float4 ca = u.vp * float4(R * A.xyz * u.c.w, 1.0), cb = u.vp * float4(R * B.xyz * u.c.w, 1.0);
    if (ca.w < 0.25 || cb.w < 0.25) { o.pos = float4(2.0, 2.0, 2.0, 1.0); return o; }
    float2 hres = k.xy * 0.5;
    float2 sa = ca.xy / ca.w * hres, sb = cb.xy / cb.w * hres;
    float2 dd = sb - sa; float len = length(dd);
    float2 dir = len > 1e-4 ? dd / len : float2(1.0, 0.0), n = float2(-dir.y, dir.x);
    float e = float(vid >> 1), s = float(vid & 1) * 2.0 - 1.0;
    float hw = k.z * 0.5 + 1.0;
    float uu = mix(-hw, len + hw, e);
    o.pos = float4((sa + dir * uu + n * s * hw) / hres, 0.5, 1.0);
    o.uv = float2(uu, s * hw); o.len = len; o.hw = k.z * 0.5;
    // 伸びていく先端は強く光る。伸びきったあとは、信号が線の上を走る(キックで強まる)
    float tip = exp(-grown * 40.0);
    float sig = pow(0.5 + 0.5 * sin(A.w * 90.0 - k2.y * 5.0 + B.w * 6.283), 12.0);
    o.col = u.color.rgb * k2.x * (0.35 + 4.0 * tip + sig * (1.2 + 3.0 * k2.z));
    return o;
}
fragment float4 brain_neuro_fs(NOut in [[stage_in]]) {
    float dx = max(max(-in.uv.x, in.uv.x - in.len), 0.0);
    float a = clamp(in.hw + 0.5 - length(float2(dx, in.uv.y)), 0.0, 1.0);
    return float4(in.col * a, a);
}

// スキャンの高さに置く CT 画像(頭の輪切り)。脳と一緒に回る水平な四角に貼る。黒い所は透ける
// k = (高さ, 四角の半分の幅 x, 半分の奥行き z, 何枚目か(小数は前後 2 枚を混ぜる))、k2 = (濃さ, 0, 0, 0)
struct COut { float4 pos [[position]]; float2 uv; };
vertex COut brain_ct_vs(uint vid [[vertex_id]], constant BU &u [[buffer(4)]], constant float4 &k [[buffer(5)]]) {
    float sx = float(vid & 1) * 2.0 - 1.0, sz = float(vid >> 1) * 2.0 - 1.0;
    float3x3 R = float3x3(u.rot0.xyz, u.rot1.xyz, u.rot2.xyz);
    // 画像の中で、頭の中心は画像の中心より少し左・下(後ろ)にある。それが脳のモデルの中心に来るようにずらす
    float4 cp = u.vp * float4(R * float3((sx + 0.02) * k.y, k.x, (sz - 0.114) * k.z), 1.0);
    cp.z = depth01(cp) * cp.w;
    COut o; o.pos = cp;
    o.uv = float2(0.5 - 0.5 * sx, 0.5 + 0.5 * sz);       // 画像の上 = 顔の側(脳の前)、画像の左 = 体の右
    return o;
}
fragment float4 brain_ct_fs(COut in [[stage_in]], texture2d_array<float> ct [[texture(0)]], constant float4 &k [[buffer(5)]], constant float4 &k2 [[buffer(6)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float n = float(ct.get_array_size());
    float f = clamp(k.w, 0.0, n - 1.0), i0 = floor(f);
    float v = mix(ct.sample(s, in.uv, uint(i0)).r, ct.sample(s, in.uv, uint(min(i0 + 1.0, n - 1.0))).r, f - i0);
    float a = smoothstep(0.03, 0.25, v) * k2.x;
    return float4(float3(v) * a, a);
}

// 画面の上に重ねる CT 画像(クラップで出す写真、スキャン中に両脇へ出す連番)。黒い所は透けるので、黒い枠は出ない。
// a = (中心 x, 中心 y(画面の端が ±1), 半分の幅, 半分の高さ(画面の高さの半分を 1 として))
// b = (回す角度 rad, 何枚目か(小数は前後 2 枚を混ぜる), 濃さ, 画面の横縦比)
// c = (画像のうち出す範囲の中心 x, y, 半分の幅, 半分の高さ(画像全体が 0..1))
struct IU { float4 a; float4 b; float4 c; };
struct IOut { float4 pos [[position]]; float2 uv; };
vertex IOut brain_img_vs(uint vid [[vertex_id]], constant IU &u [[buffer(0)]]) {
    float sx = float(vid & 1) * 2.0 - 1.0, sy = float(vid >> 1) * 2.0 - 1.0;
    float2 l = float2(sx * u.a.z, sy * u.a.w);
    float cs = cos(u.b.x), sn = sin(u.b.x);
    float2 r = float2(cs * l.x - sn * l.y, sn * l.x + cs * l.y);
    IOut o; o.pos = float4(u.a.x + r.x / u.b.w, u.a.y + r.y, 0.0, 1.0);
    o.uv = u.c.xy + float2(sx, -sy) * u.c.zw;
    return o;
}
fragment float4 brain_img_fs(IOut in [[stage_in]], texture2d_array<float> ct [[texture(0)]], constant IU &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    if (in.uv.x < 0.0 || in.uv.x > 1.0 || in.uv.y < 0.0 || in.uv.y > 1.0) discard_fragment();
    float n = float(ct.get_array_size());
    float f = clamp(u.b.y, 0.0, n - 1.0), i0 = floor(f);
    float v = mix(ct.sample(s, in.uv, uint(i0)).r, ct.sample(s, in.uv, uint(min(i0 + 1.0, n - 1.0))).r, f - i0);
    float a = smoothstep(0.03, 0.22, v) * u.b.z;
    return float4(float3(v) * a * 0.62, a);          // 少し暗めに出す(キックのブルームが乗っても白く飛びにくいように)
}

// 画面全体を CT 画像のますで埋める(クラップの写真)。うしろの絵は出さない。ますの形に合わせて画像を切り出すので、すき間はできない
// a = (ますの横の数, 縦の数, 何枚目から, ますが 1 つ進むごとに何枚進むか)、b = (再生で進んだ枚数, ますごとの再生のずれ, 寄せる倍率, 切り出す中心の縦位置)
// c = (画面の横縦比, 画像の横縦比, 使う範囲の最初の番号, 使う範囲の枚数)
struct TOut { float4 pos [[position]]; float2 uv; };
struct MU { float4 a; float4 b; float4 c; };
// 文字を描いた絵(数式)を、そのまま上に重ねる
fragment float4 brain_eq_fs(TOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant float4 &k [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return t.sample(s, in.uv) * k.x;
}
fragment float4 brain_mosaic_fs(TOut in [[stage_in]], texture2d_array<float> ct [[texture(0)]], constant MU &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 g = u.a.xy;
    float2 cell = floor(in.uv * g), l = fract(in.uv * g) - 0.5;
    float ca = (u.c.x / g.x) * g.y, r = u.c.y;                           // ますの横縦比、画像の横縦比
    float2 h = ca > r ? float2(1.0, r / ca) : float2(ca / r, 1.0);       // ますを埋めるのに使う、画像の幅と高さの割合
    float2 uv = float2(0.5, u.b.w) + l * h / u.b.z;
    float idx = cell.y * g.x + cell.x;
    float f = fmod(u.a.z + idx * u.a.w + u.b.x + idx * u.b.y, u.c.w);
    if (f < 0.0) f += u.c.w;
    float i0 = floor(f), i1 = fmod(i0 + 1.0, u.c.w);
    float v = mix(ct.sample(s, uv, uint(u.c.z + i0)).r, ct.sample(s, uv, uint(u.c.z + i1)).r, f - i0);
    return float4(float3(v) * 0.72, 1.0);
}

// 足し込んだ明るさ(上限なし)を、白く飛びすぎないように 0..1 へ収めて写す
vertex TOut brain_tone_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    TOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0 - p.y);
    return o;
}
fragment float4 brain_tone_fs(TOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant float4 &k [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = t.sample(s, in.uv).rgb * k.x;
    return float4(1.0 - exp(-c), 1.0);
}
"""
}

/// 決まった種から同じ乱数列を出す(毎回同じ絵になるように)
struct SplitMix {
    var s: UInt64
    mutating func next() -> Double {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) * (1.0 / 9007199254740992.0)
    }
}

/// バイナリの STL を読む。三角形ごとに頂点 3 つ(mm)
func loadSTL(_ url: URL) throws -> [SIMD3<Float>] {
    let d = try Data(contentsOf: url, options: .mappedIfSafe)
    guard d.count >= 84 else { throw err("STL が短すぎます: \(url.lastPathComponent)") }
    let n = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) })
    guard d.count >= 84 + n * 50 else { throw err("STL の長さが合いません: \(url.lastPathComponent)") }
    var out = [SIMD3<Float>](); out.reserveCapacity(n * 3)
    d.withUnsafeBytes { raw in
        for i in 0..<n {
            let base = 84 + i * 50 + 12                     // 先頭 12 バイトは面の向き(使わない)
            for k in 0..<3 {
                let o = base + k * 12
                out.append(SIMD3(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                 raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                 raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)))
            }
        }
    }
    return out
}

final class BrainScene {
    static let MM = 92.5                 // 1 単位(画面の高さの半分)にあたる mm。脳の高さが画面の 6〜7 割になる
    // 粒子が漂う範囲(箱の半分の大きさ)。32:9 では横長、16:9 では画面の形に合わせて、引いたカメラに全体が収まる大きさにする
    static let BOX = WIDE ? SIMD3<Float>(3.5, 1.05, 1.5) : SIMD3<Float>(2.3, 1.15, 1.5)
    let count: Int
    let triangles: Int
    private let device: MTLDevice
    private let pos: MTLBuffer, vel: MTLBuffer, tgt: MTLBuffer, nrm: MTLBuffer
    let hdr: MTLTexture                  // 粒子を足し込む先(明るさの上限なし)
    private let depth: MTLTexture
    private let stepPipe: MTLComputePipelineState
    private let occPipe: MTLRenderPipelineState, ptPipe: MTLRenderPipelineState, tonePipe: MTLRenderPipelineState
    private let linePipe: MTLRenderPipelineState
    private let redPipe: MTLRenderPipelineState      // 赤い線は、仕上がった絵の上に重ねて描く(光として足すと、白い脳の上で見えなくなる)
    private var lastU = BrainUniforms(), lastGrid = 0, lastRed = 0
    private let ctPipe: MTLRenderPipelineState
    private let neuroPipe: MTLRenderPipelineState
    private var neuro: MTLBuffer?, neuroCount = 0        // 神経細胞の網の線分
    private var neuroKey = "", neuroStart = Double.infinity   // 伸び始める時刻(脳が完成したあとの最初のキック)
    private var ctStacks: [MTLTexture?] = [nil, nil, nil]   // CT の連番を重ねた絵: 0 = 横断(頭のてっぺん → あご), 1 = 冠状断(顔 → 後頭部), 2 = 矢状断(片側 → 反対側)
    private var ctTex: MTLTexture? { ctStacks[0] }
    static let CT_ASPECT: [Double] = [352.0 / 456, 348.0 / 426, 470.0 / 430]          // 各連番の画像の横縦比
    static let CT_RANGE: [ClosedRange<Int>] = [3...30, 8...50, 6...34]                // 脳がしっかり写っている番号の範囲(0 始まり)
    struct ImgU { var a = SIMD4<Float>(), b = SIMD4<Float>(), c = SIMD4<Float>() }
    private var overlays: [(u: ImgU, stack: Int)] = []     // このコマで画面に重ねる CT 画像
    private let imgPipe: MTLRenderPipelineState
    private let mosaicPipe: MTLRenderPipelineState
    private let eqPipe: MTLRenderPipelineState
    private let solidPipe: MTLRenderPipelineState
    private var meshPos: MTLBuffer?, meshNrm: MTLBuffer?, meshCount = 0     // 面で描くときの頂点(三角形ごとに 3 つ)と、なめらかにつないだ面の向き
    private var eqTex: MTLTexture?       // 論文の数式を描いた絵(初めて使うときに作る)
    private var modelNow = false         // いま、ドラマーのモデルの地形を描いているか
    private var modelStep = 0
    private var tintNow = 0.0            // いま粒子に色がついている度合い
    private var modelBlend = 0.0         // モデルへ入りきった度合い(0 → 1 を 0.3 秒で)
    struct MosaicU { var a = SIMD4<Float>(), b = SIMD4<Float>(), c = SIMD4<Float>() }
    private var mosaic: (u: MosaicU, stack: Int)? = nil    // このコマで画面を埋める CT(クラップの写真)。nil なら出さない
    // クラップで出す写真: 鳴る時刻、出しておく秒数、どの連番の何枚目か、出し方(0..6)、ばらつきの乱数
    private var photos: [(t: Double, life: Double, stack: Int, slice: Int, style: Int, r1: Double, r2: Double)] = []
    private var photoKey = "", photoNote = ""
    private var lastCT = SIMD4<Float>(), lastCTAlpha: Float = 0
    static let CT_TOP = 3.0, CT_BOTTOM = 30.0            // 脳のてっぺんと底にあたる輪切りの番号(0 始まり。一覧の絵を見て決めた)
    // CT 画像 1 枚を置く大きさの半分。画像の中の頭の輪郭(幅 約 293 画素・前後 約 386 画素)が、脳のメッシュの輪郭(幅 128mm・前後 178mm)にそろうように決めた
    // (画像全体は 幅 154mm、前後 210mm)。輪郭どうしをそろえるので、画像の中の脳は、モデルよりひと回り小さく写る
    static let CT_HALF = SIMD2<Double>(153.8 / 2 / MM, 210.3 / 2 / MM)
    static let TINT = SIMD3<Float>(0.25, 0.80, 1.00)     // キックとクラップの区間の粒子の色(水色)
    private let alwaysDS: MTLDepthStencilState
    private let segs: MTLBuffer          // マス目と赤い線の線分(毎コマ書き直す)
    static let GRID_CELLS = 20           // マス目の数(1 辺あたり)
    static let SCAN_CELLS = 12           // スキャンの面のマス目の数
    static let MAX_SEGS = 3 * 2 * (GRID_CELLS + 1) + 2 * (SCAN_CELLS + 1) + 3 + 700
    private let occDS: MTLDepthStencilState, ptDS: MTLDepthStencilState
    private var lastT = -Double.infinity
    private var simT = 0.0               // 流れの時刻(止めている間は進まない)
    private(set) var steps = 0
    var camFrom = -Double.infinity       // カメラの動き・構図の切り替えを数え始める時刻(通しのモードでは、波形から切り替わった時刻)。それまでは正面・標準のまま
    private var fadeIn = 1.0             // 切り替わった直後に、手ブレ・マス目・赤い線をなだらかに入れるための係数

    /// 粒子を、与えられた点(切り替わる瞬間の波形メッシュの点)の上に置き直し、ばらばらの向きへ弾き出す。
    /// このあとは Curl noise の流れに乗る(波形が発散して、雲になっていく)
    func seed(from pts: [SIMD3<Float>], burst: Float) {
        guard !pts.isEmpty else { return }
        let P = pos.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let V = vel.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        var s: UInt32 = 0x9E3779B9
        func rnd() -> Float { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return Float(s >> 8) * (1.0 / 16777216.0) }
        let n = Float(pts.count)
        for i in 0..<count {
            let q = pts[min(pts.count - 1, Int(rnd() * n))]
            var d = SIMD3<Float>(rnd() * 2 - 1, rnd() * 2 - 1, rnd() * 2 - 1)
            d = d / max(1e-4, simd_length(d))
            let r = rnd(), sp = burst * (0.15 + 1.85 * r * r)             // 速く飛ぶのは一部の粒だけ
            P[i] = SIMD4(q + d * 0.004, P[i].w)
            V[i] = SIMD4(d.x * sp * 0.6, d.y * sp * 1.4, d.z * sp, 0)    // 面の上下へ多めに散る
        }
        steps = max(steps, 1)                                             // 先に漂わせる下ごしらえはしない(置いた形がくずれる)
        lastT = -Double.infinity
    }

    /// 脳のメッシュ(左右の半球)の場所。アプリの中 → 開発中の置き場所 の順に探す
    static func meshURLs() -> [URL]? {
        let names = ["lh-nih3d", "rh-nih3d"]
        let inApp = names.compactMap { Bundle.main.url(forResource: $0, withExtension: "stl") }
        if inApp.count == 2 { return inApp }
        if let dir = ProcessInfo.processInfo.environment["BRAIN_MESH_DIR"] {
            let u = names.map { URL(fileURLWithPath: dir).appendingPathComponent($0 + ".stl") }
            if u.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { return u }
        }
        return nil
    }

    init(device: MTLDevice, width: Int, height: Int, count: Int, meshes: [URL]) throws {
        self.device = device; self.count = count
        // ---- 脳の表面に、面積に比例して点をまく ----
        var tris: [SIMD3<Float>] = []
        for u in meshes { tris += try loadSTL(u) }
        let nt = tris.count / 3
        guard nt > 0 else { throw err("脳のメッシュが空です") }
        triangles = nt
        var lo = tris[0], hi = tris[0]
        for v in tris { lo = simd_min(lo, v); hi = simd_max(hi, v) }
        let center = (lo + hi) * 0.5, ext = hi - lo
        var cum = [Double](repeating: 0, count: nt)
        var total = 0.0
        for i in 0..<nt {
            let a = tris[3 * i], b = tris[3 * i + 1], c = tris[3 * i + 2]
            total += Double(simd_length(simd_cross(b - a, c - a))) * 0.5
            cum[i] = total
        }
        let len = count * MemoryLayout<SIMD4<Float>>.stride
        guard let pb = device.makeBuffer(length: len, options: .storageModeShared), let vb = device.makeBuffer(length: len, options: .storageModeShared),
              let tb = device.makeBuffer(length: len, options: .storageModeShared), let nb = device.makeBuffer(length: len, options: .storageModeShared) else {
            throw err("粒子の置き場所を作れません")
        }
        pos = pb; vel = vb; tgt = tb; nrm = nb
        // 面で描くときの頂点。同じ位置の頂点どうしで面の向きを足し合わせて、なめらかな陰影にする(三角形ごとの向きのままだと、角ばって見える)
        do {
            let inv0 = Float(1 / BrainScene.MM)
            var acc = [SIMD3<Float>](repeating: .zero, count: tris.count)
            var index = [SIMD3<Int32>: Int32](minimumCapacity: tris.count / 5)
            var ids = [Int32](repeating: 0, count: tris.count)
            var sums: [SIMD3<Float>] = []
            for i in 0..<(tris.count / 3) {
                let a = tris[3 * i], b = tris[3 * i + 1], c = tris[3 * i + 2]
                let fn = simd_cross(b - a, c - a)                    // 長さ = 面積の 2 倍(大きい面ほど重く足す)
                for k in 0..<3 {
                    let v = tris[3 * i + k]
                    let key = SIMD3<Int32>(Int32((v.x * 200).rounded()), Int32((v.y * 200).rounded()), Int32((v.z * 200).rounded()))
                    var id = index[key] ?? -1
                    if id < 0 { id = Int32(sums.count); index[key] = id; sums.append(.zero) }
                    sums[Int(id)] += fn; ids[3 * i + k] = id
                }
            }
            _ = acc; acc = []
            let len2 = tris.count * MemoryLayout<SIMD4<Float>>.stride
            if let mp = device.makeBuffer(length: len2, options: .storageModeShared), let mn = device.makeBuffer(length: len2, options: .storageModeShared) {
                let MP = mp.contents().bindMemory(to: SIMD4<Float>.self, capacity: tris.count)
                let MN = mn.contents().bindMemory(to: SIMD4<Float>.self, capacity: tris.count)
                for i in 0..<tris.count {
                    let m = tris[i] - center, s = sums[Int(ids[i])]
                    let nn = s / max(1e-12, simd_length(s))
                    MP[i] = SIMD4(m.x * inv0, m.z * inv0, -m.y * inv0, 1)   // 粒子の行き先と同じ向きの付け替え(x → 右, 上 → 上, 前 → 奥)
                    MN[i] = SIMD4(nn.x, nn.z, -nn.y, 0)
                }
                meshPos = mp; meshNrm = mn; meshCount = tris.count
            }
        }
        let P = pb.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let V = vb.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let T = tb.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let N = nb.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        var rng = SplitMix(s: 7)
        let inv = Float(1 / BrainScene.MM), box = BrainScene.BOX
        let width01 = Float(BrainScene.SPREAD)
        tris.withUnsafeBufferPointer { tp in
            cum.withUnsafeBufferPointer { cp in
                for i in 0..<count {
                    let r = rng.next() * total
                    var a = 0, b = nt - 1
                    while a < b { let m = (a + b) / 2; if cp[m] < r { a = m + 1 } else { b = m } }
                    let v0 = tp[3 * a], v1 = tp[3 * a + 1], v2 = tp[3 * a + 2]
                    var u = Float(rng.next()), w = Float(rng.next())
                    if u + w > 1 { u = 1 - u; w = 1 - w }
                    let m = v0 + (v1 - v0) * u + (v2 - v0) * w - center             // mm、脳の中心が原点。x 右, y 前, z 上
                    let cr = simd_cross(v1 - v0, v2 - v0)
                    let nn = cr / max(1e-12, simd_length(cr))
                    let rnd = Float(rng.next())
                    // 脳へ向かい始める順番: うしろから前へ + 場所ごとのむら + 粒子ごとのばらつき
                    let sweep = m.y / ext.y + 0.5
                    let k: Float = 0.045
                    let patch = 0.5 + 0.25 * (sin(m.x * k * 1.3 + m.z * k * 0.7) * sin(m.y * k + 1.7) + sin(m.x * k * 2.9 - m.y * k * 2.1 + m.z * k * 2.4 + 0.4))
                    let order = min(1, max(0, 0.45 * sweep + 0.35 * patch + 0.20 * Float(rng.next())))
                    // 画面の向きへ: x → 右, z(上) → 上, y(前) → 奥
                    T[i] = SIMD4(m.x * inv, m.z * inv, -m.y * inv, rnd)
                    N[i] = SIMD4(nn.x, nn.z, -nn.y, order * (1 - width01))
                    P[i] = SIMD4((Float(rng.next()) * 2 - 1) * box.x, (Float(rng.next()) * 2 - 1) * box.y, (Float(rng.next()) * 2 - 1) * box.z, rnd)
                    V[i] = SIMD4(0, 0, 0, 0)
                }
            }
        }

        // ---- 描く先とシェーダー ----
        let hd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        hd.usage = [.renderTarget, .shaderRead]; hd.storageMode = .private
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        dd.usage = [.renderTarget]; dd.storageMode = .private
        guard let h = device.makeTexture(descriptor: hd), let dp = device.makeTexture(descriptor: dd) else { throw err("テクスチャを作れません") }
        hdr = h; depth = dp
        let lib = try device.makeLibrary(source: brainShaderSource(), options: nil)
        guard let stepFn = lib.makeFunction(name: "brain_step") else { throw err("シェーダーがありません") }
        stepPipe = try device.makeComputePipelineState(function: stepFn)
        func pipe(_ vs: String, _ fs: String, _ format: MTLPixelFormat, depth: Bool, additive: Bool, write: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs); d.fragmentFunction = lib.makeFunction(name: fs)
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = format
            if !write { ca.writeMask = [] }
            if additive {
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add; ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .one
                ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .one
            }
            if depth { d.depthAttachmentPixelFormat = .depth32Float }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        occPipe = try pipe("brain_occ_vs", "brain_occ_fs", .rgba16Float, depth: true, additive: false, write: false)
        ptPipe = try pipe("brain_vs", "brain_fs", .rgba16Float, depth: true, additive: true, write: true)
        tonePipe = try pipe("brain_tone_vs", "brain_tone_fs", .rgba8Unorm, depth: false, additive: false, write: true)
        let d1 = MTLDepthStencilDescriptor(); d1.depthCompareFunction = .less; d1.isDepthWriteEnabled = true
        let d2 = MTLDepthStencilDescriptor(); d2.depthCompareFunction = .lessEqual; d2.isDepthWriteEnabled = false
        guard let s1 = device.makeDepthStencilState(descriptor: d1), let s2 = device.makeDepthStencilState(descriptor: d2) else { throw err("奥行きの設定を作れません") }
        occDS = s1; ptDS = s2
        linePipe = try pipe("brain_line_vs", "brain_line_fs", .rgba16Float, depth: true, additive: true, write: true)
        neuroPipe = try pipe("brain_neuro_vs", "brain_neuro_fs", .rgba16Float, depth: true, additive: true, write: true)
        let rd = MTLRenderPipelineDescriptor()
        rd.vertexFunction = lib.makeFunction(name: "brain_line_vs"); rd.fragmentFunction = lib.makeFunction(name: "brain_line_fs")
        let rc = rd.colorAttachments[0]!
        rc.pixelFormat = .rgba8Unorm
        rc.isBlendingEnabled = true                      // 上に重ねる(色は不透明度を掛けた値で出てくる)
        rc.rgbBlendOperation = .add; rc.alphaBlendOperation = .add
        rc.sourceRGBBlendFactor = .one; rc.destinationRGBBlendFactor = .oneMinusSourceAlpha
        rc.sourceAlphaBlendFactor = .one; rc.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        redPipe = try device.makeRenderPipelineState(descriptor: rd)
        rd.vertexFunction = lib.makeFunction(name: "brain_ct_vs"); rd.fragmentFunction = lib.makeFunction(name: "brain_ct_fs")
        ctPipe = try device.makeRenderPipelineState(descriptor: rd)
        rd.vertexFunction = lib.makeFunction(name: "brain_img_vs"); rd.fragmentFunction = lib.makeFunction(name: "brain_img_fs")
        imgPipe = try device.makeRenderPipelineState(descriptor: rd)
        mosaicPipe = try pipe("brain_tone_vs", "brain_mosaic_fs", .rgba8Unorm, depth: false, additive: false, write: true)
        rd.vertexFunction = lib.makeFunction(name: "brain_tone_vs"); rd.fragmentFunction = lib.makeFunction(name: "brain_eq_fs")
        eqPipe = try device.makeRenderPipelineState(descriptor: rd)
        solidPipe = try pipe("brain_solid_vs", "brain_solid_fs", .rgba16Float, depth: true, additive: false, write: true)
        let d3 = MTLDepthStencilDescriptor(); d3.depthCompareFunction = .always; d3.isDepthWriteEnabled = false
        guard let s3 = device.makeDepthStencilState(descriptor: d3),
              let sb = device.makeBuffer(length: BrainScene.MAX_SEGS * 2 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared) else { throw err("線の置き場所を作れません") }
        alwaysDS = s3; segs = sb
        for (i, sub) in ["axial", "coronal", "sagittal"].enumerated() { ctStacks[i] = BrainScene.loadCT(device, sub) }
        buildNeurons(T, N)
    }

    /// 神経細胞の網を作る。細胞の位置 = 脳の表面の点を、面の内側へ 3〜21mm 沈めた所。近い細胞どうしを 3 本ずつ、ゆるく曲げた線でつなぐ。
    /// 伸びる順番 = いくつかの出発点から、つながりをたどって何本目か(出発点から外へ広がっていく)
    private func buildNeurons(_ T: UnsafeMutablePointer<SIMD4<Float>>, _ N: UnsafeMutablePointer<SIMD4<Float>>) {
        let n = min(1800, count), near = 3, parts = 6
        var rng = SplitMix(s: 99)
        var pts = [SIMD3<Float>](); pts.reserveCapacity(n)
        for i in 0..<n {
            let t = T[i], nn = N[i]
            pts.append(SIMD3(t.x, t.y, t.z) - SIMD3(nn.x, nn.y, nn.z) * Float(0.03 + 0.20 * rng.next()))
        }
        var edges: [(Int, Int)] = []
        var adj = [[Int]](repeating: [], count: n)
        for i in 0..<n {
            var best = [(Float, Int)]()
            for j in 0..<n where j != i {
                let d = simd_length_squared(pts[i] - pts[j])
                if best.count < near { best.append((d, j)); best.sort { $0.0 < $1.0 } }
                else if d < best[near - 1].0 { best[near - 1] = (d, j); best.sort { $0.0 < $1.0 } }
            }
            for (_, j) in best where !adj[i].contains(j) { adj[i].append(j); adj[j].append(i); edges.append((i, j)) }
        }
        // 出発点から何本たどるか
        var hop = [Int](repeating: -1, count: n), queue = [Int]()
        for _ in 0..<5 { let s = Int(rng.next() * Double(n)) % n; if hop[s] < 0 { hop[s] = 0; queue.append(s) } }
        var qi = 0
        while qi < queue.count { let a = queue[qi]; qi += 1; for b in adj[a] where hop[b] < 0 { hop[b] = hop[a] + 1; queue.append(b) } }
        let maxHop = Float(max(1, hop.max() ?? 1))
        for i in 0..<n where hop[i] < 0 { hop[i] = Int(maxHop) }
        guard let buf = device.makeBuffer(length: edges.count * parts * 2 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared) else { return }
        let S = buf.contents().bindMemory(to: SIMD4<Float>.self, capacity: edges.count * parts * 2)
        var k = 0
        for (a0, b0) in edges {
            let (a, b) = hop[a0] <= hop[b0] ? (a0, b0) : (b0, a0)        // 出発点に近いほうから伸びる
            let pa = pts[a], pb = pts[b], d = pb - pa
            let side = simd_normalize(simd_cross(d, SIMD3<Float>(Float(rng.next()) - 0.5, Float(rng.next()) - 0.5, Float(rng.next()) - 0.5) + 1e-4))
            let bend = simd_length(d) * Float(0.06 + 0.16 * rng.next()), rnd = Float(rng.next())
            func at(_ s: Float) -> SIMD3<Float> { pa + d * s + side * (bend * sin(.pi * s)) }
            for q in 0..<parts {
                let s0 = Float(q) / Float(parts), s1 = Float(q + 1) / Float(parts)
                S[2 * k] = SIMD4(at(s0), (Float(hop[a]) + s0) / (maxHop + 1)); S[2 * k + 1] = SIMD4(at(s1), rnd); k += 1
            }
        }
        neuro = buf; neuroCount = k
    }

    /// 論文(Fujii, Kudo, Ohtsuki, Oda, J Neurophysiol 2010)の式 (6) と (A2) を、数式用の書体(STIX Two)で組んだ絵。
    /// 変数は斜体、sin・cos・数字・かっこは立体、という数式の組み方の決まりに合わせる。白い文字で、地は透明
    private func makeEquationTexture() -> MTLTexture? {
        let w = hdr.width, h = hdr.height, sc = CGFloat(w) / 1920 * (WIDE ? 1 : 1.12)   // 文字の大きさは横幅に合わせる
        var px = [UInt8](repeating: 0, count: w * h * 4)
        func font(_ names: [String], _ size: CGFloat) -> CTFont {
            for n in names { let f = CTFontCreateWithName(n as CFString, size, nil); if (CTFontCopyPostScriptName(f) as String) == n { return f } }
            return CTFontCreateWithName(names[names.count - 1] as CFString, size, nil)
        }
        let italicNames = ["STIXTwoText-Italic", "STIXGeneral-Italic", "TimesNewRomanPS-ItalicMT"], romanNames = ["STIXTwoText", "STIXTwoText-Regular", "STIXGeneral-Regular", "TimesNewRomanPSMT"]
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
            let size = 50 * sc
            /// 1 行を描く。src の中の書き方: _{..} = 下つき、\d = 上に点のついた φ、\q = √Q(上の線つき)。英字とギリシャ文字は斜体、sin・cos とそのほかは立体
            func drawLine(_ src: String, x x0: CGFloat, baseline y: CGFloat, measureOnly: Bool = false) -> CGFloat {
                var x = x0
                func put(_ s: String, italic: Bool, sub: Bool = false) {
                    let f = font(italic ? italicNames : romanNames, sub ? size * 0.68 : size)
                    let a: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: a))
                    if !measureOnly { ctx.textPosition = CGPoint(x: x, y: y - (sub ? size * 0.22 : 0)); CTLineDraw(line, ctx) }
                    x += CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                }
                var chars = Array(src), i = 0
                chars.append(" ")
                while i < chars.count - 1 {
                    let c = chars[i]
                    if c == "\\", chars[i + 1] == "d" {                 // 上に点のついた φ
                        let xa = x; put("φ", italic: true)
                        if !measureOnly { ctx.fillEllipse(in: CGRect(x: (xa + x) / 2 - size * 0.02, y: y + size * 0.74, width: size * 0.085, height: size * 0.085)) }
                        i += 2; continue
                    }
                    if c == "\\", chars[i + 1] == "q" {                 // √Q
                        put("√", italic: false); let xa = x - size * 0.02; put("Q", italic: true)
                        if !measureOnly { ctx.setLineWidth(size * 0.045); ctx.move(to: CGPoint(x: xa, y: y + size * 0.845)); ctx.addLine(to: CGPoint(x: x + size * 0.02, y: y + size * 0.845)); ctx.strokePath() }
                        i += 2; continue
                    }
                    if c == "_", chars[i + 1] == "{" {
                        var j = i + 2, s = ""
                        while j < chars.count, chars[j] != "}" { s.append(chars[j]); j += 1 }
                        put(s, italic: true, sub: true); i = j + 1; continue
                    }
                    let rest = String(chars[i...])
                    if rest.hasPrefix("sin") || rest.hasPrefix("cos") { put(String(rest.prefix(3)), italic: false); i += 3; continue }
                    put(String(c), italic: c.isLetter)
                    i += 1
                }
                return x - x0
            }
            // 2 本だけ: 粒子を動かしている式(6)(このモデルそのもの)と、地形の高さになっている式(A2)(ポテンシャル)。式の番号は付けない。
            // 1 本ずつ左右の中央にそろえ、2 行をひとかたまりとして画面の上下の中央に置く
            let eqs = ["\\d = −a sin φ − 2b sin 2φ − c sin (φ − ψ) + Δω + d cos φ + \\q ξ_{t}",
                       "V(φ) = −a cos φ − b cos 2φ − c cos (φ − ψ) − d sin φ − Δωφ"]
            let lead = size * 2.0
            for (i, e) in eqs.enumerated() {
                let y = CGFloat(h) / 2 + lead * (CGFloat(eqs.count - 1) / 2 - CGFloat(i)) - size * 0.3
                let wd = drawLine(e, x: 0, baseline: y, measureOnly: true)
                _ = drawLine(e, x: (CGFloat(w) - wd) / 2, baseline: y)
            }
            return true
        }
        guard ok else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
        return tex
    }

    /// CT の輪切りの連番(アプリの中の ct フォルダ、または CT_DIR)を、1 つの重ねた絵に読む
    static func loadCT(_ device: MTLDevice, _ sub: String) -> MTLTexture? {
        var dir = Bundle.main.resourceURL?.appendingPathComponent("ct").appendingPathComponent(sub)
        if let d = ProcessInfo.processInfo.environment["CT_DIR"] { dir = URL(fileURLWithPath: d).appendingPathComponent(sub) }
        guard let d = dir, let names = try? FileManager.default.contentsOfDirectory(atPath: d.path) else { return nil }
        let files = names.filter { $0.hasSuffix(".png") }.sorted()
        var w = 0, h = 0, tex: MTLTexture?
        for (i, name) in files.enumerated() {
            guard let src = CGImageSourceCreateWithURL(d.appendingPathComponent(name) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            if tex == nil {
                w = img.width; h = img.height
                let td = MTLTextureDescriptor()
                td.textureType = .type2DArray; td.pixelFormat = .r8Unorm; td.width = w; td.height = h; td.arrayLength = files.count
                td.usage = [.shaderRead]
                tex = device.makeTexture(descriptor: td)
            }
            var px = [UInt8](repeating: 0, count: w * h)
            let ok: Bool = px.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok, let t = tex else { return nil }
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, slice: i, withBytes: px, bytesPerRow: w, bytesPerImage: w * h)
        }
        return tex
    }

    /// マス目の面(xy, yz, zx の 3 枚。原点が中心の正方形)と、原点の赤い線(x, y, z 軸に沿って 3 本)の線分を書く。
    /// 返り値 = (マス目の線分の数, 赤い線の数)
    private func writeLines(_ P: Params, scanY: Double?, scanA: Double) -> (Int, Int) {
        let S = segs.contents().bindMemory(to: SIMD4<Float>.self, capacity: BrainScene.MAX_SEGS * 2)
        var n = 0
        func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ bright: Float, _ red: Float) {
            S[2 * n] = SIMD4(a, bright); S[2 * n + 1] = SIMD4(b, red); n += 1
        }
        var grid = 0
        if modelNow {
            // ドラマーのモデル: 地形の上に格子を引く(φ は 45° ごと、Δω は 0.5 ごと。φ = 180° の線だけ少し明るく)。元の地形アプリと同じ
            let hS = Float(P.bModelH), WX: Float = 4.4, WZ: Float = 5.7, k: Float = 0.8, dwMax: Float = 4
            func at(_ phi: Float, _ uu: Float) -> SIMD3<Float> {
                let dw = uu * dwMax
                let V = -cos(phi) - 2 * cos(phi - .pi) - k * dw * sin(phi) - dw * phi
                return SIMD3((phi / (2 * .pi) - 0.5) * WX, hS * (V - 1), (uu - 0.5) * WZ)
            }
            for i in 0...8 {
                let phi = Float(i) * .pi / 4
                for j in 0..<16 { add(at(phi, Float(j) / 16), at(phi, Float(j + 1) / 16), i == 4 ? 0.55 : 0.22, 0) }
            }
            for j in 0...8 {
                let uu = Float(j) / 8
                for i in 0..<36 { add(at(Float(i) / 36 * 2 * .pi, uu), at(Float(i + 1) / 36 * 2 * .pi, uu), 0.22, 0) }
            }
        }
        if P.bGrid > 0.001 {
            // 1 辺 = 粒子が漂う範囲のいちばん長い辺 × bGridSize
            let h = Float(P.bGridSize) * max(BrainScene.BOX.x, max(BrainScene.BOX.y, BrainScene.BOX.z))
            let cells = BrainScene.GRID_CELLS, g = Float(P.bGrid * fadeIn * (modelNow ? 0 : 1))
            for i in 0...cells {
                let c = -h + 2 * h * Float(i) / Float(cells)
                add(SIMD3(-h, c, 0), SIMD3(h, c, 0), g, 0); add(SIMD3(c, -h, 0), SIMD3(c, h, 0), g, 0)      // xy の面
                add(SIMD3(0, -h, c), SIMD3(0, h, c), g, 0); add(SIMD3(0, c, -h), SIMD3(0, c, h), g, 0)      // yz の面
                add(SIMD3(-h, 0, c), SIMD3(h, 0, c), g, 0); add(SIMD3(c, 0, -h), SIMD3(c, 0, h), g, 0)      // zx の面
            }
        }
        if let sy = scanY, scanA > 0.001 {               // スキャンの面: 水平なマス目の面が、上から下へ降りてくる
            let h = Float(P.bScanSize), y = Float(sy), g = Float(P.bScanLine * scanA), cells = BrainScene.SCAN_CELLS
            for i in 0...cells {
                let c = -h + 2 * h * Float(i) / Float(cells)
                add(SIMD3(-h, y, c), SIMD3(h, y, c), g, 0); add(SIMD3(c, y, -h), SIMD3(c, y, h), g, 0)
            }
        }
        grid = n
        var red = 0
        if P.bAxis > 0.001, !modelNow, fadeIn > 0.001 {       // 波形に並べているあいだ(通しの前半)は出さない
            let a = Float(P.bAxis), b = Float(min(1, max(0, P.bAxisBright)) * fadeIn * (modelNow ? 0 : 1))
            add(SIMD3(-a, 0, 0), SIMD3(a, 0, 0), b, 1); add(SIMD3(0, -a, 0), SIMD3(0, a, 0), b, 1); add(SIMD3(0, 0, -a), SIMD3(0, 0, a), b, 1)
            red = 3
        }
        return (grid, red)
    }

    // ---- カメラ: キックで回り込み、クラップで構図が切り替わる。時刻だけで決まる(位置を飛ばしても同じ絵) ----
    private var camKey = ""
    // 回り込み: 始まる時刻、向かう先の向きと高さ(rad)、始まったときの「先からのずれ」と速さ(向き・高さそれぞれ)
    private var moves: [(t: Double, ty: Double, tp: Double, ey: Double, vy: Double, ep: Double, vp: Double)] = []
    private var shots: [(t: Double, kind: Int)] = []                                        // 構図: 0 = 標準, 1 = 寄り, 2 = 俯瞰
    private weak var hatTrack: Track?
    private(set) var camNote = ""                                                           // いまの構図と向き(表示・確認用)
    private static func rnd(_ i: Int) -> Double { var r = SplitMix(s: UInt64(truncatingIfNeeded: i &* 2654435761 &+ 12345)); return r.next() }
    /// ばねとダンパー(車のサスペンションと同じ式)でつながれた点の動き。
    /// 行き先からのずれ e0 と速さ v0 で始めて、tau 秒後のずれと速さを返す。行き先を通りすぎて、揺れながら収まる
    /// w: ばねの固さ(揺れの速さ rad/秒)、z: 減衰(0 = 揺れ続ける … 1 = 揺れずに止まる)
    private static func spring(_ e0: Double, _ v0: Double, _ tau: Double, w: Double, z: Double) -> (e: Double, v: Double) {
        let wd = w * (1 - z * z).squareRoot()
        let a = e0, b = (v0 + z * w * e0) / wd
        let ex = exp(-z * w * tau), c = cos(wd * tau), s = sin(wd * tau)
        return (ex * (a * c + b * s), ex * ((b * wd - z * w * a) * c - (a * wd + z * w * b) * s))
    }
    /// 回り込みのばねの固さ: 行き先に最初に届くまでが dur 秒になるように決める
    private static func springW(dur: Double, z: Double) -> Double {
        let zz = min(0.95, max(0.05, z))
        return (Double.pi - acos(zz)) / max(0.01, dur) / (1 - zz * zz).squareRoot()
    }

    private func buildCamera(_ track: Track, _ P: Params) {
        let key = "\(camFrom)|\(P.bCamKick)|\(P.bCamDur)|\(P.bCamGap)|\(P.bCamDamp)|\(track.cueKick.count)|\(track.cueClap.count)"
        if key == camKey { return }
        camKey = key
        moves = []; shots = []
        // いまの向き y・高さ p と、その速さ。行き先はキックのたびに先へ進む
        var y = 0.0, p = 0.0, vy = 0.0, vp = 0.0, ty = 0.0, last = -Double.infinity, i = 0
        let z = min(0.95, max(0.05, P.bCamDamp)), w = BrainScene.springW(dur: P.bCamDur, z: z)
        for k in track.cueKick where k.t > camFrom + 0.02 && k.t - last >= P.bCamGap {
            if let m = moves.last {                      // 前の揺れが収まる前に次が来たら、そのときの位置と速さから続ける(動きが途切れない)
                let sy = BrainScene.spring(m.ey, m.vy, k.t - m.t, w: w, z: z), sp = BrainScene.spring(m.ep, m.vp, k.t - m.t, w: w, z: z)
                y = m.ty + sy.e; vy = sy.v; p = m.tp + sp.e; vp = sp.v
            }
            // 回る向きはだいたい同じ(ときどき逆)。角度は 0.6〜1.4 倍。高さも少し変わる
            let dirn = BrainScene.rnd(i * 3 + 2) < 0.78 ? 1.0 : -1.0
            ty += dirn * P.bCamKick * (0.6 + 0.8 * BrainScene.rnd(i * 3)) * .pi / 180
            let tp = (BrainScene.rnd(i * 3 + 1) - 0.35) * 0.5
            moves.append((k.t, ty, tp, y - ty, vy, p - tp, vp))
            last = k.t; i += 1
        }
        var prev = 0
        for (j, c) in track.cueClap.enumerated() where c.t > camFrom + 0.02 {
            var kind = min(2, Int(BrainScene.rnd(j + 500_000) * 3))
            if kind == prev { kind = (kind + 1) % 3 }    // 毎回かならず違う構図へ
            if j == track.cueClap.count - 1 { kind = 0 } // 最後のクラップのあとは標準に戻る
            shots.append((c.t, kind)); prev = kind
        }
    }

    /// クラップで出す写真の一覧。区間の中のクラップ 1 回ごとに、まだ使っていない画像と、直前と違う出し方を割り当てる
    private func buildPhotos(_ track: Track, _ P: Params) {
        let key = "\(P.photoFrom)|\(P.photoTo)|\(P.bPhotoDur)|\(track.cueClap.count)"
        if key == photoKey { return }
        photoKey = key; photos = []
        let claps = track.cueClap.map { $0.t }.filter { $0 >= P.photoFrom && $0 < P.photoTo }
        guard !claps.isEmpty else { return }
        // 3 方向の連番の全部の画像を、決まった順に混ぜておく(同じ画像は二度使わない。足りなくなったら 2 周目に入る)
        var pool: [(Int, Int)] = []
        for (s, r) in BrainScene.CT_RANGE.enumerated() { for i in r { pool.append((s, i)) } }
        var rng = SplitMix(s: 314159)
        for i in stride(from: pool.count - 1, to: 0, by: -1) { pool.swapAt(i, Int(rng.next() * Double(i + 1))) }
        var prev = -1
        for (j, t) in claps.enumerated() {
            let next = j + 1 < claps.count ? claps[j + 1] : t + P.bPhotoDur
            var style = Int(rng.next() * 5) % 5
            if style == prev { style = (style + 1 + Int(rng.next() * 3)) % 5 }
            prev = style
            let (stack, slice) = pool[j % pool.count]
            // クラップの瞬間だけ出す: 最長 bPhotoDur、次のクラップまでの半分より長くはしない(あいだには必ず 3D の絵が戻る)。最低でも 1 コマ
            photos.append((t, max(1 / Double(FPS), min(P.bPhotoDur, (next - t) * 0.5)), stack, slice, style, rng.next(), rng.next()))
        }
    }

    /// このコマで画面に重ねる CT 画像を決める(クラップの写真と、スキャン中の両脇の連番)
    private func buildOverlays(_ te: Double, frameEnd: Double, track: Track, _ P: Params, scanX: Double?, scanA: Double) {
        overlays = []; photoNote = ""; mosaic = nil
        let A = Float(Double(W) / Double(H))
        func add(_ stack: Int, _ slice: Float, cx: Float, cy: Float = 0, lw: Float, lh: Float, rot: Float = 0,
                 uvc: SIMD2<Float> = SIMD2(0.5, 0.5), uvh: SIMD2<Float> = SIMD2(0.5, 0.5), alpha: Float) {
            guard ctStacks[stack] != nil, alpha > 0.002 else { return }
            overlays.append((ImgU(a: SIMD4(cx, cy, lw, lh), b: SIMD4(rot, slice, alpha, A), c: SIMD4(uvc.x, uvc.y, uvh.x, uvh.y)), stack))
        }
        // ---- クラップの写真 ----
        if P.bPhoto > 0.001 {
            buildPhotos(track, P)
            var lo = 0, hi = photos.count
            while lo < hi { let m = (lo + hi) / 2; if photos[m].t < frameEnd { lo = m + 1 } else { hi = m } }   // クラップが鳴るコマの頭から出す
            if lo > 0, te < photos[lo - 1].t + photos[lo - 1].life {
                let ph = photos[lo - 1]
                photoNote = "  写真 \(lo)/\(photos.count) 出し方\(ph.style) 連番\(ph.stack) \(ph.slice)枚目"
                let x = Float(min(1, max(0, (te - ph.t) / max(0.03, ph.life))))
                let r = Float(BrainScene.CT_ASPECT[ph.stack]), r1 = Float(ph.r1), r2 = Float(ph.r2)
                let n = Float(ctStacks[ph.stack]?.arrayLength ?? 1)
                let rg = BrainScene.CT_RANGE[ph.stack], lo = Float(rg.lowerBound), span = Float(rg.count)
                func rowsFor(_ cols: Float) -> Float { max(1, (cols / A * r).rounded()) }     // ますの形が画像の形に近くなる縦の数
                var m = MosaicU()
                m.c = SIMD4(A, r, lo, span)
                switch ph.style {
                case 0:     // その方向の断面を全部、順番に並べて画面を埋める
                    let grid: [SIMD2<Float>] = WIDE ? [SIMD2(14, 3), SIMD2(15, 4), SIMD2(10, 4)] : [SIMD2(9, 5), SIMD2(9, 7), SIMD2(7, 6)]
                    m.a = SIMD4(grid[ph.stack].x, grid[ph.stack].y, 0, 1); m.b = SIMD4(0, 0, 1.22, 0.5)
                    m.c = SIMD4(A, r, 0, n)
                case 1:     // 画面いっぱいの 1 枚で、断面を順番に高速で再生する(クラップが鳴っている長さで、脳の上から下まで通る)
                    m.a = SIMD4(1, 1, 0, 0); m.b = SIMD4(x * (span - 1), 0, 1.55, 0.40 + 0.20 * r1)   // 頭のまわりの黒が画面に入らないところまで寄せる
                case 2:     // 何枚かに割って、ますごとに少しずつずらして高速で再生する
                    let cols: Float = [3, 4, 6, 8][min(3, Int(r1 * 4))], rows: Float = cols >= 6 ? 2 : 1
                    m.a = SIMD4(cols, rows, 0, 0); m.b = SIMD4(x * (span - 1) * (r2 < 0.5 ? 1 : -1), span / (cols * rows), 1.1, 0.5)
                case 3:     // 同じ 1 枚を、とても小さくして一面に敷き詰める
                    let cols = (26 + 46 * r1).rounded()
                    m.a = SIMD4(cols, rowsFor(cols), Float(ph.slice) - lo, 0); m.b = SIMD4(0, 0, 1.15, 0.5)
                default:    // 小さいますで、断面を順番に敷き詰める(1 ますごとに 1 枚進む)。再生もする
                    let cols = (16 + 22 * r1).rounded()
                    m.a = SIMD4(cols, rowsFor(cols), Float(ph.slice) - lo, 1); m.b = SIMD4(x * span * 0.5, 0, 1.15, 0.5)
                }
                if ctStacks[ph.stack] != nil { mosaic = (m, ph.stack) }
            }
        }
        // ---- スキャン中の両脇: 左に横断(スキャンの面と同じ番号)、右に矢状断を、スキャンと同じ進み方で順に送る ----
        if let sx = scanX, P.bScanSide > 0.001 {
            let al = Float(P.bScanSide * scanA), h: Float = WIDE ? 0.94 : 0.40      // 16:9 では両脇が狭いので小さく置く
            let ra = Float(BrainScene.CT_ASPECT[0]), rs = Float(BrainScene.CT_ASPECT[2])
            add(0, Float(BrainScene.CT_TOP + (BrainScene.CT_BOTTOM - BrainScene.CT_TOP) * sx), cx: -(1 - ra * h / A - 0.02), lw: ra * h, lh: h, alpha: al)
            let sr = BrainScene.CT_RANGE[2]
            add(2, Float(Double(sr.lowerBound) + Double(sr.upperBound - sr.lowerBound) * sx), cx: 1 - rs * h / A - 0.02, lw: rs * h, lh: h, alpha: al)
        }
    }

    /// 時刻 t のカメラ: 向き(rad)、高さ(rad)、距離の倍率
    private func camera(_ t: Double, frameEnd: Double, _ P: Params) -> (yaw: Double, pitch: Double, zoom: Double) {
        var yaw = 0.0, pitch = 0.0, zoom = 1.0, kind = 0
        if P.bCamKick > 0.001, !moves.isEmpty {
            var lo = 0, hi = moves.count
            let cut = P.bCamCut >= 0.5                    // ぱっと切り替え: キックが鳴るコマの頭で、次の場所へ一気に移る(動きはつけない)
            while lo < hi { let m = (lo + hi) / 2; if moves[m].t < (cut ? frameEnd : t + 1e-9) { lo = m + 1 } else { hi = m } }
            if lo > 0, cut {
                yaw = moves[lo - 1].ty; pitch = moves[lo - 1].tp
            } else if lo > 0 {
                let m = moves[lo - 1]
                let z = min(0.95, max(0.05, P.bCamDamp)), w = BrainScene.springW(dur: P.bCamDur, z: z)
                yaw = m.ty + BrainScene.spring(m.ey, m.vy, t - m.t, w: w, z: z).e
                pitch = m.tp + BrainScene.spring(m.ep, m.vp, t - m.t, w: w, z: z).e
            }
        }
        if P.bCamClap >= 0.5, !shots.isEmpty {           // 構図は、クラップが鳴るコマの頭でぱっと切り替える(色の反転と同じコマ)
            var lo = 0, hi = shots.count
            while lo < hi { let m = (lo + hi) / 2; if shots[m].t < frameEnd { lo = m + 1 } else { hi = m } }
            if lo > 0 {
                kind = shots[lo - 1].kind
                switch kind {
                case 1: zoom = P.bCamZoom
                case 2: pitch = P.bCamTop * .pi / 180; zoom = 1.15
                default: break
                }
            }
        }
        // ハイハットが鳴っている間だけ: 脳を離れて眺める、決まった位置へ移る
        if P.bHatCam >= 0.5, let tr = hatTrack {
            var lo = 0, hi = tr.cueHat.count
            while lo < hi { let m = (lo + hi) / 2; if tr.cueHat[m].t < frameEnd { lo = m + 1 } else { hi = m } }
            if lo > 0, tr.cueHat[lo - 1].t > camFrom, t < tr.cueHat[lo - 1].t + P.bScanDur {
                yaw = P.bHatCamYaw * .pi / 180; pitch = P.bHatCamPitch * .pi / 180            // 毎回同じ場所(固定)
                zoom = P.bHatCamZoom; kind = 3
            }
        }
        camNote = String(format: "%@ 向き %.0f°", ["標準", "寄り", "俯瞰", "客観"][kind], yaw * 180 / .pi)
        return (yaw, pitch, zoom)
    }

    static let SPREAD = 0.32             // 粒子1個が「漂う」から「脳」へ移りきるのにかかる、脳になる量の幅

    /// 時刻 t の「脳になる量」(0 = 漂うだけ, 1 = 全部の粒子が脳)
    static func morph(_ t: Double, _ P: Params) -> Double {
        if P.bMorph >= 0 { return P.bMorph }
        let formed = smooth(P.bStart, P.bStart + max(0.1, P.bLen), t)
        // できあがった脳は、bDissolveFrom〜bDissolveTo でまた Curl noise の雲へほどける。bReformFrom から bReformLen 秒かけて、もう一度脳に集まる
        let dissolved = smooth(P.bDissolveFrom, max(P.bDissolveFrom + 0.1, P.bDissolveTo), t)
        let reformed = smooth(P.bReformFrom, P.bReformFrom + max(0.1, P.bReformLen), t)
        return formed * max(1 - dissolved, reformed)
    }

    /// 粒子を進めて、hdr に描く命令を積む。返り値は脳になる量
    /// t: 曲の時刻。fixedStep: 1 コマぶん(1/30 秒)進める(1 枚だけ取り出すとき)
    /// 粒子を波形メッシュの形に並べるときの値(波形メッシュのモードと同じ意味)
    struct Wave { var amp, ymix, dz, half, zShift, aspect, burst: Double }

    @discardableResult
    func encode(_ cb: MTLCommandBuffer, time t: Double, fixedStep: Bool, track: Track, params P: Params, heights: MTLTexture, scale: Int, wave: Wave? = nil) -> Double {
        // 進める時間: 再生中は前のコマからの経過。止めている間は進めない。位置を飛ばしたときは 1 コマぶん
        var dt = 1 / Double(FPS)
        if !fixedStep {
            let d = t - lastT
            dt = (d >= 0 && d < 0.25) ? min(d, 1 / 15.0) : 1 / Double(FPS)
        }
        lastT = t
        let m = BrainScene.morph(t, P)
        // 1 枚だけ取り出すときは、そのコマの中で鳴るキックも入るよう、コマの終わりの時刻で見る
        let frameEnd = (floor(t * Double(FPS) + 1e-6) + 1) / Double(FPS)
        let te = fixedStep ? frameEnd : t
        let kick = track.kickPulse(te, decay: 0.16)
        // 面で描く区間(スキャンのあとの、キックとクラップの所。bSolidFrom〜bSolidTo): 脳を粒子でなく面で描き、音に合わせて膨らませる。出入りは 0.3 秒で入れ替える
        let solidOn = P.bSolidCG >= 0.5 && wave == nil && meshCount > 0 ? smooth(P.bSolidFrom, P.bSolidFrom + 0.3, te) * (te < P.bSolidTo ? 1 : 0) : 0
        var hatEnv = 0.0
        if let hi = track.cueHat.lastIndex(where: { $0.t <= te }) { hatEnv = max(0, 1 - (te - track.cueHat[hi].t) / max(0.05, P.bScanDur)) }
        // クラップ: 鳴ってから bSwellDecay の 1.5 倍の時間で引く
        var clapEnv = 0.0
        do {
            var lo = 0, hi = track.cueClap.count
            while lo < hi { let mm = (lo + hi) / 2; if track.cueClap[mm].t <= te { lo = mm + 1 } else { hi = mm } }
            if lo > 0 { clapEnv = exp(-(te - track.cueClap[lo - 1].t) / max(0.01, P.bSwellDecay * 1.5)) }
        }
        let swell = P.bSwell * min(1.5, track.kickPulse(te, decay: P.bSwellDecay)) + P.bSwellHat * (hatEnv * hatEnv + clapEnv)
        let aspect = Double(W) / Double(H)
        let fov = 22.0 * .pi / 180
        let baseDist = 1 / tan(fov / 2)                           // 原点の高さ 2 単位が、画面の高さちょうどになる距離
        buildCamera(track, P)
        hatTrack = track
        let cam = camera(te, frameEnd: frameEnd, P)
        // ドラマーのモデルの区間: カメラは一定の速さで回るだけ(キックの切り替え・クラップの構図・手ブレはなし)
        modelNow = wave == nil && P.bModel >= 0.5 && te >= P.bModelFrom && te < P.bModelTo
        // 引きから寄りへ: 粒が漂っている間は引いて全体を見せ、脳ができあがるにつれて近づく。
        // 引いていく動きはつけない: 脳のパートは最初のコマから引いた画角で始まる(通しでは、切り替わりのコマで一気に引いた画角になる)。波形に並べている間は動かさない
        let pull = wave != nil ? 1.0 : 1 + (P.bCamWide - 1) * (1 - smooth(0, 1, m))
        // モデルへ入る 0.3 秒のあいだは、カメラも直前の位置からモデル用の位置へすばやく動かす(粒子が飛んでいくのが見えるように、切り替えにはしない)
        let mb = modelNow ? smooth(P.bModelFrom, P.bModelFrom + max(0.05, P.bModelMove), te) : 0
        modelBlend = mb
        let distC = baseDist * P.zoom * cam.zoom * pull, yawC = P.yaw + cam.yaw, pitchC = P.pitch + cam.pitch
        let yawM = P.yaw + (P.bModelYaw + (te - P.bModelFrom) * P.bModelSpin) * .pi / 180
        let dist = distC + (baseDist * P.zoom * P.bModelZoom - distC) * mb
        let yaw = modelNow ? yawM + (yawC - yawM).remainder(dividingBy: 2 * .pi) * (1 - mb) : yawC      // 近いほうへ回す
        let pitch = max(-1.55, min(1.55, pitchC + (P.pitch + P.bModelPitch * .pi / 180 - pitchC) * mb))
        if modelNow { camNote = String(format: "モデル 向き %.0f°", yaw * 180 / .pi) }
        let eye = SIMD3(dist * sin(yaw) * cos(pitch), dist * sin(pitch), dist * cos(yaw) * cos(pitch))
        // 手ブレ: いつも掛かる、手持ちカメラのような揺れ。ゆっくりした揺れをいくつか重ねたもので、音量が上がると少し大きくなる。
        // カメラの位置は動かさず、向ける先(左右・上下)と傾きを揺らす
        func sway(_ seed: Double) -> Double {
            let f = [0.37, 0.83, 1.31, 2.17, 3.43], a = [1.0, 0.6, 0.4, 0.22, 0.12]
            var v = 0.0
            for i in 0..<5 { v += a[i] * sin(2 * .pi * f[i] * te + seed * Double(i + 1) * 1.7) }
            return v / 2.34
        }
        fadeIn = camFrom.isFinite ? smooth(camFrom, camFrom + 1.5, te) : 1
        let shake = (1 - mb) * P.bShake * (0.7 + 0.6 * track.at(track.levelSmooth, te)) * fadeIn
        let cFwd = simd_normalize(eye), cRight = simd_normalize(simd_cross(SIMD3(0, 1, 0), cFwd)), cUp = simd_cross(cFwd, cRight)
        let reach = dist / baseDist                               // 寄っているときも、画面の上での揺れ幅が同じになるように
        let aim = cRight * (0.045 * shake * sway(1.0) * reach) + cUp * (0.035 * shake * sway(2.3) * reach)
        let roll = 0.012 * shake * sway(4.1)
        let vp = perspective(fovy: fov, aspect: aspect, near: 0.2, far: dist + 16)
            * lookAt(eye: eye + SIMD3(0, -0.75 * mb, 0), center: aim + SIMD3(0, -0.75 * mb, 0), up: cUp * cos(roll) + cRight * sin(roll))   // 地形は原点より下へ広がるので、見る中心を下げる
        let ang = (P.bYaw + P.bSpin * simT) * .pi / 180          // 脳を縦軸まわりに回す
        let cs = Float(cos(ang)), sn = Float(sin(ang))
        var u = BrainUniforms()
        u.vp = simd_float4x4(columns: (SIMD4<Float>(vp.columns.0), SIMD4<Float>(vp.columns.1), SIMD4<Float>(vp.columns.2), SIMD4<Float>(vp.columns.3)))
        u.rot0 = SIMD4(cs, 0, -sn, 0); u.rot1 = SIMD4(0, 1, 0, 0); u.rot2 = SIMD4(sn, 0, cs, 0)
        u.b = SIMD4(Float(P.bCurl), Float(P.bFreq), Float(P.bEvolve), Float(P.bSheet))
        u.c = SIMD4(Float(P.bKick), Float(P.bPush), Float(P.bWave), Float(P.bScale))
        u.d = SIMD4(BrainScene.BOX, Float(BrainScene.SPREAD))
        let sc = Double(scale) * PX
        u.e = SIMD4(Float(P.bSize * sc), Float(baseDist), Float(P.bCloud * 4_194_304.0 / Double(count)), Float(P.bBrain * 4_194_304.0 / Double(count)))
        let nkey = "\(P.bMorph)|\(P.bStart)|\(P.bLen)|\(track.cueKick.count)"
        if nkey != neuroKey {
            neuroKey = nkey
            let done = P.bStart + max(0.1, P.bLen)
            neuroStart = P.bMorph >= 0 ? (P.bMorph >= 0.999 ? -1e9 : .infinity) : (track.cueKick.first { $0.t >= done }?.t ?? done)
        }
        let grownN = min(1, max(0, (te - neuroStart) / max(0.05, P.bNeuroDur)))
        // 切り替わった直後は粒が波形の細い帯に固まっていて明るすぎるので、散っていくのに合わせて明るさを上げる
        if camFrom.isFinite { u.e.z *= Float(0.22 + 0.78 * smooth(camFrom + 0.1, camFrom + 1.4, te)) }
        // 脳へ集まる途中・ほどける途中は、粒が狭い所に固まって白く飛ぶので、そのあいだ雲の明るさを下げる
        u.e.z *= Float(1 - 0.75 * 4 * m * (1 - m))
        // 白い粒子は濃く(明るく)する。色のついた区間と、ドラマーのモデルの区間はそのまま
        if wave == nil, !modelNow { let wb = Float(1 + (P.bWhite - 1) * (1 - tintNow)); u.e.z *= wb; u.e.w *= wb }
        if P.bNeuro > 0.001 { u.e.w *= Float(1 + (P.bNeuroDim - 1) * smooth(0, 0.5, grownN)) }   // 網が出ている間は、脳の表面を暗くして中を見せる
        u.f = SIMD4(Float(eye.x), Float(eye.y), Float(eye.z), Float(2.4 * sc))
        // 光はカメラについて回る(どこから見ても、左上の手前から当たる)
        let fwd = simd_normalize(eye), right = simd_normalize(simd_cross(SIMD3(0, 1, 0), fwd)), up = simd_cross(fwd, right)
        let light = SIMD3<Float>(simd_normalize(right * -0.45 + up * 0.65 + fwd * 0.6))
        u.g = SIMD4(light, 0.035)
        u.h = SIMD4(Float(P.bPull), 3.5, 13, Float(track.S))
        u.color = SIMD4(P.color, 1)
        // キックとクラップの区間: 粒子に色をつける(0.4 秒で白から移る)
        tintNow = 0
        if wave == nil, P.bTint > 0.001 {
            let k = Float(P.bTint * smooth(P.bDissolveFrom, P.bDissolveFrom + 0.4, te) * (te < P.bDissolveTo ? 1 : 0))
            tintNow = Double(k)
            u.color = SIMD4(P.color * (1 - k) + BrainScene.TINT * k, 1)
        }
        // スキャン: ハイハットが鳴るたびに、水平な面が脳の上から下へ bScanDur 秒で降りる。出入りのところは明るさをなだらかに
        var scanY: Double? = nil, scanA = 0.0, scanX: Double? = nil
        if !modelNow, P.bScan > 0.001 || P.bScanLine > 0.001 {
            var lo = 0, hi = track.cueHat.count
            while lo < hi { let mm = (lo + hi) / 2; if track.cueHat[mm].t <= te { lo = mm + 1 } else { hi = mm } }
            if lo > 0, track.cueHat[lo - 1].t > camFrom {   // 通しでは、切り替わる前(波形のあいだ)のハイハットではスキャンしない
                let x = (te - track.cueHat[lo - 1].t) / max(0.05, P.bScanDur)
                if x < 1 {
                    let top = 1.0 * P.bScale
                    scanY = top - 2 * top * x; scanX = x
                    scanA = smooth(0, 0.08, x) * (1 - smooth(0.88, 1, x))
                }
            }
        }
        buildOverlays(te, frameEnd: frameEnd, track: track, P, scanX: wave == nil ? scanX : nil, scanA: scanA)
        camNote += photoNote
        u.s = SIMD4(Float(scanY ?? 99), Float(P.bScan * scanA), Float(max(0.005, P.bScanWidth)), Float(P.bDots))

        // ---- 粒子を進める(1 コマを 2 歩に分ける) ----
        // 最初の 1 回だけ、先に 24 秒ぶん漂わせておく(一様にまいた直後は模様がないので、膜や筋ができた状態から始める)
        if let wv = wave {
            // 波形のあいだ、ハイハットが鳴っている最中だけ粒を赤くする
            if P.hatRed >= 0.5, let hc = track.hatColor(te, len: P.bScanDur) { u.color = SIMD4(hc.fg, 1) }
            u.w = SIMD4(1, Float(wv.amp), Float(wv.ymix), Float(wv.dz))
            u.w2 = SIMD4(Float(wv.half), Float(wv.zShift), Float(wv.aspect), Float(wv.burst))
            if dt <= 1e-6 { dt = 1 / Double(FPS) }       // 並べ直すだけなので、止めている間も 1 回は動かす
            if steps == 0 { steps = 1 }                  // 先に漂わせる下ごしらえは要らない
        }
        if modelNow {
            u.w = SIMD4(2, Float(P.bModelH), 4.4, 5.7)                      // 2 = モデルの地形, 高さの倍率, 横幅(φ), 奥行き(Δω)
            u.w2 = SIMD4(Float(modelStep), 4.0, 0.8, 20 * .pi / 180)        // 何歩目か, Δω の最大, k(d = kΔω), √Q(20°)
            if steps == 0 { steps = 1 }
        }
        let pre = steps == 0 ? 360 : 0
        if dt > 1e-6 || pre > 0 {
            let sub = 2
            for i in 0..<(pre + (dt > 1e-6 ? sub : 0)) {
                let h = i < pre ? 1 / 15.0 : dt / Double(sub)
                simT += h
                var us = u
                us.a = SIMD4(Float(h), Float(simT), i < pre ? 0 : Float(modelNow ? modelBlend : m), i < pre ? 0 : Float(modelNow ? 1 - pow(0.02, 1 / (max(0.05, P.bModelMove) * 60 * 0.8)) : kick))
                if modelNow { us.w2.x = Float(modelStep); modelStep += 1 }
                guard let ce = cb.makeComputeCommandEncoder() else { break }
                ce.setComputePipelineState(stepPipe)
                ce.setBuffer(pos, offset: 0, index: 0); ce.setBuffer(vel, offset: 0, index: 1)
                ce.setBuffer(tgt, offset: 0, index: 2); ce.setBuffer(nrm, offset: 0, index: 3)
                ce.setBytes(&us, length: MemoryLayout<BrainUniforms>.stride, index: 4)
                ce.setTexture(heights, index: 0)
                let w = stepPipe.threadExecutionWidth * 4
                ce.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
                ce.endEncoding()
                steps += 1
            }
        }

        // ---- 描く: 着いた粒子の奥行きを先に描き、そのあと全部の粒子を光の点として足し込む ----
        u.a = SIMD4(0, Float(simT), Float(modelNow ? modelBlend : m), Float(kick))
        u.mz = SIMD4(Float(solidOn), Float(swell), Float(P.bSwellBump * (0.3 + min(1.5, kick))), 0)
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = hdr
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        rp.depthAttachment.texture = depth
        rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1
        rp.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return m }
        enc.setVertexBuffer(pos, offset: 0, index: 0); enc.setVertexBuffer(vel, offset: 0, index: 1)
        enc.setVertexBuffer(tgt, offset: 0, index: 2); enc.setVertexBuffer(nrm, offset: 0, index: 3)
        enc.setVertexBytes(&u, length: MemoryLayout<BrainUniforms>.stride, index: 4)
        if solidOn > 0.001, let mp = meshPos, let mn = meshNrm {          // 面で描く脳。奥行きも書くので、うしろの粒子や線は隠れる
            enc.setRenderPipelineState(solidPipe); enc.setDepthStencilState(occDS)
            enc.setVertexBuffer(mp, offset: 0, index: 0); enc.setVertexBuffer(mn, offset: 0, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<BrainUniforms>.stride, index: 4)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: meshCount)
            enc.setVertexBuffer(pos, offset: 0, index: 0); enc.setVertexBuffer(vel, offset: 0, index: 1)
        }
        if m > 0.001, P.bSolid >= 0.5 {                  // うしろを隠すのは「面として見せる」ときだけ
            enc.setRenderPipelineState(occPipe); enc.setDepthStencilState(occDS)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        }
        enc.setRenderPipelineState(ptPipe); enc.setDepthStencilState(ptDS)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        // マス目の面(脳のうしろに回った線は隠れる)と、原点の赤い線(脳の中にあっても見えるよう、隠さずに描く)
        // 神経細胞の網: 脳が完成したあとの最初のキックから伸び始め、bNeuroDur 秒で脳じゅうに張り巡らされる。脳の表面に隠さず、光として足す
        if grownN > 0, P.bNeuro > 0.001, let nb = neuro {
            var k = SIMD4<Float>(Float(hdr.width), Float(hdr.height), Float(P.bNeuroW * sc), Float(grownN))
            var k2 = SIMD4<Float>(Float(P.bNeuro * m * (modelNow ? 0 : 1) * (1 - solidOn)), Float(simT), Float(kick), 0)   // 脳がほどけたら、網も消える
            enc.setRenderPipelineState(neuroPipe); enc.setDepthStencilState(alwaysDS)
            enc.setVertexBuffer(nb, offset: 0, index: 0)
            enc.setVertexBytes(&k, length: MemoryLayout<SIMD4<Float>>.stride, index: 5)
            enc.setVertexBytes(&k2, length: MemoryLayout<SIMD4<Float>>.stride, index: 6)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: neuroCount)
        }
        let (nGrid, nRed) = writeLines(P, scanY: scanY, scanA: scanA)
        if nGrid + nRed > 0 {
            var k = SIMD4<Float>(Float(hdr.width), Float(hdr.height), Float(P.bLineW * sc), 1)   // マス目の線は、粒子に色がついている間も白
            enc.setRenderPipelineState(linePipe)
            enc.setVertexBuffer(segs, offset: 0, index: 0)
            enc.setVertexBytes(&k, length: MemoryLayout<SIMD4<Float>>.stride, index: 5)
            if nGrid > 0 {
                enc.setDepthStencilState(ptDS)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: nGrid)
            }
        }
        lastU = u; lastGrid = nGrid; lastRed = nRed
        // CT 画像: スキャンの面と同じ高さ・同じ進み具合の輪切りを出す(上から下へ = 頭のてっぺんから下へ)
        lastCTAlpha = 0
        if let sy = scanY, ctTex != nil, P.bScanCT > 0.001 {
            let top = 1.0 * P.bScale, x = (top - sy) / (2 * top)
            lastCT = SIMD4(Float(sy), Float(BrainScene.CT_HALF.x * P.bScale), Float(BrainScene.CT_HALF.y * P.bScale),
                           Float(BrainScene.CT_TOP + (BrainScene.CT_BOTTOM - BrainScene.CT_TOP) * x))
            lastCTAlpha = Float(P.bScanCT * scanA)
        }
        enc.endEncoding()
        return m
    }

    /// hdr を、いま開いている描画先(仕上げ前の絵)へ写す
    func drawTone(_ enc: MTLRenderCommandEncoder, exposure: Double, params P: Params, scale: Int) {
        var k = SIMD4<Float>(Float(exposure), 0, 0, 0)
        enc.setRenderPipelineState(tonePipe)
        enc.setFragmentBytes(&k, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.setFragmentTexture(hdr, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        // スキャンの高さの CT 画像を上に重ねる(脳の中の位置にあるが、隠さずに描く)
        if lastCTAlpha > 0.001, let ct = ctTex {
            var u = lastU, k = lastCT, k2 = SIMD4<Float>(lastCTAlpha * Float(exposure / max(1e-6, P.bExposure)), 0, 0, 0)
            enc.setRenderPipelineState(ctPipe)
            enc.setVertexBytes(&u, length: MemoryLayout<BrainUniforms>.stride, index: 4)
            enc.setVertexBytes(&k, length: MemoryLayout<SIMD4<Float>>.stride, index: 5)
            enc.setFragmentBytes(&k, length: MemoryLayout<SIMD4<Float>>.stride, index: 5)
            enc.setFragmentBytes(&k2, length: MemoryLayout<SIMD4<Float>>.stride, index: 6)
            enc.setFragmentTexture(ct, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        // クラップの写真: 画面全体を CT で埋める(3D の絵は出さない)
        if let mo = mosaic, let tex = ctStacks[mo.stack], P.bPhoto > 0.001 {
            var mu = mo.u
            enc.setRenderPipelineState(mosaicPipe)
            enc.setFragmentBytes(&mu, length: MemoryLayout<MosaicU>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        // ドラマーのモデルの区間: 論文の数式を上に重ねる
        if modelNow, P.bEq > 0.001, lastT < P.bEqTo {
            if eqTex == nil { eqTex = makeEquationTexture() }
            if let et = eqTex {
                var k = SIMD4<Float>(Float(P.bEq * exposure / max(1e-6, P.bExposure)), 0, 0, 0)
                enc.setRenderPipelineState(eqPipe)
                enc.setFragmentBytes(&k, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                enc.setFragmentTexture(et, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }
        // 画面に重ねる CT 画像(スキャン中の両脇の連番)
        for o in overlays {
            guard let tex = ctStacks[o.stack] else { continue }
            var iu = o.u
            iu.b.z *= Float(exposure / max(1e-6, P.bExposure))
            enc.setRenderPipelineState(imgPipe)
            enc.setVertexBytes(&iu, length: MemoryLayout<ImgU>.stride, index: 0)
            enc.setFragmentBytes(&iu, length: MemoryLayout<ImgU>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        // 原点の赤い線を上に重ねる(脳の中にあっても見える)
        if lastRed > 0, mosaic == nil {                   // 写真で画面を埋めている間は出さない
            var u = lastU
            var lk = SIMD4<Float>(Float(hdr.width), Float(hdr.height), Float(P.bLineW * Double(scale) * PX), 0)
            enc.setRenderPipelineState(redPipe)
            enc.setVertexBuffer(segs, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<BrainUniforms>.stride, index: 4)
            enc.setVertexBytes(&lk, length: MemoryLayout<SIMD4<Float>>.stride, index: 5)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: lastRed, baseInstance: lastGrid)
        }
    }
}
