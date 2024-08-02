# Intrusion detection in Kubernetes - A study of tools and techniques
This repository demonstrates how a Proof of Concept of the applications demonstrated in Lukas Neuenschwander's master's thesis "Intrusion Detecion in Kubernetes - a study of tools and techniques" can be installed on an x86-based Ubuntu Linux server that can be a virtual machine. Most of the commands can be applied on other server operating systems or Kubernetes distributions as well. The thesis document can be found in this repository at [`./Lukas Neuenschwander MSc. Intrusion Detection in Kubernetes - A study of tools and techniques.pdf`](Lukas%20Neuenschwander%20MSc.%20Intrusion%20Detection%20in%20Kubernetes%20-%20A%20study%20of%20tools%20and%20techniques.pdf). 

## 1. Install and configure the microk8s cluster
Start on a Ubuntu 24.04 LTS machine, 22.04 will also work. If you have only one node, it should have at least 16 GB of RAM to properly work - on 3 nodes 8 GB of RAM on each node will suffice.

The following commands install microk8s, kubectl, Helm and k9s and configure the kubeconfig for these commands to correctly access it

```bash
sudo snap install microk8s --classic # Install microk8s snap
sudo usermod -aG microk8s $USER # add current user to the microk8s group to be able to run microk8s commands without using sudo
newgrp microk8s
mkdir -p ~/.kube; microk8s config > ~/.kube/config # put the microk8s kubeconfig into the default location for access from e.g. kubectl or k9s
chmod 700 ~/.kube/config # ensure the kubernetes config is not group or other readable
microk8s enable metrics-server # enable metrics server for k9s, grafana or whatever application that is accessing metrics like CPU and RAM consumption
microk8s enable hostpath-storage # this is required for elasticsearch and many other apps requiring persistent storage
```

### 1. a) configure microk8s k8s certificate for other IPs (optional)
The following commands are optional in case you need to access your cluster through a loadbalancer or floating IP. A different root certificate can be configured in a similar way.

```bash
sudo vim /var/snap/microk8s/current/certs/csr.conf.template # add any additional IPs you may want to access your cluster from like loadbalancers or floating IPs for your server here after #MOREIPS as IP.3 = ..., IP.4 = ... etc.
sudo microk8s refresh-certs --cert server.crt
microk8s stop; microk8s start
mkdir -p ~/.kube; microk8s config > ~/.kube/config # put the microk8s kubeconfig into the default location for access from e.g. kubectl or k9s
chmod 700 ~/.kube/config # ensure the kubernetes config is not group or other readable
```

