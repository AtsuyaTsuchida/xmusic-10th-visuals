import Foundation
import simd

// 音の波形を、格子状に並べた頂点(メッシュ)の高さにして点で描く。
// 仕組みは openFrameworks の ofMesh の例と同じ:
//     z = sin(i*0.1 + t)*10 + sin(j*0.15 + t)*10   … 横の波 + 奥行きの波
// の sin を、いま鳴っている音の波形に置き換えたもの。
//     高さ(i, j) = 横の波 X(i) + 奥行きの波 Y(j)
//     X(i) = いまの 1/30 秒の波形(最初の「横一本の線」そのもの)
//     Y(j) = 同じ瞬間から始まる波形を、奥行き方向に並べたもの
// 値と計算は Web 版(video/viz/index.html)と同じ。

let W = 1920, H = 540, FPS = 30      // 仕上がりの大きさとコマ数
let ROWS = 401                       // 奥行きの列数(中央の列が最初の線)
let JC = Double(ROWS - 1) / 2
let YMAX = 32                        // 奥行き1列あたりの音の点数の上限

// 広がり方(秒, 0=線だけ … 1=面いっぱい)。間はなめらかにつなぐ。
let GROW: [(Double, Double)] = [(25.6, 0), (153.6, 1)]
// カメラの前進(0=元の位置 … 1=面の中心)。面と同じ高さから真っ直ぐ水平に進む。
// 曲の頭から進み始め、一発目のキックが入る時刻にこの位置に着いて、そのあとは動かない。
// 0.194 は、以前の動き(153.6 → 204.8 秒で 0.8 まで)での 2分50秒の位置
let DOLLY_END = 0.194
func dollyKeys(_ track: Track) -> [(Double, Double)] { [(0, 0), (max(0.1, track.firstHit), DOLLY_END)] }
let SPIN_EASE = 3.2                  // 回転が一定の速さになるまでの秒数

