import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { props, shared, closeOverlay, terminals, theme, hc, notify } from "herdr";

// The mod's folder name. Change it here when the folder is renamed.
export const MOD = "agent-watch";
export const WATCHER = "agent-watch";
export const windowKey = (name) => `${MOD}-window:${name}`;

export function titlebarInit(view) {
  view.armed = false;
  view.ending = false;
}

function arm(view, cx) {
  view.armed = true;
  cx.timer.after(3000, (cx) => { view.armed = false; cx.notify(); });
}

function end(view, term, overlay, cx) {
  view.ending = true;
  cx.spawn(async (cx) => {
    const kids = terminals().filter((x) => x.parent === term.address && x.state === "live");
    for (const t of [...kids, term]) {
      const r = await hc(["kill", t.address]);
      if (r.code !== 0) notify({ title: "agent-watch", body: `${t.name ?? t.address}: ${r.stderr.trim()}`, level: "error" });
    }
    view.ending = false;
    if (overlay) closeOverlay(overlay);
    cx.notify();
  });
}

export function titlebarRender(view) {
  const t = theme();
  const p = props() ?? {};
  const { name, title } = p;
  const term = terminals().find((x) => x.name === name && x.state === "live");
  const status = term ? (term.status ?? "running") : "finished";
  const color = { working: t.working, blocked: t.blocked, done: t.done, idle: t.idle }[status] ?? t.unknown;
  const overlay = p.overlay ?? shared(windowKey(name));
  const label = view.ending ? "Ending…" : view.armed ? "End for sure?" : "End";

  return h_flex().size_full().px(10).gap(8).items_center().bg(t.chrome).border_b(1).border_color(t.border)
    .text_size(12).text_color(t.foreground)
    .child(div().size(7).rounded(4).bg(color))
    .child(div().flex_1().truncate().child(`${title} · ${status}`))
    .when(!!term && name !== WATCHER, (el) => el.child(div().id("end").px(6).rounded(4)
      .text_color(view.armed ? t.blocked : t.muted)
      .hover((s) => s.bg(t.hover).text_color(t.blocked))
      .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
      .on_click((_e, cx) => {
        if (view.ending) return;
        if (view.armed) end(view, term, overlay, cx); else arm(view, cx);
        cx.notify();
      })
      .child(label)))
    .child(div().id("close").px(6).rounded(4).text_color(t.muted)
      .hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
      .on_click(() => { if (overlay) closeOverlay(overlay); })
      .child("✕"));
}
