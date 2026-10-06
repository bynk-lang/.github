// Verify a canary report the way a Bynk `Signature` actor does, so the test
// fails if report.sh signs anything other than what the receiver checks.
//
// This mirrors `verifySignatureHmacSha256` in accuser/bynk
// bynk-emit/src/emitter/runtime.ts (v0.303.4): the raw body is read with
// `request.text()`; with a timestamp header bound, the signed string is
// `${timestamp}.${body}`; the key is the secret's UTF-8 bytes; the signature
// header is hex, optionally prefixed `sha256=`; and the timestamp must be a
// finite number within `tolerance` seconds of now.
//
//   node verify-signature.mjs <secret> <body-file> <X-Timestamp> <X-Signature>
// Exits 0 if authentic, 1 if not.
import { readFileSync } from "node:fs";

const [secret, bodyFile, timestamp, signatureHeader] = process.argv.slice(2);
const toleranceSecs = 300;
// `request.text()` decodes UTF-8; the runtime re-encodes the decoded string.
const body = new TextDecoder().decode(readFileSync(bodyFile));

function hexToBytes(hex) {
  const clean = hex.startsWith("sha256=") ? hex.slice(7) : hex;
  if (clean.length === 0 || clean.length % 2 !== 0 || /[^0-9a-fA-F]/.test(clean)) {
    return new Uint8Array(0);
  }
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  return out;
}

async function verify() {
  const ts = Number(timestamp);
  if (!Number.isFinite(ts)) return false;
  if (Math.abs(Math.floor(Date.now() / 1000) - ts) > toleranceSecs) return false;
  const sigBytes = hexToBytes(signatureHeader);
  if (sigBytes.length === 0) return false;
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"],
  );
  return crypto.subtle.verify("HMAC", key, sigBytes, enc.encode(`${timestamp}.${body}`));
}

process.exit((await verify()) ? 0 : 1);
