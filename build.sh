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

sleep "$SLEEP_DURATION"

cd "${CODEBASE_LOCATION}";

TASK_STATUS=0

DEPLOY_ENV_FILE="./deploy.env"



setupAwsCredentials() {

    logInfoMessage "=== Setting up AWS credentials ==="

    add_event "AWS_CREDENTIAL_SETUP" "STARTED" "AWS_CREDENTIAL_SETUP_STARTED" "Starting AWS credentials setup"

    if [ "${ASSUME_ROLE:-false}" == "true" ]; then

        add_event "AWS_CREDENTIAL_SETUP" "STARTED" "AWS_ROLE_ASSUMPTION_STARTED" "Starting AWS IAM role assumption"

        if [ -z "${ACCOUNT_ID:-}" ] || [ -z "${ROLE_NAME:-}" ]; then

            logErrorMessage "ACCOUNT_ID and ROLE_NAME must be set when ASSUME_ROLE=true"
            add_event "AWS_CREDENTIAL_SETUP" "FAILED" "AWS_ROLE_CONFIGURATION_INVALID" "ACCOUNT_ID and ROLE_NAME must be set when ASSUME_ROLE=true"
            exit 1
        fi

        ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

        logInfoMessage "Assuming AWS IAM role: ${ROLE_ARN}"

        if ! getAssumeRole "$ROLE_ARN"; then

            logErrorMessage "Failed to assume AWS IAM role: ${ROLE_ARN}"
            add_event "AWS_CREDENTIAL_SETUP" "FAILED" "AWS_ROLE_ASSUMPTION_FAILED" "Failed to assume AWS IAM role"
            exit 1
        fi

        add_event "AWS_CREDENTIAL_SETUP" "SUCCESS" "AWS_ROLE_ASSUMPTION_SUCCESS" "AWS IAM role assumed successfully"

    else

        logInfoMessage "ASSUME_ROLE is not set to 'true', using AWS profile"

        add_event "AWS_CREDENTIAL_SETUP" "STARTED" "AWS_PROFILE_AUTHENTICATION_STARTED" "Starting AWS profile based authentication"

        if [ -z "${AWS_PROFILE:-}" ]; then

            logErrorMessage "AWS_PROFILE must be set when ASSUME_ROLE=false"
            add_event "AWS_CREDENTIAL_SETUP" "FAILED" "AWS_PROFILE_MISSING" "AWS_PROFILE must be set when ASSUME_ROLE=false"
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

        add_event "AWS_CREDENTIAL_SETUP" "SUCCESS" "AWS_PROFILE_CREDENTIALS_LOADED" "AWS credentials loaded successfully from configured AWS profile"

    fi

    if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then

        logErrorMessage "AWS_ACCESS_KEY_ID is not set"
        add_event "AWS_CREDENTIAL_SETUP" "FAILED" "AWS_ACCESS_KEY_ID_MISSING" "AWS_ACCESS_KEY_ID is not set"
        exit 1
    fi

    if [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then

        logErrorMessage "AWS_SECRET_ACCESS_KEY is not set"
        add_event "AWS_CREDENTIAL_SETUP" "FAILED" "AWS_SECRET_ACCESS_KEY_MISSING" "AWS_SECRET_ACCESS_KEY is not set"
        exit 1
    fi

    if [ -z "${AWS_REGION:-}" ]; then

        logErrorMessage "AWS_REGION is not set"
        add_event "AWS_CREDENTIAL_SETUP" "FAILED" "AWS_REGION_MISSING" "AWS_REGION is not set"
        exit 1
    fi

    add_event "AWS_AUTHENTICATION" "STARTED" "AWS_AUTHENTICATION_STARTED" "Validating AWS authentication using STS"

    if ! AWS_IDENTITY=$(aws sts get-caller-identity 2>/tmp/aws_error.log); then

        logErrorMessage "AWS authentication failed"
        cat /tmp/aws_error.log
        add_event "AWS_AUTHENTICATION" "FAILED" "AWS_AUTHENTICATION_FAILED" "AWS authentication failed during STS get-caller-identity validation"
        exit 1
    fi


    AWS_ACCOUNT_ID=$(echo "$AWS_IDENTITY" | jq -r '.Account')
    AWS_ARN=$(echo "$AWS_IDENTITY" | jq -r '.Arn')

    logInfoMessage "AWS authentication successful"
    logInfoMessage "AWS Account ID: ${AWS_ACCOUNT_ID}"
    logInfoMessage "AWS Region: ${AWS_REGION}"
    logInfoMessage "AWS ARN: ${AWS_ARN}"

    add_event "AWS_AUTHENTICATION" "SUCCESS" "AWS_AUTHENTICATION_SUCCESS" "AWS credentials configured and authentication successful"
    logInfoMessage "=== AWS credentials setup completed ==="
}

if [[ "${ASSUME_ROLE:-false}" == "true" || -n "${AWS_PROFILE:-}" ]]; then

    add_event "AWS_CREDENTIAL_SETUP_FUNCTION" "STARTED" "AWS_CREDENTIAL_SETUP_FUNCTION_STARTED" "AWS credentials setup function execution started"
    if setupAwsCredentials; then
        add_event "AWS_CREDENTIAL_SETUP_FUNCTION" "SUCCESS" "AWS_CREDENTIAL_SETUP_FUNCTION_COMPLETED" "AWS credentials setup function completed successfully"

    else
        add_event "AWS_CREDENTIAL_SETUP_FUNCTION" "FAILED" "AWS_CREDENTIAL_SETUP_FUNCTION_FAILED" "AWS credentials setup function failed"
        exit 1
    fi

else

    logInfoMessage "Neither ASSUME_ROLE=true nor AWS_PROFILE is set, skipping AWS credential setup"
    add_event "AWS_CREDENTIAL_SETUP_FUNCTION" "SKIPPED" "AWS_CREDENTIAL_SETUP_SKIPPED" "AWS credential setup skipped because neither ASSUME_ROLE=true nor AWS_PROFILE is set"
fi


add_event "DEPLOY_ENV_VALIDATION" "STARTED" "DEPLOY_ENV_VALIDATION_STARTED" "Validating deployment environment file: ${DEPLOY_ENV_FILE}"

if [ ! -f "$DEPLOY_ENV_FILE" ]; then

    logErrorMessage "File not found: $DEPLOY_ENV_FILE"
    add_event "DEPLOY_ENV_VALIDATION" "FAILED" "DEPLOY_ENV_FILE_NOT_FOUND" "Deployment environment file not found: ${DEPLOY_ENV_FILE}"
    exit 1
fi


if ! source "$DEPLOY_ENV_FILE"; then

    logErrorMessage "Failed to source deployment environment file: ${DEPLOY_ENV_FILE}"
    add_event "DEPLOY_ENV_VALIDATION" "FAILED" "DEPLOY_ENV_FILE_SOURCE_FAILED" "Failed to source deployment environment file: ${DEPLOY_ENV_FILE}"
    exit 1
fi


add_event "DEPLOY_ENV_VALIDATION" "SUCCESS" "DEPLOY_ENV_VALIDATED" "Deployment environment file validated and loaded successfully"

markDeploymentMutated() {

  add_event "DEPLOYMENT_MUTATION" "STARTED" "DEPLOYMENT_MUTATION_STARTED" "Marking deployment as mutated"

  if ! printf '%s\n' "DEPLOY_MUTATED=true" > mutation.env; then

    logErrorMessage "Failed to create mutation.env"
    add_event "DEPLOYMENT_MUTATION" "FAILED" "MUTATION_ENV_WRITE_FAILED" "Failed to write DEPLOY_MUTATED=true to mutation.env"
    return 1
  fi


  if ! grep -v '^DEPLOY_MUTATED=' deploy.env > deploy.env.tmp; then
    true
  fi

  if ! printf '%s\n' "DEPLOY_MUTATED=true" >> deploy.env.tmp; then

    logErrorMessage "Failed to update deploy.env"
    rm -f deploy.env.tmp
    add_event "DEPLOYMENT_MUTATION" "FAILED" "DEPLOY_ENV_UPDATE_FAILED" "Failed to update deploy.env with DEPLOY_MUTATED=true"
    return 1
  fi


  if ! mv deploy.env.tmp deploy.env; then

    logErrorMessage "Failed to replace deploy.env"
    add_event "DEPLOYMENT_MUTATION" "FAILED" "DEPLOY_ENV_REPLACE_FAILED" "Failed to replace deploy.env after marking deployment as mutated"
    return 1
  fi


  logInfoMessage "Marked deployment as mutated in mutation.env and deploy.env"
  add_event "DEPLOYMENT_MUTATION" "SUCCESS" "DEPLOYMENT_MARKED_MUTATED" "Deployment marked as mutated successfully"
  return 0
}

deployecsServices() {

  add_event "ECS_SERVICE_DEPLOYMENT" "STARTED" "ECS_SERVICE_DEPLOYMENT_STARTED" "ECS service deployment started"

  if [ -z "${SERVICES:-}" ]; then

    logErrorMessage "Empty service name found in SERVICES='${SERVICES}'"
    add_event "ECS_SERVICE_DEPLOYMENT" "FAILED" "ECS_SERVICES_EMPTY" "SERVICES is empty"
    return 1
  fi


  IFS=',' read -ra SERVICE_LIST <<< "$SERVICES"


  for SERVICE in "${SERVICE_LIST[@]}"; do

    SERVICE="$(echo "$SERVICE" | xargs)"

    if [ -z "$SERVICE" ]; then

        logErrorMessage "Empty service name found"
        add_event "ECS_SERVICE_DEPLOYMENT" "FAILED" "ECS_SERVICE_NAME_EMPTY" "Empty service name found in SERVICES"
        return 1
    fi

    SERVICE_UPPER="$(echo "$SERVICE" | tr '[:lower:]-' '[:upper:]_')"

    TASK_DEF_VAR="${SERVICE_UPPER}_TASK_DEF_ARN"

    if [ -z "${!TASK_DEF_VAR:-}" ]; then

        logErrorMessage "${TASK_DEF_VAR} is not set in $DEPLOY_ENV_FILE"
        add_event "ECS_SERVICE_DEPLOYMENT" "FAILED" "TASK_DEFINITION_ARN_MISSING" "${TASK_DEF_VAR} is not set for service: ${SERVICE}"
        return 1
    fi


    TASK_DEF_ARN="${!TASK_DEF_VAR}"
    add_event "ECS_SERVICE_DEPLOYMENT" "STARTED" "SERVICE_DEPLOYMENT_STARTED" "Deployment started for service: ${SERVICE}"

    logInfoMessage "=========================================="
    logInfoMessage "Deployment started: $SERVICE"
    logInfoMessage "=========================================="

    logInfoMessage "Checking service: $SERVICE"
    logInfoMessage "Expected variable: $TASK_DEF_VAR"


    if [ -z "$TASK_DEF_ARN" ]; then

        logErrorMessage "Task definition ARN not found for service: $SERVICE"
        add_event "ECS_SERVICE_DEPLOYMENT" "FAILED" "TASK_DEFINITION_ARN_EMPTY" "Task definition ARN not found for service: ${SERVICE}"
        return 1
    fi


    logInfoMessage "Task Definition ARN found:"
    logInfoMessage "$TASK_DEF_ARN"

    logInfoMessage "=========================================="
    logInfoMessage "Deploying service : ${SERVICE}"
    logInfoMessage "Task Definition   : ${TASK_DEF_ARN}"
    logInfoMessage "=========================================="

    add_event "ECS_SERVICE_UPDATE" "STARTED" "ECS_SERVICE_UPDATE_STARTED" "Updating ECS service: ${SERVICE}"

    if ! aws ecs update-service \
        --cluster "${ECS_CLUSTER}" \
        --service "${SERVICE}" \
        --task-definition "${TASK_DEF_ARN}" \
        --force-new-deployment > /dev/null; then

        logErrorMessage "Failed to update ECS service: ${SERVICE}"
        add_event "ECS_SERVICE_UPDATE" "FAILED" "ECS_SERVICE_UPDATE_FAILED" "Failed to update ECS service: ${SERVICE}"
        echo "DEPLOYMENT_STATUS=FAILED" > deployment.env
        logInfoMessage "Deployment status as FAILED stored in deployment.env"
        return 1
    fi


    add_event "ECS_SERVICE_UPDATE" "SUCCESS" "ECS_SERVICE_UPDATE_SUCCESS" "ECS service updated successfully: ${SERVICE}"

    if [[ "${MUTATION:-false}" == "true" ]]; then

        logInfoMessage "Marking mutation in mutation.env"

        if ! markDeploymentMutated; then
            add_event "DEPLOYMENT_MUTATION" "FAILED" "DEPLOYMENT_MUTATION_FAILED" "Failed to mark deployment as mutated for service: ${SERVICE}"
            return 1
        fi

    else

        logWarningMessage "MUTATION is not set to 'true', skipping mutation marking"
        add_event "DEPLOYMENT_MUTATION" "SKIPPED" "DEPLOYMENT_MUTATION_SKIPPED" "Mutation marking skipped because MUTATION is not true"
    fi

    if [[ "${WAIT:-false}" == "true" ]]; then

        logInfoMessage "Waiting for service stability: ${SERVICE}"

        add_event "ECS_SERVICE_STABILITY" "STARTED" "ECS_SERVICE_STABILITY_WAIT_STARTED" "Waiting for ECS service stability: ${SERVICE}"


        if ! aws ecs wait services-stable \
            --cluster "${ECS_CLUSTER}" \
            --services "${SERVICE}"; then

            logErrorMessage "ECS service failed to become stable: ${SERVICE}"

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
            logInfoMessage "Deployment status as FAILED stored in deployment.env"

            add_event "ECS_SERVICE_STABILITY" "FAILED" "ECS_SERVICE_STABILITY_FAILED" "ECS service did not become stable: ${SERVICE}"
            add_event "ECS_SERVICE_DEPLOYMENT" "FAILED" "SERVICE_DEPLOYMENT_FAILED" "Deployment failed because ECS service did not become stable: ${SERVICE}"
            return 1
        fi

        logInfoMessage "Service stable: ${SERVICE}"
        add_event "ECS_SERVICE_STABILITY" "SUCCESS" "ECS_SERVICE_STABLE" "ECS service became stable successfully: ${SERVICE}"

    else

        logWarningMessage "WAIT is not set to 'true', skipping wait for service stability"
        add_event "ECS_SERVICE_STABILITY" "SKIPPED" "ECS_SERVICE_STABILITY_WAIT_SKIPPED" "ECS service stability wait skipped because WAIT is not true for service: ${SERVICE}"
    fi


    add_event "ECS_SERVICE_DEPLOYMENT" "SUCCESS" "SERVICE_DEPLOYMENT_SUCCESS" "Deployment completed successfully for service: ${SERVICE}"

  done

  echo "DEPLOYMENT_STATUS=SUCCESS" > deployment.env
  logInfoMessage "ECS Deployment status as SUCCESS stored in deployment.env"

  add_event "ECS_SERVICE_DEPLOYMENT" "SUCCESS" "ECS_SERVICE_DEPLOYMENT_COMPLETED" "All ECS services deployed successfully"
  return 0
}

deploycronServices() {

    add_event "SCHEDULER_DEPLOYMENT" "STARTED" "SCHEDULER_DEPLOYMENT_STARTED" "EventBridge scheduler deployment started"


    if [ -z "${SCHEDULER_RULES:-}" ]; then

        logErrorMessage "SCHEDULER_RULES is empty"
        add_event "SCHEDULER_DEPLOYMENT" "FAILED" "SCHEDULER_RULES_EMPTY" "SCHEDULER_RULES is empty"
        return 1
    fi


    IFS=',' read -ra SCHEDULER_LIST <<< "${SCHEDULER_RULES}"

    for RULE in "${SCHEDULER_LIST[@]}"; do

        RULE="$(echo "${RULE}" | xargs)"
        [ -z "${RULE}" ] && continue
        SCHEDULER_NAME="${RULE}"
        SCHEDULER_UPPER="$(echo "${SCHEDULER_NAME}" |tr '[:lower:]-' '[:upper:]_')"

        TASK_DEF_VAR="PREVIOUS_${SCHEDULER_UPPER}_TASK_DEF"
        NEW_TASK_DEF_VAR="${SCHEDULER_UPPER}_TASK_DEF_ARN"


        if [ -z "${!NEW_TASK_DEF_VAR:-}" ]; then

            logErrorMessage "${NEW_TASK_DEF_VAR} is not set in $DEPLOY_ENV_FILE"
            add_event "SCHEDULER_DEPLOYMENT" "FAILED" "SCHEDULER_TASK_DEFINITION_MISSING" "${NEW_TASK_DEF_VAR} is not set for scheduler rule: ${RULE}"
            return 1
        fi


        CRON_TASK_DEF_ARN="${!NEW_TASK_DEF_VAR}"

        CURRENT_TARGETS_FILE="current-targets-${RULE}.json"
        CURRENT_TARGETS_ARRAY_FILE="current-targets-array-${RULE}.json"


        if [ ! -f "${CURRENT_TARGETS_FILE}" ]; then
            logErrorMessage "Current targets file ${CURRENT_TARGETS_FILE} missing for rule ${RULE}"
            add_event "SCHEDULER_TARGET_VALIDATION" "FAILED" "CURRENT_TARGETS_FILE_MISSING" "Current targets file missing for scheduler rule: ${RULE}"
            return 1
        fi


        if [ ! -f "${CURRENT_TARGETS_ARRAY_FILE}" ]; then

            logErrorMessage "Current targets array file ${CURRENT_TARGETS_ARRAY_FILE} missing for rule ${RULE}"
            add_event "SCHEDULER_TARGET_VALIDATION" "FAILED" "CURRENT_TARGETS_ARRAY_FILE_MISSING" "Current targets array file missing for scheduler rule: ${RULE}"
            return 1
        fi


        add_event "SCHEDULER_TARGET_VALIDATION" "SUCCESS" "SCHEDULER_TARGET_FILES_VALID" "Current scheduler target files validated for rule: ${RULE}"


        logInfoMessage "=========================================="
        logInfoMessage "Updating EventBridge rule"
        logInfoMessage "Rule        : ${RULE}"
        logInfoMessage "Task Def    : ${CRON_TASK_DEF_ARN}"
        logInfoMessage "Targets     : ${CURRENT_TARGETS_FILE}"
        logInfoMessage "=========================================="


        UPDATED_TARGETS_FILE="updated-targets-${RULE}.json"

        add_event "SCHEDULER_TARGET_UPDATE" "STARTED" "SCHEDULER_TARGET_UPDATE_STARTED" "Preparing updated EventBridge target for rule: ${RULE}"


        if ! jq --arg cron_arn "${CRON_TASK_DEF_ARN}" '
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
          ' "${CURRENT_TARGETS_FILE}" > "${UPDATED_TARGETS_FILE}"; then

            logErrorMessage "Failed to generate updated targets file for rule: ${RULE}"
            add_event "SCHEDULER_TARGET_UPDATE" "FAILED" "UPDATED_TARGET_FILE_GENERATION_FAILED" "Failed to generate updated targets file for rule: ${RULE}"
            return 1
        fi


        add_event "SCHEDULER_TARGET_UPDATE" "SUCCESS" "UPDATED_TARGET_FILE_GENERATED" "Updated EventBridge target file generated for rule: ${RULE}"

        add_event "EVENTBRIDGE_TARGET_UPDATE" "STARTED" "EVENTBRIDGE_TARGET_UPDATE_STARTED" "Updating EventBridge targets for rule: ${RULE}"


        if ! aws events put-targets \
            --rule "${RULE}" \
            --targets "file://${UPDATED_TARGETS_FILE}" \
            > /dev/null; then

            logErrorMessage "Failed to update EventBridge targets for rule: ${RULE}"

            echo "CRON_DEPLOYMENT_STATUS=FAILED" > cron-deployment.env
            logInfoMessage "CRON Deployment status as FAILED stored in cron-deployment.env"

            add_event "EVENTBRIDGE_TARGET_UPDATE" "FAILED" "EVENTBRIDGE_TARGET_UPDATE_FAILED" "Failed to update EventBridge targets for rule: ${RULE}"
            add_event "SCHEDULER_DEPLOYMENT" "FAILED" "SCHEDULER_RULE_DEPLOYMENT_FAILED" "Scheduler deployment failed for rule: ${RULE}"

            return 1
        fi


        logInfoMessage "update-scheduler PASSED: ${RULE}"
        add_event "EVENTBRIDGE_TARGET_UPDATE" "SUCCESS" "EVENTBRIDGE_TARGET_UPDATE_SUCCESS" "EventBridge targets updated successfully for rule: ${RULE}"
        add_event "SCHEDULER_DEPLOYMENT" "SUCCESS" "SCHEDULER_RULE_DEPLOYMENT_SUCCESS" "Scheduler deployment completed successfully for rule: ${RULE}"

    done


    echo "CRON_DEPLOYMENT_STATUS=SUCCESS" > cron-deployment.env
    logInfoMessage "CRON Deployment status as SUCCESS stored in cron-deployment.env"
    add_event "SCHEDULER_DEPLOYMENT" "SUCCESS" "SCHEDULER_DEPLOYMENT_COMPLETED" "All EventBridge scheduler rules deployed successfully"

    return 0
}


if [[ "${SERVICE:-false}" == "true" || "${SCHEDULER:-false}" == "true" ]]; then

    if [[ "${SERVICE:-false}" == "true" ]]; then

        logInfoMessage "SERVICE is set to 'true', updating services"

        if ! deployecsServices; then

            TASK_STATUS=1
            saveTaskStatus ${TASK_STATUS} ${ACTIVITY_SUB_TASK_CODE}
            add_event "DEPLOYMENT_EXECUTION" "FAILED" "ECS_SERVICE_DEPLOYMENT_FAILED" "ECS service deployment failed"
            exit 1
        fi

    else

        logInfoMessage "SERVICE is not set to 'true', skipping services"
        add_event "ECS_SERVICE_DEPLOYMENT" "SKIPPED" "ECS_SERVICE_DEPLOYMENT_SKIPPED" "ECS service deployment skipped because SERVICE is not true"
    fi


    if [[ "${SCHEDULER:-false}" == "true" ]]; then

        logInfoMessage "SCHEDULER is set to 'true', updating scheduler"

        if ! deploycronServices; then

            TASK_STATUS=1
            saveTaskStatus ${TASK_STATUS} ${ACTIVITY_SUB_TASK_CODE}
            add_event "DEPLOYMENT_EXECUTION" "FAILED" "SCHEDULER_DEPLOYMENT_FAILED" "Scheduler deployment failed"
            exit 1
        fi

    else

        logInfoMessage "SCHEDULER is not set to 'true', skipping scheduler"
        add_event "SCHEDULER_DEPLOYMENT" "SKIPPED" "SCHEDULER_DEPLOYMENT_SKIPPED" "Scheduler deployment skipped because SCHEDULER is not true"
    fi
else

    logErrorMessage "Neither SERVICE nor SCHEDULER is set to 'true', skipping both ECS & CRON deployment"
    TASK_STATUS=1
    saveTaskStatus ${TASK_STATUS} ${ACTIVITY_SUB_TASK_CODE}
    add_event "DEPLOYMENT_EXECUTION" "FAILED" "DEPLOYMENT_COMPONENTS_DISABLED" "Neither SERVICE nor SCHEDULER is set to true; ECS and scheduler deployment skipped"

    exit 1

fi

TASK_STATUS=$?
saveTaskStatus ${TASK_STATUS} ${ACTIVITY_SUB_TASK_CODE}
