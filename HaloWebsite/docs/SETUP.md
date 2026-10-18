# Halo AI Website — Setup Guide

This guide walks you through setting up Cloudflare R2 (file storage) and Google Cloud Run (hosting) from scratch — both completely free.

---

## Part 1 — Cloudflare R2 (File Storage)

R2 stores your `.dmg` download. It has **zero egress fees**, so downloads are always free regardless of traffic.

### 1.1 Create a Cloudflare Account
1. Go to [cloudflare.com](https://cloudflare.com) and sign up for a free account
2. No credit card required for R2's free tier (10 GB storage, 1M reads/month)

### 1.2 Create an R2 Bucket
1. In the Cloudflare dashboard, go to **R2 Object Storage** → **Create bucket**
2. Name it `halo-downloads`
3. Choose a region close to your users (or let it auto-select)

### 1.3 Upload Your App
1. Open the `halo-downloads` bucket
2. Click **Upload** and select your `HaloAI.dmg` (or `Halo.app.zip`)
3. Note the exact filename — it must match `R2:FileName` in `appsettings.json`

### 1.4 Create an R2 API Token
1. Go to **R2** → **Manage R2 API Tokens** → **Create API Token**
2. Permissions: **Object Read** only (read-only is sufficient for presigned URLs)
3. Scope: **Specific bucket** → `halo-downloads`
4. Copy these three values — you'll need them:
   - **Account ID** (found in your Cloudflare dashboard URL or R2 overview)
   - **Access Key ID**
   - **Secret Access Key**

---

## Part 2 — Google Cloud Run (Hosting)

### 2.1 Create a Google Cloud Account
1. Go to [console.cloud.google.com](https://console.cloud.google.com)
2. Sign in with a Google account
3. Create a new project — name it `halo-website` or similar
4. **Note:** A credit card is required for account verification, but you will NOT be charged within the free tier limits (2M requests/month, 180K vCPU-seconds/month)

### 2.2 Enable Required APIs
Run these in the Google Cloud Shell or with the `gcloud` CLI:
```bash
gcloud services enable run.googleapis.com
gcloud services enable cloudbuild.googleapis.com
gcloud services enable secretmanager.googleapis.com
gcloud services enable containerregistry.googleapis.com
```

### 2.3 Install the gcloud CLI (on your Mac)
```bash
brew install --cask google-cloud-sdk
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

### 2.4 Store R2 Credentials in Secret Manager
Never put API keys in environment variables directly or in source code. Use Google Secret Manager:

```bash
# Replace the placeholder values with your real R2 credentials from Part 1
echo -n "YOUR_R2_ACCOUNT_ID" | gcloud secrets create r2-account-id --data-file=-
echo -n "YOUR_R2_ACCESS_KEY_ID" | gcloud secrets create r2-access-key --data-file=-
echo -n "YOUR_R2_SECRET_ACCESS_KEY" | gcloud secrets create r2-secret-key --data-file=-
```

### 2.5 Grant Cloud Run Access to Secrets
```bash
PROJECT_NUMBER=$(gcloud projects describe YOUR_PROJECT_ID --format='value(projectNumber)')
gcloud secrets add-iam-policy-binding r2-account-id \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"
gcloud secrets add-iam-policy-binding r2-access-key \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"
gcloud secrets add-iam-policy-binding r2-secret-key \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"
```

---

## Part 3 — Local Test (Optional)

Test the site locally with dummy R2 credentials before deploying:

```bash
cd HaloWebsite

# Install .NET 9 SDK if not installed
# https://dotnet.microsoft.com/download/dotnet/9.0

dotnet run --project src/HaloWebsite
# Open http://localhost:5000
```

The `/download` endpoint will return a 503 with dummy credentials — that's expected locally.

---

## Part 4 — First Deploy

```bash
cd HaloWebsite
chmod +x .cloudrun/deploy.sh
GCLOUD_PROJECT=YOUR_PROJECT_ID bash .cloudrun/deploy.sh
```

After the deploy completes, you'll see a URL like:
```
https://halo-website-xxxxxxxxxx-uc.a.run.app
```

Open it in your browser — that's your live Halo AI website! 🎉

---

## Part 5 — Custom Domain (Later)

When you're ready to attach a real domain:

1. Add a `CNAME` record in Cloudflare DNS pointing `haloai.app` → `halo-website-xxx.a.run.app`
2. In Cloud Run → **Manage custom domains** → map your domain
3. Cloudflare CDN will cache the frontend and protect the backend automatically

No cost change — still free.
