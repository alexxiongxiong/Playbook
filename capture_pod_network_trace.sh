#!/bin/bash
#Date: 2024/12/11
#Author: Alex Xiong
#Function: Used to capture the network trace for k8s pod. Only support IP-based trace.
#Version: V 1.0

set -euo pipefail

# Check if the necessary tools are installed
which kubectl >/dev/null 2>&1 || { echo "kubectl is not installed. Please install it and rerun the script."; exit 1; }

# Get the Pod and namespace entered by the user
read -p "Please enter the name of the Pod for which you want to capture a network trace: " podName
read -p "Please enter the namespace where your pod is located: " namespace

#Verify that the Pod exists. If it does not exist, exit the script
kubectl get pod -n $namespace $podName 1>/dev/null || { echo "The Pod name or namespace you entered is incorrect. Exit the script."; exit; }

#Get the node name
nodeName=$(kubectl get pod -n $namespace $podName -o jsonpath='{.spec.nodeName}')


# Deploy a temporary Pod
echo -e "\nDeploying a temporary pod on node: $nodeName"

kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: login-${nodeName}
  namespace: kube-system
spec:
  containers:
  - command:
    - nsenter
    - --mount=/proc/1/ns/mnt
    - --
    - su
    - '-'
    image: mcr.microsoft.com/devcontainers/base:alpine-3.20
    imagePullPolicy: IfNotPresent
    name: alpine
    resources:
      requests:
        cpu: 100m
        memory: 200Mi
      limits:
        cpu: 100m
        memory: 200Mi
    securityContext:
      privileged: true
    stdin: true
    terminationMessagePath: /dev/termination-log
    terminationMessagePolicy: File
    tty: true
  enableServiceLinks: true
  hostNetwork: true
  hostPID: true
  nodeSelector:
    kubernetes.io/hostname: ${nodeName}
EOF

echo "The temporary Pod login-${nodeName} is being created in your kube-system namespace. Please wait 30 seconds for the Pod to be ready."

# Please wait 30 seconds for the Pod to be ready
kubectl wait --namespace kube-system --for=condition=Ready pod/login-${nodeName} --timeout=30s || { echo "Failed to deploy login pod. Exiting."; exit 1; }
echo -e "\n"

# Get tracking parameters
read -p "Please enter the IP you want to track (e.g., 169.254.169.254): " hostIP
read -p "How many seconds you would like to track: " secondsNumber

# Capturing network trace
echo -e "\nCapturing network trace for $secondsNumber seconds..."
kubectl exec -ti login-${nodeName} -n kube-system -- bash -c "
  rm /tmp/trace-${hostIP}.pcap &>/dev/null || true
  timeout ${secondsNumber}s tcpdump -i any host $hostIP -w /tmp/trace-${hostIP}.pcap -vvn || true
"

# download network trace file
echo -e "Capturing has been done. \nStart Downloading network trace file..."
kubectl cp "${namespace}/login-${nodeName}:/tmp/trace-${hostIP}.pcap" "./trace-${hostIP}.pcap" || { echo "Failed to download network trace file."; exit 1; }
echo -e "The network trace has been downloaded locally. The file path is $(pwd)/trace-${hostIP}.pcap\n"

# delete the temporary Pod
kubectl delete pod login-${nodeName} -n kube-system --ignore-not-found

echo -e "\nThe script has been successfully exectued. Please run \"ls -al $(pwd)/trace-${hostIP}.pcap\" to check the trace file locally." 

