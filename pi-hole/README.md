# pi-hole Setup Instructions

### Image Raspberry Pi OS onto Raspberry Pi

1. Download Raspberry Pi Imager from https://www.raspberrypi.com/software/.
2. Insert Micro SD Card into system.
3. Launch Raspberry Pi Imager:
   1. Choose Device: select your Pi device from the options.
   2. Choose OS: select _Raspberry Pi OS (other)_, and then select _Raspberry Pi OS Lite_.
   3. Choose Storage: select your Micro SD Card.
4. Press Ctrl+Shift+X or Cmd+Shift+X to open the _OS Customization_ window. 
   1. General: set a name for the Pi, choose a username and password, configure WLAN if needed, and choose your locale. 
   2. Services: enable SSH.
   3. Options: eject media when finished, disable telemetry.
5. Click _Save_ to close the _OS Customization_ window.
6. Click _Next_ in the the Raspberry Pi Imager to image Raspberry Pi OS onto the Micro SD Card with the OS customizations.

### Setup dnsproxy-crypt as DNS proxy

Refer to [dnscrypt-proxy/README.md](../dnscrypt-proxy/README.md).

### Install pi-hole

> ⚠️ Before you proceed, ensure the Raspberry Pi has a static IP.

Per https://github.com/pi-hole/pi-hole/#one-step-automated-install:
```
curl -sSL https://install.pi-hole.net | sudo bash
```

When prompted for various configuration options:
1. For the most part, use the default setting.
2. When prompted for DNS upstream servers (e.g., Google, Cloudflare):
   1. Choose _Custom_
   2. Enter value:
      > 127.0.0.1#5053

After installation completes:
1. Write down admin interface password.
2. Using another system on the same network as the Raspberry Pi:
   1. Navigate your browser to http://<pi-IP>/admin
   2. Navigate to Settings > DNS > Interface settings
      1. Under _Recommended setting_, uncheck _Allow only local requests_
      2. Under _Potentially dangerous options_, select _Respond only on interface <iface>_ (for example, iface=eth0)
