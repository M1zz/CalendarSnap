// 아이일정 웹 데모: 예시 행사 안내문을 "찍으면" 일정이 뽑히고, 고른 시점대로 알림이 예약된다.
// 글자 읽기는 흉내 내지 않는다(예시 안내문의 일정을 그대로 쓴다). 알림 규칙은 앱과 같다 (Shared/ReminderSettings.swift):
//   전날 저녁 = 하루 전 20:00 · 당일 아침 = 07:30 · 1시간 전 · 정각 (뒤의 둘은 시간이 정해진 일정에만)
//   처음 켜진 것은 전날 저녁 · 당일 아침. 알림 제목은 "아이 이름 · 일정 제목", 본문 끝에 📌 준비물.
(() => {
  const root = document.getElementById("demo");
  if (!root) return;
  const T = JSON.parse(root.dataset.text);
  const lang = document.documentElement.lang;
  const fmt = o => new Intl.DateTimeFormat(lang, o);
  const monthName = fmt({ month: "long" }), dayFmt = fmt({ month: "short", day: "numeric" }),
        timeFmt = fmt({ hour: "numeric", minute: "2-digit" }),
        whenFmt = fmt({ weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });

  // 다음 달의 일정으로 만든다 — 알림이 언제나 앞날이 되도록.
  const now = new Date(), y = now.getFullYear(), m = now.getMonth() + 1;
  const events = T.events.map(e => {
    const [h, min] = (e.time || "0:0").split(":").map(Number);
    return { ...e, allDay: !e.time, date: new Date(y, m, e.day, h, min) };
  });

  const on = [true, true, false, false];
  const RULES = [
    e => new Date(e.date.getFullYear(), e.date.getMonth(), e.date.getDate() - 1, 20, 0),
    e => new Date(e.date.getFullYear(), e.date.getMonth(), e.date.getDate(), 7, 30),
    e => e.allDay ? null : new Date(e.date - 3600e3),
    e => e.allDay ? null : e.date,
  ];
  let snapped = false;

  const line = e => `${dayFmt.format(e.date)}${e.allDay ? "" : " " + timeFmt.format(e.date)} ${e.title}${e.items ? ` (${e.items})` : ""}`;
  root.innerHTML = `
    <div class="demo-stage">
      <div class="paper">
        <p class="paper-title">${T.noticeTitle.replace("{month}", monthName.format(events[0].date))}</p>
        <ul>${events.map(e => `<li>${line(e)}</li>`).join("")}</ul>
        <div class="flash" aria-hidden="true"></div>
      </div>
      <div class="snap-row">
        <button type="button" class="chip snap">
          <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path fill="currentColor" d="M9 3 7.2 5H4a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-3.2L15 3H9Zm3 5a4.5 4.5 0 1 1 0 9 4.5 4.5 0 0 1 0-9Z"/></svg>
          <span>${T.snap}</span>
        </button>
      </div>
    </div>
    <div class="demo-controls">
      <fieldset class="opts">
        ${T.options.map((o, i) => `
          <label class="opt"><input type="checkbox" data-i="${i}" ${on[i] ? "checked" : ""}>
            <span>${o}${i > 1 ? `<small>${T.timedOnly}</small>` : ""}</span></label>`).join("")}
      </fieldset>
      <p class="found" aria-live="polite"></p>
      <ol class="notes"></ol>
      <p class="muted small demo-note">${T.note}</p>
    </div>`;

  const $ = q => root.querySelector(q);
  const paper = $(".paper"), snapBtn = $(".snap"), found = $(".found"), list = $(".notes");

  function render() {
    paper.classList.toggle("read", snapped);
    snapBtn.querySelector("span").textContent = snapped ? T.again : T.snap;
    snapBtn.classList.toggle("hint", !snapped);
    if (!snapped) { found.textContent = ""; list.innerHTML = `<li class="empty">${T.empty}</li>`; return; }
    const items = events.flatMap(e => RULES.map((rule, i) => on[i] && rule(e) ? { e, i, at: rule(e) } : null))
      .filter(x => x && x.at > now).sort((a, b) => a.at - b.at);
    found.textContent = T.found.replace("{e}", events.length).replace("{n}", items.length);
    list.innerHTML = items.map(({ e, i, at }) => `
      <li class="note">
        <span class="note-when">${whenFmt.format(at)}</span>
        <b>${T.child} · ${e.title}</b>
        <span>${T.bodies[i]}${e.items ? `<br>📌 ${e.items}` : ""}</span>
      </li>`).join("");
  }

  snapBtn.addEventListener("click", () => {
    snapped = !snapped;
    if (snapped) { paper.classList.remove("shot"); void paper.offsetWidth; paper.classList.add("shot"); }
    render();
  });
  root.querySelector(".opts").addEventListener("change", e => { on[+e.target.dataset.i] = e.target.checked; render(); });

  render();
})();
