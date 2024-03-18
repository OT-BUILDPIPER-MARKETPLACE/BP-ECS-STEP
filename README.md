# BP-ECS-STEP
I'll help to deploy new version of application on ECS Cluster

## Setup
* Clone the code available at [BP-ECS-STEP](https://github.com/OT-BUILDPIPER-MARKETPLACE/BP-ECS-STEP)
* Build the docker image

```
git submodule init
git submodule update
docker build -t ot/tf-modules-step:0.1 .
```


* Do local testing via image only

```
# terraform with default(apply, Elasticache)
docker run -it --rm -v $PWD:/src -e WORKSPACE=/src -e CODEBASE_DIR=/ ot/bp-ecs-step:0.0.1

# terraform with plan(Elasticache))
docker run -it --rm -v $PWD:/src  -e INSTRUCTION=plan -e WORKSPACE=/src -e CODEBASE_DIR=/ ot/bp-ecs-step:0.0.1

# debug
docker run -it --rm -v $PWD:/src -e WORKSPACE=/src -e CODEBASE_DIR=/ --entrypoint sh ot/bp-ecs-step:0.0.1

```%