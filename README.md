# aio-agent

Runtime repository for the `aio-agent` stack.

It contains the Docker Compose layout, nginx routing, published metrics endpoints, and the public certificate material required by the agent instance.

For private local-only materials such as Prometheus client certificates and CA private keys, use `volumes/certs-private/metrics/`.
