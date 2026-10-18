# Halo AI Website — Deploy Guide

## Deploying a New Version of the Site

When you update content or fix a bug on the website:

```bash
cd HaloWebsite
bash .cloudrun/deploy.sh
```

Cloud Run does a zero-downtime rolling deploy — the old version handles traffic until the new one is healthy.

---

## Uploading a New Version of the App

1. Build the new `HaloAI.dmg` from HaloNative
2. Upload it to the `halo-downloads` R2 bucket, replacing the old file (same filename)
3. No website redeploy needed — the download endpoint always generates a fresh presigned URL pointing at whatever is in R2

If you want to use a versioned filename (e.g. `HaloAI-1.1.0.dmg`):
1. Update `R2:FileName` in `appsettings.json` (or set it as a Cloud Run env var)
2. Redeploy the site

---

## Updating Changelog / Content

Edit `Pages/Changelog.cshtml` or `Pages/Index.cshtml` and redeploy.

---

## Monitoring (Free)

Cloud Run logs are available at:
```
https://console.cloud.google.com/run → Select service → Logs
```

Download counts can be tracked by checking R2 metrics in the Cloudflare dashboard.

---

## Rolling Back

```bash
# List recent revisions
gcloud run revisions list --service halo-website --region us-central1

# Route all traffic back to a previous revision
gcloud run services update-traffic halo-website \
    --to-revisions REVISION_NAME=100 \
    --region us-central1
```
