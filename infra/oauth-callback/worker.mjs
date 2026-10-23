// Cloudflare Worker entry. See README.md to deploy.
import { forward } from "./callback.mjs";

export default {
  fetch(request) {
    const { status, headers, body } = forward(request.method, request.url);
    return new Response(body || null, { status, headers });
  },
};
