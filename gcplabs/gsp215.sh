#!/bin/bash
set -euo pipefail

# ============================================================
# GSP215 - Set Up and Configure a Global External Application
# Load Balancer with Cloud Armor
# ============================================================

EU_REGION="europe-west4"
US_REGION="us-east1"
SIEGE_REGION="us-west1"
SIEGE_ZONE="us-west1-a"

EU_SUBNET="regions/europe-west4/subnetworks/default"
US_SUBNET="regions/us-east1/subnetworks/default"

STARTUP_URL="gs://spls/gsp215/gcpnet/httplb/startup.sh"

echo "=================================================="
echo "GSP215"
echo "Project: $(gcloud config get-value project)"
echo "=================================================="

# ============================================================
# TASK 1 - FIREWALL RULES
# ============================================================

echo "[1/5] Firewall rules"

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
# TASK 2 - INSTANCE TEMPLATES
# ============================================================

echo "[2/5] Instance templates"

gcloud compute instance-templates create europe-west4-template \
  --machine-type=e2-micro \
  --network=default \
  --subnet="$EU_SUBNET" \
  --tags=http-server \
  --metadata=startup-script-url="$STARTUP_URL" \
  --quiet

gcloud compute instance-templates create us-east1-template \
  --machine-type=e2-micro \
  --network=default \
  --subnet="$US_SUBNET" \
  --tags=http-server \
  --metadata=startup-script-url="$STARTUP_URL" \
  --quiet

# ============================================================
# EUROPE REGIONAL MIG
# ============================================================

echo "Creating europe-west4-mig"

gcloud compute instance-groups managed create europe-west4-mig \
  --region="$EU_REGION" \
  --zones=europe-west4-a,europe-west4-b \
  --template=europe-west4-template \
  --size=1 \
  --base-instance-name=europe-west4-mig \
  --quiet

gcloud compute instance-groups managed set-named-ports europe-west4-mig \
  --region="$EU_REGION" \
  --named-ports=http:80 \
  --quiet

gcloud compute instance-groups managed set-autoscaling europe-west4-mig \
  --region="$EU_REGION" \
  --min-num-replicas=1 \
  --max-num-replicas=2 \
  --target-cpu-utilization=0.80 \
  --cool-down-period=45 \
  --quiet

# ============================================================
# US REGIONAL MIG
# ============================================================

echo "Creating us-east1-mig"

gcloud compute instance-groups managed create us-east1-mig \
  --region="$US_REGION" \
  --zones=us-east1-b,us-east1-c \
  --template=us-east1-template \
  --size=1 \
  --base-instance-name=us-east1-mig \
  --quiet

gcloud compute instance-groups managed set-named-ports us-east1-mig \
  --region="$US_REGION" \
  --named-ports=http:80 \
  --quiet

gcloud compute instance-groups managed set-autoscaling us-east1-mig \
  --region="$US_REGION" \
  --min-num-replicas=1 \
  --max-num-replicas=2 \
  --target-cpu-utilization=0.80 \
  --cool-down-period=45 \
  --quiet

# ============================================================
# TASK 3 - TCP HEALTH CHECK
# ============================================================

echo "[3/5] TCP health check"

gcloud compute health-checks create tcp http-health-check \
  --port=80 \
  --check-interval=5s \
  --timeout=5s \
  --healthy-threshold=2 \
  --unhealthy-threshold=2 \
  --quiet

# ============================================================
# GLOBAL BACKEND SERVICE
# ============================================================

echo "Creating backend service"

gcloud compute backend-services create http-backend \
  --global \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --protocol=HTTP \
  --port-name=http \
  --health-checks=http-health-check \
  --enable-logging \
  --logging-sample-rate=1.0 \
  --quiet

# Europe - RATE / 50 RPS

gcloud compute backend-services add-backend http-backend \
  --global \
  --instance-group=europe-west4-mig \
  --instance-group-region="$EU_REGION" \
  --balancing-mode=RATE \
  --max-rate-per-instance=50 \
  --capacity-scaler=1.0 \
  --quiet

# US - UTILIZATION / 80%

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

echo "Creating URL map"

