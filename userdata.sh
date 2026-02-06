#!/bin/bash
set -euxo pipefail

# Log everything to a file for debugging
exec > >(tee /var/log/userdata.log) 2>&1
echo "=== UserData script started at $(date) ==="

export DEBIAN_FRONTEND=noninteractive
export AWS_REGION="${aws_region}"
export ECR_URL="${ecr_url}"
export ECR_REPO="${ecr_repo}"
export IMAGE_TAG="${image_tag}"
export ACCOUNT_ID="${account_id}"
export ECR_REPO_NAME="${ecr_repo_name}"

# -------------------------------------------------------
# 1. System Preparation
# -------------------------------------------------------
echo "=== Updating system packages ==="
apt-get update -y
apt-get upgrade -y
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    unzip \
    git \
    jq \
    socat \
    conntrack

# -------------------------------------------------------
# 2. Install AWS CLI v2
# -------------------------------------------------------
echo "=== Installing AWS CLI v2 ==="
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
cd /tmp && unzip -o awscliv2.zip
./aws/install --update
aws --version

# -------------------------------------------------------
# 3. Disable swap (required for Kubernetes)
# -------------------------------------------------------
echo "=== Disabling swap ==="
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# -------------------------------------------------------
# 4. Load kernel modules & configure sysctl
# -------------------------------------------------------
echo "=== Configuring kernel modules and sysctl ==="
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# -------------------------------------------------------
# 5. Install containerd
# -------------------------------------------------------
echo "=== Installing containerd ==="

# Add Docker's official GPG key and repo (for containerd)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y containerd.io docker-ce docker-ce-cli

# Configure containerd to use systemd cgroup driver
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

# Enable and start Docker (needed for building images)
systemctl enable docker
systemctl start docker

# -------------------------------------------------------
# 6. Install Kubernetes (kubeadm, kubelet, kubectl)
# -------------------------------------------------------
echo "=== Installing Kubernetes components ==="

# Add Kubernetes apt repo (v1.29)
KUBE_VERSION="1.29"
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v$${KUBE_VERSION}/deb/Release.key" | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v$${KUBE_VERSION}/deb/ /" | \
    tee /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

# -------------------------------------------------------
# 7. Initialize Kubernetes cluster (single-node)
# -------------------------------------------------------
echo "=== Initializing Kubernetes cluster ==="

PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "")

kubeadm init \
    --pod-network-cidr=10.244.0.0/16 \
    --apiserver-advertise-address="$PRIVATE_IP" \
    --apiserver-cert-extra-sans="$PRIVATE_IP,$PUBLIC_IP" \
    --node-name="$(hostname)"

# Configure kubectl for root user
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config
export KUBECONFIG=/root/.kube/config

# Configure kubectl for ubuntu user
mkdir -p /home/ubuntu/.kube
cp -f /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown ubuntu:ubuntu /home/ubuntu/.kube/config

# -------------------------------------------------------
# 8. Install Flannel CNI
# -------------------------------------------------------
echo "=== Installing Flannel CNI ==="
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# -------------------------------------------------------
# 9. Remove control-plane taint (single-node cluster)
# -------------------------------------------------------
echo "=== Removing control-plane taint for single-node scheduling ==="
sleep 10
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

# Wait for node to be ready
echo "=== Waiting for node to be Ready ==="
for i in $(seq 1 60); do
    NODE_STATUS=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [ "$NODE_STATUS" = "True" ]; then
        echo "Node is Ready!"
        break
    fi
    echo "Waiting for node... ($i/60)"
    sleep 10
done

kubectl get nodes -o wide

# -------------------------------------------------------
# 10. Authenticate to ECR
# -------------------------------------------------------
echo "=== Authenticating to ECR ==="

# Login Docker to ECR
aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ECR_URL"

# -------------------------------------------------------
# 11. Clone repo, build Docker image, push to ECR
# -------------------------------------------------------
echo "=== Cloning Spring App repository ==="
cd /tmp
git clone https://github.com/tlh2857-2024/springapp.git
cd springapp

# Check if Dockerfile exists; if not create one
if [ ! -f Dockerfile ]; then
    echo "=== Creating Dockerfile for Spring Boot app ==="
    cat <<'DOCKERFILE' > Dockerfile
FROM maven:3.9-eclipse-temurin:17 AS build
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn clean package -DskipTests

FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
DOCKERFILE
fi

