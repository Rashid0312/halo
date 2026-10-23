// Vercel function entry (alternative to the Cloudflare Worker). vercel.json
// routes /oauth/callback here. See README.md to deploy.
import { forward } from "../../callback.mjs";

export default function handler(request, response) {
  const { status, headers, body } = forward(request.method, `https://${request.headers.host}${request.url.replace(/^\/api/, "")}`);
  for (const [name, value] of Object.entries(headers)) response.setHeader(name, value);
  response.status(status).send(body);
}
