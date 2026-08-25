terraform {
  cloud {
    organization = "toomhorvath"

    workspaces {
      name = "01-unifi-vm"
    }
  }
}
