#!/bin/bash
set -eu
which kubectl 1>/dev/null || { exit; echo "please install kubectl first"; }

echo "You have the following nodes on your AKS cluster:"
kubectl get node -o wide;

echo -e "\n";

read -p "please input your node name which you would like to login: " nodeName

# evaluate if the user's input is valid; if no, exit the script
echo $(kubectl get node -o jsonpath='{.items[*].metadata.name}') | grep -w $nodeName 1>/dev/null || { echo "You input an invalid AKS node name. Quit the script"; exit 1; }

# start to deploy previleged pod used to login worker node
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

# evaluate if the pod deployment is successful and wait for pods coming up
[ $? -eq 0 ] && echo -e "\nThe Pod login-${nodeName} is coming up! please wait for 10 seconds";
sleep 10;

# guide user to login AKS node via new-created pod
echo -e "\nThe Pod login-${nodeName} has been created in your kube-system namespace. \n\nplease run \"kubectl exec -ti login-${nodeName} -n kube-system -- bash\" to login worker node\n";
