#!/bin/bash
set -euo pipefail

# ============================================================
# GSP215
# Global External Application Load Balancer + Cloud Armor
# ============================================================

EU_REGION="europe-west4"
US_REGION="us-east1"

EU_ZONES="europe-west4-a,europe-west4-b"
US_ZONES="us-east1-b,us-east1-c"

SIEGE_ZONE="us-west1-a"

STARTUP_URL="gs://spls/gsp215/gcpnet/httplb/startup.sh"

echo "=================================================="
echo "GSP215 START"
echo "Project: $(gcloud config get-value project)"
echo "=================================================="

# ============================================================
# TASK 1
# FIREWALL
# ============================================================

echo "[1/5] Creating firewall rules..."

gcloud compute firewall-rules create default-allow-http \
  --network=default \
  --target-tags=http-server \
  --source-ranges=0.0.0.0/0 \
  --allow=tcp:80 \
  --quiet

gcloud compute firewall-rules create default-allow-health-check \
  --network=default \
  --target-tags=http-server \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --allow=tcp \
  --quiet

# ============================================================
# TASK 2
# INSTANCE TEMPLATES
# ============================================================

echo "[2/5] Creating instance templates..."

gcloud compute instance-templates create europe-west4-template \
  --machine-type=e2-micro \
  --network=default \
  --subnet=default \
  --tags=http-server \
  --metadata=startup-script-url="$STARTUP_URL" \
  --quiet

gcloud compute instance-templates create us-east1-template \
  --machine-type=e2-micro \
  --network=default \
  --subnet=default \
  --tags=http-server \
  --metadata=startup-script-url="$STARTUP_URL" \
  --quiet

# ============================================================
# EUROPE MIG
# ============================================================

echo "Creating europe-west4-mig..."

gcloud compute instance-groups managed create europe-west4-mig \
  --region="$EU_REGION" \
  --zones="$EU_ZONES" \
  --template=europe-west4-template \
  --size=1 \
  --base-instance-name=europe-west4-mig \
  --quiet

gcloud compute instance-groups managed set-autoscaling europe-west4-mig \
  --region="$EU_REGION" \
  --min-num-replicas=1 \
  --max-num-replicas=2 \
  --target-cpu-utilization=0.80 \
  --cool-down-period=45 \
  --quiet

gcloud compute instance-groups managed set-named-ports europe-west4-mig \
  --region="$EU_REGION" \
  --named-ports=http:80 \
  --quiet

# ============================================================
# US MIG
# ============================================================

echo "Creating us-east1-mig..."

gcloud compute instance-groups managed create us-east1-mig \
  --region="$US_REGION" \
  --zones="$US_ZONES" \
  --template=us-east1-template \
  --size=1 \
  --base-instance-name=us-east1-mig \
  --quiet

gcloud compute instance-groups managed set-autoscaling us-east1-mig \
  --region="$US_REGION" \
  --min-num-replicas=1 \
  --max-num-replicas=2 \
  --target-cpu-utilization=0.80 \
  --cool-down-period=45 \
  --quiet

gcloud compute instance-groups managed set-named-ports us-east1-mig \
  --region="$US_REGION" \
  --named-ports=http:80 \
  --quiet

# ============================================================
# TASK 3
# HEALTH CHECK
#
# IMPORTANT:
# The lab explicitly requires TCP:80.
# ============================================================

echo "[3/5] Creating TCP health check..."

gcloud compute health-checks create tcp http-health-check \
  --port=80 \
  --check-interval=5s \
  --timeout=5s \
  --healthy-threshold=2 \
  --unhealthy-threshold=2 \
  --quiet

# ============================================================
# BACKEND SERVICE
# ============================================================

echo "Creating backend service..."

gcloud compute backend-services create http-backend \
  --global \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --protocol=HTTP \
  --port-name=http \
  --health-checks=http-health-check \
  --enable-logging \
  --logging-sample-rate=1.0 \
  --quiet

# Europe:
# RATE
# 50 RPS
# Capacity 100%

gcloud compute backend-services add-backend http-backend \
  --global \
  --instance-group=europe-west4-mig \
  --instance-group-region="$EU_REGION" \
  --balancing-mode=RATE \
  --max-rate-per-instance=50 \
  --capacity-scaler=1.0 \
  --quiet

# US:
# UTILIZATION
# 80%
# Capacity 100%

gcloud compute backend-services add-backend http-backend \
  --global \
  --instance-group=us-east1-mig \
  --instance-group-region="$US_REGION" \
  --balancing-mode=UTILIZATION \
  --max-utilization=0.80 \
  --capacity-scaler=1.0 \
  --quiet

# ============================================================
# URL MAP
# ============================================================

echo "Creating URL map..."

gcloud compute url-maps create http-lb \
  --default-service=http-backend \
  --quiet

# ============================================================
# TARGET HTTP PROXY
# ============================================================

echo "Creating target HTTP proxy..."

gcloud compute target-http-proxies create http-lb-http-proxy \
  --url-map=http-lb \
  --quiet

# ============================================================
# IPV4 FRONTEND
#
# Lab specifies:
# IPv4
# HTTP
# Ephemeral
# Port 80
# ============================================================

echo "Creating IPv4 frontend..."

