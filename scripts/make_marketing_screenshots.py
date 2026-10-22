#!/usr/bin/env python3
"""App Store 마케팅 스크린샷: 시뮬레이터 원본 캡처 + 헤드라인 → HTML → 헤드리스 Chrome.

사용법: python3 scripts/make_marketing_screenshots.py [언어 ...]   (없으면 전부)

  원본  docs/screenshots/raw/<언어>/NN-….png         (iPhone 6.9" 시뮬레이터 캡처 1320x2868, 올라가지 않는다)
  제출  docs/screenshots/marketing/<스토어 로케일>/NN-….png   (1242x2688, DeployBar 가 그대로 올린다)

파일 이름 순서가 스토어에 보이는 순서다. 다음 릴리즈에는 원본만 다시 찍고 이 스크립트를 다시 돌린다.
"""
import subprocess, sys, pathlib, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW = ROOT / "docs" / "screenshots" / "raw"
OUT = ROOT / "docs" / "screenshots" / "marketing"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 1242, 2688   # 이 계정의 iPhone 제출 규격

# ── 앱마다 고치는 곳 ──────────────────────────────────────────────
# 앱 언어 → App Store 로케일 (스토어 폴더 이름)
STORE = {"ko": "ko", "en": "en-US", "en-GB": "en-GB", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant", "ja": "ja", "ru": "ru", "es": "es-ES", "de": "de-DE", "fr": "fr-FR", "it": "it", "pt-BR": "pt-BR", "th": "th", "vi": "vi", "cs": "cs"}
# 바탕 · 포인트 색 (헤더·검색 결과 그림과 맞춘다)
BG, ACCENT, INK, SUB = "#EEF3FE", "#2F6BF0", "#14213D", "#5E6782"
# 언어 → [(원본 파일, 레이아웃, 헤드라인, 서브카피)]
SHOTS = {
    "ko": [
        ("01-scan.png",      "hero-bleed",  "알림장 사진 한 장이면<br>한 달 일정 끝", "날짜와 준비물을 알아서 읽어 와요"),
        ("02-events.png",    "left-text",   "저장 전에<br>한 번 더 확인", "제목, 날짜, 준비물을 바로 고쳐요"),
        ("03-calendar.png",  "text-bottom", "아이마다 색으로 한눈에", "형제자매 일정도 헷갈리지 않아요"),
        ("04-reminders.png", "dark",        "전날 저녁에<br>준비물 알림", "도시락, 체육복 더는 놓치지 마세요"),
    ],
    "en": [
        ("01-scan.png",      "hero-bleed",  "One photo of the notice,<br>a whole month sorted", "Dates and things to bring, read for you"),
        ("02-events.png",    "left-text",   "Check it once<br>before you save", "Fix titles, dates and notes in a tap"),
        ("03-calendar.png",  "text-bottom", "Every child in<br>their own color", "No more mixing up siblings’ plans"),
        ("04-reminders.png", "dark",        "A reminder the<br>evening before", "Never forget the lunch box or gym kit"),
    ],
    "en-GB": [
        ("01-scan.png", "hero-bleed", "One photo of the notice,<br>a whole month sorted", "Dates and things to bring, read for you"),
        ("02-events.png", "left-text", "Check it once<br>before you save", "Fix titles, dates and notes in a tap"),
        ("03-calendar.png", "text-bottom", "Every child in<br>their own colour", "No more mixing up siblings’ plans"),
        ("04-reminders.png", "dark", "A reminder the<br>evening before", "Never forget the packed lunch or PE kit"),
    ],
    "zh-Hans": [
        ("01-scan.png", "hero-bleed", "拍一张通知<br>整月日程搞定", "日期和需带物品，自动读取"),
        ("02-events.png", "left-text", "保存前<br>再确认一遍", "标题、日期、备注，一点就改"),
        ("03-calendar.png", "text-bottom", "每个孩子<br>一种颜色", "兄弟姐妹的安排不再混淆"),
        ("04-reminders.png", "dark", "前一天晚上<br>提醒带东西", "午餐、运动服，再也不忘"),
    ],
    "zh-Hant": [
        ("01-scan.png", "hero-bleed", "拍一張通知<br>整月行程搞定", "日期和需帶物品，自動讀取"),
        ("02-events.png", "left-text", "儲存前<br>再確認一遍", "標題、日期、備註，一點就改"),
        ("03-calendar.png", "text-bottom", "每個孩子<br>一種顏色", "兄弟姊妹的安排不再混淆"),
        ("04-reminders.png", "dark", "前一天晚上<br>提醒帶東西", "午餐、運動服，再也不忘"),
    ],
    "ja": [
        ("01-scan.png", "hero-bleed", "お知らせを1枚撮れば<br>1か月分の予定が完成", "日付と持ち物を自動で読み取ります"),
        ("02-events.png", "left-text", "保存する前に<br>もう一度確認", "タイトル・日付・持ち物をすぐ直せます"),
        ("03-calendar.png", "text-bottom", "お子さまごとに<br>色でひと目で", "きょうだいの予定も混ざりません"),
        ("04-reminders.png", "dark", "前日の夜に<br>持ち物をお知らせ", "お弁当も体操服も、もう忘れません"),
    ],
    "ru": [
        ("01-scan.png", "hero-bleed", "Одно фото объявления —<br>и месяц в порядке", "Даты и что взять — считаем сами"),
        ("02-events.png", "left-text", "Проверьте<br>перед сохранением", "Название, дату и заметки можно поправить"),
        ("03-calendar.png", "text-bottom", "Каждому ребёнку —<br>свой цвет", "Планы братьев и сестёр не перепутаются"),
        ("04-reminders.png", "dark", "Напоминание<br>накануне вечером", "Обед и форму больше не забудете"),
    ],
    "es": [
        ("01-scan.png", "hero-bleed", "Una foto del aviso<br>y todo el mes listo", "Fechas y lo que hay que llevar, leídos por ti"),
        ("02-events.png", "left-text", "Revísalo una vez<br>antes de guardar", "Edita título, fecha y notas con un toque"),
        ("03-calendar.png", "text-bottom", "Cada peque,<br>con su color", "Sin mezclar los planes de los hermanos"),
        ("04-reminders.png", "dark", "Un aviso la<br>tarde anterior", "Que no se olvide la fiambrera ni el chándal"),
    ],
    "de": [
        ("01-scan.png", "hero-bleed", "Ein Foto vom Aushang,<br>der ganze Monat fertig", "Datum und Mitbringsel werden ausgelesen"),
        ("02-events.png", "left-text", "Vor dem Sichern<br>noch einmal prüfen", "Titel, Datum und Notizen im Nu ändern"),
        ("03-calendar.png", "text-bottom", "Jedes Kind<br>in seiner Farbe", "Geschwister-Termine bleiben getrennt"),
        ("04-reminders.png", "dark", "Erinnerung<br>am Vorabend", "Brotdose und Sportzeug nie mehr vergessen"),
    ],
    "fr": [
        ("01-scan.png", "hero-bleed", "Une photo de l’affichage,<br>tout le mois organisé", "Dates et affaires à apporter, lues pour vous"),
        ("02-events.png", "left-text", "Vérifiez avant<br>d’enregistrer", "Titre, date et notes à modifier d’un geste"),
        ("03-calendar.png", "text-bottom", "Chaque enfant<br>a sa couleur", "Plus de confusion entre frères et sœurs"),
        ("04-reminders.png", "dark", "Un rappel<br>la veille au soir", "Plus d’oubli de pique-nique ni de tenue de sport"),
    ],
    "it": [
        ("01-scan.png", "hero-bleed", "Una foto dell’avviso<br>e il mese è pronto", "Date e cose da portare, lette per te"),
        ("02-events.png", "left-text", "Controlla prima<br>di salvare", "Titolo, data e note da correggere in un tocco"),
        ("03-calendar.png", "text-bottom", "Ogni bambino<br>con il suo colore", "Gli impegni dei fratelli non si confondono"),
        ("04-reminders.png", "dark", "Un promemoria<br>la sera prima", "Mai più pranzo al sacco dimenticato"),
    ],
    "pt-BR": [
        ("01-scan.png", "hero-bleed", "Uma foto do aviso,<br>o mês inteiro pronto", "Datas e o que levar, lidos para você"),
        ("02-events.png", "left-text", "Confira antes<br>de salvar", "Título, data e anotações em um toque"),
        ("03-calendar.png", "text-bottom", "Cada criança<br>com sua cor", "Os planos dos irmãos não se misturam"),
        ("04-reminders.png", "dark", "Um lembrete na<br>noite anterior", "Nunca mais esqueça o lanche"),
    ],
    "th": [
        ("01-scan.png", "hero-bleed", "ถ่ายประกาศใบเดียว<br>ได้ทั้งเดือน", "อ่านวันที่และของที่ต้องเตรียมให้เอง"),
        ("02-events.png", "left-text", "ตรวจอีกครั้ง<br>ก่อนบันทึก", "แก้ชื่อเรื่อง วันที่ และโน้ตได้ทันที"),
        ("03-calendar.png", "text-bottom", "เด็กแต่ละคน<br>มีสีของตัวเอง", "ตารางพี่น้องไม่ปะปนกัน"),
        ("04-reminders.png", "dark", "แจ้งเตือน<br>เย็นวันก่อน", "ไม่ลืมปิ่นโตและชุดพละอีกต่อไป"),
    ],
    "vi": [
        ("01-scan.png", "hero-bleed", "Chụp một thông báo,<br>có ngay lịch cả tháng", "Tự đọc ngày và đồ cần mang"),
        ("02-events.png", "left-text", "Kiểm tra lại<br>trước khi lưu", "Sửa tiêu đề, ngày, ghi chú chỉ một chạm"),
        ("03-calendar.png", "text-bottom", "Mỗi bé<br>một màu riêng", "Lịch anh chị em không bị lẫn"),
        ("04-reminders.png", "dark", "Nhắc từ<br>tối hôm trước", "Không còn quên cơm hộp, đồ thể dục"),
    ],
    "cs": [
        ("01-scan.png", "hero-bleed", "Jedna fotka oznámení,<br>celý měsíc hotový", "Data a věci s sebou přečteme za vás"),
        ("02-events.png", "left-text", "Zkontrolujte<br>před uložením", "Název, datum a poznámky upravíte jedním klepnutím"),
        ("03-calendar.png", "text-bottom", "Každé dítě<br>má svou barvu", "Plány sourozenců se nepomíchají"),
        ("04-reminders.png", "dark", "Připomínka<br>večer předem", "Na svačinu a cvičební oblečení už nezapomenete"),
    ],
}
# ─────────────────────────────────────────────────────────────────

BASE_CSS = f"""
* {{ margin:0; padding:0; box-sizing:border-box; }}
html,body {{ width:{W}px; height:{H}px; overflow:hidden; }}
body {{ background:{BG}; position:relative;
  font-family:-apple-system, "SF Pro Display", "Apple SD Gothic Neo", "Hiragino Sans", "PingFang SC", sans-serif; }}
.headline {{ font-size:96px; font-weight:800; color:{INK}; letter-spacing:-0.03em; line-height:1.18; }}
.sub {{ font-size:48px; font-weight:500; color:{SUB}; letter-spacing:-0.01em; line-height:1.35; }}
:lang(ko) .headline, :lang(ko) .sub {{ word-break:keep-all; }}
.phone {{ background:#17171a; border-radius:112px; border:3px solid #3a3a3e; padding:24px;
  box-shadow: 50px 80px 120px rgba(20,40,90,.25), 16px 26px 46px rgba(0,0,0,.16); }}
.phone img {{ width:100%; display:block; border-radius:90px; }}
.dot {{ display:inline-block; width:22px; height:22px; border-radius:50%; background:{ACCENT}; margin-bottom:46px; }}
"""

LAYOUTS = {
    "hero-bleed": """
.text { text-align:center; padding:250px 80px 0; }
.sub { margin-top:44px; }
.wrap { display:flex; justify-content:center; margin-top:120px; }
.phone { width:960px; }
""",
    "left-text": """
.text { text-align:left; padding:260px 100px 0 110px; }
.sub { margin-top:44px; }
.wrap { perspective:2600px; perspective-origin:30% 30%; position:absolute; left:290px; top:930px; }
.phone { width:820px; transform:rotateY(16deg) rotateX(2deg); }
""",
    "text-bottom": """
.wrap { perspective:2800px; perspective-origin:50% 40%; display:flex; justify-content:center; margin-top:150px; }
.phone { width:840px; transform:rotateY(-10deg) rotateX(2deg); }
.text { text-align:center; padding:100px 80px 0; }
.sub { margin-top:40px; }
""",
    "flat-rotate": """
.text { text-align:center; padding:240px 80px 0; }
.sub { margin-top:44px; }
.wrap { position:absolute; left:120px; top:950px; }
.phone { width:960px; transform:rotate(-6deg); }
""",
    "dark": f"""
body {{ background:#2457e6; }}
.headline {{ color:#ffffff; }} .sub {{ color:#d6e4ff; }}
.text {{ text-align:center; padding:250px 80px 0; }}
.sub {{ margin-top:44px; }}
.wrap {{ display:flex; justify-content:center; margin-top:120px; }}
.phone {{ width:900px; border-color:#48484e;
  box-shadow: 0 0 160px rgba(80,140,255,.22), 40px 70px 110px rgba(0,0,0,.55); }}
""",
}

TEXT = '<div class="text"><div class="dot"></div><div class="headline">{headline}</div><div class="sub">{sub}</div></div>'
PHONE = '<div class="wrap"><div class="phone"><img src="{img}"></div></div>'
HTML = '<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><style>{css}</style></head><body>{body}</body></html>'


def chrome_shot(html, png, tmp):
    """헤드리스 Chrome 으로 한 장 그린다.

    ⚠️ Chrome 은 그림을 다 쓰고도 끝나지 않고 멈추는 일이 잦다(여러 개가 동시에 돌 때 특히).
       그래서 끝나기를 기다리지 않고, 파일이 생겨 크기가 멈추면 프로세스를 닫는다.
    """
    png.unlink(missing_ok=True)
    proc = subprocess.Popen([CHROME, "--headless=new", f"--user-data-dir={tmp}/chrome", "--no-first-run",
                             "--disable-component-update", "--no-default-browser-check", "--disable-extensions",
                             f"--screenshot={png}", f"--window-size={W},{H}", "--force-device-scale-factor=1",
                             "--hide-scrollbars", "--allow-file-access-from-files", html.as_uri()],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    last, deadline = -1, time.time() + 180
    try:
        while time.time() < deadline:
            time.sleep(1)
            size = png.stat().st_size if png.exists() else -1
            if size > 10000 and size == last:
                return True
            last = size
            if proc.poll() is not None and size <= 0:
                return False
        return False
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        # 남은 도우미 프로세스도 이 프로필 것만 골라 닫는다
        subprocess.run(["pkill", "-f", f"{tmp}/chrome"], capture_output=True)


def render(lang):
    out_dir = OUT / STORE[lang]
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("*.png"):
        old.unlink()
    with tempfile.TemporaryDirectory() as tmp:
        for fname, layout, headline, sub in SHOTS[lang]:
            src = RAW / lang / fname
            assert src.exists(), f"원본이 없다: {src}"
            text = TEXT.format(headline=headline, sub=sub)
            phone = PHONE.format(img=src.as_uri())
            body = phone + text if layout == "text-bottom" else text + phone
            html = pathlib.Path(tmp) / f"{lang}-{fname}.html"
            html.write_text(HTML.format(lang=lang, css=BASE_CSS + LAYOUTS[layout], body=body), encoding="utf-8")
            png = out_dir / fname
            if not any(chrome_shot(html, png, tmp) for _ in range(3)):
                raise SystemExit(f"그리지 못했다: {png}")
            print("rendered", png.relative_to(ROOT))


if __name__ == "__main__":
    for lang in (sys.argv[1:] or list(SHOTS)):
        render(lang)
