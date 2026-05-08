#!/usr/bin/env node
"use strict";

const http = require("http");
const https = require("https");

const PORT = Number(process.env.PORT || 8787);
const TELEGRAM_BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const TELEGRAM_CHAT_ID = process.env.TELEGRAM_CHAT_ID;
const SHARED_SECRET = process.env.WEBHOOK_SECRET || "";

if (!TELEGRAM_BOT_TOKEN || !TELEGRAM_CHAT_ID) {
  console.error("Missing TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID");
  process.exit(1);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk;
      if (body.length > 1_000_000) {
        req.destroy();
        reject(new Error("body too large"));
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function formatMessage(payload) {
  const event = payload.event || payload;
  const reasonBitmap = event.reasonBitmap || event.reason_bitmap || "unknown";
  const target = event.target || event.primaryTarget || "unknown";
  const blockNumber = event.blockNumber || event.block_number || "unknown";
  const creditedStake = event.creditedStake || event.credited_stake || "unknown";
  const tokenBacking = event.tokenBacking || event.token_backing || "unknown";
  const oldStaking = event.lastMigrationOldStaking || event.last_migration_old_staking || "unknown";
  const migrator = event.lastMigrator || event.last_migrator || "unknown";
  const amount = event.lastMigrationAmount || event.last_migration_amount || "unknown";

  return [
    "TempleDAO migration backing alert",
    `target: ${target}`,
    `block: ${blockNumber}`,
    `reasonBitmap: ${reasonBitmap}`,
    `creditedStake: ${creditedStake}`,
    `tokenBacking: ${tokenBacking}`,
    `lastMigrationOldStaking: ${oldStaking}`,
    `lastMigrator: ${migrator}`,
    `lastMigrationAmount: ${amount}`
  ].join("\n");
}

function sendTelegram(text) {
  const body = JSON.stringify({
    chat_id: TELEGRAM_CHAT_ID,
    text,
    disable_web_page_preview: true
  });

  const req = https.request(
    {
      method: "POST",
      hostname: "api.telegram.org",
      path: `/bot${TELEGRAM_BOT_TOKEN}/sendMessage`,
      headers: {
        "content-type": "application/json",
        "content-length": Buffer.byteLength(body)
      }
    },
    (res) => {
      res.resume();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        console.error(`Telegram returned HTTP ${res.statusCode}`);
      }
    }
  );
  req.on("error", (err) => console.error("Telegram send failed:", err.message));
  req.end(body);
}

const server = http.createServer(async (req, res) => {
  if (req.method !== "POST" || req.url !== "/drosera/templedao") {
    res.writeHead(404);
    res.end("not found");
    return;
  }

  if (SHARED_SECRET && req.headers["x-webhook-secret"] !== SHARED_SECRET) {
    res.writeHead(401);
    res.end("unauthorized");
    return;
  }

  try {
    const raw = await readBody(req);
    const payload = raw ? JSON.parse(raw) : {};
    sendTelegram(formatMessage(payload));
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
  } catch (err) {
    res.writeHead(400);
    res.end(err.message);
  }
});

server.listen(PORT, () => {
  console.log(`TempleDAO Telegram webhook listening on :${PORT}`);
});
