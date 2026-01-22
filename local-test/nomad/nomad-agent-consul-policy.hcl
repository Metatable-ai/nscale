# Policy for Nomad agent to register/deregister services in Consul
agent_prefix "" {
  policy = "read"
}

node_prefix "" {
  policy = "write"
}

service_prefix "" {
  policy = "write"
}

# Required for checking service health
session_prefix "" {
  policy = "write"
}
