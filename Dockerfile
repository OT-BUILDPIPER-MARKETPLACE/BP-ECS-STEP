FROM ubuntu:latest
RUN apt-get update && \
    apt-get install -y \
    bash \
    jq \
    python3 \
    python3-pip && \
    pip3 install --upgrade pip

RUN python3 -m pip install awscli
WORKDIR /app

COPY build.sh .

ADD BP-BASE-SHELL-STEPS /app/buildpiper/shell-functions/
ENV IAM_ROLE_TO_ASSUME=""
ENV VALIDATION_FAILURE_ACTION=WARNING
ENV ACTIVITY_SUB_TASK_CODE=BP-ECS-TASK
ENV TASK_FAMILY=""
ENV REGION=""
ENV IMAGE=""
ENV CLUSTER=""
ENV SLEEP_DURATION=5s

ENTRYPOINT ["./build.sh"]