gcloud compute url-maps create http-lb \
  --default-service=http-backend \
  --quiet

# ============================================================
# TARGET HTTP PROXY
# ============================================================

gcloud compute target-http-proxies create http-lb-http-proxy \
  --url-map=http-lb \
  --quiet

# ============================================================
# IPV4 FORWARDING RULE
# ============================================================

echo "Creating IPv4 frontend"

gcloud compute forwarding-rules create http-lb-ipv4 \
  --global \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --network-tier=PREMIUM \
  --target-http-proxy=http-lb-http-proxy \
  --ports=80 \
  --quiet

# ============================================================
# IPV6 FORWARDING RULE
# ============================================================

echo "Creating IPv6 frontend"

gcloud compute forwarding-rules create http-lb-ipv6 \
  --global \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --network-tier=PREMIUM \
  --target-http-proxy=http-lb-http-proxy \
  --ports=80 \
  --ip-version=IPV6 \
  --quiet

LB_IP=$(gcloud compute forwarding-rules describe http-lb-ipv4 \
  --global \
  --format="value(IPAddress)")

LB_IP6=$(gcloud compute forwarding-rules describe http-lb-ipv6 \
  --global \
  --format="value(IPAddress)")

echo
echo "IPv4: $LB_IP"
echo "IPv6: $LB_IP6"
echo

# ============================================================
# WAIT FOR BACKENDS TO BECOME HEALTHY
# ============================================================

echo "Waiting for healthy backends..."

for i in $(seq 1 60); do

  HEALTH="$(
    gcloud compute backend-services get-health http-backend \
      --global \
      --format="value(status.healthStatus[].healthState)" \
      2>/dev/null || true
  )"

  if echo "$HEALTH" | grep -q "HEALTHY"; then
    echo "Backend is healthy."
    break
  fi

  echo "Backend not healthy yet ($i/60)"
  sleep 5
done

# ============================================================
# TASK 4 - SIEGE VM
# ============================================================

echo "[4/5] Creating siege-vm"

cat > /tmp/siege-startup.sh <<EOF
#!/bin/bash

set -e

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y siege

LB_IP="$LB_IP"

echo "Waiting for load balancer..."

until curl -sSf --connect-timeout 5 --max-time 10 \
  "http://\$LB_IP" >/dev/null; do
  sleep 5
done

echo "Starting Siege against \$LB_IP"

nohup siege \
  -c 150 \
  -t120s \
  "http://\$LB_IP" \
  > /var/log/gsp215-siege.log 2>&1 < /dev/null &

echo \$! > /var/run/gsp215-siege.pid
EOF

gcloud compute instances create siege-vm \
  --zone="$SIEGE_ZONE" \
  --machine-type=e2-micro \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --metadata-from-file=startup-script=/tmp/siege-startup.sh \
  --quiet

SIEGE_IP=$(
  gcloud compute instances describe siege-vm \
    --zone="$SIEGE_ZONE" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
)

echo "Siege VM IP: $SIEGE_IP"

# ============================================================
# WAIT FOR SIEGE TEST
# ============================================================

echo "Waiting for Siege test to finish..."

sleep 140

# ============================================================
# TASK 5 - CLOUD ARMOR
# ============================================================

echo "[5/5] Cloud Armor"

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

echo "Verifying Cloud Armor..."

for i in $(seq 1 36); do

  CODE=$(
    gcloud compute ssh siege-vm \
      --zone="$SIEGE_ZONE" \
      --quiet \
      --command="curl -s -o /dev/null -w '%{http_code}' http://$LB_IP" \
      2>/dev/null || true
  )

  echo "Attempt $i/36 -> HTTP $CODE"

  if [ "$CODE" = "403" ]; then
    echo "Cloud Armor verified."
    break
  fi

  sleep 5
done

echo
echo "=================================================="
echo "GSP215 COMPLETE"
echo "=================================================="
echo "Load Balancer IPv4 : $LB_IP"
echo "Load Balancer IPv6 : $LB_IP6"
echo "Siege VM IP        : $SIEGE_IP"
echo "Cloud Armor        : denylist-siege"
echo "=================================================="
