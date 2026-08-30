#!/bin/bash
set -e

EU_REGION="europe-west4"
US_REGION="us-east1"
SIEGE_ZONE="us-west1-a"
STARTUP="gs://spls/gsp215/gcpnet/httplb/startup.sh"

# Firewall rules
gcloud compute firewall-rules create default-allow-http \
  --network=default \
  --target-tags=http-server \
  --source-ranges=0.0.0.0/0 \
  --allow=tcp:80 \
  --quiet 2>/dev/null || true

gcloud compute firewall-rules create default-allow-health-check \
  --network=default \
  --target-tags=http-server \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --allow=tcp \
  --quiet 2>/dev/null || true

# Instance templates
gcloud compute instance-templates create europe-west4-template \
  --machine-type=e2-micro \
  --network=default \
  --subnet=default \
  --tags=http-server \
  --metadata=startup-script-url="$STARTUP" \
  --quiet 2>/dev/null || true

gcloud compute instance-templates create us-east1-template \
  --machine-type=e2-micro \
  --network=default \
  --subnet=default \
  --tags=http-server \
  --metadata=startup-script-url="$STARTUP" \
  --quiet 2>/dev/null || true

# Europe MIG
gcloud compute instance-groups managed create europe-west4-mig \
  --region="$EU_REGION" \
  --template=europe-west4-template \
  --size=1 \
  --zones=europe-west4-a,europe-west4-b \
  --base-instance-name=europe-west4-mig \
  --quiet 2>/dev/null || true

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

# US MIG
gcloud compute instance-groups managed create us-east1-mig \
  --region="$US_REGION" \
  --template=us-east1-template \
  --size=1 \
  --zones=us-east1-b,us-east1-c \
  --base-instance-name=us-east1-mig \
  --quiet 2>/dev/null || true

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

# Health check
gcloud compute health-checks create http http-health-check \
  --port=80 \
  --request-path=/ \
  --check-interval=5s \
  --timeout=5s \
  --healthy-threshold=2 \
  --unhealthy-threshold=2 \
  --quiet 2>/dev/null || true

# Backend service
gcloud compute backend-services create http-backend \
  --global \
  --protocol=HTTP \
  --port-name=http \
  --health-checks=http-health-check \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --enable-logging \
  --logging-sample-rate=1 \
  --quiet 2>/dev/null || true

gcloud compute backend-services add-backend http-backend \
  --global \
  --instance-group=europe-west4-mig \
  --instance-group-region="$EU_REGION" \
  --balancing-mode=RATE \
  --max-rate-per-instance=50 \
  --capacity-scaler=1 \
  --quiet 2>/dev/null || true

gcloud compute backend-services add-backend http-backend \
  --global \
  --instance-group=us-east1-mig \
  --instance-group-region="$US_REGION" \
  --balancing-mode=UTILIZATION \
  --max-utilization=0.8 \
  --capacity-scaler=1 \
  --quiet 2>/dev/null || true

# URL map + proxy
gcloud compute url-maps create http-lb \
  --default-service=http-backend \
  --quiet 2>/dev/null || true

gcloud compute target-http-proxies create http-lb-http-proxy \
  --url-map=http-lb \
  --quiet 2>/dev/null || true

# IPv4 frontend
gcloud compute forwarding-rules create http-lb-ipv4 \
  --global \
  --target-http-proxy=http-lb-http-proxy \
  --ports=80 \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --quiet 2>/dev/null || true

# IPv6 frontend
gcloud compute addresses create http-lb-ipv6 \
  --global \
  --ip-version=IPV6 \
  --quiet 2>/dev/null || true

gcloud compute forwarding-rules create http-lb-ipv6 \
  --global \
  --target-http-proxy=http-lb-http-proxy \
  --ports=80 \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --address=http-lb-ipv6 \
  --quiet 2>/dev/null || true

LB_IP=$(gcloud compute forwarding-rules describe http-lb-ipv4 \
  --global \
  --format='value(IPAddress)')

LB_IP6=$(gcloud compute forwarding-rules describe http-lb-ipv6 \
  --global \
  --format='value(IPAddress)')

echo "LB IPv4: $LB_IP"
echo "LB IPv6: $LB_IP6"

# Siege VM startup script
cat > /tmp/siege-startup.sh <<EOF
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y siege

LB="$LB_IP"

until curl -sf --max-time 5 "http://\$LB" >/dev/null; do
  sleep 5
done

nohup siege -c 150 -t120s "http://\$LB" \
  >/var/log/gsp215-siege.log 2>&1 < /dev/null &
EOF

# Siege VM
gcloud compute instances create siege-vm \
  --zone="$SIEGE_ZONE" \
  --machine-type=e2-micro \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --metadata-from-file=startup-script=/tmp/siege-startup.sh \
  --quiet 2>/dev/null || true

SIEGE_IP=$(gcloud compute instances describe siege-vm \
  --zone="$SIEGE_ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')

echo "Siege IP: $SIEGE_IP"

# Wait for the stress test to finish without opening an interactive SSH session
while true; do
  STATUS=$(gcloud compute ssh siege-vm \
    --zone="$SIEGE_ZONE" \
    --quiet \
    --command='pgrep -x siege >/dev/null && echo RUNNING || echo DONE' \
    2>/dev/null || echo RUNNING)

  [ "$STATUS" = "DONE" ] && break
  sleep 5
done

# Cloud Armor
gcloud compute security-policies create denylist-siege \
  --description="Deny siege-vm traffic" \
  --quiet 2>/dev/null || true

gcloud compute security-policies rules create 1000 \
  --security-policy=denylist-siege \
  --src-ip-ranges="$SIEGE_IP/32" \
  --action=deny-403 \
  --description="Deny siege-vm" \
  --quiet 2>/dev/null || true

gcloud compute backend-services update http-backend \
  --global \
  --security-policy=denylist-siege \
  --quiet

# Verify 403
for i in $(seq 1 36); do
  CODE=$(gcloud compute ssh siege-vm \
    --zone="$SIEGE_ZONE" \
    --quiet \
    --command="curl -s -o /dev/null -w '%{http_code}' http://$LB_IP" \
    2>/dev/null || true)

  if [ "$CODE" = "403" ]; then
    echo "Cloud Armor verified: HTTP 403"
    break
  fi

  sleep 5
done

echo "======================================"
echo "GSP215 COMPLETE"
echo "LB IPv4 : $LB_IP"
echo "LB IPv6 : $LB_IP6"
echo "Siege IP: $SIEGE_IP"
echo "======================================"
