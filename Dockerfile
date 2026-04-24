FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    bash \
    jq \
    python3 \
    python3-pip && \
    pip3 install --no-cache-dir --upgrade pip awscli && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY build.sh .
ADD BP-BASE-SHELL-STEPS .

ENV IAM_ROLE_TO_ASSUME=""
ENV VALIDATION_FAILURE_ACTION=WARNING
ENV ACTIVITY_SUB_TASK_CODE=BP-ECS-TASK
ENV TASK_FAMILY=""
ENV REGION=""
ENV IMAGE=""
ENV CLUSTER=""
ENV SLEEP_DURATION="0s"

ENTRYPOINT ["./build.sh"]