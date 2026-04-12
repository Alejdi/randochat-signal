import { Server } from "socket.io";
import { createServer } from "http";
import { createClient } from "@supabase/supabase-js";

const PORT = process.env.PORT || 4000;
const FALLBACK_MS = 10_000; // how long to wait for a same-country match before falling back to global

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
  const duration_ms = extra.duration_ms ?? null;
  console.log(`[event] ${type} sid=${sid} country=${country}${duration_ms != null ? ` dur=${duration_ms}ms` : ""}`);
  if (!supabase) return;
  supabase
    .from("events")
    .insert({
      session_id: sid,
      type,
      country,
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

function tryMatch(sid) {
  const meta = sessions.get(sid);
  const country = meta?.country || null;
  const now = Date.now();

  // Phase 1: same-country match (strict)
  for (let i = 0; i < queue.length; i++) {
    const other = queue[i];
    if (other.sid === sid) continue;
    if (isBlocked(sid, other.sid)) continue;
    if (country && other.country && other.country === country) {
      queue.splice(i, 1);
      removeFromQueue(sid);
      pair(sid, other.sid);
      return true;
    }
  }

  // Phase 2: fallback match — either side has waited long enough, or either side has no country
  for (let i = 0; i < queue.length; i++) {
    const other = queue[i];
    if (other.sid === sid) continue;
    if (isBlocked(sid, other.sid)) continue;
    const meAged = sessions.get(sid)?.queueEnteredAt
      ? now - sessions.get(sid).queueEnteredAt >= FALLBACK_MS
      : false;
    const theyAged = now - other.enteredAt >= FALLBACK_MS;
    const anyCountryMissing = !country || !other.country;
    if (meAged || theyAged || anyCountryMissing) {
      queue.splice(i, 1);
      removeFromQueue(sid);
      pair(sid, other.sid);
      return true;
    }
  }

  return false;
}

function enqueue(sid) {
  const meta = sessions.get(sid);
  const country = meta?.country || null;
  const now = Date.now();
  if (meta) meta.queueEnteredAt = now;

  if (tryMatch(sid)) return;

  // Not matched — join the queue
  if (!queue.find((e) => e.sid === sid)) {
    queue.push({ sid, country, enteredAt: now });
  }

  // Retry once the fallback window elapses, in case no one new joins
  setTimeout(() => {
    if (!queue.find((e) => e.sid === sid)) return; // already matched or left
    // Walk the rest of the queue looking for any non-blocked pairing
    for (const other of queue) {
      if (other.sid === sid) continue;
      if (isBlocked(sid, other.sid)) continue;
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
  io.emit("presence", { online: io.engine.clientsCount });
}

io.on("connection", (socket) => {
  const country = countryOf(socket);
  sessions.set(socket.id, {
    country,
    startedAt: Date.now(),
    matches: 0,
    skips: 0,
  });
  logEvent(socket.id, "session_start", { country });
  broadcastPresence();

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
    const record = {
      reporter_sid: socket.id,
      reported_sid: peer,
      reason: String(reason || "").slice(0, 500),
    };
    console.log(`[REPORT] ${record.reporter_sid} -> ${record.reported_sid}: ${record.reason}`);
    logEvent(socket.id, "report", { data: { peer, reason: record.reason } });
    if (!supabase) return;
    const { error } = await supabase.from("reports").insert(record);
    if (error) console.error("[randochat] report insert failed:", error.message);
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

http.listen(PORT, () => console.log(`[randochat] signaling on :${PORT}`));
