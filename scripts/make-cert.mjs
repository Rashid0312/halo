// Creates a self-signed code-signing certificate, "Mercy Local Signing", in the
// login keychain. Run once per Mac:
//
//   npm run cert
//
// Ad-hoc signed builds get a new identity every build, so macOS forgets their
// Accessibility / Automation grants after each update. Builds signed with this
// certificate keep one identity, and the grants stick. dist.mjs uses it when
// it's there and falls back to ad-hoc when it isn't.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const IDENTITY = "Mercy Local Signing";
const KEYCHAIN = path.join(os.homedir(), "Library/Keychains/login.keychain-db");

const sh = (cmd, args, opts = {}) => execFileSync(cmd, args, { encoding: "utf8", ...opts });

if (sh("security", ["find-identity", "-v", "-p", "codesigning"]).includes(`"${IDENTITY}"`)) {
  console.log(`"${IDENTITY}" is already in your keychain.`);
  process.exit(0);
}

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mercy-cert-"));
const f = (name) => path.join(dir, name);
try {
  fs.writeFileSync(
    f("cert.cnf"),
    `[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${IDENTITY}
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
`,
  );
  sh("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-config", f("cert.cnf"), "-keyout", f("key.pem"), "-out", f("cert.pem")]);
  // -legacy: macOS's keychain can't read OpenSSL 3's default PKCS#12 encryption.
  const legacy = /^OpenSSL 3/.test(sh("openssl", ["version"])) ? ["-legacy"] : [];
  sh("openssl", ["pkcs12", "-export", ...legacy, "-inkey", f("key.pem"), "-in", f("cert.pem"), "-out", f("cert.p12"), "-passout", "pass:mercy"]);
  sh("security", ["import", f("cert.p12"), "-k", KEYCHAIN, "-P", "mercy", "-T", "/usr/bin/codesign"]);
  console.log("macOS will ask for your password to trust the certificate for code signing.");
  sh("security", ["add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", KEYCHAIN, f("cert.pem")], { stdio: "inherit" });
  console.log(`Created "${IDENTITY}". Builds from npm run dist are now signed with it.`);
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
