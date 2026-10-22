#!/usr/bin/env python3
"""App Store 크리에이티브 자산(제품 페이지 헤더 · 검색 결과) 생성: HTML → 헤드리스 Chrome.

사용법: python3 scripts/make_creative_assets.py [언어 ...]     (없으면 전부)

자리
  docs/screenshots/creative/<스토어 로케일>/header.png   3840x1646  제품 페이지 맨 위
  docs/screenshots/creative/<스토어 로케일>/search.png   3840x2560  검색 결과 (없으면 스크린샷이 대신 보인다)

⚠️ 안전 영역 밖은 기기에 따라 잘린다. 글은 **반드시** 안전 영역 안에 둔다(배경 · 기기 그림은 넘쳐도 된다).
   수치는 Apple 공식 PSD 템플릿에서 잰 값이다(https://developer.apple.com/app-store/asset-best-practices/).
   아이폰에서 헤더는 가운데만 남고, 검색 결과는 약 385pt 폭으로 줄어 보인다. 그래서 글이 크다.

⚠️ 가격 · 할인 · 주소(URL) · 수상 · 다른 플랫폼 이름은 넣지 않는다(Apple 가이드).
"""
import shutil, subprocess, sys, pathlib, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW = ROOT / "docs" / "screenshots" / "raw" / "creative"
OUT = ROOT / "docs" / "screenshots" / "creative"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# 아이일정은 지금 한국어 페이지 하나뿐이다(App Store Connect 기준, 2026-10).
STORE = {}

# (가로, 세로, 안전 영역 left, top, right, bottom)
SPEC = {
    "header": (3840, 1646, (1097, 493, 2743, 1154)),
    "search": (3840, 2560, (836, 765, 3004, 1795)),
}

# 검색 결과: 눈썹글(그 나라 사람이 치는 검색어) · 헤드라인 · 보조 한 줄.
# 기기 화면은 스캔 탭 - 어린이집 안내문에서 뽑아 낸 일정이 아이 이름과 함께 줄지어 있다.
SEARCH = {
    "ko": ("어린이집 알림장", "찍기만 하면<br>한 달 일정 정리", "준비물은 전날 저녁에 알려 드려요"),
    "en": ("daycare calendar", "Snap it.<br>Get the whole month", "Packing reminders the evening before"),
    "en-GB": ("nursery calendar", "Snap it.<br>Get the whole month", "Packing reminders the evening before"),
    "zh-Hans": ("幼儿园通知", "拍一下<br>整月日程搞定", "准备物品前一天晚上提醒你"),
    "zh-Hant": ("幼兒園通知", "拍一下<br>整月行程搞定", "準備物品前一天晚上提醒你"),
    "ja": ("保育園 連絡帳", "撮るだけで<br>1か月の予定を整理", "持ち物は前日の夜にお知らせ"),
    "ru": ("календарь детского сада", "Снимите —<br>и события месяца готовы", "Что взять — напомним накануне вечером"),
}

# 헤더: 처음 온 사람에게 한 가지 약속. 종이로 온 일정을 찍으면 달력에 다 들어간다.
HEADER = {
    "ko": ("우리 아이 일정", "알림장 한 장 찍으면<br>한 달 일정 끝"),
    "en": ("My child’s schedule", "One photo of the notice,<br>a whole month of events"),
    "en-GB": ("My child’s schedule", "One photo of the notice,<br>a whole month of events"),
    "zh-Hans": ("我家宝贝的日程", "拍一张通知<br>整月日程就绪"),
    "zh-Hant": ("我家寶貝的行程", "拍一張通知<br>整月行程就緒"),
    "ja": ("うちの子の予定", "お知らせを1枚撮れば<br>1か月分の予定が完成"),
    "ru": ("Расписание моего малыша", "Одно фото объявления —<br>и события всего месяца"),
}

# 기기 화면(시뮬레이터 캡처, 가상의 두 아이 일정으로 채움)
SHOT_CALENDAR = "01-calendar.png"
SHOT_SCAN = "02-scan.png"

