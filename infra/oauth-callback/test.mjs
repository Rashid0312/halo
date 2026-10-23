// node test.mjs — checks the callback logic with no dependencies.
import assert from "node:assert/strict";
import { forward } from "./callback.mjs";

const base = "https://auth.example.com/oauth/callback";
const state = "AbC-123_xyz.~AbC-123_xyz";

let r = forward("GET", `${base}?code=4%2F0Ab-x%2By&state=${state}&scope=email`);
assert.equal(r.status, 302);
const next = new URL(r.headers.Location);
assert.equal(next.protocol, "halo:");
assert.equal(`${next.protocol}//${next.host}${next.pathname}`, "halo://oauth/callback");
assert.equal(next.searchParams.get("code"), "4/0Ab-x+y");
assert.equal(next.searchParams.get("state"), state);
assert.equal(next.searchParams.get("scope"), null, "only code and state are forwarded");
assert.equal(r.headers["Cache-Control"], "no-store");
assert.equal(r.headers["Referrer-Policy"], "no-referrer");

r = forward("GET", `${base}?error=access_denied&state=${state}`);
assert.equal(new URL(r.headers.Location).searchParams.get("error"), "access_denied");
r = forward("GET", `${base}?error=<script>&state=${state}`);
assert.equal(new URL(r.headers.Location).searchParams.get("error"), "access_denied", "odd errors are normalised");

for (const bad of [`${base}?code=x`, `${base}?code=x&state=short`, `${base}?code=x&state=${state}%22%3E`,
                   `${base}?code=x&error=y&state=${state}`, `${base}?state=${state}`, `${base}?code=&state=${state}`,
                   `${base}?code=${"a".repeat(5000)}&state=${state}`]) {
  r = forward("GET", bad);
  assert.equal(r.status, 400, bad.slice(0, 80));
  assert.ok(!r.body.includes("code=") && !r.headers.Location);
}
assert.equal(forward("POST", `${base}?code=x&state=${state}`).status, 404);
assert.equal(forward("GET", `https://auth.example.com/?code=x&state=${state}`).status, 404);
console.log("PASS: callback forwards only code/state (or a normalised error) to halo://oauth/callback and rejects malformed requests");
