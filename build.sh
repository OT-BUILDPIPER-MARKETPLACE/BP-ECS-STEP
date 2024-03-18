#!/bin/bash
source /app/buildpiper/shell-functions/functions.sh
source /app/buildpiper/shell-functions/log-functions.sh
source /app/buildpiper/shell-functions/str-functions.sh
source /app/buildpiper/shell-functions/file-functions.sh
source /app/buildpiper/shell-functions/aws-functions.sh

bp_image_uri=$(getComponentName)
bp_image_tag=$(getRepositoryTag)

# Extract ${BP_IMAGE_URI} and ${BP_IMAGE_TAG} using jq
bp_image_uri=$(echo "$json_data" | jq -r '.addition_meta_data.placeholders[] | select(.key == "${BP_IMAGE_URI}") | .value')
bp_image_tag=$(echo "$json_data" | jq -r '.addition_meta_data.placeholders[] | select(.key == "${BP_IMAGE_TAG}") | .value')
git_url=$(echo "$json_data" | jq -r '.manifest_meta_data.manifest_git_repo.git_url')

repo_name=$(basename "$git_url" | sed 's/\.git$//')

# Print the extracted values
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