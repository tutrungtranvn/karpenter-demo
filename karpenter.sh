#########
# Setup #
#########

git clone https://github.com/vfarcic/karpenter-demo

cd karpenter-demo

export CLUSTER_NAME=eks-karpenter-cluster
export KARPENTER_VERSION=v0.26.1
export AWS_DEFAULT_REGION=ap-southeast-1
export KARPENTER_IAM_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/eks-karpenter"


cat cluster.yaml \
    | sed -e "s@name: .*@name: $CLUSTER_NAME@g" \
    | sed -e "s@region: .*@region: $AWS_DEFAULT_REGION@g" \
    | tee cluster.yaml

cat provisioner.yaml \
    | sed -e "s@instanceProfile: .*@instanceProfile: KarpenterNodeInstanceProfile-$CLUSTER_NAME@g" \
    | sed -e "s@.* # Zones@      values: [${AWS_DEFAULT_REGION}a, ${AWS_DEFAULT_REGION}b, ${AWS_DEFAULT_REGION}c] # Zones@g" \
    | tee provisioner.yaml

cat app.yaml \
    | sed -e "s@topology.kubernetes.io/zone: .*@topology.kubernetes.io/zone: ${AWS_DEFAULT_REGION}a@g" \
    | tee app.yaml

eksctl create cluster \
    --config-file cluster.yaml

export CLUSTER_ENDPOINT=$(aws eks describe-cluster \
    --name $CLUSTER_NAME \
    --query "cluster.endpoint" \
    --output json)

    echo $CLUSTER_ENDPOINT

###########################
# Karpenter Prerequisites #
###########################

export SUBNET_IDS=$(\
    aws cloudformation describe-stacks \
    --stack-name eksctl-$CLUSTER_NAME-cluster \
    --query 'Stacks[].Outputs[?OutputKey==`SubnetsPrivate`].OutputValue' \
    --output text)

aws ec2 create-tags \
    --resources $(echo $SUBNET_IDS | tr ',' '\n') \
    --tags Key="kubernetes.io/cluster/$CLUSTER_NAME",Value=

curl -fsSL https://karpenter.sh/"${KARPENTER_VERSION}"/getting-started/getting-started-with-eksctl/cloudformation.yaml  > $TEMPOUT && \
aws cloudformation deploy \
--stack-name "Karpenter-${CLUSTER_NAME}" \
--template-file "${TEMPOUT}" \
--capabilities CAPABILITY_NAMED_IAM \   
--parameter-overrides "ClusterName=${CLUSTER_NAME}" 

export AWS_ACCOUNT_ID=$(\
    aws sts get-caller-identity \
    --query Account \
    --output text)

eksctl create iamidentitymapping \
    --username system:node:{{EC2PrivateDNSName}} \
    --cluster  $CLUSTER_NAME \
    --arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-$CLUSTER_NAME \
    --group system:bootstrappers \
    --group system:nodes

eksctl create iamserviceaccount \
    --cluster $CLUSTER_NAME \
    --name eks-karpenter \
    --namespace karpenter \
    --attach-policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/KarpenterControllerPolicy-$CLUSTER_NAME \
    --approve

# Execute only if this is the first time using spot instances in this account
aws iam create-service-linked-role \
    --aws-service-name spot.amazonaws.com

###########################################
# Applications Without Cluster Autoscaler #
###########################################

kubectl get nodes

cat app.yaml

kubectl apply --filename app.yaml

kubectl get pods,nodes

#####################
# Install Karpenter #
#####################

helm repo add karpenter \
    https://charts.karpenter.sh

helm repo update

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version ${KARPENTER_VERSION} --namespace karpenter \
  --create-namespace \
  --set serviceAccount.create=false \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${KARPENTER_IAM_ROLE_ARN} \
  --set settings.aws.clusterName=${CLUSTER_NAME} \
  --set settings.aws.defaultInstanceProfile=KarpenterNodeInstanceProfile-${CLUSTER_NAME} \
  --set settings.aws.interruptionQueueName=${CLUSTER_NAME} \
  --set controller.clusterName=$CLUSTER_NAME \
  --set controller.clusterEndpoint=$CLUSTER_ENDPOINT \
  --wait
kubectl --namespace karpenter get all

##############################################
# Scale Up Kubernetes Cluster With Karpenter #
##############################################

cat provisioner.yaml

# Open https://kubernetes.io/docs/reference/labels-annotations-taints/

kubectl apply \
    --filename provisioner.yaml

kubectl get pods,nodes

kubectl get pods,nodes

kubectl --namespace karpenter logs \
    --selector karpenter=controller

####################################################
# Scale Down The Kubernetes Cluster With Karpenter #
####################################################

kubectl delete --filename app.yaml

kubectl --namespace karpenter logs \
    --selector karpenter=controller

kubectl get nodes

###########
# Destroy #
###########

helm --namespace karpenter \
    uninstall karpenter

eksctl delete iamserviceaccount \
    --cluster $CLUSTER_NAME \
    --name karpenter \
    --namespace karpenter

aws cloudformation delete-stack \
    --stack-name Karpenter-$CLUSTER_NAME

# Install jq from https://stedolan.github.io/jq if you do not have it already

aws ec2 describe-launch-templates \
    | jq -r ".LaunchTemplates[].LaunchTemplateName" \
    | grep -i Karpenter-$CLUSTER_NAME \
    | xargs -I{} \
        aws ec2 delete-launch-template \
        --launch-template-name {}

eksctl delete cluster \
    --name $CLUSTER_NAME \
    --region $AWS_DEFAULT_REGION