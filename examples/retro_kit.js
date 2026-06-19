// retro_kit.js — shared "Monkey Island night-bazaar" pixel-art kit for all
// lex-robot dashboards. Served by the sidecar at GET /retro_kit.js.
//
// Every dashboard's Phaser scene calls into RK for its background, robots,
// buildings, speech bubbles and capability callouts, so the retro look stays
// identical across demos. Functions take the Phaser `scene` as first arg.
//
// Usage in a dashboard:
//   <script src="/retro_kit.js"></script>      (before the inline <script>)
//   ...
//   RK.drawBg(this);
//   const con = RK.makeRobot(this, x, y, 'A', 0x60a5fa);
//   RK.startWhenFontsReady(() => new Phaser.Game(RK.gameConfig('game-container', W, H, MyScene)));

const RK = (() => {
  // ── fonts ───────────────────────────────────────────────────────────────
  function injectFonts() {
    if (document.getElementById('rk-fonts')) return;
    const pre1 = document.createElement('link'); pre1.rel = 'preconnect'; pre1.href = 'https://fonts.googleapis.com';
    const pre2 = document.createElement('link'); pre2.rel = 'preconnect'; pre2.href = 'https://fonts.gstatic.com'; pre2.crossOrigin = '';
    const l = document.createElement('link'); l.id = 'rk-fonts'; l.rel = 'stylesheet';
    l.href = 'https://fonts.googleapis.com/css2?family=VT323&family=Press+Start+2P&display=swap';
    document.head.appendChild(pre1); document.head.appendChild(pre2); document.head.appendChild(l);
  }
  injectFonts();

  // qrcode-generator (Kazuhiko Arase) — standalone, no deps. Defines global `qrcode`.
  function injectQRLib() {
    if (document.getElementById('rk-qrlib')) return;
    const s = document.createElement('script'); s.id = 'rk-qrlib';
    s.src = 'https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js';
    document.head.appendChild(s);
  }
  injectQRLib();

  const PX  = 'VT323';            // readable retro terminal — labels & bubbles
  const PXH = '"Press Start 2P"'; // chunky NES — headings & big callouts

  // ── Monkey Island night palette ─────────────────────────────────────────
  const C = {
    SKY_TOP: 0x0f1f3d, SKY_BOT: 0x2d4a6b, MOON: 0xf5e6c8,
    GROUND: 0x24343d, COBBLE: 0x2c4049, COBBLE_HI: 0x35505c, HORIZON: 0x16262e,
    WOOD: 0x4a3322, WOOD_DK: 0x3a2718, WOOD_LT: 0x7a5230, POLE: 0x5a3a1f,
    STONE: 0x49606b, STONE_DK: 0x35474f, STONE_HI: 0x5e7884,
    CREAM: 0xe8d4a0, SKIN: 0xe0a878, GOLD: 0xffd166, GREEN: 0x4ade80, RED: 0xf87171,
  };

  // ── colour helpers ──────────────────────────────────────────────────────
  function shade(hex, f) {
    let r = (hex >> 16) & 255, g = (hex >> 8) & 255, b = hex & 255;
    r = Math.min(255, Math.round(r * f)); g = Math.min(255, Math.round(g * f)); b = Math.min(255, Math.round(b * f));
    return (r << 16) | (g << 8) | b;
  }
  function mix(a, b, t) {
    const ar = (a >> 16) & 255, ag = (a >> 8) & 255, ab = a & 255;
    const br = (b >> 16) & 255, bg = (b >> 8) & 255, bb = b & 255;
    return (Math.round(ar + (br - ar) * t) << 16) | (Math.round(ag + (bg - ag) * t) << 8) | Math.round(ab + (bb - ab) * t);
  }

  // ── background: night sky + cobblestone street ──────────────────────────
  function drawBg(scene, opts) {
    opts = opts || {};
    const W = scene.scale.width, H = scene.scale.height;
    const g = scene.add.graphics().setDepth(0);
    const skyH = Math.floor(H * (opts.skyFrac || 0.17));
    const bands = 10;
    for (let i = 0; i < bands; i++) {
      g.fillStyle(mix(C.SKY_TOP, C.SKY_BOT, i / (bands - 1)), 1);
      g.fillRect(0, Math.floor(i * skyH / bands), W, Math.ceil(skyH / bands) + 1);
    }
    g.fillStyle(C.MOON, 0.85);
    [[0.08,0.30],[0.22,0.62],[0.34,0.18],[0.46,0.50],[0.58,0.30],[0.66,0.66],
     [0.74,0.22],[0.16,0.82],[0.50,0.78],[0.30,0.42],[0.62,0.12]]
      .forEach(([sx, sy]) => g.fillRect(Math.floor(W * sx), Math.floor(skyH * sy), 2, 2));
    g.fillStyle(C.MOON, 1);      g.fillCircle(W * 0.87, skyH * 0.40, 15);
    g.fillStyle(C.SKY_TOP, 1);   g.fillCircle(W * 0.84, skyH * 0.33, 13);
    const ground = opts.ground || C.GROUND;
    g.fillStyle(ground, 1);  g.fillRect(0, skyH, W, H - skyH);
    g.fillStyle(C.HORIZON, 1); g.fillRect(0, skyH - 1, W, 3);
    for (let y = skyH + 6, ri = 0; y < H; y += 14, ri++) {
      const off = (ri % 2) * 9;
      for (let x = -off; x < W; x += 18) {
        g.fillStyle(C.COBBLE, 1);    g.fillRoundedRect(x + 1, y + 1, 15, 11, 3);
        g.fillStyle(C.COBBLE_HI, 1); g.fillRoundedRect(x + 1, y + 1, 15, 4, 2);
      }
    }
    return g;
  }

  // ── wooden signpost (ENTRY / EXIT / HQ markers) ─────────────────────────
  function makeSign(scene, x, y, label) {
    const g = scene.add.graphics().setDepth(2);
    g.fillStyle(0x0a1a1f, 0.4); g.fillEllipse(x, y + 26, 26, 7);
    g.fillStyle(C.POLE, 1);    g.fillRect(x - 3, y - 8, 6, 34);
    g.fillStyle(C.WOOD_LT, 1); g.fillRect(x - 24, y - 20, 48, 16);
    g.fillStyle(C.WOOD_DK, 1); g.fillRect(x - 24, y - 20, 48, 2);
    scene.add.text(x, y - 12, label, { fontFamily: PXH, fontSize: '6px', color: '#2a1c10' })
      .setOrigin(0.5, 0.5).setDepth(3);
  }

  // ── pixel robot (the actor in every demo) ───────────────────────────────
  // Returns a Phaser container; caller positions/tweens it.
  function makeRobot(scene, x, y, label, color) {
    const g = scene.add.graphics();
    const px = (bx, by, bw, bh, col, a = 1) => { g.fillStyle(col, a); g.fillRect(bx, by, bw, bh); };
    g.fillStyle(0x0a1a1f, 0.4); g.fillEllipse(0, 15, 26, 7);     // shadow
    px(-6, 6, 4, 6, 0x2a3340); px(2, 6, 4, 6, 0x2a3340);          // legs
    px(-9, -6, 18, 13, color);                                    // body
    px(-9, -6, 18, 2, 0xffffff, 0.28);                            // sheen
    px(-4, -2, 8, 6, 0x0f1f2d, 0.55);                             // chest panel
    px(-7, -17, 14, 11, shade(color, 1.12));                      // head
    px(-7, -17, 14, 2, 0xffffff, 0.25);                          // head sheen
    px(-4, -13, 3, 3, 0x0f1f2d); px(1, -13, 3, 3, 0x0f1f2d);      // eyes
    px(-4, -13, 3, 1, 0x7fd4ff); px(1, -13, 3, 1, 0x7fd4ff);      // eye glow
    px(-1, -21, 2, 4, C.POLE);                                    // antenna
    g.fillStyle(C.GOLD, 1); g.fillCircle(0, -21, 2);
    const t = scene.add.text(0, 17, label, { fontFamily: PX, fontSize: '13px', color: '#dfeaf2' }).setOrigin(0.5, 0);
    return scene.add.container(x, y, [g, t]).setDepth(20);
  }

  // ── pixel merchant figure (behind a stall counter) ──────────────────────
  function pixPerson(g, cx, footY, cloth) {
    const px = (x, y, w, h, col) => { g.fillStyle(col, 1); g.fillRect(Math.round(cx + x), Math.round(footY + y), w, h); };
    px(-7, -2, 14, 10, cloth);
    px(-7, -2, 14, 2, shade(cloth, 1.25));
    px(-9, 0, 3, 7, cloth); px(6, 0, 3, 7, cloth);
    px(-5, -14, 10, 12, C.SKIN);
    px(-5, -14, 10, 3, shade(C.SKIN, 0.78));
    px(-3, -9, 2, 2, 0x2a1c10); px(1, -9, 2, 2, 0x2a1c10);
  }
  function makeWare(g, x, y, col) {
    g.fillStyle(shade(col, 0.7), 1);  g.fillRect(x - 4, y - 7, 8, 8);
    g.fillStyle(col, 1);              g.fillRect(x - 4, y - 7, 8, 3);
    g.fillStyle(shade(col, 1.3), 1);  g.fillRect(x - 4, y - 7, 2, 8);
    g.fillStyle(shade(col, 0.55), 1); g.fillRect(x - 3, y - 9, 6, 2);
  }

  // ── market stall (bazaar / auction / trading booths) ────────────────────
  // Returns { g, soldText, cx, cy, SW, SH, color }.
  function makeStall(scene, cx, cy, name, sub, accent, SW, SH, AH) {
    AH = AH || 18;
    const x0 = cx - SW / 2, y0 = cy - SH / 2;
    const g = scene.add.graphics().setDepth(3);
    const counterY = y0 + SH - 22;
    g.fillStyle(0x0a1a1f, 0.45); g.fillEllipse(cx, y0 + SH + 4, SW * 0.92, 14);
    g.fillStyle(C.WOOD, 1);   g.fillRect(x0 + 6, y0 + AH - 2, SW - 12, SH - AH);
    g.fillStyle(C.WOOD_DK, 1);
    for (let py = y0 + AH + 8; py < counterY - 2; py += 12) g.fillRect(x0 + 8, py, SW - 16, 2);
    g.fillStyle(C.POLE, 1);
    g.fillRect(x0 + 4, y0 + AH, 5, SH - AH); g.fillRect(x0 + SW - 9, y0 + AH, 5, SH - AH);
    pixPerson(g, cx, counterY - 4, accent);
    g.fillStyle(C.WOOD_LT, 1); g.fillRect(x0 + 2, counterY, SW - 4, 12);
    g.fillStyle(shade(C.WOOD_LT, 1.2), 1); g.fillRect(x0 + 2, counterY, SW - 4, 2);
    g.fillStyle(C.WOOD_DK, 1); g.fillRect(x0 + 2, counterY + 12, SW - 4, 8);
    makeWare(g, x0 + SW * 0.30, counterY, accent);
    makeWare(g, x0 + SW * 0.50, counterY, shade(accent, 1.3));
    makeWare(g, x0 + SW * 0.70, counterY, shade(accent, 0.7));
    const stripes = 8, sw = SW / stripes;
    for (let i = 0; i < stripes; i++) {
      g.fillStyle(i % 2 ? accent : C.CREAM, 1);
      g.fillRect(x0 + i * sw, y0, Math.ceil(sw) + 1, AH);
      g.fillTriangle(x0 + i * sw, y0 + AH, x0 + (i + 1) * sw, y0 + AH, x0 + i * sw + sw / 2, y0 + AH + 7);
    }
    g.fillStyle(0x2a1c10, 1); g.fillRect(x0 - 2, y0 - 3, SW + 4, 4);
    g.fillStyle(shade(accent, 1.3), 0.5); g.fillRect(x0, y0, SW, 2);
    if (name) scene.add.text(cx, y0 + SH + 12, name, {
      fontFamily: PX, fontSize: '15px', color: '#f0e6cf', align: 'center', wordWrap: { width: SW + 20 } })
      .setOrigin(0.5, 0.5).setDepth(4);
    if (sub) scene.add.text(cx, y0 + SH + 26, sub, {
      fontFamily: PX, fontSize: '12px', color: '#8aa0aa', align: 'center', wordWrap: { width: SW + 24 } })
      .setOrigin(0.5, 0).setDepth(4);
    const soldText = scene.add.text(cx, cy, 'SOLD!', {
      fontFamily: PXH, fontSize: '8px', color: '#ffd166', backgroundColor: '#0a1a1fdd', padding: { x: 6, y: 4 } })
      .setOrigin(0.5, 0.5).setDepth(6).setVisible(false);
    return { g, soldText, cx, cy, SW, SH, color: accent };
  }

  // ── stone building (heist rooms / station modules / triage zones) ───────
  // opts: { roof: bool, door: bool, accent, icon: '✚'|'⚙'|... }
  // Returns { g, cx, cy, w, h, accent, label, sub } — caller keeps refs it needs.
  function makeBuilding(scene, cx, cy, w, h, name, sub, accent, opts) {
    opts = opts || {};
    const x0 = cx - w / 2, y0 = cy - h / 2;
    const g = scene.add.graphics().setDepth(3);
    g.fillStyle(0x0a1a1f, 0.45); g.fillEllipse(cx, y0 + h + 4, w * 0.92, 13);
    // walls — stone blocks
    g.fillStyle(C.STONE_DK, 1); g.fillRect(x0, y0, w, h);
    g.fillStyle(C.STONE, 1);    g.fillRect(x0 + 2, y0 + 2, w - 4, h - 4);
    for (let by = y0 + 6, r = 0; by < y0 + h - 4; by += 13, r++) {
      const off = (r % 2) * 13;
      for (let bx = x0 + 4 - off; bx < x0 + w - 4; bx += 26) {
        g.fillStyle(C.STONE_HI, 0.5); g.fillRect(bx, by, 24, 2);
        g.fillStyle(C.STONE_DK, 0.6); g.fillRect(bx + 24, by, 2, 11);
      }
    }
    // accent header band
    g.fillStyle(accent, 0.95); g.fillRect(x0 + 2, y0 + 2, w - 4, 12);
    g.fillStyle(shade(accent, 1.3), 0.6); g.fillRect(x0 + 2, y0 + 2, w - 4, 2);
    // roof
    if (opts.roof !== false) {
      g.fillStyle(shade(accent, 0.6), 1);
      g.fillTriangle(x0 - 4, y0 + 2, x0 + w + 4, y0 + 2, cx, y0 - 14);
      g.fillStyle(shade(accent, 0.45), 1);
      g.fillTriangle(x0 - 4, y0 + 2, cx, y0 + 2, cx, y0 - 14);
    }
    // door
    if (opts.door !== false) {
      const dw = Math.min(26, w * 0.26), dh = Math.min(30, h * 0.5);
      g.fillStyle(C.WOOD_DK, 1); g.fillRect(cx - dw / 2, y0 + h - dh, dw, dh);
      g.fillStyle(C.WOOD, 1);    g.fillRect(cx - dw / 2 + 2, y0 + h - dh + 2, dw - 4, dh - 2);
      g.fillStyle(C.GOLD, 1);    g.fillCircle(cx + dw / 2 - 5, y0 + h - dh / 2, 1.6);
    }
    // optional glyph (e.g. ✚ for hospital)
    if (opts.icon) scene.add.text(cx, y0 + 8, opts.icon, { fontFamily: PX, fontSize: '15px', color: '#0a1a1f' }).setOrigin(0.5, 0.5).setDepth(4);
    const label = name ? scene.add.text(cx, y0 + h + 12, name, {
      fontFamily: PX, fontSize: '15px', color: '#f0e6cf', align: 'center', wordWrap: { width: w + 30 } })
      .setOrigin(0.5, 0.5).setDepth(4) : null;
    const subT = sub ? scene.add.text(cx, y0 + h + 26, sub, {
      fontFamily: PX, fontSize: '12px', color: '#8aa0aa', align: 'center', wordWrap: { width: w + 34 } })
      .setOrigin(0.5, 0).setDepth(4) : null;
    return { g, cx, cy, w, h, accent, label, sub: subT };
  }

  // ── speech bubble ───────────────────────────────────────────────────────
  function speech(scene, x, y, text, bg) {
    const t = scene.add.text(x, y, text, {
      fontFamily: PX, fontSize: '13px', color: '#f0e6cf',
      backgroundColor: bg || '#0a1a1fee', padding: { x: 6, y: 3 }, wordWrap: { width: 160 },
    }).setOrigin(0.5, 1).setDepth(24).setAlpha(0);
    scene.tweens.add({ targets: t, alpha: 1, duration: 120 });
    scene.tweens.add({ targets: t, y: y - 14, alpha: 0, delay: 750, duration: 350, onComplete: () => t.destroy() });
    return t;
  }

  // ── capability callouts (the "Lex enforcement, live" overlays) ──────────
  // kind: 'deny' | 'kill' | 'gate' | 'grant' | 'audit'
  const CAP_COL = { deny: 0xf87171, kill: 0xff5555, gate: 0xffd166, grant: 0x4ade80, audit: 0x7fd4ff };
  function capBanner(scene, text, kind) {
    const W = scene.scale.width, H = scene.scale.height;
    const col = CAP_COL[kind] || 0xffd166;
    const hexS = '#' + col.toString(16).padStart(6, '0');
    const flash = scene.add.rectangle(W / 2, H / 2, W, H, col, 0.16).setDepth(55);
    scene.tweens.add({ targets: flash, alpha: 0, duration: 420, onComplete: () => flash.destroy() });
    const t = scene.add.text(W / 2, H * 0.5, text, {
      fontFamily: PXH, fontSize: '11px', color: hexS, align: 'center',
      backgroundColor: '#0a1a1fee', padding: { x: 16, y: 12 },
    }).setOrigin(0.5, 0.5).setDepth(60).setAlpha(0).setScale(0.6);
    scene.tweens.add({ targets: t, alpha: 1, scale: 1, duration: 240, ease: 'Back.easeOut' });
    scene.tweens.add({ targets: t, alpha: 0, duration: 500, delay: 2600, onComplete: () => t.destroy() });
    return t;
  }
  // Small rotated stamp pinned over a target (e.g. ⛔ DENIED on a robot).
  function capStamp(scene, x, y, text, kind) {
    const col = CAP_COL[kind] || 0xf87171;
    const hexS = '#' + col.toString(16).padStart(6, '0');
    const t = scene.add.text(x, y, text, {
      fontFamily: PXH, fontSize: '7px', color: hexS, align: 'center',
      backgroundColor: '#0a1a1fdd', padding: { x: 5, y: 4 },
    }).setOrigin(0.5, 0.5).setDepth(58).setAlpha(0).setScale(1.8).setAngle(-12);
    scene.tweens.add({ targets: t, alpha: 1, scale: 1, duration: 200, ease: 'Back.easeOut' });
    scene.tweens.add({ targets: t, alpha: 0, y: y - 16, duration: 600, delay: 1900, onComplete: () => t.destroy() });
    return t;
  }

  // ── QR "meeting" ────────────────────────────────────────────────────────
  // Two agents that share no prior key meet by exchanging a bootstrap blob.
  // makeQR renders that blob (the real bytes) as a scannable QR in-scene, so the
  // "they didn't know each other" property is literally on screen. onReady gets
  // the placed sprite (async — the QR image must decode first).
  function _hash(s) { let h = 0; for (let i = 0; i < s.length; i++) { h = (h * 31 + s.charCodeAt(i)) | 0; } return Math.abs(h); }
  function makeQR(scene, x, y, text, size, onReady) {
    size = size || 60;
    if (typeof qrcode === 'undefined') return; // lib not loaded yet — skip gracefully
    const qr = qrcode(0, 'L');
    qr.addData(text || '');
    qr.make();
    const cell = Math.max(2, Math.floor(size / qr.getModuleCount()));
    const url = qr.createDataURL(cell, 1);
    const key = 'qr_' + _hash(text || '') + '_' + (text ? text.length : 0);
    const place = () => {
      // white quiet-zone backing so the code stays scannable on the dark scene
      const pad = 4;
      const bg = scene.add.rectangle(x, y, size + pad * 2, size + pad * 2, 0xf0e6cf, 1).setDepth(25).setAlpha(0);
      const img = scene.add.image(x, y, key).setDepth(26).setDisplaySize(size, size).setAlpha(0);
      scene.tweens.add({ targets: [bg, img], alpha: 1, duration: 200 });
      const grp = { bg, img, destroy: () => { bg.destroy(); img.destroy(); } };
      if (onReady) onReady(grp);
    };
    if (scene.textures.exists(key)) { place(); return; }
    const im = new Image();
    im.onload = () => { if (!scene.textures.exists(key)) scene.textures.addImage(key, im); place(); };
    im.src = url;
  }
  // Animated "scan" beam sweeping from a reader to the QR.
  function scanBeam(scene, x1, y1, x2, y2) {
    const g = scene.add.graphics().setDepth(27);
    const draw = (t) => {
      g.clear();
      const cx = x1 + (x2 - x1) * t, cy = y1 + (y2 - y1) * t;
      g.lineStyle(2, 0x7fd4ff, 0.9); g.beginPath(); g.moveTo(x1, y1); g.lineTo(cx, cy); g.strokePath();
      g.fillStyle(0x7fd4ff, 0.9); g.fillCircle(cx, cy, 3);
    };
    scene.tweens.addCounter({ from: 0, to: 1, duration: 500, ease: 'Sine.easeInOut',
      onUpdate: (tw) => draw(tw.getValue()),
      onComplete: () => scene.tweens.add({ targets: g, alpha: 0, duration: 350, onComplete: () => g.destroy() }) });
  }

  // ── Human prompt (the reusable "operator answers" UI) ───────────────────
  // Any dashboard calls RK.humanPrompt(question, id) on a `human_question` event
  // to show a floating answer box; submitting POSTs /answer-human {id, answer}.
  // dismissHumanPrompt(id) clears it (call on `human_answered`).
  const _prompts = {};
  function humanPrompt(question, qid) {
    if (_prompts[qid]) { _prompts[qid].q.textContent = question; return; }
    const wrap = document.createElement('div');
    wrap.style.cssText = 'position:fixed;left:50%;bottom:18px;transform:translateX(-50%);z-index:9999;background:#0a1a1fee;border:2px solid #ffd166;border-radius:8px;padding:12px 14px;display:flex;flex-direction:column;gap:8px;width:min(540px,92vw);box-shadow:0 6px 28px #000a;font-family:VT323,monospace;';
    const q = document.createElement('div'); q.textContent = question; q.style.cssText = 'color:#ffd166;font-size:16px;line-height:1.3;';
    const row = document.createElement('div'); row.style.cssText = 'display:flex;gap:8px;';
    const inp = document.createElement('input'); inp.type = 'text'; inp.placeholder = 'your answer…';
    inp.style.cssText = 'flex:1;background:#16273a;border:1px solid #24384a;color:#dfeaf2;font-family:VT323,monospace;font-size:15px;padding:6px 9px;border-radius:4px;outline:none;';
    const btn = document.createElement('button'); btn.textContent = 'Send';
    btn.style.cssText = 'background:#16273a;border:1px solid #ffd166;color:#ffd166;font-family:VT323,monospace;font-size:15px;padding:6px 14px;border-radius:4px;cursor:pointer;';
    const submit = () => {
      const a = inp.value.trim(); if (!a) return;
      btn.disabled = true;
      fetch('/answer-human', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id: qid, answer: a }) }).catch(() => {});
      dismissHumanPrompt(qid);
    };
    btn.onclick = submit;
    inp.addEventListener('keydown', e => { if (e.key === 'Enter') submit(); });
    row.appendChild(inp); row.appendChild(btn); wrap.appendChild(q); wrap.appendChild(row);
    document.body.appendChild(wrap);
    _prompts[qid] = { wrap, q };
    setTimeout(() => inp.focus(), 50);
  }
  function dismissHumanPrompt(qid) { const p = _prompts[qid]; if (p) { p.wrap.remove(); delete _prompts[qid]; } }

  // ── Phaser config + font-gated start ────────────────────────────────────
  function gameConfig(parent, W, H, scene) {
    return { type: Phaser.AUTO, parent, width: W, height: H,
      backgroundColor: 0x0f1f3d, scene,
      scale: { mode: Phaser.Scale.NONE }, render: { antialias: false, pixelArt: true, roundPixels: true } };
  }
  function startWhenFontsReady(fn) {
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(fn); else fn();
  }

  return { PX, PXH, C, shade, mix, drawBg, makeSign, makeRobot, pixPerson, makeWare,
           makeStall, makeBuilding, speech, capBanner, capStamp, makeQR, scanBeam, humanPrompt, dismissHumanPrompt, gameConfig, startWhenFontsReady };
})();
