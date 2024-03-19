#!/bin/bash
source functions.sh
source log-functions.sh
source str-functions.sh
source file-functions.sh
source aws-functions.sh

bp_image_uri=$(getComponentName)
bp_image_tag=$(getRepositoryTag)
git_url=$(getGitUrl)

repo_name=$(basename "$git_url" | sed 's/\.git$//')

echo "BP_IMAGE_URI: $bp_image_uri"
echo "BP_IMAGE_TAG: $bp_image_tag"
echo "Repository Name: $repo_name"

getAssumeRole $IAM_ROLE_TO_ASSUME

cd $WORKSPACE/$repo_name


TASK_FAMILY=$(cat task-definition.json | jq -r '.family')

TASK_DEFINITION=$(aws ecs describe-task-definition --task-definition "$TASK_FAMILY" --region "$REGION")

NEW_TASK_DEFINTIION=$(echo $TASK_DEFINITION | jq --arg IMAGE "$bp_image_uri" '.taskDefinition | .containerDefinitions[0].image = $IMAGE | del(.taskDefinitionArn) | del(.revision) | del(.status) | del(.requiresAttributes) | del(.compatibilities) |  del(.registeredAt) | del(.registeredBy)')


echo $NEW_TASK_DEFINTIION > tf.json

aws ecs register-task-definition  --region "$REGION"  --cli-input-json file://tf.json

aws ecs update-service --cluster $CLUSTER --service $TASK_FAMILY --region $REGION --task-definition $TASK_FAMILY --force-new-deployment --output text