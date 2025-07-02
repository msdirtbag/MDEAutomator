#!/bin/bash
# Azure Container Apps Configuration for Persistent MCP Server
# This script configures scaling rules to prevent automatic shutdown

RESOURCE_GROUP="your-resource-group"
CONTAINER_APP_NAME="mcpautodev"

echo "Configuring Container App scaling rules..."

# Update Container App with proper scaling configuration
az containerapp update \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --min-replicas 1 \
  --max-replicas 1 \
  --scale-rule-name "http-scaler" \
  --scale-rule-type "http" \
  --scale-rule-http-metadata concurrentRequests=10 \
  --scale-rule-auth-trigger-parameter "HeaderName=User-Agent" \
  --revision-suffix "persistent-v2"

echo "✓ Container App configured for persistent mode"

# Add startup probe to ensure proper health checks
az containerapp update \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --startup-probe-failure-threshold 3 \
  --startup-probe-initial-delay 30 \
  --startup-probe-period 10 \
  --startup-probe-success-threshold 1 \
  --startup-probe-timeout 5 \
  --startup-probe-type "httpGet" \
  --startup-probe-http-path "/health" \
  --startup-probe-http-port 8080

echo "✓ Startup probe configured"

# Add liveness probe
az containerapp update \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --liveness-probe-failure-threshold 3 \
  --liveness-probe-initial-delay 0 \
  --liveness-probe-period 30 \
  --liveness-probe-success-threshold 1 \
  --liveness-probe-timeout 5 \
  --liveness-probe-type "httpGet" \
  --liveness-probe-http-path "/health" \
  --liveness-probe-http-port 8080

echo "✓ Liveness probe configured"

echo "🚀 Configuration complete! Container should stay running now."
