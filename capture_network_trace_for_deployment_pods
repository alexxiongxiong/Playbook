#!/bin/bash
set -euo pipefail

ValidateSoftwareInstallation(){
  #Validate the required softwares have been installed on the user terminal
  which kubectl > /dev/null || { echo "kubectl was not installed on your terminal. Quitting the script."; exit 1; }
}


GetUserInput(){
  read -p "Please enter the name of the deployment for which you want to capture network traces: " PODNAME
  kubectl get pod -A -o wide| grep ${PODNAME} >/dev/null || { echo "Error: None of the pod names match your input. Please re-verify the deployment name you entered"; exit 1; }
  read -p "Please enter the IP which you want to trace: " HOST_IP
}

LabelNode(){
  NODELIST=$(kubectl get pod -A -o wide| grep ${PODNAME} | awk -F " " '{print $8}' |uniq)
  for NODE in $NODELIST; do
    kubectl label node ${NODE} capturenetworktracefortest=true;
  done
}

UnLableNode(){
  ALLK8sNODES=$(kubectl get node -o name)
  for K8SNODE in $ALLK8sNODES; do
    kubectl label ${K8SNODE} capturenetworktracefortest- &>/dev/null || true
  done
}

DeployPVC(){
  cat << EOF | kubectl apply -f -
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: network-capture-tcpdump-pvc
    namespace: kube-system
  spec:
    accessModes:
      - ReadWriteMany
    storageClassName: azurefile-csi
    resources:
      requests:
        storage: 100Gi
EOF
}


DeployDaemonset(){
  kubectl apply -f - << EOF
  apiVersion: apps/v1
  kind: DaemonSet
  metadata:
    name: network-capture-tcpdump
    namespace: kube-system
    labels:
      app: network-capture-tcpdump
  spec:
    selector:
      matchLabels:
        app: network-capture-tcpdump
    template:
      metadata:
        labels:
          app: network-capture-tcpdump
      spec:
        nodeSelector:
          capturenetworktracefortest: "true"
        containers:
        - name: network-capture-tcpdump
          image: 'ubuntu:latest'
          command:
          - bash
          - -c
          - |
            apt-get update && apt-get install -y tcpdump;
            tcpdump -C 100 -W 20 -G 1800 -i any host ${HOST_IP} -w /mnt/tcpdump/\$(hostname)"_"$(date -u +%Y-%m-%dT%H_%M).pcap;
          volumeMounts:
          - name: volume
            mountPath: /mnt/tcpdump
        hostNetwork: true
        hostPID: true
        hostIPC: true
        volumes:
        - name: volume
          persistentVolumeClaim:
            claimName: network-capture-tcpdump-pvc
EOF
}

ShowCapturingInfo(){
  PV_NAME=$(kubectl get  pvc -n kube-system | grep network-capture-tcpdump-pvc | awk -F " " '{print $3}')
  STORAGEACCOUNT_NAME=$(kubectl describe pv ${PV_NAME}| grep VolumeHandle | awk -F "#" '{print $2}' )
  echo "Now is $(date)."
  echo "Note: The capture is ongoing and the dump files are currently stored in storage account ${STORAGEACCOUNT_NAME} and the specific share name is $PV_NAME. Please go ahead to reproduce the issue."
}

ShowCapturedInfo(){
  PV_NAME=$(kubectl get  pvc -n kube-system | grep network-capture-tcpdump-pvc | awk -F " " '{print $3}')
  STORAGEACCOUNT_NAME=$(kubectl describe pv ${PV_NAME}| grep VolumeHandle | awk -F "#" '{print $2}' )
  echo "Note: The capturing has been stopped. Now is $(date)."
  echo "The dump files has been stored in storage account ${STORAGEACCOUNT_NAME} and the specific share name is $PV_NAME. Please go ahead to check them on Azure Portal."
}

echo "This script can be used to help you capture a network trace of the AKS node where your application is running. Below are the options for it to work."
echo "1. Capture the network trace."
echo "2. Stop the capturing."
echo "3. Quit the script."

read -p "Please enter the number of the operation you want to perform. " NUMBER

case $NUMBER in 
1)
  ValidateSoftwareInstallation
  GetUserInput
  LabelNode
  DeployPVC
  DeployDaemonset
  sleep 5
  ShowCapturingInfo
  ;;
2)
  ValidateSoftwareInstallation
  UnLableNode
  kubectl delete daemonset network-capture-tcpdump -n kube-system
  ShowCapturedInfo  
  ;;
3)
  echo "You choose to quit the script. Exiting now."
  exit 0
  ;;
*)
  echo "You input is invalid. Please enter 1 or 2 or 3 to continue the script."
  ;;
esac
