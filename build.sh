#!/bin/bash
source /opt/buildpiper/shell-functions/functions.sh
source /opt/buildpiper/shell-functions/log-functions.sh
source /opt/buildpiper/shell-functions/str-functions.sh
source /opt/buildpiper/shell-functions/file-functions.sh
source /opt/buildpiper/shell-functions/aws-functions.sh


if [ "$DEBUG" = true ]; then
  set -x
fi

CODEBASE_LOCATION="${WORKSPACE}"/"${CODEBASE_DIR}"
logInfoMessage "I'll do processing at [$CODEBASE_LOCATION]"
sleep  $SLEEP_DURATION


cd  "${CODEBASE_LOCATION}"
TASK_STATUS=0

DEPLOY_ENV_FILE="./deploy.env"


setupAwsCredentials() {

    logInfoMessage "=== Setting up AWS credentials ==="

    if [ "${ASSUME_ROLE:-false}" == "true" ]; then

        if [ -z "${ACCOUNT_ID:-}" ] || [ -z "${ROLE_NAME:-}" ]; then
            logErrorMessage "ACCOUNT_ID and ROLE_NAME must be set when ASSUME_ROLE=true"
            exit 1
        fi

        ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

        logInfoMessage "Assuming AWS IAM role: ${ROLE_ARN}"

        getAssumeRole "$ROLE_ARN"

    else

        logInfoMessage "ASSUME_ROLE is not set to 'true', using AWS profile"

        if [ -z "${AWS_PROFILE:-}" ]; then
            logErrorMessage "AWS_PROFILE must be set when ASSUME_ROLE=false"
            exit 1
        fi
        export AWS_PROFILE="${AWS_PROFILE}"
        # Get credentials from AWS profile
        export AWS_ACCESS_KEY_ID="$(aws configure get aws_access_key_id --profile "$AWS_PROFILE")"
        export AWS_SECRET_ACCESS_KEY="$(aws configure get aws_secret_access_key --profile "$AWS_PROFILE")"
        export AWS_SESSION_TOKEN="$(aws configure get aws_session_token --profile "$AWS_PROFILE" 2>/dev/null || true)"

        # Get region from AWS profile
        export AWS_REGION="$(aws configure get region --profile "$AWS_PROFILE")"
        export AWS_DEFAULT_REGION="$AWS_REGION"

        logInfoMessage "AWS credentials loaded from profile: ${AWS_PROFILE}"
    fi

    if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
        logErrorMessage "AWS_ACCESS_KEY_ID is not set"
        exit 1
    fi

    if [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        logErrorMessage "AWS_SECRET_ACCESS_KEY is not set"
        exit 1
    fi

    if [ -z "${AWS_REGION:-}" ]; then
        logErrorMessage "AWS_REGION is not set"
        exit 1
    fi

    if ! AWS_IDENTITY=$(aws sts get-caller-identity 2>/tmp/aws_error.log); then
        logErrorMessage "AWS authentication failed"
        cat /tmp/aws_error.log
        exit 1
    fi

    AWS_ACCOUNT_ID=$(echo "$AWS_IDENTITY" | jq -r '.Account')
    AWS_ARN=$(echo "$AWS_IDENTITY" | jq -r '.Arn')

    logInfoMessage "AWS authentication successful"
    logInfoMessage "AWS Account ID: ${AWS_ACCOUNT_ID}"
    logInfoMessage "AWS Region: ${AWS_REGION}"
    logInfoMessage "AWS ARN: ${AWS_ARN}"

    logInfoMessage "=== AWS credentials setup completed ==="
}

  if [[ "${ASSUME_ROLE:-false}" == "true" || -n "${AWS_PROFILE:-}" ]]; then
      setupAwsCredentials
  else
      logInfoMessage "Neither ASSUME_ROLE=true nor AWS_PROFILE is set, skipping AWS credential setup"
  fi


if [ ! -f "$DEPLOY_ENV_FILE" ]; then
    logErrorMessage "File not found: $DEPLOY_ENV_FILE"
    exit 1
fi

source "$DEPLOY_ENV_FILE"

deployecsServices() {

if [ -z "$SERVICES" ]; then
	logErrorMessage "Empty service name found in SERVICES='${SERVICES}'"
	exit 1
fi

IFS=',' read -ra SERVICE_LIST <<< "$SERVICES"

for SERVICE in "${SERVICE_LIST[@]}"; do


    SERVICE="$(echo "$SERVICE" | xargs)"

    SERVICE_UPPER=$(echo "$SERVICE" | tr '[:lower:]-' '[:upper:]_')

    TASK_DEF_VAR="${SERVICE_UPPER}_TASK_DEF_ARN"
	if [ -z "${TASK_DEF_VAR}" ]; then
		logErrorMessage "${TASK_DEF_VAR} is not set in $DEPLOY_ENV_FILE"
		exit 1
	fi

    logInfoMessage "=========================================="
    logInfoMessage
    logInfoMessage "Deployment started: $SERVICE"
    logInfoMessage 
    logInfoMessage "=========================================="

    logInfoMessage "=========================================="

    logInfoMessage "=========================================="
    logInfoMessage "Checking service: $SERVICE"
    logInfoMessage "Expected variable: $TASK_DEF_VAR"
    logInfoMessage "=========================================="

    # Check whether variable exists and has a value
    TASK_DEF_ARN="${!TASK_DEF_VAR}"

    if [ -z "$TASK_DEF_ARN" ]; then
        logErrorMessage "Task definition ARN not found for service: $SERVICE"
        logErrorMessage "Expected variable: $TASK_DEF_VAR"
        exit 1
    fi

  
    logInfoMessage "Task Definition ARN found:"
    logInfoMessage "$TASK_DEF_ARN"

  logInfoMessage "=========================================="
  logInfoMessage "Deploying service : ${SERVICE}"
  logInfoMessage "Task Definition   : ${TASK_DEF_ARN}"
  logInfoMessage "=========================================="

  aws ecs update-service \
    --cluster "${ECS_CLUSTER}" \
    --service "${SERVICE}" \
    --task-definition "${TASK_DEF_ARN}" \
    --force-new-deployment > /dev/null

  if [[ "${MUTATION}" == "true" ]]; then
	logInfoMessage "Marking mutation in mutation.env"
	markDeploymentMutated
	else 
	logWarningMessage "MUTATION is not set to 'true', skipping mutation marking"
  fi

  if [[ "${WAIT}" == "true" ]]; then

        logInfoMessage "Waiting for service stability: ${SERVICE}"

        if ! aws ecs wait services-stable \
            --cluster "${ECS_CLUSTER}" \
            --services "${SERVICE}"; then

            logInfoMessage "========== ECS SERVICE STATUS =========="

            aws ecs describe-services \
                --cluster "${ECS_CLUSTER}" \
                --services "${SERVICE}" \
                --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount,Pending:pendingCount,Deployments:deployments[*].{Status:status,Running:runningCount,Desired:desiredCount,TaskDef:taskDefinition}}'

            logInfoMessage "========== ECS SERVICE EVENTS =========="

            aws ecs describe-services \
                --cluster "${ECS_CLUSTER}" \
                --services "${SERVICE}" \
                --query 'services[0].events[0:15].[createdAt,message]' \
                --output table
			echo "DEPLOYMENT_STATUS=FAILED" > deployment.env
            exit 1
        fi
        logInfoMessage "Service stable: ${SERVICE}"
    else
        logWarningMessage "WAIT is not set to 'true', skipping wait for service stability"
    fi

done

logInfoMessage "All services validated successfully."
TASK_STATUS=$?

saveTaskStatus ${TASK_STATUS} ${ACTIVITY_SUB_TASK_CODE}
echo "DEPLOYMENT_STATUS=SUCCESS" > deployment.env
}