/// 見た目の値(パネルのスライダーで動かせる)
final class Params {
    var grow = -0.01      // 広がり。負なら曲の進行に合わせて自動
    var dolly = -0.01     // カメラの前進(0=元の位置, 1=面の中心)。負なら自動
    var turn = 0.0        // 面を縦軸まわりに回す角度(度)。線のときは 0 で、広がるにつれてこの角度まで回る。0 = 回さない
    var turnEnd = 0.6     // 回りきる広がり
    var spin = 0.0        // カメラが面の内部に入ってから、面が水平に回り続ける速さ(度/秒)。0 = 回さない(カメラが進むだけ)
    var tilt = 0.0        // 面を見下ろす角度(度)。0 = 面と同じ高さから水平に見る
    var depth = 7.1       // 面の奥行き(画面の高さの半分 = 1)。7.1 で横幅と同じ = 正方形の面
    var fov = 22.0        // 遠近の強さ(度)
    var amp = 1.0         // 線だけのときの波の高さ
    var ampMesh = 0.30    // 面になったときの波の高さ
    var ymix = 1.0        // 奥行きの波の強さ(横の波 = 1)
    var ytime = 6.0       // 奥行き1列あたりの音の点数(小さいほど奥行きの波がゆるやか)
    var xs = 4.0          // 横は音の何点おきに頂点を置くか
    var size = 1.0        // 点の大きさ(px)
    var gain = 1.0        // 面になったときの点の明るさ
    var width = 2.0       // 最初の線の太さ(px)
    var lineEnd = 0.35    // 線が消えきる広がり
    var fog = 0.5         // 奥を暗くする量
    var color = SIMD3<Float>(1, 1, 1)
    // タイトル: 曲の頭で、文字がゆっくり浮かび上がって消える(どちらのモードでも出る)。書体は Futura の大文字
    var titleLine1 = "SHINYA FUJII"
    var titleLine2 = "10TH ANNIVERSARY SESSION"
    var tTitle = 1.0      // タイトルの明るさ(0 = 出さない)
    var tSize = 56.0      // 1行目の文字の大きさ(1920x540 でのピクセル)。2行目はその半分
    var tTrack = 0.5      // 字間(文字の大きさを 1 として)。2行目はその 1.6 倍
    var tIn = 3.0         // 浮かび上がり始める時刻(秒)
    var tInLen = 6.0      // 浮かび上がるのにかける秒数
    var tOut = 20.0       // 消え始める時刻(秒)
    var tOutLen = 6.0     // 消えるのにかける秒数
    var tBlack = 1.0      // タイトルが出ている間、ほかの絵を消す量(1 = 黒地に文字だけ。タイトルが消えるのに合わせて絵が現れる)
    // ブルーム: 明るい所がにじんで光る。キックのたびに強く光って、すっと引く(どちらのモードでも掛かる)
    var bloom = 6.0       // キックで光る強さ(0 = 光らない)
    var bloomBase = 0.0   // いつも掛けておく強さ
    var bloomDecay = 0.22 // キックの光が引く速さ(秒。この秒数でおよそ 1/3 になる)
    var bloomThresh = 0.15 // これより明るい所だけがにじむ(0 = 全部)
    var bloomSize = 1.0   // にじみの広がり
    // クラップ: 鳴った1コマ(1/30秒)だけ、画面全体の色を反転する
    var flash = 1.0       // 反転する量(0 = しない、1 = 完全に反転)
    var flashVel = 0.0    // この強さ(0..1)より弱いクラップでは反転しない
    // モード: 0 = 波形メッシュ、1 = 動画(動画ファイルを音に合わせて切り替え、ゆらす)
    var mode = 0.0
    // 動画モードの値
    var vMin = 0.8        // 動画を切り替える最短の間隔(秒)。キックが来ても、これより短くは切り替えない
    var vMax = 12.0       // キックが来なくても、この秒数たったら切り替える
    var vSpeed = 1.0      // 動画の再生の速さ
    var vWarpX = 0.0      // 波形で絵を横にずらす量(いったん使わない方針で 0)。以前の値は 0.03(1 = 画面の幅)。画面の縦位置ごとに波形の値を当てる
    var vWarpY = 0.0      // 波形で絵を縦にずらす量(いったん使わない方針で 0)。以前の値は 0.10(1 = 画面の高さ)。0.5 で波形の線とちょうど同じ形
    var vZoom = 0.06      // キックで寄る量
    var vFlash = 0.5      // キックで明るくなる量
    var vShift = 0.004    // キックで色がずれる量(1 = 画面の幅)
    var vSat = 1.0        // 彩度(0 = 白黒)
    var vContrast = 1.0   // コントラスト
    var vBright = 1.0     // 明るさ
    // ライフゲーム: 反応拡散が始まるまで、細かい格子として動画に重ねる。生きているますの中にだけ動画が見える。
    // 音から生まれ、音量に合わせて進む。この間は、波形で絵をずらさない
    var vLife = 0.0       // 重ねる濃さ(0 = 出さない。いまの初期値、いったん使わない方針。動画がそのまま出る)
    var vLifeCols = 480.0 // 格子の横の数(480 で1ます 4 ピクセル)
    var vLifeRate = 10.0  // 世代の進む速さ(世代/秒の目安。音が大きいほど速くなる)
    var vLifeWave = 0.5   // 波形の線の上に生まれる量
    var vLifeBurst = 1.0  // 音の立ち上がりで、まとまってまく量
    var vLifeGrid = 0.06  // 格子の位置に出す点の明るさ
    var vLifeDim = 0.0    // ますの外の動画の明るさ(0 = 真っ暗)
    var vLifeLift = 0.7   // ますの中の動画を明るくする量(色味はそのまま)
    // 反応拡散(Gray-Scott)。キックが入った時刻から、動画に代わって出てくる。動画の明るさが模様の出方を決める
    var vRD = 0.0         // 反応拡散を出す量。0 = 出さない(いまの初期値。いったん使わない方針)。負なら自動(最初のキックから)、0..1 なら手で決める
    var vRDStart = -1.0   // 自動のときの開始(秒)。負なら最初のキックの時刻
    var vRDFade = 1.6     // 動画から反応拡散へ移る長さ(秒)。0 でぱっと切り替わる
    var vRDIters = 14.0   // 1コマあたりの計算回数(模様の動く速さ)
    var vRDSize = 960.0   // 計算する格子の横の数(小さいほど模様が大きい)
    var vRDInject = 1.0   // キックで種をまく量
    var vRDDark = 0.30    // 模様の外の明るさ(動画をどれだけ残すか)
    var vRDEmboss = 0.6   // 模様のふちの陰影
    var vRDLift = 0.7     // 模様の色を明るくそろえる量(色味はそのまま。暗い素材でも模様が見える)
    // 中へ入る: 画面の中心の模様へカメラが寄っていき、その中にまた反応拡散があり、さらにその中へ…と入り続ける
    var vDepth = -0.01    // 深さ(階層)。負なら自動(下の値で時間とともに深くなる)、0 以上なら手で決める
    var vDiveDelay = 12.8 // 反応拡散が始まってから、入り始めるまでの秒数
    var vDiveSec = 6.4    // 1階層ぶん入るのにかける秒数(小さいほど速い)
    var vDiveBoost = 1.0  // キックが多い区間で速くなる量(0 = いつも同じ速さ)
    var vDivePunch = 0.03 // キックで一瞬前へ押し出される量(階層)
    var vHue = 0.08       // 階層ごとに色味をずらす量(1 = 色相を一周)
    var vDiveTurn = 0.0   // 1階層入る間に絵が回る角度(度)。0 = 回さない
    var vCore = 1.15      // 入口の点の大きさ(1 = 寄りきったとき画面の角にちょうど届く大きさ)
    // 手ブレ: 音量に合わせて大きくなる、手持ちカメラのような揺れ。キックで小さく突かれる
    var vShake = 1.0      // 手ブレの大きさ(0 = なし)
    var vShakeKick = 1.0  // キックで突かれる量
    var vLine = 0.0       // 上に重ねる波形の線の明るさ(0 = 出さない。初期値は出さない)
    var vPos = 0.5        // 動画の縦位置(32:9 に切り出す位置。0 = 上、1 = 下)
    // 脳のシーン(モード 2): Curl noise の流れで漂う粒子が、脳の表面に集まる
    var seqCut = 83.2     // 通し(モード 3)で、波形メッシュから脳のシーンへ切り替わる時刻(秒)。このあたりの最初のクラップのコマで切り替わる
    var seqVideo = 1.0    // 通しの終盤(クラップが終わってキックだけが続く区間)を、エフェクトなしの動画素材の切り替えにする(0 = しない)
    var seqVideoHold = 0.4 // 最後のキックのあと、動画を出しておく秒数(そのあと脳のシーンへ戻る)
    var hatRed = 1.0      // 波形のあいだ、ハイハット(Hihat Code)が鳴っている最中だけ波形を赤くする(0 = しない)。鳴っている長さは bScanDur(0.36 秒)
    var hatBlue = 1.0     // 波形が赤くなっている間の、背景の青の濃さ(0 = 黒のまま)
    var seqTypo = 1.0     // 通しの中ほど(クラップが抜けてキックだけになる区間)を、タイポグラフィのパートにする(0 = しない)
    var seqLogo = 1.0     // タイポグラフィのパートの後半(シンセパッドが入る所から)は、文字のかわりに x-Music Laboratory のロゴを置く(0 = 文字のまま)
    var logoFrom = 160.0  // ロゴに替わる時刻(秒)。v9 では、キックの合間に鳴り続ける音(パッド)が 160 秒から入る。このあたりの最初のキックで替わる
    var typoSim = 1.0     // ロゴのパートの背景を、色の面ではなく、ドラマーのモデルのシミュレーションにする(0 = キックで色が替わる面)
    var logoVideo = 1.0   // x-Music のロゴのうしろを、小田急のドラムセッションの動画にする(0 = Neuro と同じくモデルのシミュレーション)
    var seqFx = 1.0       // ロゴのあと(クラップが戻る所から fxTo 秒まで)、同じ動画を流し続けて、キック・クラップ・金物ごとにエフェクトを切り替える(0 = しない)
    var fxTo = 236.8      // エフェクトのパートの終わり(秒)。v9 では、キックだけのパート(終盤の動画)が始まる所
    var seqCycle = 1.0    // 金物が入る所からは、キックごとに素材を順番に回す動画に替える(0 = 小田急の動画のまま。ただし 200 秒で尽きる)
    var fxGrid = 1.0      // 音が鳴らないあいだも、16 分音符(0.1 秒)ごとにエフェクトを切り替える(0 = 鳴ったときだけ)
    var fxBloom = 0.15    // エフェクトのパートでの、キックのブルームの掛かり具合
    var logoScale = 0.7   // ロゴ(アイコンと名前、x-Music のロゴ)の大きさ。1 = 最初の大きさ
    var typoSimDim = 0.5  // ロゴのうしろのシミュレーションの明るさ(1 = そのまま。ロゴが読めるように下げてある)
    var seqDate = 1.0     // 終盤のキックのパートで、中央に日付(2016/04/01 → 2026/11/22)を数えて出す。終わったあとは黒地に日付だけ(0 = 出さない)
    var dateGlowAfter = 5.0 // 今日の日付が出てから、光へ移り始めるまでの秒数
    var dateGlowLen = 4.0  // 日付が消えて光が浮かぶのにかける秒数
    var dateGlow = 0.26   // 光の明るさ(中心)
    var seqBurst = 1.4    // 通しで切り替わった瞬間に、波形の粒が弾け飛ぶ速さ
    var bMorph = -0.01    // 脳になる量(0 = 漂うだけ, 1 = 全部の粒子が脳)。負なら自動(下の時刻で進む)
    var bStart = 90.0     // 自動のとき、脳へ集まり始める時刻(秒)
    var bLen = 19.0       // 集まりきるまでの秒数
    var bCurl = 0.34      // 流れの速さ
    var bFreq = 0.85      // 渦の細かさ(大きいほど小さな渦)
    var bEvolve = 0.12    // 流れの形が変わっていく速さ
    var bSheet = 1.0      // 粒子が膜や筋にまとまる強さ(0 = 一様な霧)
    var bKick = 1.2       // キックで流れが強まる量
    var bPush = 0.10      // キックで、脳の粒子が外へ跳ねる量
    var bWave = 0.03      // いまの波形で、脳の表面が波打つ量
    var bPull = 70.0      // 脳へ引き寄せる強さ
    var bSpin = 6.0       // 脳が回る速さ(度/秒)
    var bYaw = 90.0       // 脳の向き(度)。90 で横顔
    var bScale = 1.35     // 脳の大きさ
    var bSize = 1.3       // 粒子の大きさ(px)
    var bCloud = 0.09    // 漂う粒子の明るさ
    var bBrain = 0.21     // 脳の粒子の明るさ
    var bDots = 0.10      // 脳に着いた粒子のうち、描く割合(小さいほど粒がまばらで、1 粒ずつ見える。1 = 全部描く)
    var bSolid = 0.0      // 1 = うしろの粒を隠して、面のある立体として見せる。0 = 隠さない(透けて見える粒の集まり)
    var bExposure = 1.0   // 全体の明るさ
    var bGrid = 0.22      // マス目の面(xy, yz, zx の 3 枚)の線の明るさ(0 = 出さない)
    var bGridSize = 1.5   // マス目の面の 1 辺(粒子が漂う範囲のいちばん長い辺を 1 として)
    var bAxis = 0.12      // 原点の赤い線の長さ(原点から片側。画面の高さの半分 = 1。0 = 出さない)
    var bAxisBright = 1.0 // 赤い線の濃さ(0..1)
    var bLineW = 2.0      // マス目と赤い線の太さ(px)
    // カメラ(脳のシーン): キックで、次の場所へすばやく回り込む。クラップで、構図(標準・寄り・俯瞰)がぱっと切り替わる
    var bCamWide = 2.0    // 粒が漂っている間の、カメラの引き(1 = 脳ができたときと同じ距離。脳になる量に合わせて 1 へ近づく)
    var bCamKick = 100.0  // キック 1 回で回り込む角度(度。実際は 0.6〜1.4 倍にばらつく。0 = 回らない)
    var bCamCut = 1.0     // 1 = キックでは動きをつけず、原点のまわりの次の場所へぱっと切り替える。0 = ばねの動きで回り込む(下の 2 つの値を使う)
    var bCamDur = 0.40    // 回り込みで、行き先に最初に届くまでの秒数(そのあと通りすぎて、揺れながら収まる)
    var bCamDamp = 0.50   // 回り込みのあとの揺れの収まりやすさ(小さいほど大きく通りすぎて長く揺れる。1 に近いと揺れない)
    var bShake = 1.0      // 手ブレの大きさ(0 = なし)
    var bCamGap = 0.30    // 次の回り込みまでの最短の間隔(秒)。これより詰まったキックでは動かない
    var bCamClap = 1.0    // クラップで構図を切り替える(0 = しない)
    var bCamZoom = 0.50   // 「寄り」のときの距離(標準を 1 として)
    var bCamTop = 62.0    // 「俯瞰」のときの見下ろす角度(度)
    // スキャン(脳のシーン): ハイハットが鳴るたびに、水平なマス目の面が脳の上から下へ降り、通っている高さの粒子が帯になって光る
    var bScan = 14.0      // 帯が光る強さ(0 = 光らせない)
    var bScanLine = 0.9   // スキャンの面のマス目の明るさ(0 = 面を出さない)
    var bScanDur = 0.36   // 上から下まで降りる秒数。0.36 = Hihat Code のサンプルの長さ(34575 点 / 96kHz)
    var bScanCT = 1.0     // スキャンの高さに合う CT 画像(頭の輪切り)を、その高さに重ねる濃さ(0 = 出さない)
    var bScanWidth = 0.05 // 光る帯の幅
    var bScanSize = 2.2   // スキャンの面の大きさ(中心から端まで)
    // 神経細胞の網(脳のシーン): 脳が完成したあとの最初のキックから、脳の中に張り巡らされる
    var bNeuro = 0.30     // 網の明るさ(0 = 出さない)
    var bNeuroDur = 1.6   // 張り巡らされるまでの秒数
    var bNeuroW = 1.2     // 線の太さ(px)
    var bNeuroDim = 1.0   // 網が出ている間の、脳の表面の明るさ(1 = 変えない。下げると中の網が透けて見える)
    // クラップの写真(脳のシーン): 決めた区間のクラップでは、色の反転のかわりに CT 画像を出す。置き方・大きさ・動きは毎回ちがい、同じ画像は二度使わない
    var bPhoto = 1.0      // 写真を出す(0 = 出さない。そのときは色の反転に戻る)
    var photoFrom = 102.0 // 写真を出す区間の始まり(秒)。v9 では、キックだけの区間(96〜102 秒)のあと、クラップが戻る 102.4 秒の手前
    var photoTo = 109.6   // 区間の終わり(秒)。v9 では、ハイハットが入る 109.6 秒
    var bPhotoDur = 0.10  // クラップの瞬間に写真を出しておく最長の秒数(3 コマ)。次のクラップまでの半分より長くはならず、あいだは 3D の絵に戻る
    // ハイハットの間(脳のシーン): 脳を離れて眺めるカメラ位置へ移り、画面の両脇に CT の連番をスキャンと同じ進み方で出す
    var bHatCam = 1.0     // ハイハットの間は客観視のカメラにする(0 = しない)
    var bHatCamYaw = 35.0  // 客観視のカメラの向き(度)。毎回同じ場所
    var bHatCamPitch = 22.0 // 客観視のカメラの高さ(度)
    var bHatCamZoom = 1.7 // 客観視のときの距離(標準を 1 として)
    var bScanSide = 1.0   // スキャン中に両脇へ出す CT の連番の濃さ(0 = 出さない)
    // 脳がほどける(脳のシーン): できあがった脳が、また Curl noise の雲に戻る。そのあと、もう一度集まる
    var bDissolveFrom = 121.6 // ほどけ始める時刻(秒)。v9 では、ハイハットが終わってクラップだけになる所
    var bDissolveTo = 134.4   // ほどけきる時刻(秒)。v9 では、金物のついたハイハットが入る所
    var bReformFrom = 297.1   // もう一度脳に集まり始める時刻(秒)。v9 では、タイポグラフィのパートが終わる所
    var bReformLen = 8.0      // 集まりきるまでの秒数
    // ドラマーのモデル(脳のシーン): 粒子を、藤井さんの論文の式(6)(両手の相対位相のモデル)で動かして、ポテンシャルの地形に並べる。数式を上に重ねる
    var bModel = 1.0      // モデルの区間を入れる(0 = 入れない)
    var bModelFrom = 134.4 // 始まる時刻(秒)
    var bModelTo = 172.8  // 終わる時刻(秒)。ロゴのパートのうしろでも続ける
    var bModelSpin = 9.0  // カメラが回る速さ(度/秒)
    var bModelYaw = 15.0  // カメラの最初の向き(度)
    var bModelPitch = 27.0 // カメラの高さ(度)
    var bModelZoom = 1.55 // カメラの距離(標準を 1 として)
    var bModelMove = 1.0  // Curl noise の雲からモデルの地形へ、粒子が移るのにかける秒数
    var bModelH = 0.115   // 地形の高さの倍率
    var bEq = 0.92        // 数式の濃さ(0 = 出さない)
    var bEqTo = 147.1     // 数式を出しておく時刻(秒)。ここからはロゴが出るので、数式は消す
    var bBloom = 0.3      // このシーンでのブルームの掛かり具合(1 = ほかのモードと同じ。粒子が密なので、そのままだと脳が白く飛ぶ)
    // ドラッグで足す視点の回転
    var yaw = 0.0, pitch = 0.0, zoom = 1.0
}

