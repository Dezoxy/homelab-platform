terraform {
  cloud {
    organization = "toomhorvath"

    workspaces {
      name = "01-edge-lxc"
    }
  }
}