# 바탕 · 글자색은 앱 아이콘과 같다: 파란 그라데이션, 흰 달력, 주황 · 청록 점.
BASE_CSS = """
* { margin:0; padding:0; box-sizing:border-box; }
html,body { width:%(W)dpx; height:%(H)dpx; overflow:hidden; }
body { background:#2f6bf0; position:relative;
  font-family:-apple-system, "SF Pro Display", "Apple SD Gothic Neo", sans-serif; }
.paper { position:absolute; inset:0; background: linear-gradient(135deg, #2457e6 0%%, #3d82f5 55%%, #5fb2ff 100%%); }
.glow { position:absolute; border-radius:50%%; filter:blur(160px); pointer-events:none; }
.text { position:absolute; display:flex; flex-direction:column; justify-content:center; }
.eyebrow { font-weight:700; color:#ffc46b; letter-spacing:-0.01em; line-height:1.15; }
.headline { font-weight:800; color:#ffffff; letter-spacing:-0.03em; line-height:1.15; text-wrap:balance; }
.sub { font-weight:500; color:rgba(255,255,255,.82); letter-spacing:-0.01em; line-height:1.35; text-wrap:balance; }
:lang(ko) .headline, :lang(ko) .sub, :lang(ko) .eyebrow { word-break:keep-all; }
.phone { position:absolute; background:#15161a; border:6px solid #2b2d33; padding:40px; border-radius:190px;
  box-shadow: 0 60px 160px rgba(10,30,90,.45), 0 0 0 2px #34363d inset; }
.phone img { width:100%%; display:block; border-radius:152px; }
.dot { position:absolute; border-radius:36px; }
"""

# 글이 상자를 넘지 않을 때까지 줄인다. 잘리는 글은 없다 - 끝까지 안 맞으면 표시하고 멈춘다.
FIT_JS = """
<script>
// 문구에 적은 줄(<br>)보다 더 쪼개지면 "Rispondi / con un / tocco" 처럼 읽기가 끊긴다.
// 적은 줄 수를 지킬 때까지 줄인다.
function lines(el) {
  return Math.round(el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight));
}
function fit(box, el, max, min) {
  const want = el.querySelectorAll('br').length + 1;
  let size = max;
  el.style.fontSize = size + 'px';
  while (size > min && (box.scrollHeight > box.clientHeight + 1 || box.scrollWidth > box.clientWidth + 1 ||
         lines(el) > want)) {
    size -= 4; el.style.fontSize = size + 'px';
  }
  if (box.scrollHeight > box.clientHeight + 1 || box.scrollWidth > box.clientWidth + 1 || lines(el) > want)
    document.body.dataset.overflow = '1';
}
document.fonts.ready.then(() => {
  const box = document.querySelector('.text');
  const h = document.querySelector('.headline');
  fit(box, h, +h.dataset.max, +h.dataset.min);
  document.body.dataset.done = '1';
});
</script>
"""


def phone(img, left, top, width, rotate=0):
    return (f'<div class="phone" style="left:{left}px;top:{top}px;width:{width}px;'
            f'transform:rotate({rotate}deg)"><img src="{img}"></div>')


def shot(lang, name):
    path = RAW / lang / name
    if not path.exists():
        raise SystemExit(f"기기 화면이 없다: {path}")
    return path.as_uri()


def search_html(lang):
    W, H, (l, t, r, b) = SPEC["search"]
    eyebrow, headline, sub = SEARCH[lang]
    sw, sh = r - l, b - t
    col = int(sw * 0.56)
    ph_w = 1040
    ph_left = l + col + int(sw * 0.04)
    return f"""
<div class="paper"></div>
<div class="glow" style="left:{ph_left - 300}px;top:600px;width:1700px;height:1600px;background:rgba(255,255,255,.18)"></div>
<div class="dot" style="left:200px;top:260px;width:150px;height:150px;background:#ff9a2e;opacity:.9"></div>
<div class="dot" style="left:420px;top:260px;width:150px;height:150px;background:rgba(255,255,255,.22)"></div>
<div class="dot" style="left:3300px;top:2200px;width:150px;height:150px;background:#2ec4b6;opacity:.9"></div>
{phone(shot(lang, SHOT_SCAN), ph_left, t - 360, ph_w, 0)}
<div class="text" style="left:{l}px;top:{t}px;width:{col}px;height:{sh}px">
  <div class="eyebrow" style="font-size:96px">{eyebrow}</div>
  <div class="headline" data-max="230" data-min="130" style="margin-top:36px">{headline}</div>
  <div class="sub" style="font-size:84px;margin-top:52px">{sub}</div>
</div>"""


