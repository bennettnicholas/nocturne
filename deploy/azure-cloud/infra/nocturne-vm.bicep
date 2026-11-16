// Nocturne on a single Azure Linux VM.
//
// Only this file is Azure-specific. On first boot the VM downloads Nocturne's released install
// script (the one the install script guide uses) and runs it. That script installs Docker and the
// Docker Compose release, keeps itself on the server as nocturne-up with a systemd unit, and waits
// for DNS before it starts Nocturne.
//
// Deployed by Deploy-NocturneAzure.ps1 or deploy-nocturne-azure.sh. Everything lives in one
// resource group.

@description('Azure region. Defaults to the resource group\'s region.')
param location string = resourceGroup().location

@description('Short name used for every resource (letters, digits, hyphens).')
@maxLength(20)
param name string = 'nocturne'

@description('VM size. Nocturne needs 2 GB RAM minimum, 4 GB recommended. Default: the cheapest 4 GB size in most regions.')
param vmSize string = 'Standard_B2als_v2'

@description('Ubuntu 24.04 image SKU: "server" for x64 sizes, "server-arm64" for Arm sizes (e.g. Standard_B2ps_v2).')
@allowed([ 'server', 'server-arm64' ])
param imageSku string = 'server'

@description('Use Trusted Launch (secure boot + vTPM). The deploy script turns it off for sizes that do not support it.')
param trustedLaunch bool = true

@description('OS disk size in GB (images ~2.5 GB, data well under 1 GB per CGM per year). 32 GB is the smallest Standard SSD tier.')
param osDiskSizeGb int = 32

@description('Linux admin user name.')
param adminUsername string = 'nocturne'

@description('SSH public key for the admin user (password sign-in is disabled).')
param sshPublicKey string

@description('Public IPv4 address allowed to SSH in (CIDR, e.g. 203.0.113.7/32).')
param sshAllowedCidr string

@description('The domain Nocturne answers on, e.g. nocturne.example.com or yourname.duckdns.org. It and *.domain must point at the VM.')
param domain string

@description('The install script to run on first boot. The default is the latest release.')
param installScriptUrl string = 'https://github.com/nightscout/nocturne/releases/latest/download/install.sh'

@secure()
@description('INSTANCE_KEY: 32+ characters. Losing it makes stored connector secrets unreadable.')
param instanceKey string

@secure()
param postgresPassword string

@secure()
param postgresAppPassword string

@secure()
param postgresMigratorPassword string

@secure()
param postgresWebPassword string

// The VM's free Azure DNS name, <name>-<hash>.<region>.cloudapp.azure.com, is its SSH address.
// Nocturne itself needs a domain with a wildcard record, which Azure names cannot have.
var dnsLabel = toLower('${name}-${uniqueString(resourceGroup().id)}')
var azureFqdn = '${dnsLabel}.${location}.cloudapp.azure.com'

// The passwords the deploy script generated, and keeps a copy of. The install script only fills in
// settings that are blank, so it keeps these.
var envSeed = 'BASE_DOMAIN=${domain}\nINSTANCE_KEY=${instanceKey}\nPOSTGRES_PASSWORD=${postgresPassword}\nPOSTGRES_APP_PASSWORD=${postgresAppPassword}\nPOSTGRES_MIGRATOR_PASSWORD=${postgresMigratorPassword}\nPOSTGRES_WEB_PASSWORD=${postgresWebPassword}\n'

// First-boot script (cloud-init runs custom data that starts with #!). It writes .env readable by
// root only, downloads the install script and runs it. The deploy script follows the log until
// NOCTURNE_INSTALL_DONE. The instance key is never written to the log.
// replace('\r', '') keeps it valid bash even if this file is saved with Windows line endings.
var bootScript = replace(replace(replace(replace('''#!/bin/bash
set -uo pipefail
exec >> /var/log/nocturne-install.log 2>&1
mkdir -p /opt/nocturne
chmod 700 /opt/nocturne
umask 077
[ -f /opt/nocturne/.env ] || echo '__ENV_B64__' | base64 -d > /opt/nocturne/.env
key=$(sed -n 's/^INSTANCE_KEY=//p' /opt/nocturne/.env)
# A new VM can be without a route to the internet for its first minutes.
for try in $(seq 1 40); do
  curl -fsSL -o /opt/nocturne/install.sh '__INSTALL_URL__' && bash -n /opt/nocturne/install.sh && break
  rm -f /opt/nocturne/install.sh
  echo "could not download the install script (attempt $try); retrying in 15s"
  sleep 15
done
[ -f /opt/nocturne/install.sh ] || { echo 'NOCTURNE_INSTALL_FAILED: could not download the install script'; exit 1; }
BASE_DOMAIN='__DOMAIN__' DNS_WAIT_MINUTES=10 bash /opt/nocturne/install.sh < /dev/null 2>&1 \
  | sed -u "s/$key/[instance key: see your secrets file]/g"
status=${PIPESTATUS[0]}
if [ "$status" = 0 ]; then echo NOCTURNE_INSTALL_DONE; else echo "NOCTURNE_INSTALL_FAILED: install.sh exited with $status"; fi
''', '\r', ''), '__ENV_B64__', base64(envSeed)), '__INSTALL_URL__', installScriptUrl), '__DOMAIN__', domain)

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${name}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'ssh-from-admin'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: sshAllowedCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        // Caddy: HTTP-01 certificate challenges and the redirect to HTTPS.
        name: 'http'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'https'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        // HTTP/3 (QUIC), which Caddy also serves.
        name: 'https-quic'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${name}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.20.0.0/16' ] }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.20.0.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${name}-ip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'   // stays the same across VM restarts, so DNS never goes stale
    dnsSettings: { domainNameLabel: dnsLabel }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${name}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: vnet.properties.subnets[0].id }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: publicIp.id }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: '${name}-vm'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      customData: base64(bootScript)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: imageSku
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: osDiskSizeGb
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
        deleteOption: 'Delete'
      }
    }
    // Trusted Launch (secure boot + vTPM) where the size supports it; never on Arm64.
    securityProfile: (trustedLaunch && imageSku == 'server') ? {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    } : null
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
    diagnosticsProfile: {
      bootDiagnostics: { enabled: true }   // managed storage: lets you see the boot log in the portal
    }
  }
}

output baseDomain string = domain
output azureFqdn string = azureFqdn
output publicIpAddress string = publicIp.properties.ipAddress
output vmName string = vm.name
output adminUsername string = adminUsername
