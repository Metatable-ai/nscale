node_prefix "" {
  policy = "read"
}

key_prefix "scale-to-zero/" {
  policy = "write"
}

# Read for service discovery, write for potential cleanup of orphaned services
service_prefix "" {
  policy = "write"
}