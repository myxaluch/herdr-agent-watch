import { View, div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { hc, appHome, checking, props, terminals, theme, notify, openOverlay, closeOverlay, setShared, nextCommand, focused, run } from "herdr";
import { MOD, WATCHER, windowKey, titlebarInit, titlebarRender } from "./titlebar.js";

const ENGINE = `mods/${MOD}/engine.sh`;
const JOB_LABEL = "agent-watch";
const isJob = (t) => t.labels?.[JOB_LABEL] === "1";
const jobTitle = (t) => t.labels?.["aw.title"] ?? t.name;

export default class AgentWatch extends View {
  init(_props, cx) {
    this.titlebar = (props() ?? {}).role === "titlebar";
    if (this.titlebar) {
      titlebarInit(this);
      return;
    }
    this.starting = false;
    this.windows = new Map();
    if (!checking()) {
      this.ensureWatcher(cx);
      cx.timer.every(60000, (cx) => this.ensureWatcher(cx));
    }
    cx.spawn(async (cx) => {
      for (;;) {
        const command = await nextCommand();
        if (command.startsWith("open:")) this.openByName(command.slice(5));
        if (command.startsWith("say:")) this.say(command.slice(4));
        if (command === "close") this.closeFocused();
        cx.notify();
      }
    });
  }

  openByName(name) {
    const term = this.live().find((x) => x.name === name);
    if (!term) {
      notify({ title: "agent-watch", body: `${name} is not running`, level: "warning" });
      return;
    }
    this.openWindow(term, jobTitle(term));
  }

  closeFocused() {
    const f = focused();
    const id = f && f.pane === null && f.terminal ? this.windows.get(f.terminal) : undefined;
    if (id) {
      closeOverlay(id);
      this.windows.delete(f.terminal);
      return;
    }
    run("tab.close");
  }

  say(payload) {
    let msg;
    try { msg = JSON.parse(payload); } catch { return; }
    notify({
      title: msg.title ?? "agent-watch",
      body: msg.body,
      level: msg.level ?? "info",
      action: msg.terminal ? { name: `${MOD}.open:${msg.terminal}` } : undefined,
    });
  }

  live() {
    return terminals().filter((t) => t.state === "live");
  }

  ensureWatcher(cx) {
    if (this.starting || this.live().some((t) => t.name === WATCHER)) return;
    this.starting = true;
    cx.spawn(async (cx) => {
      const script = `${appHome()}/${ENGINE}`;
      const r = await hc(["run", "--bg", "--no-parent", "--name", WATCHER, "bash", script]);
      if (r.code !== 0 && !this.live().some((t) => t.name === WATCHER)) {
        notify({ title: "agent-watch", body: r.stderr.trim() || r.stdout.trim(), level: "error" });
      }
      this.starting = false;
      cx.notify();
    });
  }

  openWindow(term, title) {
    const id = openOverlay({
      kind: "window",
      key: `${MOD}:${term.name}`,
      width: 1100,
      height: 720,
      layout: {
        type: "column",
        children: [
          { type: "block", size: { px: 30 }, content: { mod: MOD, props: { role: "titlebar", name: term.name, title } } },
          { type: "block", content: { terminal: term.address } },
        ],
      },
    });
    this.windows.set(term.address, id);
    setShared(windowKey(term.name), id);
  }

  render() {
    if (this.titlebar) return titlebarRender(this);

    const t = theme();
    const live = this.live();
    const watching = live.some((x) => x.name === WATCHER);
    const jobs = live.filter(isJob);
    const color = { working: t.working, blocked: t.blocked, done: t.done, idle: t.idle };

    const job = (x) => {
      const label = jobTitle(x);
      return h_flex().id(`job-${x.name}`).gap(5).items_center().px(6).rounded(4)
        .hover((s) => s.bg(t.hover))
        .on_click(() => this.openWindow(x, label))
        .child(div().size(6).rounded(3).bg(color[x.status] ?? t.unknown))
        .child(label);
    };

    return h_flex().size_full().px(14).gap(10).items_center().bg(t.chrome).border_t(1).border_color(t.border)
      .text_size(11.5).text_color(t.muted)
      .child(h_flex().id("watcher").gap(6).items_center()
        .on_click(() => { const w = live.find((x) => x.name === WATCHER); if (w) this.openWindow(w, "agent-watch log"); })
        .child(div().size(6).rounded(3).bg(watching ? t.done : t.blocked))
        .child(watching ? "agent-watch" : "agent-watch: starting…"))
      .when(jobs.length === 0, (el) => el.child(div().text_color(t.dim).child("no open jobs")))
      .children(jobs.map(job));
  }
}