struct ParamInfo {
    let key: String
    let label: String
    let min: Double, max: Double, step: Double
    let path: ReferenceWritableKeyPath<Params, Double>
    var group = "mesh"      // mesh / video / brain: その モードのスライダーとして出す。common: どちらでも出す。view: 出さない(--set 用)
}

let PARAMS: [ParamInfo] = [
    ParamInfo(key: "grow", label: "広がり(負=自動)", min: -0.01, max: 1, step: 0.01, path: \.grow),
    ParamInfo(key: "dolly", label: "カメラ前進(負=自動)", min: -0.01, max: 1, step: 0.01, path: \.dolly),
    ParamInfo(key: "turn", label: "面の回転", min: -180, max: 180, step: 1, path: \.turn),
    ParamInfo(key: "turnEnd", label: "回りきる広がり", min: 0.05, max: 1, step: 0.01, path: \.turnEnd),
    ParamInfo(key: "spin", label: "内部での回転(度/秒)", min: -60, max: 60, step: 0.5, path: \.spin),
    ParamInfo(key: "tilt", label: "見下ろす角度", min: 0, max: 89, step: 1, path: \.tilt),
    ParamInfo(key: "depth", label: "奥行き", min: 0.5, max: 10, step: 0.1, path: \.depth),
    ParamInfo(key: "fov", label: "遠近", min: 4, max: 70, step: 1, path: \.fov),
    ParamInfo(key: "amp", label: "高さ(線)", min: 0.1, max: 2, step: 0.05, path: \.amp),
    ParamInfo(key: "ampMesh", label: "高さ(面)", min: 0.05, max: 2, step: 0.05, path: \.ampMesh),
    ParamInfo(key: "ymix", label: "奥行きの波の強さ", min: 0, max: 2, step: 0.05, path: \.ymix),
    ParamInfo(key: "ytime", label: "奥行きの波の細かさ", min: 1, max: Double(YMAX), step: 1, path: \.ytime),
    ParamInfo(key: "xs", label: "頂点の横間隔", min: 1, max: 16, step: 1, path: \.xs),
    ParamInfo(key: "size", label: "点の大きさ", min: 1, max: 6, step: 0.1, path: \.size),
    ParamInfo(key: "gain", label: "点の明るさ", min: 0.05, max: 1, step: 0.05, path: \.gain),
    ParamInfo(key: "width", label: "線の太さ", min: 0.5, max: 6, step: 0.1, path: \.width),
    ParamInfo(key: "lineEnd", label: "線が消える広がり", min: 0.02, max: 1, step: 0.01, path: \.lineEnd),
    ParamInfo(key: "fog", label: "奥の暗さ", min: 0, max: 1, step: 0.05, path: \.fog),
    ParamInfo(key: "yaw", label: "視点の横回転(rad)", min: -3.2, max: 3.2, step: 0.01, path: \.yaw, group: "view"),
    ParamInfo(key: "pitch", label: "視点の縦回転(rad)", min: -1.55, max: 1.55, step: 0.01, path: \.pitch, group: "view"),
    ParamInfo(key: "zoom", label: "視点の距離", min: 0.2, max: 4, step: 0.01, path: \.zoom, group: "view"),
    ParamInfo(key: "mode", label: "モード", min: 0, max: 3, step: 1, path: \.mode, group: "view"),
    ParamInfo(key: "tTitle", label: "タイトルの明るさ", min: 0, max: 1, step: 0.01, path: \.tTitle, group: "common"),
    ParamInfo(key: "tBlack", label: "タイトルの間は黒地に", min: 0, max: 1, step: 0.01, path: \.tBlack, group: "common"),
    ParamInfo(key: "tSize", label: "タイトルの大きさ", min: 16, max: 160, step: 1, path: \.tSize, group: "common"),
    ParamInfo(key: "tTrack", label: "タイトルの字間", min: 0, max: 1.5, step: 0.01, path: \.tTrack, group: "common"),
    ParamInfo(key: "tIn", label: "タイトルが出始める秒", min: 0, max: 60, step: 0.1, path: \.tIn, group: "common"),
    ParamInfo(key: "tInLen", label: "浮かび上がる長さ(秒)", min: 0.1, max: 30, step: 0.1, path: \.tInLen, group: "common"),
    ParamInfo(key: "tOut", label: "タイトルが消え始める秒", min: 0, max: 120, step: 0.1, path: \.tOut, group: "common"),
    ParamInfo(key: "tOutLen", label: "消える長さ(秒)", min: 0.1, max: 30, step: 0.1, path: \.tOutLen, group: "common"),
    ParamInfo(key: "bloom", label: "キックのブルーム", min: 0, max: 12, step: 0.05, path: \.bloom, group: "common"),
    ParamInfo(key: "bloomBase", label: "常時のブルーム", min: 0, max: 3, step: 0.05, path: \.bloomBase, group: "common"),
    ParamInfo(key: "bloomDecay", label: "ブルームが引く秒数", min: 0.03, max: 1.5, step: 0.01, path: \.bloomDecay, group: "common"),
    ParamInfo(key: "bloomThresh", label: "にじむ明るさの下限", min: 0, max: 0.95, step: 0.01, path: \.bloomThresh, group: "common"),
    ParamInfo(key: "bloomSize", label: "にじみの広がり", min: 0.3, max: 3, step: 0.05, path: \.bloomSize, group: "common"),
    ParamInfo(key: "flash", label: "クラップで反転", min: 0, max: 1, step: 0.05, path: \.flash, group: "common"),
    ParamInfo(key: "flashVel", label: "反転するクラップの強さ", min: 0, max: 1, step: 0.01, path: \.flashVel, group: "common"),
    ParamInfo(key: "vMin", label: "切り替えの最短間隔(秒)", min: 0.1, max: 8, step: 0.1, path: \.vMin, group: "video"),
    ParamInfo(key: "vMax", label: "切り替えの最長間隔(秒)", min: 1, max: 60, step: 0.5, path: \.vMax, group: "video"),
    ParamInfo(key: "vSpeed", label: "再生の速さ", min: 0.1, max: 4, step: 0.05, path: \.vSpeed, group: "video"),
    ParamInfo(key: "vPos", label: "動画の縦位置", min: 0, max: 1, step: 0.01, path: \.vPos, group: "video"),
    ParamInfo(key: "vLife", label: "ライフゲームの濃さ", min: 0, max: 1, step: 0.01, path: \.vLife, group: "video"),
    ParamInfo(key: "vLifeCols", label: "ライフの格子(横の数)", min: 96, max: 960, step: 16, path: \.vLifeCols, group: "video"),
    ParamInfo(key: "vLifeRate", label: "ライフの進む速さ", min: 0, max: 60, step: 0.5, path: \.vLifeRate, group: "video"),
    ParamInfo(key: "vLifeWave", label: "波形から生まれる量", min: 0, max: 1, step: 0.01, path: \.vLifeWave, group: "video"),
    ParamInfo(key: "vLifeBurst", label: "音の立ち上がりでまく", min: 0, max: 2, step: 0.05, path: \.vLifeBurst, group: "video"),
    ParamInfo(key: "vLifeGrid", label: "格子の点の明るさ", min: 0, max: 0.5, step: 0.01, path: \.vLifeGrid, group: "video"),
    ParamInfo(key: "vLifeDim", label: "ますの外の明るさ", min: 0, max: 1, step: 0.01, path: \.vLifeDim, group: "video"),
    ParamInfo(key: "vLifeLift", label: "ますの中を明るく", min: 0, max: 1, step: 0.01, path: \.vLifeLift, group: "video"),
    ParamInfo(key: "vRD", label: "反応拡散(負=自動)", min: -0.01, max: 1, step: 0.01, path: \.vRD, group: "video"),
    ParamInfo(key: "vRDStart", label: "反応拡散の開始秒(負=キック)", min: -1, max: 300, step: 0.1, path: \.vRDStart, group: "video"),
    ParamInfo(key: "vRDFade", label: "反応拡散へ移る長さ(秒)", min: 0, max: 16, step: 0.1, path: \.vRDFade, group: "video"),
    ParamInfo(key: "vRDIters", label: "模様の動く速さ", min: 1, max: 40, step: 1, path: \.vRDIters, group: "video"),
    ParamInfo(key: "vRDSize", label: "模様の細かさ", min: 320, max: 1920, step: 16, path: \.vRDSize, group: "video"),
    ParamInfo(key: "vRDInject", label: "キックで種をまく", min: 0, max: 4, step: 0.05, path: \.vRDInject, group: "video"),
    ParamInfo(key: "vRDDark", label: "模様の外の明るさ", min: 0, max: 1, step: 0.01, path: \.vRDDark, group: "video"),
    ParamInfo(key: "vRDLift", label: "模様の色を明るく", min: 0, max: 1, step: 0.01, path: \.vRDLift, group: "video"),
    ParamInfo(key: "vRDEmboss", label: "模様の陰影", min: 0, max: 3, step: 0.05, path: \.vRDEmboss, group: "video"),
    ParamInfo(key: "vDepth", label: "中へ入る深さ(負=自動)", min: -0.01, max: 12, step: 0.01, path: \.vDepth, group: "video"),
    ParamInfo(key: "vDiveDelay", label: "入り始めるまで(秒)", min: 0, max: 120, step: 0.1, path: \.vDiveDelay, group: "video"),
    ParamInfo(key: "vDiveSec", label: "1階層に入る秒数", min: 0.5, max: 60, step: 0.1, path: \.vDiveSec, group: "video"),
    ParamInfo(key: "vDiveBoost", label: "キックが多いと速く", min: 0, max: 4, step: 0.05, path: \.vDiveBoost, group: "video"),
    ParamInfo(key: "vDivePunch", label: "キックで前へ押す", min: 0, max: 0.3, step: 0.005, path: \.vDivePunch, group: "video"),
    ParamInfo(key: "vHue", label: "階層ごとの色のずれ", min: 0, max: 0.5, step: 0.01, path: \.vHue, group: "video"),
    ParamInfo(key: "vDiveTurn", label: "入りながら回る(度/階層)", min: -180, max: 180, step: 1, path: \.vDiveTurn, group: "video"),
    ParamInfo(key: "vCore", label: "入口の点の大きさ", min: 0.8, max: 3, step: 0.05, path: \.vCore, group: "video"),
    ParamInfo(key: "vShake", label: "手ブレ", min: 0, max: 4, step: 0.05, path: \.vShake, group: "video"),
    ParamInfo(key: "vShakeKick", label: "キックで突かれる", min: 0, max: 4, step: 0.05, path: \.vShakeKick, group: "video"),
    ParamInfo(key: "vWarpX", label: "波形で横にずらす", min: 0, max: 0.5, step: 0.005, path: \.vWarpX, group: "video"),
    ParamInfo(key: "vWarpY", label: "波形で縦にずらす", min: 0, max: 1, step: 0.01, path: \.vWarpY, group: "video"),
    ParamInfo(key: "vZoom", label: "キックで寄る", min: 0, max: 0.5, step: 0.01, path: \.vZoom, group: "video"),
    ParamInfo(key: "vFlash", label: "キックで明るく", min: 0, max: 3, step: 0.05, path: \.vFlash, group: "video"),
    ParamInfo(key: "vShift", label: "キックで色ずれ", min: 0, max: 0.05, step: 0.001, path: \.vShift, group: "video"),
    ParamInfo(key: "vSat", label: "彩度", min: 0, max: 2, step: 0.05, path: \.vSat, group: "video"),
    ParamInfo(key: "vContrast", label: "コントラスト", min: 0.2, max: 3, step: 0.05, path: \.vContrast, group: "video"),
    ParamInfo(key: "vBright", label: "明るさ", min: 0, max: 3, step: 0.05, path: \.vBright, group: "video"),
    ParamInfo(key: "vLine", label: "波形の線の明るさ", min: 0, max: 1, step: 0.05, path: \.vLine, group: "video"),
    ParamInfo(key: "seqCut", label: "通し: 切り替わる秒", min: 0, max: 360, step: 0.1, path: \.seqCut, group: "common"),
    ParamInfo(key: "seqVideo", label: "通し: 終盤は素材の切替", min: 0, max: 1, step: 1, path: \.seqVideo, group: "common"),
    ParamInfo(key: "hatRed", label: "ハイハットで波形の色", min: 0, max: 1, step: 1, path: \.hatRed, group: "common"),
    ParamInfo(key: "hatBlue", label: "その間の背景の色の濃さ", min: 0, max: 1, step: 0.01, path: \.hatBlue, group: "common"),
    ParamInfo(key: "seqTypo", label: "通し: タイポグラフィ", min: 0, max: 1, step: 1, path: \.seqTypo, group: "common"),
    ParamInfo(key: "seqLogo", label: "通し: 後半はロゴ", min: 0, max: 1, step: 1, path: \.seqLogo, group: "common"),
    ParamInfo(key: "logoFrom", label: "ロゴに替わる秒", min: 0, max: 360, step: 0.1, path: \.logoFrom, group: "common"),
    ParamInfo(key: "typoSim", label: "ロゴの背景はモデル", min: 0, max: 1, step: 1, path: \.typoSim, group: "common"),
    ParamInfo(key: "logoVideo", label: "x-Music の背景は動画", min: 0, max: 1, step: 1, path: \.logoVideo, group: "common"),
    ParamInfo(key: "seqFx", label: "通し: 動画にエフェクト", min: 0, max: 1, step: 1, path: \.seqFx, group: "common"),
    ParamInfo(key: "seqCycle", label: "通し: 金物から順番に", min: 0, max: 1, step: 1, path: \.seqCycle, group: "common"),
    ParamInfo(key: "fxTo", label: "エフェクトの終わり(秒)", min: 0, max: 360, step: 0.1, path: \.fxTo, group: "common"),
    ParamInfo(key: "fxGrid", label: "16分ごとにも切替", min: 0, max: 1, step: 1, path: \.fxGrid, group: "common"),
    ParamInfo(key: "fxBloom", label: "エフェクト中のブルーム", min: 0, max: 1, step: 0.01, path: \.fxBloom, group: "common"),
    ParamInfo(key: "logoScale", label: "ロゴの大きさ", min: 0.2, max: 1.2, step: 0.01, path: \.logoScale, group: "common"),
    ParamInfo(key: "typoSimDim", label: "ロゴの背景の明るさ", min: 0, max: 1, step: 0.01, path: \.typoSimDim, group: "common"),
    ParamInfo(key: "seqDate", label: "通し: 終盤に日付", min: 0, max: 1, step: 1, path: \.seqDate, group: "common"),
    ParamInfo(key: "dateGlowAfter", label: "日付のあと光まで(秒)", min: 0, max: 60, step: 0.5, path: \.dateGlowAfter, group: "common"),
    ParamInfo(key: "dateGlowLen", label: "光へ移る長さ(秒)", min: 0.1, max: 30, step: 0.1, path: \.dateGlowLen, group: "common"),
    ParamInfo(key: "dateGlow", label: "最後の光の明るさ", min: 0, max: 1, step: 0.01, path: \.dateGlow, group: "common"),
    ParamInfo(key: "seqBurst", label: "通し: 弾け飛ぶ速さ", min: 0, max: 8, step: 0.05, path: \.seqBurst, group: "common"),
    ParamInfo(key: "bMorph", label: "脳になる量(負=自動)", min: -0.01, max: 1, step: 0.01, path: \.bMorph, group: "brain"),
    ParamInfo(key: "bStart", label: "集まり始める秒", min: 0, max: 360, step: 0.1, path: \.bStart, group: "brain"),
    ParamInfo(key: "bLen", label: "集まりきるまで(秒)", min: 1, max: 240, step: 0.5, path: \.bLen, group: "brain"),
    ParamInfo(key: "bCurl", label: "流れの速さ", min: 0, max: 2, step: 0.01, path: \.bCurl, group: "brain"),
    ParamInfo(key: "bFreq", label: "渦の細かさ", min: 0.2, max: 4, step: 0.05, path: \.bFreq, group: "brain"),
    ParamInfo(key: "bEvolve", label: "流れが変わる速さ", min: 0, max: 1, step: 0.01, path: \.bEvolve, group: "brain"),
    ParamInfo(key: "bSheet", label: "膜にまとまる強さ", min: 0, max: 3, step: 0.05, path: \.bSheet, group: "brain"),
    ParamInfo(key: "bKick", label: "キックで流れが強まる", min: 0, max: 6, step: 0.05, path: \.bKick, group: "brain"),
    ParamInfo(key: "bPush", label: "キックで外へ跳ねる", min: 0, max: 1, step: 0.01, path: \.bPush, group: "brain"),
    ParamInfo(key: "bWave", label: "波形で波打つ", min: 0, max: 0.5, step: 0.005, path: \.bWave, group: "brain"),
    ParamInfo(key: "bPull", label: "引き寄せる強さ", min: 5, max: 200, step: 1, path: \.bPull, group: "brain"),
    ParamInfo(key: "bSpin", label: "脳が回る速さ(度/秒)", min: -60, max: 60, step: 0.5, path: \.bSpin, group: "brain"),
    ParamInfo(key: "bYaw", label: "脳の向き(度)", min: -180, max: 180, step: 1, path: \.bYaw, group: "brain"),
    ParamInfo(key: "bScale", label: "脳の大きさ", min: 0.3, max: 2.5, step: 0.01, path: \.bScale, group: "brain"),
    ParamInfo(key: "bSize", label: "粒子の大きさ", min: 0.5, max: 6, step: 0.05, path: \.bSize, group: "brain"),
    ParamInfo(key: "bCloud", label: "漂う粒子の明るさ", min: 0, max: 0.5, step: 0.005, path: \.bCloud, group: "brain"),
    ParamInfo(key: "bBrain", label: "脳の粒子の明るさ", min: 0, max: 2, step: 0.01, path: \.bBrain, group: "brain"),
    ParamInfo(key: "bDots", label: "脳の粒を描く割合", min: 0.005, max: 1, step: 0.005, path: \.bDots, group: "brain"),
    ParamInfo(key: "bSolid", label: "うしろの粒を隠す", min: 0, max: 1, step: 1, path: \.bSolid, group: "brain"),
    ParamInfo(key: "bExposure", label: "全体の明るさ", min: 0.1, max: 5, step: 0.05, path: \.bExposure, group: "brain"),
    ParamInfo(key: "bGrid", label: "マス目の明るさ", min: 0, max: 2, step: 0.01, path: \.bGrid, group: "brain"),
    ParamInfo(key: "bGridSize", label: "マス目の面の大きさ", min: 0.3, max: 4, step: 0.05, path: \.bGridSize, group: "brain"),
    ParamInfo(key: "bAxis", label: "赤い線の長さ", min: 0, max: 4, step: 0.05, path: \.bAxis, group: "brain"),
    ParamInfo(key: "bAxisBright", label: "赤い線の濃さ", min: 0, max: 1, step: 0.01, path: \.bAxisBright, group: "brain"),
    ParamInfo(key: "bLineW", label: "線の太さ", min: 0.5, max: 6, step: 0.1, path: \.bLineW, group: "brain"),
    ParamInfo(key: "bCamWide", label: "はじめの引き", min: 1, max: 5, step: 0.05, path: \.bCamWide, group: "brain"),
    ParamInfo(key: "bCamKick", label: "キックで回り込む角度", min: 0, max: 3600, step: 1, path: \.bCamKick, group: "brain"),
    ParamInfo(key: "bCamCut", label: "キックはぱっと切替", min: 0, max: 1, step: 1, path: \.bCamCut, group: "brain"),
    ParamInfo(key: "bCamDur", label: "回り込みの秒数", min: 0.03, max: 1.5, step: 0.01, path: \.bCamDur, group: "brain"),
    ParamInfo(key: "bCamDamp", label: "余韻の収まりやすさ", min: 0.05, max: 0.95, step: 0.01, path: \.bCamDamp, group: "brain"),
    ParamInfo(key: "bShake", label: "手ブレ", min: 0, max: 4, step: 0.05, path: \.bShake, group: "brain"),
    ParamInfo(key: "bCamGap", label: "回り込みの最短間隔", min: 0, max: 4, step: 0.05, path: \.bCamGap, group: "brain"),
    ParamInfo(key: "bCamClap", label: "クラップで構図を切替", min: 0, max: 1, step: 1, path: \.bCamClap, group: "brain"),
    ParamInfo(key: "bCamZoom", label: "寄りの距離", min: 0.15, max: 1, step: 0.01, path: \.bCamZoom, group: "brain"),
    ParamInfo(key: "bCamTop", label: "俯瞰の角度(度)", min: 10, max: 88, step: 1, path: \.bCamTop, group: "brain"),
    ParamInfo(key: "bScan", label: "スキャンの帯の強さ", min: 0, max: 30, step: 0.1, path: \.bScan, group: "brain"),
    ParamInfo(key: "bScanLine", label: "スキャンの面の明るさ", min: 0, max: 3, step: 0.01, path: \.bScanLine, group: "brain"),
    ParamInfo(key: "bScanDur", label: "スキャンの秒数", min: 0.1, max: 3, step: 0.01, path: \.bScanDur, group: "brain"),
    ParamInfo(key: "bScanCT", label: "スキャンのCT画像の濃さ", min: 0, max: 1, step: 0.01, path: \.bScanCT, group: "brain"),
    ParamInfo(key: "bScanWidth", label: "スキャンの帯の幅", min: 0.005, max: 0.3, step: 0.005, path: \.bScanWidth, group: "brain"),
    ParamInfo(key: "bScanSize", label: "スキャンの面の大きさ", min: 0.5, max: 6, step: 0.05, path: \.bScanSize, group: "brain"),
    ParamInfo(key: "bNeuro", label: "神経の網の明るさ", min: 0, max: 3, step: 0.01, path: \.bNeuro, group: "brain"),
    ParamInfo(key: "bNeuroDur", label: "網が広がる秒数", min: 0.1, max: 10, step: 0.05, path: \.bNeuroDur, group: "brain"),
    ParamInfo(key: "bNeuroW", label: "網の線の太さ", min: 0.5, max: 5, step: 0.1, path: \.bNeuroW, group: "brain"),
    ParamInfo(key: "bNeuroDim", label: "網の間の脳の明るさ", min: 0, max: 1, step: 0.01, path: \.bNeuroDim, group: "brain"),
    ParamInfo(key: "bPhoto", label: "クラップで写真", min: 0, max: 1, step: 1, path: \.bPhoto, group: "brain"),
    ParamInfo(key: "photoFrom", label: "写真の区間の始まり(秒)", min: 0, max: 360, step: 0.1, path: \.photoFrom, group: "brain"),
    ParamInfo(key: "photoTo", label: "写真の区間の終わり(秒)", min: 0, max: 360, step: 0.1, path: \.photoTo, group: "brain"),
    ParamInfo(key: "bPhotoDur", label: "写真 1 枚の最長秒数", min: 0.05, max: 2, step: 0.01, path: \.bPhotoDur, group: "brain"),
    ParamInfo(key: "bHatCam", label: "ハイハットで客観視", min: 0, max: 1, step: 1, path: \.bHatCam, group: "brain"),
    ParamInfo(key: "bHatCamYaw", label: "客観視の向き(度)", min: -180, max: 180, step: 1, path: \.bHatCamYaw, group: "brain"),
    ParamInfo(key: "bHatCamPitch", label: "客観視の高さ(度)", min: -80, max: 85, step: 1, path: \.bHatCamPitch, group: "brain"),
    ParamInfo(key: "bHatCamZoom", label: "客観視の距離", min: 0.5, max: 4, step: 0.05, path: \.bHatCamZoom, group: "brain"),
    ParamInfo(key: "bScanSide", label: "両脇の CT の濃さ", min: 0, max: 1, step: 0.01, path: \.bScanSide, group: "brain"),
    ParamInfo(key: "bDissolveFrom", label: "脳がほどけ始める秒", min: 0, max: 360, step: 0.1, path: \.bDissolveFrom, group: "brain"),
    ParamInfo(key: "bDissolveTo", label: "ほどけきる秒", min: 0, max: 360, step: 0.1, path: \.bDissolveTo, group: "brain"),
    ParamInfo(key: "bReformFrom", label: "もう一度集まる秒", min: 0, max: 360, step: 0.1, path: \.bReformFrom, group: "brain"),
    ParamInfo(key: "bReformLen", label: "集まり直す長さ(秒)", min: 0.5, max: 60, step: 0.5, path: \.bReformLen, group: "brain"),
    ParamInfo(key: "bModel", label: "ドラマーのモデル", min: 0, max: 1, step: 1, path: \.bModel, group: "brain"),
    ParamInfo(key: "bModelFrom", label: "モデルの始まり(秒)", min: 0, max: 360, step: 0.1, path: \.bModelFrom, group: "brain"),
    ParamInfo(key: "bModelTo", label: "モデルの終わり(秒)", min: 0, max: 360, step: 0.1, path: \.bModelTo, group: "brain"),
    ParamInfo(key: "bModelSpin", label: "モデル: 回る速さ(度/秒)", min: -60, max: 60, step: 0.5, path: \.bModelSpin, group: "brain"),
    ParamInfo(key: "bModelPitch", label: "モデル: カメラの高さ", min: -20, max: 85, step: 1, path: \.bModelPitch, group: "brain"),
    ParamInfo(key: "bModelZoom", label: "モデル: カメラの距離", min: 0.3, max: 4, step: 0.05, path: \.bModelZoom, group: "brain"),
    ParamInfo(key: "bModelMove", label: "モデルへ移る秒数", min: 0.05, max: 5, step: 0.05, path: \.bModelMove, group: "brain"),
    ParamInfo(key: "bModelH", label: "モデル: 地形の高さ", min: 0.01, max: 0.3, step: 0.005, path: \.bModelH, group: "brain"),
    ParamInfo(key: "bEq", label: "数式の濃さ", min: 0, max: 1, step: 0.01, path: \.bEq, group: "brain"),
    ParamInfo(key: "bBloom", label: "ブルームの掛かり具合", min: 0, max: 1, step: 0.01, path: \.bBloom, group: "brain"),
]