echo "=== Building Docker image ==="
docker build -t "$ECR_REPO_NAME:$IMAGE_TAG" .

echo "=== Tagging and pushing image to ECR ==="
docker tag "$ECR_REPO_NAME:$IMAGE_TAG" "$ECR_REPO:$IMAGE_TAG"
docker push "$ECR_REPO:$IMAGE_TAG"

# -------------------------------------------------------
# 12. Create ECR pull secret in Kubernetes
# -------------------------------------------------------
echo "=== Creating ECR pull secret in Kubernetes ==="

ECR_TOKEN=$(aws ecr get-login-password --region "$AWS_REGION")

kubectl create secret docker-registry ecr-secret \
    --docker-server="$ECR_URL" \
    --docker-username=AWS \
    --docker-password="$ECR_TOKEN" \
    --namespace=default || true

# -------------------------------------------------------
# 13. Create ECR credential refresh CronJob
# -------------------------------------------------------
echo "=== Setting up ECR credential refresh cron ==="
cat <<'CRONSCRIPT' > /usr/local/bin/refresh-ecr-token.sh
#!/bin/bash
export KUBECONFIG=/root/.kube/config
export AWS_REGION="${aws_region}"
ECR_URL="${ecr_url}"

ECR_TOKEN=$(aws ecr get-login-password --region "$AWS_REGION")

kubectl delete secret ecr-secret --namespace=default --ignore-not-found
kubectl create secret docker-registry ecr-secret \
    --docker-server="$ECR_URL" \
    --docker-username=AWS \
    --docker-password="$ECR_TOKEN" \
    --namespace=default

# Also refresh docker login
echo "$ECR_TOKEN" | docker login --username AWS --password-stdin "$ECR_URL"
CRONSCRIPT

chmod +x /usr/local/bin/refresh-ecr-token.sh

# ECR tokens expire every 12 hours; refresh every 10 hours
(crontab -l 2>/dev/null; echo "0 */10 * * * /usr/local/bin/refresh-ecr-token.sh >> /var/log/ecr-refresh.log 2>&1") | crontab -

# -------------------------------------------------------
# 14. Deploy Spring App using springapp.yaml (or generate)
# -------------------------------------------------------
echo "=== Deploying Spring Application ==="

# Check if springapp.yaml exists in the repo
if [ -f /tmp/springapp/springapp.yaml ]; then
    echo "=== Found springapp.yaml in repo - updating image reference ==="
    # Replace image placeholder with actual ECR image
    sed -i "s|image:.*|image: $ECR_REPO:$IMAGE_TAG|g" /tmp/springapp/springapp.yaml
    # Add imagePullSecrets if not present
    if ! grep -q "imagePullSecrets" /tmp/springapp/springapp.yaml; then
        sed -i '/containers:/i\      imagePullSecrets:\n      - name: ecr-secret' /tmp/springapp/springapp.yaml
    fi
    cp /tmp/springapp/springapp.yaml /root/springapp.yaml
else
    echo "=== springapp.yaml not found in repo - generating deployment manifest ==="
    cat <<APPYAML > /root/springapp.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: springapp
  labels:
    app: springapp
spec:
  replicas: 2
  selector:
    matchLabels:
      app: springapp
  template:
    metadata:
      labels:
        app: springapp
    spec:
      imagePullSecrets:
      - name: ecr-secret
      containers:
      - name: springapp
        image: $ECR_REPO:$IMAGE_TAG
        ports:
        - containerPort: 8080
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        readinessProbe:
          httpGet:
            path: /actuator/health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /actuator/health
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 15
---
apiVersion: v1
kind: Service
metadata:
  name: springapp-service
spec:
  type: NodePort
  selector:
    app: springapp
  ports:
  - protocol: TCP
    port: 80
    targetPort: 8080
    nodePort: 30080
APPYAML
fi

kubectl apply -f /root/springapp.yaml

# -------------------------------------------------------
# 15. Wait for deployment to roll out
# -------------------------------------------------------
echo "=== Waiting for Spring App deployment ==="
kubectl rollout status deployment/springapp --timeout=300s || true

echo "=== Deployment Status ==="
kubectl get deployments -o wide
kubectl get pods -o wide
kubectl get services -o wide

echo "=== UserData script completed at $(date) ==="
echo "=== Spring App should be accessible at http://<PUBLIC_IP>:30080 ==="
