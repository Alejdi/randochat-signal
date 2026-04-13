import { Server } from "socket.io";
import { createServer } from "http";
import { createClient } from "@supabase/supabase-js";

const PORT = process.env.PORT || 4000;
const FALLBACK_MS = 10_000;              // same-country match window before falling back to global
const BAN_REFRESH_MS = 30_000;
const AUTO_BAN_WINDOW_MS = 10 * 60_000;  // look back 10 minutes
const AUTO_BAN_THRESHOLD = 3;            // reports in that window → auto-ban
const ADMIN_RELAY_SECRET = process.env.ADMIN_RELAY_SECRET || null;

const supabase =
  process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY
    ? createClient(
        process.env.SUPABASE_URL,
        process.env.SUPABASE_SERVICE_ROLE_KEY,
        { auth: { persistSession: false } }
      )
    : null;

if (!supabase) {
  console.warn("[randochat] Supabase not configured — events/reports will log to stdout only");
}

const http = createServer((req, res) => {
  if (req.url === "/health") { res.writeHead(200); res.end("ok"); return; }
  if (req.url === "/live") {
    const auth = req.headers["authorization"] || "";
    if (!ADMIN_RELAY_SECRET || auth !== `Bearer ${ADMIN_RELAY_SECRET}`) {
      res.writeHead(401); res.end("unauthorized"); return;
    }
    const now = Date.now();
    const list = [];
    for (const [sid, meta] of sessions) {
      const partner = partners.get(sid) || null;
      const state = partner
        ? "matched"
        : queue.find((e) => e.sid === sid)
        ? "searching"
        : "idle";
      list.push({
        sid,
        country: meta.country,
        ip: meta.ip,
        username: meta.username,
        started_at: new Date(meta.startedAt).toISOString(),
        uptime_ms: now - meta.startedAt,
        matches: meta.matches || 0,
        skips: meta.skips || 0,
        partner,
        state,
      });
    }
    list.sort((a, b) => b.uptime_ms - a.uptime_ms);
    res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    res.end(JSON.stringify({
      sessions: list,
      queue_size: queue.length,
      active_bans: banned.size,
      now: new Date(now).toISOString(),
    }));
    return;
  }
  res.writeHead(404); res.end();
});
const io = new Server(http, { cors: { origin: "*" } });

// Queue: [{ sid, country, enteredAt }]
const queue = [];
const partners = new Map();
const blocks = new Map();
// Per-socket metadata: { country, startedAt, matches, skips }
const sessions = new Map();

function logEvent(sid, type, extra = {}) {
  const meta = sessions.get(sid);
  const country = extra.country ?? meta?.country ?? null;
  const ip = extra.ip ?? meta?.ip ?? null;
  const username = extra.username ?? meta?.username ?? null;
  const duration_ms = extra.duration_ms ?? null;
  console.log(`[event] ${type} sid=${sid} ip=${ip} country=${country} user=${username}${duration_ms != null ? ` dur=${duration_ms}ms` : ""}`);
  if (!supabase) return;
  supabase
    .from("events")
    .insert({
      session_id: sid,
      type,
      country,
      ip,
      username,
      duration_ms,
      data: extra.data ?? null,
    })
    .then(({ error }) => {
      if (error) console.error("[event] insert failed:", error.message);
    });
}

function countryOf(socket) {
  const h = socket.handshake.headers || {};
  const raw = h["cf-ipcountry"] || h["x-vercel-ip-country"] || h["x-country-code"];
  if (!raw || raw === "XX" || raw === "T1") return null;
  return String(raw).toUpperCase().slice(0, 2);
}

function ipOf(socket) {
  const h = socket.handshake.headers || {};
  const raw =
    h["cf-connecting-ip"] ||
    (h["x-forwarded-for"] || "").toString().split(",")[0].trim() ||
    h["x-real-ip"] ||
    socket.handshake.address ||
    null;
  if (!raw) return null;
  return String(raw).replace(/^::ffff:/, "").slice(0, 64) || null;
}

// ---- Ban list (in-memory, refreshed from Supabase) ----
const banned = new Set();

async function refreshBans() {
  if (!supabase) return;
  const nowIso = new Date().toISOString();
  const { data, error } = await supabase
    .from("bans")
    .select("ip, expires_at, active")
    .eq("active", true);
  if (error) {
    console.error("[bans] refresh failed:", error.message);
    return;
  }
  const next = new Set();
  for (const row of data || []) {
    if (!row.ip) continue;
    if (row.expires_at && row.expires_at <= nowIso) continue;
    next.add(row.ip);
  }
  banned.clear();
  for (const ip of next) banned.add(ip);
  console.log(`[bans] loaded ${banned.size} active ban(s)`);
}

refreshBans();
setInterval(refreshBans, BAN_REFRESH_MS);

