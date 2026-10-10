ui = true

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = true
}

storage "raft" {
  path    = "/vault/data"
  node_id = "vault-1"
}

cluster_addr  = "http://vault:8201"
disable_mlock = true
