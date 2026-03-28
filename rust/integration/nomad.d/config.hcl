consul {
  address = "consul:8500"
}

client {
  cpu_total_compute = 4000

  options = {
    "driver.docker.enable" = "1"
  }
}
