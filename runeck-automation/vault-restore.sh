#!/bin/bash

kns vault
etcdcluster=$(kubectl get etcdcluster -nvault | awk '{print $1}' | grep -v NAME)
remainEtcd=$(kubectl get po -l app=etcd -nvault | grep -vi name | wc -l)
clusterSize=$(kubectl get etcdcluster -nvault -ojsonpath="{.items[*].spec.size}")
currentNamespace=$(kubectl config view --minify --output 'jsonpath={..namespace}')

echo "Validating namespace"
if [[ "$currentNamespace" != "vault" ]]; then
  echo "You're not in the vault namespace, killing job"
  echo $currentNamespace
  exit 1
elif [[ "$currentNamespace" == "vault" ]]; then
  echo "In vault namespace continuing"
  echo $currentNamespace
else
  echo "How did you even get here, like for real what is the matter with you, close the laptop and go sit in the corner."
  exit 1
fi

etcdNuke () {
  kubectl get po -l app=etcd -nvault
  kubectl delete po -l app=etcd -nvault
  remainEtcd=$(kubectl get po -l app=etcd -nvault | grep -vi name | wc -l)
  while [[ $remainEtcd -ne 0 ]];
  do
    echo "etcd pods still not fully terminated"
    sleep 5
    kubectl get po -l app=etcd -nvault 
    remainEtcd=$(kubectl get po -l app=etcd -nvault | grep -vi name | wc -l)
  done
  echo "all etcd pods are ded"
}

restore () {
    etcdClusterCheck
    kubectl delete etcdrestore k8s-vault-etcd -nvault
    kubectl apply -f ~/rundeck/vault/@option.Vaultcluster@/restore_cr.yaml
    remainEtcd=$(kubectl get po -l app=etcd -nvault | awk '{print $2}' | grep 1/1 | wc -l)
    if [[ "$clusterSize" != "" ]]; then
      while [[ $remainEtcd -ne $clusterSize ]];
      do
        echo "etcd pods still not fully started"
        sleep 5
        kubectl get po -l app=etcd -nvault 
        remainEtcd=$(kubectl get po -l app=etcd -nvault | awk '{print $2}' | grep 1/1 | wc -l)
      done
      kubectl get po -l app=etcd -nvault
      echo "all etcd pods are up and running, time to unseal this bad boi"
      unseal
    elif [[ "$clusterSize" != "" ]]; then
      echo "Etcd cluster size can't be verified because it's not deployed, please review the etcd cluster object"
    else
      echo "No valid options were chosen when verifying if etcdclustersize was null. Something wrong with that"
    fi
}

etcdClusterCheck () {
  echo "Checking to see if etcdcluster object is available, if it isn't it will be created."
  if [[ "$etcdcluster" == "" ]]; then
    echo "EtcdCluster object not found. creating object"
    kubectl apply -f ~/rundeck/vault/@option.Vaultcluster@/EtcdCluster.yaml
    remainEtcd=$(kubectl get po -l app=etcd -nvault | awk '{print $2}' | grep 1/1 | wc -l)
    clusterSize=$(kubectl get etcdcluster -nvault -ojsonpath="{.items[*].spec.size}")
    etcdNuke
  elif [[ "$etcdcluster" == "k8s-vault-etcd" ]]; then
    echo "Etcd cluster found, continuing"
  else
    echo "Nothing returned with any solid information, wrong etcd cluster name or something else regarding the etcdcluster is off. fix it, fix it. fix it!"
  fi

}

vaultValidate () {
  running=$(kubectl get po -l app=vault | grep Running | wc -l)
  while [[ $running < 2 ]];
  do
    echo "vault pods not ready yet"
    kubectl get po -l app=vault
    running=$(kubectl get po -l app=vault | grep Running | wc -l)
    sleep 5
  done
  kubectl get po -l app=vault
}

unseal () {
    echo "Unsealing Vault"
    echo "Check to see if vault pods are in running state"
    kubectl delete po -l app=vault --force --grace-period=0
    vaultValidate
    master=$(kubectl get po -l app=vault | grep -v NAME -m1 | awk '{print $1}' | tr -d '\n')
    kubectl -n vault port-forward $master 8200 &
    export VAULT_SKIP_VERIFY="true"
    export VAULT_ADDR=https://localhost:8200
    export VAULT_TOKEN=$(kubectl get secret vault-secret-config -nvault -ojsonpath="{.data.root_token}" | base64 -d)
    key1=$(kubectl get secret vault-secret-config -nvault -ojsonpath="{.data.unseal_key_1}" | base64 -d)
    key2=$(kubectl get secret vault-secret-config -nvault -ojsonpath="{.data.unseal_key_2}" | base64 -d)
    key3=$(kubectl get secret vault-secret-config -nvault -ojsonpath="{.data.unseal_key_3}" | base64 -d)
    vault unseal $key1
    vault unseal $key2
    vault unseal $key3
    pkill kubectl -9
    sleep 5
    kubectl -n vault port-forward $master 8200 &
    sealed=$(vault status | grep Sealed | awk '{print $2}')
    if [[ "$sealed" == "true" ]]; then
      echo "For some reason vault didn't unseal, please investigate further and try again"
      pkill kubectl -9
      exit 1
    elif [[ "$sealed" == "false" ]]; then
      vault list sre/
      echo "Vault was unsealed and ready for action"
      pkill kubectl -9
    else
      echo "How did you wind up here? I don't like people and would appreciate you go troubleshooting as to why you can't do things correctly"
      pkill kubectl -9
      exit 1
    fi
}

fullRestore () {
    if [[ $remainEtcd -lt $clusterSize ]] && [[ "$force" != "yes" ]] && [[ $remainEtcd -ne 0 ]]; then
        echo "etcd cluster is broken, Deleting remaining etcd containers getting ready for restore"
        etcdNuke
        restore
    elif [[ $remainEtcd -eq $clusterSize ]] && [[ "$force" != "yes" ]] && [[ $remainEtcd -ne 0 ]]; then
        echo "All etcd pods are running, are you sure you want to do this? Use force flag to continue"
        exit 1
    elif [[ $remainEtcd -eq $clusterSize ]] && [[ "$force" == "yes" ]] && [[ $remainEtcd -ne 0 ]]; then
        echo "Straight up nuking etcd cluster due to force flag"
        etcdNuke
        restore
    elif [[ $remainEtcd -eq 0 ]]; then
        echo "No running etcd pods, starting restoration of cluster"
        restore
    else
        echo "Something awful happened and I'm not sure how or why you're here"
        exit 1
    fi
}

@option.argument@