### 1 b) make the cluster accessible from another machine (optional)
You can also remote control your cluster from another machine where kubectl, Helm etc. are installed. Just follow the same commands as indicated in the last part of [Step 1](#1-install-and-configure-the-microk8s-cluster) to install them. Make sure to run [Step 1a)](#1-a-configure-microk8s-k8s-certificate-for-other-ips-optional) if the node is accessed through a load balancer, floating IP or other IP. Then run the following commands on the machine you would like to remote control the cluster from. 
```bash
mkdir ~.kube
scp <IP of your microk8s node>:.kube/config ~/.kube/config # If you already have other kubeconfigs, make sure to merge them with this new config instead of overwriting them with this command
```

## 2 Make the container runtime containerd available for falco and other apps
As microk8s is installed as a snap that is deployed in a sandbox, it uses its own version of the container runtime containerd. This means that containerd is not available in the default linux location `/run/containerd/containerd.sock` where apps like falco look for it.

> **_NOTE:_** Make sure the following commands are run on *all* the cluster nodes.

```bash
sudo tee -a /etc/fstab <<EOF
/var/snap/microk8s/common/run /run/containerd none nofail,defaults,bind 0 0
EOF
sudo systemctl daemon-reload # load updated /etc/fstab
sudo mount -a # this command should not throw any error
```

> **_NOTE:_** If for some reason you do not want to run these commands that practically replace `/run/containerd` with `/var/snap/microk8s/common/run/`, there is a script called `patch-microk8s-containerd-socket.sh` in the falco folder that fixes the socket path specifically for falco. However it must be run every time after upgrading or falco with helm or change its configuration using Helm, so this approach is safer.


## 3. Clone this repo, run all future commands from the root of this repo
```bash
git clone https://github.com/fjellvannet/intrusion-detection-in-kubernetes.git
cd intrusion-detection-in-kubernetes
```
> **_NOTE:_** After this command, all the following commands must be run from the root of the cloned repo. Also, the commands from now on only need to be run once, either on a development machine or on the first microk8s node. As they are applied to Kubernetes it is not necessary to repeat them for each node.

## 4. Install and configure kubectl, Helm and k9s
These commands install kubectl, k9s and Helm. You can run them either directly on the Ubuntu machine you just installed microk8s on, or on another machine that has access to the Ubuntu node that was configured in [Step 1b)](#1-b-make-the-cluster-accessible-from-another-machine-optional).
```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" # download kubectl, see https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
sudo install kubectl /usr/local/bin; rm kubectl # install kubectl binary to /usr/local/bin and remove the downloded kubectl file from this folder
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash # install the latest Helm release into /usr/local/bin
# download the newest k9s .deb-package from GitHub, if this command does not work find the k9s_linux_amd64.deb from https://github.com/derailed/k9s/releases/latest
wget "https://github.com/derailed/k9s/releases/download/$(wget -O- https://github.com/derailed/k9s/releases/latest | grep 'Release v' | head -1 | grep -oE 'v([0-9]+\.){2}[0-9]+')/k9s_linux_amd64.deb"
sudo apt install ./k9s_linux_amd64.deb; rm k9s_linux_amd64.deb # install k9s
```
### 4 a) Add log-ultimate plug-in to k9s (optional)
These commands show how the log-ultimate plug-in can be added to k9s. It requires stern and jq to be installed, so they are deployed first.
```bash
wget "https://github.com/stern/stern/releases/download/$(wget -O- https://github.com/stern/stern/releases/latest | grep 'Release v' | head -1 | grep -oE 'v([0-9]+\.){2}[0-9]+')/stern_$(wget -O- https://github.com/stern/stern/releases/latest | grep 'Release v' | head -1 | grep -oE '([0-9]+\.){2}[0-9]+')_linux_amd64.tar.gz" # download the newest version of stern
tar -xaf stern_*_linux_amd64.tar.gz stern # extract stern from the tar
sudo install stern /usr/local/bin; rm stern stern_*_linux_amd64.tar.gz # install stern and remove the binaries from here
sudo apt install jq # install jq
cp k9s/log-ultimate.yaml ~/.config/k9s/plugins.yaml # copy the plugin in to k9s's default plugin location
```

### 4 b) Configure Cilium as a network driver (optional)
The following commands removes the default Calico network driver from your microk8s-cluster and replaces it with [Cilium](https://cilium.io/) in which you can configure [Hubble](https://docs.cilium.io/en/stable/overview/intro/). These commands are optional - feel free to keep Calico if you want :)

> **_NOTE:_** If your cluster is already running, you should be very careful with this step, as it can render your cluster unusable if it fails.

```bash
microk8s enable community # enable community addons - required for cilium addon
# you probably need to run this command - for me it was always necessary - to be able to enable community addons, thereafter rerun microk8s enable community
git config --global --add safe.directory /snap/microk8s/current/addons/community/.git # this command is not always necessary to run - check if microk8s enable community requires it. If it does not, you do not need to run it
microk8s enable cilium # enable cilium addon
sudo microk8s cilium hubble enable --ui # enable hubble with its ui
microk8s cilium config set hubble-export-file-path /var/run/cilium/hubble/events.log # make sure hubble saves its network logs in this location
```

### 4 c) Add more nodes to your cluster (optional)
> **_NOTE:_** If you would like to use Cilium, make sure to run all the commands in [step 3a](#4-b-configure-cilium-as-a-network-driver-optional) on *all* the nodes *BEFORE* adding them to the cluster and running these steps.

For each node you would like to add to the cluster, run
```bash
microk8s add-node # on the primary node
# It displays a command to be run on the new node that is to be added, starting with microk8s join...
```

## 5. Configure microk8s for audit-logs
These commands prepare microk8s to export its audit logs.

```bash
sudo -s
cp falco/kube-api-audit-policy-all.yaml /var/snap/microk8s/current/args # copy the policy file that defines which audit logs are active - here all are activated
cp falco/falco-kube-apiserver-audit-webhook.yaml /var/snap/microk8s/current/args # configure the falco webhook for auditlogs
cat falco/kube-apiserver-extra-args.txt >> /var/snap/microk8s/current/args/kube-apiserver # append the additional args required to export audit logs
exit # go out of sudo -s
microk8s stop; microk8s start # microk8s should start again without errors. If it does not, try to figure out how to fix these errors
```

## 6. Install Falco
In the current configuration, falco exports its log via [Apache Kafka](https://kafka.apache.org) to [Elasticsearch](https://elastic.co/elasticsearch) because falcosidekick does not support the self-signed certificates used by elasticsearch in this test cluster. It would also be possible to make falco export its logs to files that are read by [Filebeat](https://elastic.co/beats) but that has not been done here.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami # add kafka's Helm repository
helm repo add falcosecurity https://falcosecurity.github.io/charts # add falco's Helm repository
helm repo update # update helm repos
helm upgrade --install kafka bitnami/kafka -n elastic-system -f falco/kafka-values.yaml --create-namespace # deploy kafka. The values limit its resource consumption
helm upgrade --install falco falcosecurity/falco --namespace falco --create-namespace -f falco/falco-rules.yaml -f falco/falco-values.yaml --set falcosidekick.config.kafka.password="$(kubectl get secret kafka-user-passwords --namespace elastic-system -o jsonpath='{.data.client-passwords}' | base64 -d | cut -d , -f 1)"
microk8s stop; microk8s start # the cluster must be restarted to properly activate the webhook for auditlogs
```

Falco should now start to run.

## 7. Deploy the Elastic Cloud on Kubernetes (ECK) Stack
These commands deploy first the Helm-chart and then the ECK Operator. Finally all the other components Logstash, Kibana etc are installed.

> **_NOTE:_** The logstash pods will fail if kafka has not been deployed yet. Make sure to deploy kafka first as indicated, or remove the kafka pipeline from the logstash configuration if you do not want to use falco.

```bash
helm repo add elastic https://helm.elastic.co # add the elastic repo
helm repo update # update the Helm repos
helm install elastic-operator elastic/eck-operator -n elastic-system --create-namespace # deploy the elastic operator
kubectl apply -n elastic-system -f eck/logstash-eck.yaml --create-namespace # deploy the remaining ECK components
ELASTIC_PASSWORD=$(kubectl get secret elasticsearch-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 --decode); echo $ELASTIC_PASSWORD; unset ELASTIC_PASSWORD # this command displays the password for kibana, the username is elastic
kubectl port-forward -n elastic-system svc/kibana-kb-http 5601 # enable port-forwarding for kibana. This command runs in the foreground, so keep its tab open or send it to the background with Ctrl + Z or so
```
If you have configured a remote host to steer the cluster as shown in [Step 1b)](#1-b-make-the-cluster-accessible-from-another-machine-optional), you can directly access Kibana on [https://127.0.0.1:5601](https://127.0.0.1:5601) from your webbrowser. If you haven't, forward the kibana port the previous port-forward command opened on the ubuntu node to your development host using from your remote host with a browser:
```bash
ssh -fNT -L 5601:127.0.0.1:5601 <your microk8s node IP>
```

> **_NOTE:_** This setup does not deploy any Index Lifecycle Managment, so the disk of your Ubuntu nodes will fill up quickly. For a PoC this should not be a problem.

### 7 a) Deploy Fluent Bit for more efficient log collection (optional)
These commands deploy Fluent Bit for collection of container logs. Note that it fetches the same data as filebeat, so it will increase the amount of logs drastically as all the container logs are parsed by Filebeat AND Fluent Bit

```bash
kubectl apply -f fluentbit/fluent-bit.yaml -n elastic-system
```

## 8. Deploy Prometheus and Grafana in the kube-prometheus-stack
These commands deploy the kube-prometheus-stack, a readily set up instance of Grafana with a Prometheus backend

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts # add Helm chart
helm repo update # update helm charts repo
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n kube-metrics --create-namespace # deploy the kube-prometheus-stack
```

## 9. Deploy Tetragon
These commands deploy Tetragon with the detection rule for `/etc/hosts` demonstrated in chapter 6. If you have not deployed Cilium in [Step 3](#3-a-configure-cilium-as-a-network-driver-optional), make sure to add the Cilium Helm chart from there before running these commands.

```bash
helm upgrade --install tetragon cilium/tetragon -n tetragon --create-namespace --set export.mode="" # helm deploy tetragon, disable outputting events to stdout as they are stored in log-files anyway
kubectl apply -f tetragon/cilium-detection-rule-etc-hosts.yaml # add additional detection rule for tetragon
```

## 10. Deploy Kubernetes dashboard (optional)
These commands deploy the kubernetes-dashboard.
```bash
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/ # Add kubernetes-dashboard repository
helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard --create-namespace --namespace kubernetes-dashboard # Deploy a Helm Release named "kubernetes-dashboard" using the kubernetes-dashboard chart
kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard-kong-proxy 8443:443 # start port-forwarding for kubernetes dashboard
ssh -fNT -L 8443:localhost:8443 <your microk8s node IP or name> # this command is only necessary if you have not followed step 1b)
kubectl -n kubernetes-dashboard create token default # This command generates an access token you can use to open the dashboard
```

## 11. Deploy KubeView (optional)
This is described on the official [GitHub page here](https://github.com/benc-uk/kubeview/releases).

## 12. Deploy kube-audit-rest (optional)
Follow the README in `kube-audit-rest/full-elastic-stack/README.md`, creds to [https://github.com/RichardoC/kube-audit-rest](https://github.com/RichardoC/kube-audit-rest) for this awesome tool which that code and README is adapted from.

## 13. Deploy privileged pods
In the `privileged-pod`-folder, there are two YAML-files available. One deploys a DaemonSet with Ubuntu-Pods that only have the node's root directory mounted called `ubuntu-root-mount.yaml`. The other deploys a DaemonSet of privileged pods with all permissions that also have their node's root directory mounted. Both can be deployed into the cluster using respectively:

```bash
kubectl apply -f privileged-pod/<filename>.yaml
```