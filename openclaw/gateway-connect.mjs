// Signs in to the gateway the way the Control UI does: a browser Origin, the
// shared token from OPENCLAW_GATEWAY_TOKEN and an Ed25519 device identity kept
// in <identity-file>. Optionally makes one call. Prints one JSON line per step.
//   node gateway-connect.mjs <ws-url> <origin> <identity-file> [<method> <params-json>]
// Exit codes: 0 signed in (and the call succeeded), 2 sign-in refused, 3 call failed, 4 no answer.
import crypto from "node:crypto";
import fs from "node:fs";

const [url, origin, identityFile, method, paramsJson] = process.argv.slice(2);
const token = process.env.OPENCLAW_GATEWAY_TOKEN ?? "";
const client = { id: "openclaw-control-ui", version: "control-ui", platform: "web", mode: "webchat" };
const role = "operator";
const scopes = [
  "operator.admin",
  "operator.read",
  "operator.write",
  "operator.approvals",
  "operator.questions",
  "operator.pairing",
];

if (!fs.existsSync(identityFile)) {
  const { privateKey } = crypto.generateKeyPairSync("ed25519");
  fs.writeFileSync(identityFile, privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600 });
}
const privateKey = crypto.createPrivateKey(fs.readFileSync(identityFile, "utf8"));
const publicKey = crypto.createPublicKey(privateKey).export({ type: "spki", format: "der" }).subarray(-32);
const deviceId = crypto.createHash("sha256").update(publicKey).digest("hex");

const print = (line) => console.log(JSON.stringify(line));

function session() {
  const ws = new WebSocket(url, { headers: { Origin: origin } });
  const waiting = new Map();
  let id = 0;
  let challenge;
  let closedWith;
  const closed = new Promise((_, reject) => (closedWith = reject));
  closed.catch(() => {});
  ws.onerror = () => {};
  ws.onclose = (event) => closedWith(new Error(`closed ${event.code} ${event.reason}`));
  ws.onmessage = (event) => {
    const frame = JSON.parse(event.data);
    if (frame.type === "event" && frame.event === "connect.challenge") {
      challenge(frame.payload);
    } else if (frame.type === "res" && waiting.has(frame.id)) {
      waiting.get(frame.id)(frame);
      waiting.delete(frame.id);
    }
  };
  const challenged = Promise.race([new Promise((resolve) => (challenge = resolve)), closed]);
  const call = (name, params) =>
    Promise.race([
      new Promise((resolve) => {
        const key = String(++id);
        waiting.set(key, resolve);
        ws.send(JSON.stringify({ type: "req", id: key, method: name, params }));
      }),
      closed,
    ]);
  return { ws, challenged, call };
}

async function signIn() {
  for (let attempt = 1; ; attempt++) {
    const s = session();
    const { nonce, ts } = await s.challenged;
    const payload = ["v3", deviceId, client.id, client.mode, role, scopes.join(","), String(ts), token, nonce, "web", ""].join("|");
    const signature = crypto.sign(null, Buffer.from(payload), privateKey).toString("base64url");
    const res = await s.call("connect", {
      minProtocol: 4,
      maxProtocol: 4,
      client,
      role,
      scopes,
      caps: [],
      auth: { token },
      device: { id: deviceId, publicKey: publicKey.toString("base64url"), signature, signedAt: ts, nonce },
    });
    const retryAfter = res.error?.retryAfterMs ?? res.error?.details?.retryAfterMs;
    if (!res.ok && res.error?.retryable && retryAfter && attempt < 30) {
      s.ws.close();
      await new Promise((resolve) => setTimeout(resolve, retryAfter));
      continue;
    }
    return { s, res };
  }
}

const timer = setTimeout(() => {
  print({ step: "timeout" });
  process.exit(4);
}, 120000);

try {
  const { s, res } = await signIn();
  if (!res.ok) {
    print({ step: "connect", ok: false, deviceId, error: res.error });
    process.exit(2);
  }
  const auth = res.payload.auth ?? {};
  print({
    step: "connect",
    ok: true,
    deviceId,
    protocol: res.payload.protocol,
    server: res.payload.server?.version,
    role: auth.role,
    scopes: auth.scopes,
    deviceToken: Boolean(auth.deviceToken),
  });
  if (method) {
    const out = await s.call(method, JSON.parse(paramsJson ?? "{}"));
    print({ step: method, ok: out.ok, payload: out.payload, error: out.error });
    if (!out.ok) process.exit(3);
  }
  clearTimeout(timer);
  s.ws.close();
} catch (error) {
  print({ step: "transport", error: String(error.message ?? error) });
  process.exit(4);
}
