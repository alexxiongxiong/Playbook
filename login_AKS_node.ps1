# Check if kubectl is installed
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "Please install kubectl first"
    exit
}

# Display the AKS cluster nodes
Write-Host "You have the following nodes on your AKS cluster:"
kubectl get node -o wide
Write-Host "`n"

# Prompt the user to input the node name
$nodeName = Read-Host "Please input the name of the node you would like to log in to"

# Validate the user's input
$nodeList = kubectl get node -o jsonpath='{.items[*].metadata.name}'
if ($nodeList -notmatch "\b$nodeName\b") {
    Write-Host "You input an invalid AKS node name. Quitting the script."
    exit 1
}

# Deploy a privileged pod to log in to the worker node
$podYaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: login-$nodeName
  namespace: default
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
    kubernetes.io/hostname: $nodeName
"@

$podYaml | kubectl apply -f -
if ($LASTEXITCODE -eq 0) {
    Write-Host "`nThe Pod login-$nodeName is coming up! Please wait for 10 seconds."
    Start-Sleep -Seconds 10
} else {
    Write-Host "Failed to create the Pod. Exiting."
    exit 1
}

# Guide the user to log in to the AKS node
Write-Host "`nThe Pod login-$nodeName has been created in your default namespace."
Write-Host "`nPlease run the following command to log in to the worker node:"
Write-Host "kubectl exec -ti login-$nodeName -n default -- bash"