function pair(a, b) {
  partners.set(a, b);
  partners.set(b, a);
  io.to(a).emit("matched", { peer: b, initiator: true });
  io.to(b).emit("matched", { peer: a, initiator: false });
  const ma = sessions.get(a);
  const mb = sessions.get(b);
  if (ma) ma.matches = (ma.matches || 0) + 1;
  if (mb) mb.matches = (mb.matches || 0) + 1;
  logEvent(a, "match", { country: ma?.country, data: { peer_country: mb?.country } });
  logEvent(b, "match", { country: mb?.country, data: { peer_country: ma?.country } });
}

function removeFromQueue(sid) {
  const i = queue.findIndex((e) => e.sid === sid);
  if (i !== -1) queue.splice(i, 1);
}

function isBlocked(a, b) {
  return (blocks.get(a)?.has(b)) || (blocks.get(b)?.has(a));
}

function filterCompatible(meFilter, meCountry, otherFilter, otherCountry) {
  // If I requested a specific country, the other user MUST be from there
  if (meFilter && meFilter !== "any") {
    if (!otherCountry || otherCountry !== meFilter) return false;
  }
  // Symmetric: if they requested a specific country, I must match it
  if (otherFilter && otherFilter !== "any") {
    if (!meCountry || meCountry !== otherFilter) return false;
  }
  return true;
}

function tryMatch(sid) {
  const meta = sessions.get(sid);
  const country = meta?.country || null;
  const filter  = meta?.filter  || "any";
  const now = Date.now();

  // Phase 1: when BOTH users have "any" filter and same country, prefer that.
  if (filter === "any") {
    for (let i = 0; i < queue.length; i++) {
      const other = queue[i];
      if (other.sid === sid) continue;
      if (isBlocked(sid, other.sid)) continue;
      if (other.filter !== "any") continue;
      if (!country || !other.country || other.country !== country) continue;
      queue.splice(i, 1);
      removeFromQueue(sid);
      pair(sid, other.sid);
      return true;
    }
  }

  // Phase 2: any filter-compatible match. If both are "any", require the fallback
  // window so Phase 1 gets a chance to land a same-country pair. Strict filters
  // bypass the wait — users who set a specific country are opting into a global
  // pool for that country.
  for (let i = 0; i < queue.length; i++) {
    const other = queue[i];
    if (other.sid === sid) continue;
    if (isBlocked(sid, other.sid)) continue;
    if (!filterCompatible(filter, country, other.filter, other.country)) continue;

    if (filter === "any" && other.filter === "any") {
      const meAged = meta?.queueEnteredAt ? now - meta.queueEnteredAt >= FALLBACK_MS : false;
      const theyAged = now - other.enteredAt >= FALLBACK_MS;
      const anyCountryMissing = !country || !other.country;
      if (!meAged && !theyAged && !anyCountryMissing) continue;
    }

    queue.splice(i, 1);
    removeFromQueue(sid);
    pair(sid, other.sid);
    return true;
  }

  return false;
}

function enqueue(sid) {
  const meta = sessions.get(sid);
  const country = meta?.country || null;
  const filter  = meta?.filter  || "any";
  const now = Date.now();
  if (meta) meta.queueEnteredAt = now;

  if (tryMatch(sid)) return;

  // Not matched — join the queue
  if (!queue.find((e) => e.sid === sid)) {
    queue.push({ sid, country, filter, enteredAt: now });
  }

  // Retry once the fallback window elapses, in case no one new joins
  setTimeout(() => {
    if (!queue.find((e) => e.sid === sid)) return; // already matched or left
    const meEntry = sessions.get(sid);
    const meCountry = meEntry?.country || null;
    const meFilter  = meEntry?.filter  || "any";
    for (const other of queue) {
      if (other.sid === sid) continue;
      if (isBlocked(sid, other.sid)) continue;
      if (!filterCompatible(meFilter, meCountry, other.filter, other.country)) continue;
      removeFromQueue(sid);
      removeFromQueue(other.sid);
      pair(sid, other.sid);
      return;
    }
  }, FALLBACK_MS + 200);
}

function leavePartner(sid, notify = true) {
  const p = partners.get(sid);
  if (p) {
    partners.delete(sid);
    partners.delete(p);
    if (notify) io.to(p).emit("partner-left");
  }
  removeFromQueue(sid);
}

function broadcastPresence() {
  const countries = {};
  for (const meta of sessions.values()) {
    const c = meta?.country;
    if (!c) continue;
    countries[c] = (countries[c] || 0) + 1;
  }
  io.emit("presence", {
    online: io.engine.clientsCount,
    countries,
  });
}

