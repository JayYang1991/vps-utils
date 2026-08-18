/**
 * Static Decoy / Landing Page: 汉武帝刘彻生平与汉赋华章
 * Displays an authentic, rich historical biography of Emperor Wu of Han
 */

export function renderLandingPage() {
  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>汉武盛世 · 汉武大帝刘彻生平述略</title>
  <meta name="description" content="汉武帝刘彻（公元前156年-公元前87年），西汉第七位皇帝，杰出的政治家、战略家、文学家。开疆拓土，独尊儒术，凿空西域，铸就大汉雄风。">
  <style>
    :root {
      --bg-dark: #0f141c;
      --bg-card: #18202c;
      --bg-card-hover: #1e293b;
      --border-color: #2e3a4e;
      --gold-primary: #d4af37;
      --gold-light: #f3e5ab;
      --gold-dark: #997a15;
      --red-accent: #8b1e1e;
      --text-main: #f1f5f9;
      --text-muted: #94a3b8;
      --text-dim: #64748b;
      --radius: 8px;
    }

    * { margin: 0; padding: 0; box-sizing: border-box; }

    body {
      background-color: var(--bg-dark);
      color: var(--text-main);
      font-family: -apple-system, BlinkMacSystemFont, "Noto Serif SC", "Source Han Serif SC", "Songti SC", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", serif;
      line-height: 1.8;
      letter-spacing: 0.02em;
    }

    header {
      background: linear-gradient(180deg, rgba(15, 20, 28, 0.95) 0%, rgba(15, 20, 28, 0.8) 100%);
      backdrop-filter: blur(12px);
      position: sticky;
      top: 0;
      z-index: 100;
      border-bottom: 1px solid var(--border-color);
    }

    .nav-container {
      max-width: 1100px;
      margin: 0 auto;
      padding: 1rem 1.5rem;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }

    .site-title {
      font-size: 1.25rem;
      font-weight: 700;
      color: var(--gold-light);
      display: flex;
      align-items: center;
      gap: 8px;
      text-decoration: none;
    }

    .site-title span {
      background: var(--red-accent);
      color: #fff;
      font-size: 0.75rem;
      padding: 2px 6px;
      border-radius: 4px;
      font-family: sans-serif;
    }

    .nav-menu {
      display: flex;
      gap: 1.5rem;
      list-style: none;
    }

    .nav-menu a {
      color: var(--text-muted);
      text-decoration: none;
      font-size: 0.9rem;
      transition: color 0.2s;
    }

    .nav-menu a:hover {
      color: var(--gold-light);
    }

    .container {
      max-width: 1100px;
      margin: 0 auto;
      padding: 2rem 1.5rem;
    }

    /* Hero Banner */
    .hero {
      text-align: center;
      padding: 4rem 1rem 3rem;
      border-bottom: 1px solid var(--border-color);
      position: relative;
    }

    .hero-badge {
      display: inline-block;
      border: 1px solid var(--gold-dark);
      color: var(--gold-light);
      padding: 4px 14px;
      font-size: 0.8rem;
      border-radius: 999px;
      margin-bottom: 1.5rem;
      background: rgba(212, 175, 55, 0.08);
    }

    .hero h1 {
      font-size: 2.8rem;
      font-weight: 800;
      color: var(--gold-light);
      letter-spacing: 0.06em;
      margin-bottom: 1rem;
      text-shadow: 0 2px 10px rgba(0,0,0,0.5);
    }

    .hero-subtitle {
      font-size: 1.2rem;
      color: var(--text-muted);
      max-width: 760px;
      margin: 0 auto 2rem;
      font-weight: 300;
    }

    .hero-quote {
      font-style: italic;
      color: #cbd5e1;
      background: rgba(24, 32, 44, 0.7);
      border-left: 3px solid var(--gold-primary);
      padding: 1rem 1.5rem;
      max-width: 680px;
      margin: 0 auto;
      text-align: left;
      font-size: 0.95rem;
      border-radius: 0 var(--radius) var(--radius) 0;
    }

    /* Content Sections */
    .section-title {
      font-size: 1.6rem;
      color: var(--gold-light);
      margin: 3rem 0 1.5rem;
      display: flex;
      align-items: center;
      gap: 12px;
      border-bottom: 1px solid var(--border-color);
      padding-bottom: 0.6rem;
    }

    .section-title::before {
      content: "";
      display: inline-block;
      width: 6px;
      height: 1.4rem;
      background: var(--gold-primary);
      border-radius: 2px;
    }

    .grid-2 {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: 1.5rem;
      margin-bottom: 1.5rem;
    }

    .card {
      background: var(--bg-card);
      border: 1px solid var(--border-color);
      border-radius: var(--radius);
      padding: 1.5rem;
      transition: all 0.2s;
    }

    .card:hover {
      background: var(--bg-card-hover);
      border-color: #3b4d66;
    }

    .card h3 {
      font-size: 1.15rem;
      color: var(--gold-light);
      margin-bottom: 0.75rem;
      display: flex;
      align-items: center;
      gap: 6px;
    }

    .card p {
      font-size: 0.92rem;
      color: #cbd5e1;
      text-align: justify;
    }

    /* Timeline */
    .timeline {
      position: relative;
      margin: 2rem 0;
      padding-left: 24px;
      border-left: 2px solid var(--border-color);
    }

    .timeline-item {
      position: relative;
      margin-bottom: 2rem;
    }

    .timeline-item::before {
      content: "";
      position: absolute;
      left: -31px;
      top: 6px;
      width: 12px;
      height: 12px;
      border-radius: 50%;
      background: var(--gold-primary);
      box-shadow: 0 0 0 4px var(--bg-dark);
    }

    .timeline-year {
      font-weight: 700;
      color: var(--gold-primary);
      font-size: 1rem;
      margin-bottom: 0.25rem;
    }

    .timeline-content {
      font-size: 0.92rem;
      color: #e2e8f0;
    }

    /* Evaluation Table */
    .eval-table {
      width: 100%;
      border-collapse: collapse;
      margin: 1.5rem 0;
      font-size: 0.9rem;
    }

    .eval-table th, .eval-table td {
      border: 1px solid var(--border-color);
      padding: 12px 16px;
      text-align: left;
    }

    .eval-table th {
      background: #111722;
      color: var(--gold-light);
      font-weight: 600;
    }

    .eval-table tr:nth-child(even) {
      background: rgba(255,255,255,0.02);
    }

    footer {
      border-top: 1px solid var(--border-color);
      padding: 3rem 1.5rem;
      text-align: center;
      color: var(--text-dim);
      font-size: 0.85rem;
      margin-top: 4rem;
    }

    @media (max-width: 768px) {
      .hero h1 { font-size: 2rem; }
      .nav-menu { display: none; }
      .grid-2 { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>

  <header>
    <div class="nav-container">
      <a href="/" class="site-title">
        <span>西汉</span> 汉武大帝 · 刘彻生平志
      </a>
      <ul class="nav-menu">
        <li><a href="#overview">生平述要</a></li>
        <li><a href="#governance">内修政理</a></li>
        <li><a href="#military">北击匈奴</a></li>
        <li><a href="#silkroad">凿空西域</a></li>
        <li><a href="#culture">文治华章</a></li>
        <li><a href="#timeline">大事年表</a></li>
      </ul>
    </div>
  </header>

  <main class="container">

    <!-- Hero Section -->
    <section class="hero">
      <div class="hero-badge">公元前156年 － 公元前87年 · 在位五十四年</div>
      <h1>雄才大略 · 冠绝百代</h1>
      <p class="hero-subtitle">
        汉武帝刘彻，西汉第七位皇帝，杰出的政治家、战略家与文学家。他以内圣外王之略，罢黜百家、独尊儒术；北却匈奴、封狼居胥；凿空西域、开通丝路，奠定了华夏版图与汉民族之魂。
      </p>
      <div class="hero-quote">
        “惜秦皇汉武，略输文采；唐宗宋祖，稍逊风骚。一代天骄，成吉思汗，只识弯弓射大雕。俱往矣，数风流人物，还看今朝。” —— 毛泽东《沁园春·雪》
      </div>
    </section>

    <!-- 生平述要 -->
    <section id="overview">
      <h2 class="section-title">生平概览与初政</h2>
      <div class="grid-2">
        <div class="card">
          <h3>👑 少年登基与建元新政</h3>
          <p>
            汉武帝生于汉景帝前元元年（前156年），初名刘彘，七岁立为皇太子。前141年即位，时年十六岁。即位之初起用赵绾、王臧等儒生推行“建元新政”，因触及窦太后所持黄老无为之策而暂受波折，却显露出年轻君主锐意变革、大展宏图的宏大志愿。
          </p>
        </div>
        <div class="card">
          <h3>🏛️ 掌握朝纲与全面亲政</h3>
          <p>
            建元六年（前135年）窦太后崩逝后，汉武帝正式全面亲政。他任用贤能、广开言路，打破血缘世袭藩篱，设立“中朝”以削弱相权，将国家最高决断权收归帝王一身，开创了西汉中央集权体制的新纪元。
          </p>
        </div>
      </div>
    </section>

    <!-- 内修政理 -->
    <section id="governance">
      <h2 class="section-title">内修制度与经济均输</h2>
      <div class="grid-2">
        <div class="card">
          <h3>📜 推恩令与加强中央集权</h3>
          <p>
            采纳主父偃之策颁布<strong>“推恩令”</strong>，允许诸侯王将封地分封给子弟为列侯，由汉廷统辖郡县，化整为零地彻底瓦解了汉初以来同姓诸侯割据隐患；配合“附益法”与“左官律”，使诸侯王无力与中央抗衡。
          </p>
        </div>
        <div class="card">
          <h3>🪙 统一币制与盐铁官营</h3>
          <p>
            任用桑弘羊等人推行经济改革：收回郡国铸币权，由上林三官统一铸造<strong>“五铢钱”</strong>；实行盐、铁、酒专卖官营；创立<strong>均输、平准法</strong>平抑物价，充盈国库，为长年经略边疆提供了坚实的财政物质保障。
          </p>
        </div>
        <div class="card">
          <h3>⚖️ 十三州部刺史制度</h3>
          <p>
            元封五年（前106年），将全国除三辅以外划分为十三州部，每州设刺史一人，以“六条问事”监察郡国守相及地方豪强，极大地加强了中央朝廷对地方官员与豪强势力的监察威慑。
          </p>
        </div>
        <div class="card">
          <h3>🌾 兴修水利与治理黄河</h3>
          <p>
            亲自率领群臣到瓠子（今河南濮阳）堵塞决口，作《瓠子之歌》；大规模开凿白渠、六辅渠、龙首渠等水利工程，使关中及黄河中下游农业生产得到长足发展。
          </p>
        </div>
      </div>
    </section>

    <!-- 北击匈奴 -->
    <section id="military">
      <h2 class="section-title">开疆拓土与北击匈奴</h2>
      <div class="grid-2">
        <div class="card">
          <h3>⚔️ 彻底告别屈辱和亲</h3>
          <p>
            汉武帝毅然改变文景以来的被动和亲之策，主动出击。起用一代名将<strong>卫青、霍去病</strong>，先后发动河南之战（前127年）、漠南之战（前124年）、河西之战（前121年）与漠北之战（前119年）。
          </p>
        </div>
        <div class="card">
          <h3>🚩 封狼居胥与河西四郡</h3>
          <p>
            霍去病登临狼居胥山筑坛祭天、姑衍山祭地，创下华夏武将至高荣誉“封狼居胥”。汉廷全面收复河套与河西走廊，设立<strong>武威、张掖、酒泉、敦煌</strong>河西四郡，自此“匈奴远遁，而漠南无王庭”。
          </p>
        </div>
        <div class="card">
          <h3>🌏 经略西南夷与统合岭南</h3>
          <p>
            派遣唐蒙、司马相如经略西南，设武都、牂柯、越巂、沈黎、文山等郡；平定南越叛乱，设置九郡，将华南沿海与海南岛正式纳入大汉版图中央管辖。
          </p>
        </div>
        <div class="card">
          <h3>🏰 东北设郡与拓展海疆</h3>
          <p>
            发兵平定卫满朝鲜，设立乐浪、玄菟、真番、临屯汉四郡，使大汉帝国东极朝鲜、北逾阴山、西逾葱岭、南临南海，威震寰宇。
          </p>
        </div>
      </div>
    </section>

    <!-- 凿空西域 -->
    <section id="silkroad">
      <h2 class="section-title">凿空西域与丝绸之路</h2>
      <div class="card" style="margin-bottom: 1.5rem;">
        <h3>🐫 张骞出使西域（凿空之旅）</h3>
        <p>
          建元二年（前138年）与元鼎二年（前115年），汉武帝两度派遣<strong>张骞</strong>出使西域诸国，联络大月氏、乌孙，彻底打破了中原与中亚、西亚的地理阻隔，开辟了闻名世界的<strong>“丝绸之路”</strong>。
        </p>
        <p style="margin-top: 10px;">
          中原的丝绸、瓷器、漆器、冶铁技术远播西方；西域的汗血马、葡萄、苜蓿、石榴、胡麻、核桃等物产及乐器亦传入中原，开启了东西方文明双向交融的辉煌篇章。
        </p>
      </div>
    </section>

    <!-- 文治华章 -->
    <section id="culture">
      <h2 class="section-title">罢黜百家与文治华章</h2>
      <div class="grid-2">
        <div class="card">
          <h3>📖 罢黜百家 · 独尊儒术</h3>
          <p>
            采纳大儒董仲舒“推明孔氏，抑黜百家”的建策，确立儒家思想为国家正统思想。创办最高学府<strong>“太学”</strong>，设《诗》《书》《礼》《易》《春秋》五经博士，确立以儒术取士选官制度，奠定了中华两千余年正统文化基石。
          </p>
        </div>
        <div class="card">
          <h3>📜 汉赋崛起与史家绝唱</h3>
          <p>
            设立乐府机构采集民间诗歌，武帝本人精通辞赋，写下《秋风辞》《瓠子歌》《悼李夫人赋》等千古名篇。司马迁在其统治时期历经磨难，最终著成“史家之绝唱，无韵之离骚”的鸿篇巨著《史记》。
          </p>
        </div>
      </div>
    </section>

    <!-- 大事年表 -->
    <section id="timeline">
      <h2 class="section-title">汉武帝刘彻大事年表</h2>
      <div class="timeline">
        <div class="timeline-item">
          <div class="timeline-year">公元前156年（景帝前元元年）</div>
          <div class="timeline-content">刘彻生于长安猗兰殿，初名刘彘，母为王娡（孝景王皇后）。</div>
        </div>
        <div class="timeline-item">
          <div class="timeline-year">公元前141年（后元三年）</div>
          <div class="timeline-content">汉景帝驾崩，刘彻十六岁即皇帝位，次年改元“建元”，开启中国历史上首个年号纪元。</div>
        </div>
        <div class="timeline-item">
          <div class="timeline-year">公元前138年（建元三年）</div>
          <div class="timeline-content">派遣张骞首次出使西域，探求通往大月氏之路。</div>
        </div>
        <div class="timeline-item">
          <div class="timeline-year">公元前127年（元朔二年）</div>
          <div class="timeline-content">颁布主父偃“推恩令”；命卫青收复河南地（河套），置朔方郡、九原郡。</div>
        </div>
        <div class="timeline-item">
          <div class="timeline-year">公元前121年（元狩二年）</div>
          <div class="timeline-content">霍去病进军河西，大破匈奴各部，休屠王、浑邪王率众归降，汉廷设立河西四郡。</div>
        </div>
        <div class="timeline-item">
          <div class="timeline-year">公元前119年（元狩四年）</div>
          <div class="timeline-content">卫青、霍去病各率骑兵五万出击漠北，霍去病封狼居胥，匈奴主力遭受毁灭性打击。</div>
        </div>
        <div class="timeline-item">
          <div class="timeline-year">公元前110年（元封元年）</div>
          <div class="timeline-content">汉武帝亲率大军巡视北疆，至泰山举行隆重封禅大典，大汉国势达到鼎盛。</div>
        </div>
        <div class="timeline-item">
          <div class="timeline-year">公元前89年（征和四年）</div>
          <div class="timeline-content">经历了巫蛊之祸与李广利降匈奴之痛，武帝深刻反思，颁布著名的<strong>《轮台罪己诏》</strong>，罢征伐之议，封桑弘羊为大司农，转为“禁苛暴，止擅赋，力本农”，开启昭宣中兴序幕。</div>
        </div>
        <div class="timeline-item">
          <div class="timeline-year">公元前87年（后元二年）</div>
          <div class="timeline-content">汉武帝巡幸五利宫，病重，立幼子刘弗陵（汉昭帝）为太子，托孤霍光、金日磾、上官桀、桑弘羊，崩于五柞宫，享年七十岁，葬于茂陵，庙号世宗。</div>
        </div>
      </div>
    </section>

    <!-- 历代评价 -->
    <section>
      <h2 class="section-title">历代名家评价</h2>
      <table class="eval-table">
        <thead>
          <tr>
            <th style="width: 140px;">评论者 / 出处</th>
            <th>评述原文与精要</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><strong>司马迁</strong><br>《史记·武帝本纪》</td>
            <td>“汉家改封，及丰沛之士，尽爵位为通侯，然天下未安，乃起汉兴之功……世宗即位，招来四夷，经略边荒，虽多耗费，然功业盖世。”</td>
          </tr>
          <tr>
            <td><strong>班固</strong><br>《汉书·武帝纪》</td>
            <td>“汉承百王之弊，高祖拨乱反正，文景务在养民，至于稽古礼文之事，犹多阙焉。孝武初立，卓然罢黜百家，表章六经……如武帝之雄才大略，不改文景之恭俭以济斯民，虽《诗》《书》所称何有加焉！”</td>
          </tr>
          <tr>
            <td><strong>司马光</strong><br>《资治通鉴》</td>
            <td>“武帝穷奢极欲，繁刑重敛，内侈宫室，外事四夷，信惑神怪，巡游无度，使百姓疲敝，起为盗贼，其所以异于秦始皇者无几矣。然秦以之亡，汉以之兴者，孝武能尊先王之道，知统绪之可持久，知安民之可大也。”</td>
          </tr>
        </tbody>
      </table>
    </section>

  </main>

  <footer>
    <p>史海钩沉 · 汉武盛世历史文化普及页面</p>
    <p style="margin-top: 6px;">西汉世宗武皇帝刘彻（前156年 - 前87年）· 茂陵岁月，千秋雄风</p>
  </footer>

</body>
</html>`;
}
