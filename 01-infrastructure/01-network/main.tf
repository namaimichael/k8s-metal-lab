terraform {
  required_providers {
    maas = {
      source  = "canonical/maas"
      version = "~> 2.0"
    }
  }
}

variable "maas_api_key" {}
variable "maas_url" {}

provider "maas" {
  api_version = "2.0"
  api_key     = var.maas_api_key
  api_url     = var.maas_url
}

resource "maas_subnet" "k8s_subnet" {
  cidr       = "192.168.65.0/24"
  fabric     = "0"
  vlan       = 0
  gateway_ip = "192.168.65.1"
  name       = "k8s-subnet"
}

resource "maas_subnet_ip_range" "dhcp" {
  subnet   = maas_subnet.k8s_subnet.id
  type     = "dynamic"
  start_ip = "192.168.65.150"
  end_ip   = "192.168.65.200"
}

resource "null_resource" "enable_dhcp" {
  provisioner "local-exec" {
    command = <<-EOT
      python3 <<'PYEOF'
import urllib.request, urllib.parse, json, sys, os, time, hmac, hashlib, base64, re
from urllib.error import HTTPError

api_key = os.environ["MAAS_API_KEY"]
maas_url = os.environ["MAAS_URL"].rstrip("/")

consumer_key, token_key, token_secret = api_key.split(":")

def oauth_header(method, url):
    consumer_secret = ""
    ts = str(int(time.time()))
    nonce = base64.b64encode(os.urandom(16)).decode()
    params = {
        "oauth_consumer_key": consumer_key,
        "oauth_token": token_key,
        "oauth_signature_method": "PLAINTEXT",
        "oauth_timestamp": ts,
        "oauth_nonce": nonce,
        "oauth_version": "1.0",
        "oauth_signature": f"{consumer_secret}&{token_secret}",
    }
    header = "OAuth " + ", ".join(f'{k}="{v}"' for k, v in params.items())
    return header

# Get rack controllers
req = urllib.request.Request(f"{maas_url}/api/2.0/rackcontrollers/")
req.add_header("Authorization", oauth_header("GET", req.full_url))
with urllib.request.urlopen(req) as r:
    racks = json.load(r)

if not racks:
    print("ERROR: No rack controllers found")
    sys.exit(1)

primary = racks[0]["system_id"]
print(f"Using rack controller: {primary}")

# Enable DHCP on fabric 0, vlan 0
data = urllib.parse.urlencode({"dhcp_on": "true", "primary_rack": primary}).encode()
req = urllib.request.Request(f"{maas_url}/api/2.0/fabrics/0/vlans/0/", data=data, method="PUT")
req.add_header("Authorization", oauth_header("PUT", req.full_url))
try:
    with urllib.request.urlopen(req) as r:
        result = json.load(r)
        print(f"DHCP enabled: {result.get('dhcp_on')}, primary_rack: {result.get('primary_rack')}")
except HTTPError as e:
    print(f"ERROR: {e.code} {e.read().decode()}")
    sys.exit(1)
PYEOF
    EOT
    environment = {
      MAAS_API_KEY = var.maas_api_key
      MAAS_URL     = var.maas_url
    }
  }

  depends_on = [maas_subnet_ip_range.dhcp]
}

# Keep this to prevent destroy attempts on the default VLAN
resource "maas_vlan" "default" {
  fabric = "0"
  vid    = 0
  # do NOT set dhcp_on here — managed by null_resource above
}