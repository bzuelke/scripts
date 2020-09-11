#!/bin/bash

region=$(grep -Po 'region:\K[^ ]+' <<<@option.tags@ | cut -d',' -f1)
export AWS_DEFAULT_REGION=$region
export AWS_DEFAULT_PROFILE=aws_profile_goes_here
host=$(aws ec2 describe-instances --instance-ids @option.instanceID@ --query "Reservations[*].Instances[*].NetworkInterfaces[*].PrivateIpAddresses[*].PrivateDnsName" --output text)
state=$(aws ec2 describe-instances --instance-id @option.instanceID@ --query "Reservations[*].Instances[*].State.Name" --output text)

if [[ "$host" == *"does not exist"* ]]; then
  echo "The host provided does not exist on the account/cluster. Try again but be better"
  exit 1
elif [[ "$state" == "terminated" ]] || [[ "$state" == "shutting-down" ]]; then
  echo "$host is currently in a $state state, no need to continue with the job. Exiting"
  exit 1
else 
  echo "Found $host and is in $state state"
fi

echo "The instance that will be drained/terminated is $host"
hostcheck=$(kubectl get no $host -L kops.k8s.io/instancegroup | awk '{print $6}' | grep -iv instancegroup)
echo "hostcheck = $hostcheck"

kube_terminate () {
    timeout 60 kubectl drain $host --ignore-daemonsets --delete-local-data
    echo "$host has been drained"
    draintimeout=$?

    echo "Beginning to terminate $host"
    timeout 60 kubectl delete no $host 
    termtimeout=$?
    echo "$host has been deleted"
}

ec2_terminate () {
    kube_terminate
    echo "drain timeout = $draintimeout"
    echo "termination timeout = $termtimeout"
    if [[ $draintimeout -eq 124 ]] || [[ $termtimeout -eq 124 ]]; then
        echo "Termination/Drain timed out, terminating the instance via AWS CLI"
        aws ec2 terminate-instances --instance-ids @option.instanceID@
    elif [[ $draintimeout -eq 0 ]] && [[ $termtimeout -eq 0 ]]; then
        echo "Node was drained and deleted in k8s, terminating in aws"
        aws ec2 terminate-instances --instance-ids @option.instanceID@
        echo "Termination of $host was successful"
    else
        echo "There was an issue where nothing was terminated and everything sucks. (failed, exiting)"
        exit 1
    fi
}

if [[ "$hostcheck" == *"jenkins"* ]] || [[ "$hostcheck" == *"master"* ]] || [[ "$hostcheck" == *"mgmt"* ]];then
  echo "This is a $hostcheck, ignoring (failed, exiting)"
  exit 1
elif [[ "$hostcheck" == "" ]] && [[ "$host" != "" ]]; then
  echo "ec2 termination starting, no node found in kubernetes but lives in aws"
  aws ec2 terminate-instances --instance-ids @option.instanceID@
elif [[ "$hostcheck" != "" ]] && [[ "$host" != "" ]]; then
  echo "Found $host and $hostcheck not null"
  echo "Beginning drain on $host"
  ec2_terminate
else
  echo "This job fell into the pit of dispair. There is nothing to do, there isn't any option that makes sense, and i'm sad now. (failed, exiting)"
  exit 1
fi