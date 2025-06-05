#!/bin/bash
source /opt/buildpiper/shell-functions/functions.sh
source /opt/buildpiper/shell-functions/log-functions.sh
source /opt/buildpiper/shell-functions/str-functions.sh
source /opt/buildpiper/shell-functions/file-functions.sh
source /opt/buildpiper/shell-functions/aws-functions.sh

sleep  $SLEEP_DURATION

if [ "$DEBUG" = true ]; then
  set -x
fi
if [ "$ASSUME_OTHER_ROLE" == true ]
then
    role_output=$(aws sts assume-role --role-arn arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME --role-session-name $ROLE_SESSION_NAME)
    # Check if the assume-role command was successful
    if [ $? -ne 0 ]; then
      echo "Failed to assume role."
      exit 1
    fi
    # Parse the JSON output and set environment variables
    AWS_ACCESS_KEY_ID=$(echo $role_output | jq -r '.Credentials.AccessKeyId')
    AWS_SECRET_ACCESS_KEY=$(echo $role_output | jq -r '.Credentials.SecretAccessKey')
    AWS_SESSION_TOKEN=$(echo $role_output | jq -r '.Credentials.SessionToken')
    # Export the variables
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export AWS_SESSION_TOKEN
fi

if [[ "$OPERATION" == "Stop" || "$OPERATION" == "Start" ]]; then
  if [[ -z "$CLUSTER_NAME" ]]; then
    echo "❌ [ERROR] CLUSTER_NAME is required for ECS operations."
    exit 1
  fi

  echo "🛠️  Starting ECS '$OPERATION' operation on cluster: $CLUSTER_NAME"

  DESIRED_COUNT=0
  [[ "$OPERATION" == "Start" ]] && DESIRED_COUNT=1

  echo "🔄 Fetching ECS services from cluster..."
  SERVICE_ARN_LIST=$(aws ecs list-services --cluster "$CLUSTER_NAME" --query 'serviceArns[]' --output text)

  if [[ -z "$SERVICE_ARN_LIST" ]]; then
    echo "⚠️  No services found in ECS cluster: $CLUSTER_NAME"
    exit 1
  fi

  echo "🔄 Updating ECS services to desired count: $DESIRED_COUNT"
  TASK_STATUS=0

  for SERVICE_ARN in $SERVICE_ARN_LIST; do
    SERVICE_NAME=$(basename "$SERVICE_ARN")
    echo "➡️  Service: $SERVICE_NAME"

    aws ecs update-service \
      --cluster "$CLUSTER_NAME" \
      --service "$SERVICE_NAME" \
      --desired-count "$DESIRED_COUNT" >/dev/null

    if [[ $? -ne 0 ]]; then
      echo "❌ Failed to update $SERVICE_NAME task count to $DESIRED_COUNT"
      exit 1
    else
      echo "✅ Successfully updated $SERVICE_NAME task count to $DESIRED_COUNT"
    fi
  done

  echo "🎯 ECS '$OPERATION' operation completed for all services"
  saveTaskStatus ${TASK_STATUS} ${ACTIVITY_SUB_TASK_CODE}
  exit ${TASK_STATUS}
fi