def header_html(lang):
    W, H, (l, t, r, b) = SPEC["header"]
    eyebrow, headline = HEADER[lang]
    sw, sh = r - l, b - t
    # 형광펜 획을 안전 영역 바깥에 흩는다(아이폰에서는 잘려도 되는 장식).
    # 아이콘의 달력 칸(주황 · 청록 · 흰 칸)을 안전 영역 바깥에 흩는다.
    dots = [(80, 120, "#ff9a2e", 1), (260, 120, "rgba(255,255,255,.2)", 1), (3560, 1360, "#2ec4b6", 1),
            (3380, 1360, "rgba(255,255,255,.2)", 1), (3600, 140, "rgba(255,255,255,.2)", 1), (120, 1400, "rgba(255,255,255,.2)", 1)]
    strokes_html = "".join(f'<div class="dot" style="left:{x}px;top:{y}px;width:140px;height:140px;'
                           f'background:{c}"></div>' for x, y, c, _ in dots)
    return f"""
<div class="paper"></div>
<div class="glow" style="left:{l - 200}px;top:{t - 400}px;width:{sw + 400}px;height:{sh + 800}px;background:rgba(255,255,255,.14)"></div>
{strokes_html}
{phone(shot(lang, SHOT_SCAN), 300, 360, 640, -9)}
{phone(shot(lang, SHOT_CALENDAR), 2900, 360, 640, 9)}
<div class="text" style="left:{l}px;top:{t}px;width:{sw}px;height:{sh}px;align-items:center;text-align:center">
  <div class="eyebrow" style="font-size:76px">{eyebrow}</div>
  <div class="headline" data-max="200" data-min="110" style="margin-top:22px">{headline}</div>
</div>"""


def html_lang(lang):
    return {"zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant"}.get(lang, lang)


def render(lang, kind):
    W, H, _ = SPEC[kind]
    body = search_html(lang) if kind == "search" else header_html(lang)
    page = (f'<!doctype html><html lang="{html_lang(lang)}"><head><meta charset="utf-8"><style>'
            f'{BASE_CSS % {"W": W, "H": H}}</style></head><body>{body}{FIT_JS}</body></html>')
    html_path = pathlib.Path(tempfile.gettempdir()) / f"aiilj-creative-{lang}-{kind}.html"
    html_path.write_text(page, encoding="utf-8")
    # 글이 끝까지 안 맞으면 그림을 만들지 않는다(잘린 글이 스토어에 올라가는 것보다 낫다).
    dom = subprocess.run([CHROME, "--headless=new", "--dump-dom", f"--window-size={W},{H}",
                          "--force-device-scale-factor=1", "--disable-gpu", "--virtual-time-budget=3000",
                          html_path.as_uri()], capture_output=True, text=True, timeout=90).stdout
    if 'data-done="1"' not in dom:
        raise SystemExit(f"글 맞추기가 끝나지 않았다: {lang} {kind}")
    if 'data-overflow="1"' in dom:
        raise SystemExit(f"글이 안전 영역을 넘는다: {lang} {kind} - 문구를 줄일 것")
    out_dir = OUT / STORE.get(lang, lang)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_png = out_dir / f"{kind}.png"
    # ⚠️ Chrome 은 가끔 아무것도 안 그리고 끝나거나 멈춘다. 세 번까지 한다.
    # ⚠️ 그리고 나서 끝내다가 멈춰 0 이 아닌 코드로 죽는 일도 있다(Teardown watchdog).
    #    그래서 끝 코드가 아니라 '새로 쓴 그림이 있는가' 로 판단한다.
    out_png.unlink(missing_ok=True)
    for _ in range(3):
        try:
            r = subprocess.run([CHROME, "--headless=new", f"--screenshot={out_png}",
                                f"--window-size={W},{H}", "--force-device-scale-factor=1",
                                "--hide-scrollbars", "--disable-gpu", "--virtual-time-budget=3000",
                                "--allow-file-access-from-files", html_path.as_uri()],
                               capture_output=True, timeout=90)
        except subprocess.TimeoutExpired:
            if out_png.exists() and out_png.stat().st_size > 0:
                break
            continue
        if out_png.exists() and out_png.stat().st_size > 0:
            break
    else:
        raise SystemExit(f"Chrome 이 그리지 못했다: {out_png}")
    print(f"rendered {out_png}")


if __name__ == "__main__":
    langs = sys.argv[1:] or list(SEARCH)
    for lang in langs:
        if lang not in SEARCH:
            raise SystemExit(f"모르는 언어: {lang} (아는 것: {', '.join(SEARCH)})")
        for kind in ("header", "search"):
            render(lang, kind)