io.on("connection", (socket) => {
  const country = countryOf(socket);
  const ip = ipOf(socket);

  if (ip && banned.has(ip)) {
    console.log(`[bans] rejecting banned ip=${ip}`);
    socket.emit("banned", { reason: "Your access has been restricted." });
    socket.disconnect(true);
    return;
  }

  sessions.set(socket.id, {
    country,
    ip,
    username: null,
    filter: "any",
    startedAt: Date.now(),
    matches: 0,
    skips: 0,
  });
  logEvent(socket.id, "session_start", { country, ip });
  broadcastPresence();

  socket.on("hello", ({ username, filter } = {}) => {
    const meta = sessions.get(socket.id);
    if (!meta) return;
    const clean = typeof username === "string" ? username.trim().slice(0, 32) : null;
    if (clean && /^[A-Za-z0-9_]+$/.test(clean)) {
      meta.username = clean;
    }
    if (typeof filter === "string") {
      meta.filter = filter === "any" ? "any" : filter.toUpperCase().slice(0, 2);
    }
  });

  socket.on("set-filter", ({ filter } = {}) => {
    const meta = sessions.get(socket.id);
    if (!meta) return;
    meta.filter = filter === "any" ? "any" : String(filter || "any").toUpperCase().slice(0, 2);
    // Update the queue entry if user is currently waiting
    const entry = queue.find((e) => e.sid === socket.id);
    if (entry) entry.filter = meta.filter;
  });

  socket.on("join-queue", () => {
    leavePartner(socket.id);
    enqueue(socket.id);
  });

  socket.on("signal", ({ to, data }) => {
    if (partners.get(socket.id) === to) {
      io.to(to).emit("signal", { from: socket.id, data });
    }
  });

  socket.on("next", () => {
    const meta = sessions.get(socket.id);
    if (meta) meta.skips = (meta.skips || 0) + 1;
    logEvent(socket.id, "skip");
    leavePartner(socket.id);
    enqueue(socket.id);
  });

  socket.on("stop", () => {
    leavePartner(socket.id);
  });

  socket.on("block", ({ peer }) => {
    if (!blocks.has(socket.id)) blocks.set(socket.id, new Set());
    blocks.get(socket.id).add(peer);
    logEvent(socket.id, "block", { data: { peer } });
    leavePartner(socket.id);
  });

  socket.on("report", async ({ peer, reason }) => {
    const peerMeta = sessions.get(peer);
    const record = {
      reporter_sid: socket.id,
      reported_sid: peer,
      reason: String(reason || "").slice(0, 500),
      reported_ip: peerMeta?.ip ?? null,
      reported_username: peerMeta?.username ?? null,
    };
    console.log(`[REPORT] ${record.reporter_sid} -> ${record.reported_sid} (${record.reported_ip}): ${record.reason}`);
    logEvent(socket.id, "report", { data: { peer, reason: record.reason, reported_ip: record.reported_ip } });
    if (!supabase) return;
    const { error } = await supabase.from("reports").insert(record);
    if (error) { console.error("[randochat] report insert failed:", error.message); return; }

    // Auto-ban check: N reports against the same IP within the window → permanent ban
    if (!record.reported_ip) return;
    try {
      const sinceIso = new Date(Date.now() - AUTO_BAN_WINDOW_MS).toISOString();
      const { count } = await supabase
        .from("reports")
        .select("id", { count: "exact", head: true })
        .eq("reported_ip", record.reported_ip)
        .gte("created_at", sinceIso);
      if ((count || 0) < AUTO_BAN_THRESHOLD) return;

      // Skip if already actively banned
      const { count: activeCount } = await supabase
        .from("bans")
        .select("id", { count: "exact", head: true })
        .eq("ip", record.reported_ip)
        .eq("active", true);
      if ((activeCount || 0) > 0) return;

      const reasonText = `auto: ${count} reports in ${AUTO_BAN_WINDOW_MS / 60000}m`;
      const { error: banError } = await supabase.from("bans").insert({
        ip: record.reported_ip,
        reason: reasonText,
        banned_by: "auto",
        active: true,
      });
      if (banError) { console.error("[auto-ban] insert failed:", banError.message); return; }

      banned.add(record.reported_ip);
      console.log(`[auto-ban] ${record.reported_ip} — ${reasonText}`);

      // Disconnect the offender immediately if they're still connected
      for (const [sid, meta] of sessions) {
        if (meta.ip !== record.reported_ip) continue;
        const s = io.sockets.sockets.get(sid);
        if (!s) continue;
        s.emit("banned", { reason: "Multiple reports received." });
        s.disconnect(true);
      }
    } catch (e) {
      console.error("[auto-ban] error:", e?.message || e);
    }
  });

  socket.on("gift", ({ type }) => {
    const p = partners.get(socket.id);
    if (p) io.to(p).emit("gift", { type });
  });

  socket.on("disconnect", () => {
    const meta = sessions.get(socket.id);
    if (meta) {
      const duration_ms = Date.now() - meta.startedAt;
      logEvent(socket.id, "session_end", {
        duration_ms,
        data: { matches: meta.matches || 0, skips: meta.skips || 0 },
      });
    }
    sessions.delete(socket.id);
    leavePartner(socket.id);
    blocks.delete(socket.id);
    broadcastPresence();
  });
});

http.listen(PORT, () => console.log(`[randochat] signaling on :${PORT} (supabase=${!!supabase} relay=${!!ADMIN_RELAY_SECRET})`));
