#!/bin/bash
source /opt/buildpiper/shell-functions/functions.sh
source /opt/buildpiper/shell-functions/log-functions.sh
source /opt/buildpiper/shell-functions/str-functions.sh
source /opt/buildpiper/shell-functions/file-functions.sh
source /opt/buildpiper/shell-functions/aws-functions.sh

bp_image_uri=$(getComponentName)
bp_image_tag=$(getRepositoryTag)
git_url=$(getGitUrl)

add_event "DEPLOYMENT" "STARTED" \
    "Deployment initiated" \
    "Repo: ${repo_name}, Image: ${bp_image_uri}:${bp_image_tag}"

repo_name=$(basename "$git_url" | sed 's/\.git$//')

echo "BP_IMAGE_URI: $bp_image_uri"
echo "BP_IMAGE_TAG: $bp_image_tag"
echo "Repository Name: $repo_name"

getAssumeRole $IAM_ROLE_TO_ASSUME
if [ $? -ne 0 ]; then
  add_event "ASSUME ROLE" "FAILED" "IAM role assumption failed" "$IAM_ROLE_TO_ASSUME"
  exit 1
else
  add_event "ASSUME ROLE" "SUCCESS" "IAM role assumed successfully" "$IAM_ROLE_TO_ASSUME"
fi

cd $WORKSPACE/$repo_name
if [ $? -ne 0 ]; then
  add_event "CD" "FAILED" "Changing directory failed" "$WORKSPACE/$repo_name"
  exit 1
else
  add_event "CD" "SUCCESS" "Changed directory successfully" "$WORKSPACE/$repo_name"
fi

TASK_FAMILY=$(cat task-definition.json | jq -r '.family')

TASK_DEFINITION=$(aws ecs describe-task-definition --task-definition "$TASK_FAMILY" --region "$REGION")

NEW_TASK_DEFINTIION=$(echo $TASK_DEFINITION | jq --arg IMAGE "$bp_image_uri" '.taskDefinition | .containerDefinitions[0].image = $IMAGE | del(.taskDefinitionArn) | del(.revision) | del(.status) | del(.requiresAttributes) | del(.compatibilities) |  del(.registeredAt) | del(.registeredBy)')

echo $NEW_TASK_DEFINTIION > tf.json

aws ecs register-task-definition  --region "$REGION"  --cli-input-json file://tf.json
if [ $? -ne 0 ]; then
  add_event "TASK DEFINITION" "FAILED" "Task definition registration failed" "$TASK_FAMILY"
  exit 1
else
  add_event "TASK DEFINITION" "SUCCESS" "Task definition registered" "$TASK_FAMILY"
fi


aws ecs update-service --cluster $CLUSTER --service $TASK_FAMILY --region $REGION --task-definition $TASK_FAMILY --force-new-deployment --output text
if [ $? -ne 0 ]; then
  add_event "SERVICE UPDATE" "FAILED" "Service update failed" "$TASK_FAMILY"
  exit 1
else
  add_event "SERVICE UPDATE" "SUCCESS" "Deployment triggered" "$TASK_FAMILY"
fi

add_event "DEPLOYMENT" "COMPLETED" \
    "Deployment finished successfully" \
    "Service: ${TASK_FAMILY}"