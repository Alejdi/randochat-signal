import { Server } from "socket.io";
import { createServer } from "http";
import { createClient } from "@supabase/supabase-js";

const PORT = process.env.PORT || 4000;

const supabase =
  process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY
    ? createClient(
        process.env.SUPABASE_URL,
        process.env.SUPABASE_SERVICE_ROLE_KEY,
        { auth: { persistSession: false } }
      )
    : null;

if (!supabase) {
  console.warn("[randochat] Supabase not configured — reports will log to stdout only");
}
const http = createServer((req, res) => {
  if (req.url === "/health") { res.writeHead(200); res.end("ok"); return; }
  res.writeHead(404); res.end();
});
const io = new Server(http, { cors: { origin: "*" } });

const queue = [];
const partners = new Map();
const blocks = new Map();

function pair(a, b) {
  partners.set(a, b);
  partners.set(b, a);
  io.to(a).emit("matched", { peer: b, initiator: true });
  io.to(b).emit("matched", { peer: a, initiator: false });
}

function enqueue(sid) {
  const aBlocks = blocks.get(sid) || new Set();
  for (let i = 0; i < queue.length; i++) {
    const other = queue[i];
    if (other === sid) continue;
    const bBlocks = blocks.get(other) || new Set();
    if (aBlocks.has(other) || bBlocks.has(sid)) continue;
    queue.splice(i, 1);
    pair(sid, other);
    return;
  }
  if (!queue.includes(sid)) queue.push(sid);
}

function leavePartner(sid, notify = true) {
  const p = partners.get(sid);
  if (p) {
    partners.delete(sid);
    partners.delete(p);
    if (notify) io.to(p).emit("partner-left");
  }
  const i = queue.indexOf(sid);
  if (i !== -1) queue.splice(i, 1);
}

function broadcastPresence() {
  io.emit("presence", { online: io.engine.clientsCount });
}

io.on("connection", (socket) => {
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
    leavePartner(socket.id);
    enqueue(socket.id);
  });

  socket.on("stop", () => {
    leavePartner(socket.id);
  });

  socket.on("block", ({ peer }) => {
    if (!blocks.has(socket.id)) blocks.set(socket.id, new Set());
    blocks.get(socket.id).add(peer);
    leavePartner(socket.id);
  });

  socket.on("report", async ({ peer, reason }) => {
    const record = {
      reporter_sid: socket.id,
      reported_sid: peer,
      reason: String(reason || "").slice(0, 500),
    };
    console.log(`[REPORT] ${record.reporter_sid} -> ${record.reported_sid}: ${record.reason}`);
    if (!supabase) return;
    const { error } = await supabase.from("reports").insert(record);
    if (error) console.error("[randochat] report insert failed:", error.message);
  });

  socket.on("gift", ({ type }) => {
    const p = partners.get(socket.id);
    if (p) io.to(p).emit("gift", { type });
  });

  socket.on("disconnect", () => {
    leavePartner(socket.id);
    blocks.delete(socket.id);
    broadcastPresence();
  });
});

http.listen(PORT, () => console.log(`[randochat] signaling on :${PORT}`));
