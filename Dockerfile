FROM amazon/aws-cli

RUN yum update -y 
RUN yum install jq -y

ENV SLEEP_DURATION 5s

COPY build.sh .
ADD BP-BASE-SHELL-STEPS /opt/buildpiper/shell-functions/

ENTRYPOINT [ "./build.sh" ]
