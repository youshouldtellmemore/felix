# DNS Proxy Service

Raspberry Pi OS apt repository does not include dnsproxy-crypt so it must be installed and upgraded manually.

# Install dnsproxy-crypt

Download and run the automation script [install-dnscrypt-proxy.sh](install-dnscrypt-proxy.sh).

```shell
wget https://raw.githubusercontent.com/youshouldtellmemore/felix/refs/heads/main/dnscrypt-proxy/install-dnscrypt-proxy.sh
chmod +x install-dnscrypt-proxy.sh
./install-dnscrypt-proxy.sh
```

The resolver is installed and configured to listen on 127.0.0.1:5053 to provide DoH to Cloudflare with DNSSEC enforcement.