markDeploymentMutated() {
  printf '%s\n' "DEPLOY_MUTATED=true" > mutation.env
  grep -v '^DEPLOY_MUTATED=' deploy.env > deploy.env.tmp || true
  printf '%s\n' "DEPLOY_MUTATED=true" >> deploy.env.tmp
  logInfoMessage "Marked deployment as mutated in mutation.env and deploy.env"
  mv deploy.env.tmp deploy.env
}

deploycronServices (){

	IFS=',' read -ra SCHEDULER_LIST <<< "${SCHEDULER_RULES}"

	for RULE in "${SCHEDULER_LIST[@]}"; do

	RULE="$(echo "${RULE}" | xargs)"
	[ -z "${RULE}" ] && continue

	SCHEDULER_NAME="${RULE}"
	SCHEDULER_UPPER="$(echo "${SCHEDULER_NAME}" | tr '[:lower:]-' '[:upper:]_')"

	# Dynamic task definition variable
	TASK_DEF_VAR="PREVIOUS_${SCHEDULER_UPPER}_TASK_DEF"
	NEW_TASK_DEF_VAR="${SCHEDULER_UPPER}_TASK_DEF_ARN"

	if [ -z "${NEW_TASK_DEF_VAR}" ]; then
		logInfoMessage "${NEW_TASK_DEF_VAR} is not set in $DEPLOY_ENV_FILE"
		exit 1
	fi

	CRON_TASK_DEF_ARN="${!NEW_TASK_DEF_VAR}"

	CURRENT_TARGETS_FILE="current-targets-${RULE}.json"
	CURRENT_TARGETS_ARRAY_FILE="current-targets-array-${RULE}.json"

	[ -f "${CURRENT_TARGETS_FILE}" ] || {
		logErrorMessage "Current targets file ${CURRENT_TARGETS_FILE} missing for rule ${RULE}"
		exit 1
	}

	[ -f "${CURRENT_TARGETS_ARRAY_FILE}" ] || {
		logErrorMessage "Current targets array file ${CURRENT_TARGETS_ARRAY_FILE} missing for rule ${RULE}"
		exit 1
	}

	logInfoMessage "=========================================="
	logInfoMessage "Updating EventBridge rule"
	logInfoMessage "Rule        : ${RULE}"
	logInfoMessage "Task Def    : ${CRON_TASK_DEF_ARN}"
	logInfoMessage "Targets     : ${CURRENT_TARGETS_FILE}"
	logInfoMessage "=========================================="

	UPDATED_TARGETS_FILE="updated-targets-${RULE}.json"

	jq --arg cron_arn "${CRON_TASK_DEF_ARN}" '
		[
		.Targets[0]
		| {
			Id,
			Arn,
			RoleArn,
			Input,
			InputPath,
			InputTransformer,
			RetryPolicy,
			DeadLetterConfig,
			EcsParameters
			}
		| del(.. | nulls)
		| .EcsParameters.TaskDefinitionArn = $cron_arn
		]
	' "${CURRENT_TARGETS_FILE}" > "${UPDATED_TARGETS_FILE}"

        if ! aws events put-targets \
            --rule "${RULE}" \
            --targets "file://${UPDATED_TARGETS_FILE}" \
            > /dev/null; then

            logErrorMessage "Failed to update EventBridge targets for rule: ${RULE}"

            echo "CRON_DEPLOYMENT_STATUS=FAILED" > cron-deployment.env
            exit 1
        fi
		logInfoMessage "update-scheduler PASSED: ${RULE}"
	done
	echo "CRON_DEPLOYMENT_STATUS=SUCCESS" > cron-deployment.env	
	TASK_STATUS=$?

	saveTaskStatus ${TASK_STATUS} ${ACTIVITY_SUB_TASK_CODE}

}


if [[ "${SERVICE}" == "true" || "${SCHEDULER}" == "true" ]]; then
  if [[ "${SERVICE}" == "true" ]]; then
    logInfoMessage "SERVICE is set to 'true', updating services"
    deployecsServices
  else
    logInfoMessage "SERVICE is not set to 'true', skipping services"
  fi

  if [[ "${SCHEDULER}" == "true" ]]; then
    logInfoMessage "SCHEDULER is set to 'true', updating scheduler"
    deploycronServices
	
  else
    logInfoMessage "SCHEDULER is not set to 'true', skipping scheduler"
  fi

else
  logErrorMessage "Neither SERVICE nor SCHEDULER is set to 'true', skipping both ECS & CRON deployment"

  TASK_STATUS=1
  saveTaskStatus ${TASK_STATUS} ${ACTIVITY_SUB_TASK_CODE}
  exit 1
fi
