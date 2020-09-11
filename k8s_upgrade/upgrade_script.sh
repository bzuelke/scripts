#!/bin/bash

while getopts hr:v:c:p: opt; do
  case $opt in
    v) old_k8s="$OPTARG"
    ;;
    r) region=$OPTARG
    ;;
    c) cluster=$OPTARG
    ;;
    p) profile=$OPTARG
    ;;
    h) echo "v = old k8s version | i.e v1.12.9"
       echo "r = aws region | i.e us-east-1"
       echo "c = cluster name | i.e cluster.k8s.local"
       echo "p = aws profile | i.e my_aws_account"
    ;;
  esac
done

echo "**************************************************"
echo "Input flags used"
echo "Old K8s Version = $old_k8s"
echo "AWS Region = $region"
echo "Cluster Name = $cluster"
echo "AWS Account = $profile"
echo "**************************************************"

defaultRegion="us-east-1"
export AWS_DEFAULT_PROFILE=$profile
export AWS_DEFAULT_REGION=${region:-$defaultRegion}

echo "=========================================================="
echo "Time Started"
date
"==============================================================="

echo "=========================================================="
echo "* Pre-Snapshot:"
kubectl get all --all-namespaces
echo "=========================================================="

#for master in $(kops get ig --name ${cluster} | grep master | awk '{print $1}') ;
#do
#  echo "*****************************************************************"
#  echo "* Rolling Master Nodes in group ${master}                       *"
#  echo "*****************************************************************"
#  kops rolling-update cluster ${cluster} --instance-group ${master} --yes
#  
#  echo "*****************************************************************"
#  echo "* Validating kops cluster after ${master} rolled                 *"
#  echo "*****************************************************************"
#  watch -e "! kops validate cluster ${cluster} |grep -m 1 \"Your cluster ${cluster} is ready\"" && exit 0
#done

declare -A PIDS
for IG in $(kubectl get no -L kops.k8s.io/instancegroup | tail -n +2 | awk '{print $6}' | sort | uniq | egrep -v "master|mgmt|jenkins") ; 
do
  echo "**************************************************"
  echo "* Getting current desired node count to scale up *"
  echo "**************************************************"
  igSize=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name ${IG}.${cluster} --query "AutoScalingGroups[].DesiredCapacity" --output text)

  new=$(echo "(${igSize}*2)+4" | bc)

  echo "${IG} desired node count is now ${new}"

  echo "***************************************"
  echo "* Setting desired for node groups now *"
  echo "***************************************"

  aws autoscaling set-desired-capacity --auto-scaling-group-name ${IG}.${cluster} --desired-capacity ${new}

  echo "*********************************"
  echo "* Restarting cluster autoscaler *"
  echo "*********************************"
  kubectl delete po $(kubectl get po -nkube-system --cluster=${cluster} --context=${cluster} | grep autoscaler | awk '{print $1}') -nkube-system

  igSize=$(kubectl get no -l kops.k8s.io/instancegroup=${IG} --cluster=${cluster} --context=${cluster} | tail -n +2 | wc -l)

  echo "*********************************"
  echo "* Wait for new nodes to come up *"
  echo "*********************************"
  while [ ${igSize} -ne ${new} ];
  do
    echo "${IG} nodes not joined to the cluster yet"
    sleep 5s
    igSize=$(kubectl get no -l kops.k8s.io/instancegroup=${IG} --cluster=${cluster} --context=${cluster} | tail -n +2 | wc -l)
  done &
  PIDS[${IG}]=$!
  echo "*********************************"
  echo "${IG} nodes are now up and running"
  echo "*********************************"
done

echo "*******************************"
echo "waiting on PIDS"
for PID in ${PIDS[@]} ; 
do
  wait ${PID}
done
echo "*******************************"

echo "*********************************************"
echo "* echo "Draining previous version of nodes" *"
echo "*********************************************"

for node in $(kubectl get no -l 'environment notin (master, jenkins, mgmt)' -o jsonpath="{range.items[?(@.status.nodeInfo.kubeletVersion == \"${old_k8s}\")]}{@.metadata.name}{\"\n\"}") ;
do
    kubectl drain ${node} --ignore-daemonsets --delete-local-data --force &
done

sleep 90s

echo "*****************************************"
echo "* Terminating previous version of nodes *"
echo "*****************************************"
echo "Terminating previous version of nodes"
for node in $(kubectl get no -l 'environment notin (master, jenkins, mgmt)' -o jsonpath="{range.items[?(@.status.nodeInfo.kubeletVersion == \"${old_k8s}\")]}{@.metadata.name}{\"\n\"}") ;
do
    kubectl delete no ${node} &
done

echo "=========================================================="
echo "Time Completed"
date
"==============================================================="

echo "################"
echo "FIN"
echo "################"

exit 0