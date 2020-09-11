#!/bin/bash
region=$(echo @option.cluster@ | cut -d "-" -f3)
cluster=$(echo @option.cluster@ | cut -d ":" -f2)


datadog=$(kubectl get po -ndatadog --cluster=$cluster | awk '{print $5}' | grep -vi age | grep -vE "^[0-9]s" | wc -l)
datadog_up=$(kubectl get po -ndatadog --cluster=$cluster  | awk '{print $2}' | grep -vi ready | grep -v 0 | wc -l)
if [[ $datadog_up -lt $datadog ]] || [[ -z $datadog_up ]] || [[ -z $datadog ]]; then 
  echo "Datadog is showing one or all are offline currently, not firing this as it is a potential false positive"
  echo "If datadog is having issues still please reach out to SRE to review"
  kubectl get po -l app=datadog --all-namespaces --cluster=$cluster 
  exit 1
else 
  echo "Datadog is showing a ready state. Continuing"
fi

failed_monitoring_app=$(kubectl get po -l app=failed_monitoring_app --all-namespaces --cluster=$cluster  | awk '{print $3}' | grep -vi ready | wc -l)
failed_monitoring_app_up=$(kubectl get po -l app=failed_monitoring_app --all-namespaces --cluster=$cluster  | awk '{print $3}' | grep -vi ready | grep -v 1/1 | wc -l)
if [[ $failed_monitoring_app_up -lt $failed_monitoring_app ]] || [[ -z $failed_monitoring_app_up ]] || [[ -z $failed_monitoring_app ]]; then 
  echo "failed_monitoring_app is showing one or all are offline currently, not firing this as it is a potential false positive"
  echo "If datadog is having issues still please reach out to SRE to review"
  kubectl get po -l app=failed_monitoring_app --all-namespaces --cluster=$cluster 
  exit 1
else 
  echo "failed_monitoring_app is showing a ready state which would show that datadog is in fact showing problems, starting job process on $cluster"
  kubectl get po -l app=failed_monitoring_app --all-namespaces --cluster=$cluster
fi

echo "Current Datadog Pods"
kubectl get po -ndatadog --cluster=$cluster 
echo "Forcing delete of Datadog pods"
#kubectl delete po -ndatadog --cluster=$cluster  --force --grace-period 0 --all
echo "Wait for all of the pods start normally"
while ! [[ -z $(kubectl get po -ndatadog --cluster=$cluster  | awk '{print $2}' | grep 0) ]]
do
  echo "Pods are not ready yet"
  sleep 5
done
echo "Pods should be running and available"
kubectl get po -ndatadog --cluster=$cluster 
