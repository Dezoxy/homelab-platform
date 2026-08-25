terraform {
  cloud {
    organization = "toomhorvath"

    workspaces {
      name = "01-reverse-proxy-lxc"
    }
  }
}
