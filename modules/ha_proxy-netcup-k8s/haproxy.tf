# The haproxy configuration, pushed over SSH. Not part of the image install, so
# that changing a backend is an ordinary apply rather than a reinstall.

locals {
  # HTTP terminated, so X-Forwarded-For reaches Traefik. HTTPS passed through,
  # so the certificates stay in one place.
  haproxy_config = <<-CFG
    # Managed by OpenTofu - modules/ha_proxy-netcup-k8s. Local edits are overwritten.
    global
        log /dev/log local0
        maxconn 8192
        user haproxy
        group haproxy
        daemon

    defaults
        log     global
        timeout connect 5s
        timeout client  60s
        timeout server  60s
        retries 3

    frontend http_in
        bind :80
        mode http
        option httplog
        option forwardfor
        default_backend ingress_http

    backend ingress_http
        mode http
        balance roundrobin
        # Any HTTP answer means alive; Traefik returns 404 for an unknown Host.
        option httpchk GET /
        http-check expect rstatus ^[234]
    %{~for name, ip in var.http_backends~}
        server ${name} ${ip}:80 check inter 3s fall 2 rise 2
    %{~endfor~}

    frontend https_in
        bind :443
        mode tcp
        option tcplog
        default_backend ingress_https

    backend ingress_https
        mode tcp
        balance roundrobin
    %{~for name, ip in var.http_backends~}
        server ${name} ${ip}:443 check inter 3s fall 2 rise 2
    %{~endfor~}
    %{if length(var.api_backends) > 0}
    # TLS hello, not "httpchk GET /readyz": Talos disables anonymous auth, so
    # /readyz answers 401 and haproxy marks the whole control plane DOWN.
    frontend api_in
        bind :${var.api_port}
        mode tcp
        option tcplog
        default_backend kube_api

    backend kube_api
        mode tcp
        balance roundrobin
        option ssl-hello-chk
    %{~for name, ip in var.api_backends~}
        server ${name} ${ip}:${var.api_port} check inter 3s fall 2 rise 2
    %{~endfor~}
    %{~endif}
  CFG
}

locals {
  # haproxy refuses a file whose last line has no LF, and template directives
  # strip trailing whitespace.
  haproxy_config_file = "${trimsuffix(local.haproxy_config, "\n")}\n"
}

resource "terraform_data" "config" {
  triggers_replace = {
    config = sha256(local.haproxy_config_file)
  }

  connection {
    type        = "ssh"
    host        = local.ip
    user        = "root"
    private_key = var.ssh_private_key_path == "" ? null : file(pathexpand(var.ssh_private_key_path))
    agent       = var.ssh_private_key_path == ""
    # The install reboots before sshd comes up.
    timeout = "15m"
  }

  provisioner "file" {
    content     = local.haproxy_config_file
    destination = "/etc/haproxy/haproxy.cfg.new"
  }

  provisioner "remote-exec" {
    inline = [
      # Validate before replacing the running config.
      "set -eu",
      "haproxy -c -f /etc/haproxy/haproxy.cfg.new",
      "mv /etc/haproxy/haproxy.cfg.new /etc/haproxy/haproxy.cfg",
      "systemctl reload haproxy || systemctl restart haproxy",
      "systemctl is-active haproxy",
    ]
  }

  depends_on = [netcup_scp_server_action.install]
}
