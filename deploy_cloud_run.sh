#!/bin/bash

# ============================================================================
# LiteLLM Proxy Cloud Run Deployment Script
# ============================================================================
# This script automates the entire GCP pipeline: enabling required services,
# creating an Artifact Registry repository, compiling the container via Cloud Build,
# and deploying to fully-managed Google Cloud Run with IAM/environment bindings.

set -e # Exit immediately if any command fails

# ANSI Color Codes for premium console output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
BOLD='\033[1m'

echo -e "${GREEN}${BOLD}====================================================================${NC}"
echo -e "${GREEN}${BOLD}              LiteLLM Vertex AI Proxy Cloud Run Deployer            ${NC}"
echo -e "${GREEN}${BOLD}====================================================================${NC}"

# 1. Verify gcloud authentication
echo -e "${GREEN}[*] Verifying Google Cloud SDK authentication...${NC}"
PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")

if [ -z "$PROJECT_ID" ]; then
    echo -e "${RED}[X] ERROR: No active GCP project detected in gcloud config!${NC}"
    echo -e "    Please run: gcloud auth login && gcloud config set project YOUR_PROJECT_ID"
    exit 1
fi

echo -e "${GREEN}[✓] Active GCP Project: ${BOLD}${PROJECT_ID}${NC}"

# 2. Configure Deployment Variables
# We ask the user for basic inputs with smart, production-ready defaults
echo -e ""
echo -e "${BOLD}Configuration Parameters:${NC}"

# Default Cloud Run deployment location
read -p "$(echo -e ${GREEN}"Enter Cloud Run Deployment Region [default: us-central1]: "${NC})" DEPLOY_REGION
DEPLOY_REGION=${DEPLOY_REGION:-us-central1}

# Default Vertex AI endpoint location (usually defaults to same region for minimum latency)
read -p "$(echo -e ${GREEN}"Enter Vertex AI Backend Region [default: global]: "${NC})" VERTEX_REGION
VERTEX_REGION=${VERTEX_REGION:-global}

# Generate a cryptographically secure Master Key as the default
DEFAULT_KEY=$(openssl rand -hex 24 2>/dev/null || echo "sk-litellm-vertex-$(date +%s)")
read -p "$(echo -e ${GREEN}"Enter Proxy Master Key (for Cursor auth) [Leave blank to auto-generate]: "${NC})" MASTER_KEY
MASTER_KEY=${MASTER_KEY:-$DEFAULT_KEY}

echo -e ""
echo -e "${GREEN}[*] Summary of Configuration:${NC}"
echo -e "    - GCP Project:     ${BOLD}${PROJECT_ID}${NC}"
echo -e "    - Deploy Region:   ${BOLD}${DEPLOY_REGION}${NC}"
echo -e "    - Vertex Region:   ${BOLD}${VERTEX_REGION}${NC}"
echo -e "    - Proxy Auth Key:  ${BOLD}${MASTER_KEY}${NC}"
echo -e ""
read -p "$(echo -e ${YELLOW}"Proceed with deployment? (y/N): "${NC})" CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${RED}[i] Deployment cancelled by user.${NC}"
    exit 0
fi

# 3. Enable Required Google APIs
echo -e "${GREEN}[*] Enabling required Google Cloud Services (Artifact Registry, Cloud Build, Cloud Run)...${NC}"
gcloud services enable \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    run.googleapis.com \
    aiplatform.googleapis.com \
    --quiet

# 4. Create Artifact Registry if missing
REPO_NAME="litellm-proxy-repo"
echo -e "${GREEN}[*] Checking for Artifact Registry Repository '${REPO_NAME}' in ${DEPLOY_REGION}...${NC}"
if gcloud artifacts repositories describe $REPO_NAME --location=$DEPLOY_REGION &>/dev/null; then
    echo -e "${GREEN}[✓] Artifact Registry Repository already exists.${NC}"
else
    echo -e "${GREEN}[*] Repository not found. Creating Artifact Registry Docker repository '${REPO_NAME}' in ${DEPLOY_REGION}...${NC}"
    gcloud artifacts repositories create $REPO_NAME \
        --repository-format=docker \
        --location=$DEPLOY_REGION \
        --description="Docker repository for LiteLLM proxy services" \
        --quiet
fi

# 5. Compile & Push Container via Google Cloud Build
IMAGE_URI="${DEPLOY_REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/litellm-proxy:latest"
echo -e "${GREEN}[*] Submitting build to Google Cloud Build...${NC}"
echo -e "${YELLOW}[i] Image URI: ${IMAGE_URI}${NC}"
gcloud builds submit --tag $IMAGE_URI .

# 6. Deploy to Google Cloud Run
SERVICE_NAME="litellm-vertex-proxy"
echo -e "${GREEN}[*] Deploying image to fully-managed Google Cloud Run...${NC}"
gcloud run deploy $SERVICE_NAME \
    --image=$IMAGE_URI \
    --region=$DEPLOY_REGION \
    --platform=managed \
    --allow-unauthenticated \
    --update-env-vars="GCP_PROJECT_ID=${PROJECT_ID},GCP_REGION=${VERTEX_REGION},LITELLM_MASTER_KEY=${MASTER_KEY}" \
    --quiet

# 7. Retrieve Deployment URL
SERVICE_URL=$(gcloud run services describe $SERVICE_NAME --region=$DEPLOY_REGION --format="value(status.url)" 2>/dev/null || echo "")

# 8. Post-Deployment IAM Instructions
# Extract the runtime Service Account attached to the Cloud Run service
RUN_ACCOUNT=$(gcloud run services describe $SERVICE_NAME --region=$DEPLOY_REGION --format="value(spec.template.spec.serviceAccountName)" 2>/dev/null || echo "")
if [ -z "$RUN_ACCOUNT" ]; then
    # Default Cloud Run Service Account format if describe fails
    PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
    RUN_ACCOUNT="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
fi

echo -e ""
echo -e "${GREEN}${BOLD}====================================================================${NC}"
echo -e "${GREEN}${BOLD}                 🚀 DEPLOYMENT COMPLETED SUCCESSFULLY               ${NC}"
echo -e "${GREEN}${BOLD}====================================================================${NC}"
echo -e ""
echo -e "${BOLD}1. Proxy Endpoint URL:${NC}"
echo -e "   ${GREEN}${BOLD}${SERVICE_URL}/v1${NC}"
echo -e ""
echo -e "${BOLD}2. Proxy Master API Key (Bearer Token):${NC}"
echo -e "   ${GREEN}${BOLD}${MASTER_KEY}${NC}"
echo -e ""
echo -e "${YELLOW}${BOLD}⚠️ CRITICAL: MANDATORY IAM ROLE BINDING REQUIRED${NC}"
echo -e "To allow Cloud Run to access Vertex AI without access key JSON files, run this command:"
echo -e "${BOLD}gcloud projects add-iam-policy-binding ${PROJECT_ID} \\"
echo -e "    --member=\"serviceAccount:${RUN_ACCOUNT}\" \\"
echo -e "    --role=\"roles/aiplatform.user\"${NC}"
echo -e ""
echo -e "${BOLD}3. Cursor IDE Configuration Checklist:${NC}"
echo -e "   - Open Cursor Settings -> Models."
echo -e "   - Enter the API Key: ${BOLD}${MASTER_KEY}${NC}"
echo -e "   - Set 'Override Base URL' to: ${BOLD}${SERVICE_URL}/v1${NC}"
echo -e "   - Toggle or Add your models: ${BOLD}gemini-2.5-pro, gemini-3.1-pro-preview, etc.${NC}"
echo -e "${GREEN}${BOLD}====================================================================${NC}"