func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

func curve(_ keys: [(Double, Double)], _ t: Double) -> Double {
    if t <= keys[0].0 { return keys[0].1 }
    for i in 1..<keys.count where t <= keys[i].0 {
        let (ta, ga) = keys[i - 1], (tb, gb) = keys[i]
        return ga + (gb - ga) * smooth(ta, tb, t)
    }
    return keys[keys.count - 1].1
}

/// カメラが面の手前の端を越える時刻(自動の前進での値)。ここから面が回り始める
func enterTime(dist: Double, keys: [(Double, Double)]) -> Double {
    let edge = 1 - (Double(W) / Double(H)) / dist
    let ta = keys[0].0, tb = keys[keys.count - 1].0
    var t = ta
    while t <= tb {
        if curve(keys, t) >= edge { return t }
        t += 1 / Double(FPS)
    }
    return .infinity
}

/// 回転の角度(度)。止まった状態から SPIN_EASE 秒かけてなめらかに一定の速さになる
func spinAt(_ t: Double, enter: Double, spin: Double) -> Double {
    let u = t - enter
    if !(u > 0) { return 0 }
    let x = min(1, u / SPIN_EASE)
    return spin * (SPIN_EASE * (x * x * x - x * x * x * x / 2) + max(0, u - SPIN_EASE))
}

// 行列(列優先。OpenGL と同じ並び)
func perspective(fovy: Double, aspect: Double, near n: Double, far f: Double) -> simd_double4x4 {
    let t = 1 / tan(fovy / 2)
    return simd_double4x4(columns: (
        SIMD4(t / aspect, 0, 0, 0), SIMD4(0, t, 0, 0),
        SIMD4(0, 0, (f + n) / (n - f), -1), SIMD4(0, 0, 2 * f * n / (n - f), 0)))
}

func lookAt(eye e: SIMD3<Double>, center c: SIMD3<Double>, up: SIMD3<Double>) -> simd_double4x4 {
    let z = simd_normalize(e - c), x = simd_normalize(simd_cross(up, z)), y = simd_cross(z, x)
    return simd_double4x4(columns: (
        SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
        SIMD4(-simd_dot(x, e), -simd_dot(y, e), -simd_dot(z, e), 1)))
}
