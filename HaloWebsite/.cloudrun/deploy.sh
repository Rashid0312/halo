#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
#  Halo AI Website — Google Cloud Run deploy script
#  Run from the HaloWebsite root directory.
#
#  Prerequisites:
#    - gcloud CLI installed (brew install --cask google-cloud-sdk)
#    - gcloud auth login && gcloud config set project YOUR_PROJECT_ID
#    - Secrets already created in Google Secret Manager (see docs/SETUP.md)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

PROJECT_ID="${GCLOUD_PROJECT:-$(gcloud config get-value project)}"
REGION="${GCLOUD_REGION:-us-central1}"
SERVICE_NAME="halo-website"
IMAGE="gcr.io/${PROJECT_ID}/${SERVICE_NAME}"

echo "🚀 Deploying Halo AI website to Cloud Run"
echo "   Project : ${PROJECT_ID}"
echo "   Region  : ${REGION}"
echo "   Service : ${SERVICE_NAME}"
echo ""

# Build and push container image
echo "📦 Building and pushing container image..."
gcloud builds submit \
    --tag "${IMAGE}" \
    --project "${PROJECT_ID}"

# Deploy to Cloud Run
echo "☁️  Deploying to Cloud Run..."
gcloud run deploy "${SERVICE_NAME}" \
    --image "${IMAGE}" \
    --platform managed \
    --region "${REGION}" \
    --allow-unauthenticated \
    --port 8080 \
    --memory 256Mi \
    --cpu 1 \
    --min-instances 0 \
    --max-instances 10 \
    --set-env-vars "ASPNETCORE_ENVIRONMENT=Production" \
    --set-secrets "R2__AccountId=r2-account-id:latest" \
    --set-secrets "R2__AccessKey=r2-access-key:latest" \
    --set-secrets "R2__SecretKey=r2-secret-key:latest" \
    --project "${PROJECT_ID}"

echo ""
echo "✅ Deployed! Service URL:"
gcloud run services describe "${SERVICE_NAME}" \
    --region "${REGION}" \
    --format "value(status.url)" \
    --project "${PROJECT_ID}"