gcloud compute forwarding-rules create http-lb-ipv4 \
  --global \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --network-tier=PREMIUM \
  --target-http-proxy=http-lb-http-proxy \
  --ports=80 \
  --quiet

# ============================================================
# IPV6 FRONTEND
#
# Lab specifies:
# IPv6
# HTTP
# Ephemeral
# Port 80
# ============================================================

echo "Creating IPv6 frontend..."

gcloud compute forwarding-rules create http-lb-ipv6 \
  --global \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --network-tier=PREMIUM \
  --target-http-proxy=http-lb-http-proxy \
  --ports=80 \
  --ip-version=IPV6 \
  --quiet

# ============================================================
# GET LOAD BALANCER IPS
# ============================================================

LB_IP_V4="$(
  gcloud compute forwarding-rules describe http-lb-ipv4 \
    --global \
    --format="value(IPAddress)"
)"

LB_IP_V6="$(
  gcloud compute forwarding-rules describe http-lb-ipv6 \
    --global \
    --format="value(IPAddress)"
)"

echo
echo "LB IPv4: $LB_IP_V4"
echo "LB IPv6: $LB_IP_V6"
echo

# ============================================================
# WAIT FOR LB TO ACTUALLY BECOME REACHABLE
#
# No arbitrary 180-second sleep.
# ============================================================

echo "Waiting for load balancer..."

LB_READY=0

for i in $(seq 1 60); do

  HTTP_CODE="$(
    curl \
      --connect-timeout 5 \
      --max-time 10 \
      -s \
      -o /dev/null \
      -w "%{http_code}" \
      "http://$LB_IP_V4" || true
  )"

  echo "Attempt $i/60 -> HTTP $HTTP_CODE"

  if [[ "$HTTP_CODE" == "200" ]]; then
    LB_READY=1
    break
  fi

  sleep 5
done

if [[ "$LB_READY" -ne 1 ]]; then
  echo "ERROR: Load balancer did not become ready."
  echo "Checking backend health..."
  gcloud compute backend-services get-health http-backend --global || true
  exit 1
fi

echo "Load balancer is ready."

# ============================================================
# TASK 4
# SIEGE VM
# ============================================================

echo "[4/5] Creating siege-vm..."

cat >/tmp/siege-startup.sh <<EOF
#!/bin/bash

set -e

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y install siege

LB_IP="$LB_IP_V4"

# Wait until LB responds.
until curl --connect-timeout 5 --max-time 10 -sf "http://\$LB_IP" >/dev/null; do
    sleep 5
done

echo "LB ready. Starting Siege."

# Required lab test:
# 150 concurrent users
# 120 seconds

nohup siege \
    -c 150 \
    -t120s \
    "http://\$LB_IP" \
    >/var/log/gsp215-siege.log 2>&1 < /dev/null &

echo \$! >/var/run/gsp215-siege.pid
EOF

gcloud compute instances create siege-vm \
  --zone="$SIEGE_ZONE" \
  --machine-type=e2-micro \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --metadata-from-file=startup-script=/tmp/siege-startup.sh \
  --quiet

SIEGE_IP="$(
  gcloud compute instances describe siege-vm \
    --zone="$SIEGE_ZONE" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
)"

echo "Siege VM IP: $SIEGE_IP"

# ============================================================
# WAIT FOR THE REQUIRED 120 SECOND TEST
#
# The test itself is 120 seconds, so this wait is intentional.
# It is NOT an arbitrary infrastructure wait.
# ============================================================

echo "Allowing the 120-second Siege test to complete..."

sleep 130

# ============================================================
# TASK 5
# CLOUD ARMOR
# ============================================================

echo "[5/5] Creating Cloud Armor policy..."

gcloud compute security-policies create denylist-siege \
  --description="Deny siege-vm traffic" \
  --quiet

gcloud compute security-policies rules create 1000 \
  --security-policy=denylist-siege \
  --src-ip-ranges="$SIEGE_IP/32" \
  --action=deny-403 \
  --description="Deny siege-vm" \
  --quiet

gcloud compute backend-services update http-backend \
  --global \
  --security-policy=denylist-siege \
  --quiet

# ============================================================
# VERIFY 403
# ============================================================

echo "Waiting for Cloud Armor propagation..."

ARMOR_READY=0

for i in $(seq 1 36); do

  HTTP_CODE="$(
    gcloud compute ssh siege-vm \
      --zone="$SIEGE_ZONE" \
      --quiet \
      --command="curl -s -o /dev/null -w '%{http_code}' http://$LB_IP_V4" \
      2>/dev/null || true
  )"

  echo "Cloud Armor check $i/36 -> HTTP $HTTP_CODE"

  if [[ "$HTTP_CODE" == "403" ]]; then
    ARMOR_READY=1
    break
  fi

  sleep 5
done

if [[ "$ARMOR_READY" -ne 1 ]]; then
  echo "WARNING: Cloud Armor did not return 403 within the check window."
  echo "The policy may still be propagating."
else
  echo "Cloud Armor verified: HTTP 403"
fi

echo
echo "=================================================="
echo "GSP215 SETUP COMPLETE"
echo "=================================================="
echo "LB IPv4 : $LB_IP_V4"
echo "LB IPv6 : $LB_IP_V6"
echo "Siege IP: $SIEGE_IP"
echo "Policy  : denylist-siege"
echo "Backend : http-backend"
echo "=================================================="
