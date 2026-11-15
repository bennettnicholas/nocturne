// Nocturne on a single Azure Linux VM.
//
// Only this file is Azure-specific. On first boot the VM runs ../install-nocturne.sh, the
// cloud-agnostic installer, which is embedded in the VM's custom data (so nothing needs to be
// hosted anywhere) and runs Nocturne's official Docker Compose release bundle.
//
// Deployed by Deploy-NocturneAzure.ps1. Everything lives in one resource group.

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

@description('Your own domain (e.g. nocturne.example.com). Empty = use the free Azure DNS name.')
param customDomain string = ''

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

@description('API image to run instead of the release\'s, e.g. a branch build. Empty = the release\'s. Give with webImage.')
param apiImage string = ''

@description('Web image to run instead of the release\'s. Empty = the release\'s. Give with apiImage.')
param webImage string = ''

var imageArgs = empty(apiImage) ? '' : ' --api-image ${apiImage} --web-image ${webImage}'

// Free Azure DNS name: <name>-<hash>.<region>.cloudapp.azure.com. The hash is stable per resource
// group, so re-deploying keeps the same address (and the same Let's Encrypt certificate).
var dnsLabel = toLower('${name}-${uniqueString(resourceGroup().id)}')
var azureFqdn = '${dnsLabel}.${location}.cloudapp.azure.com'
var baseDomain = empty(customDomain) ? azureFqdn : customDomain

// The secrets the installer reads with --secrets-file.
var secretsEnv = 'BASE_DOMAIN=${baseDomain}\nINSTANCE_KEY=${instanceKey}\nPOSTGRES_PASSWORD=${postgresPassword}\nPOSTGRES_APP_PASSWORD=${postgresAppPassword}\nPOSTGRES_MIGRATOR_PASSWORD=${postgresMigratorPassword}\nPOSTGRES_WEB_PASSWORD=${postgresWebPassword}\n'

// First-boot script (cloud-init runs custom data that starts with #!). It saves the installer
// to /opt/nocturne so it can be re-run later, writes the secrets readable by root only, and runs
// the installer, which deletes the secrets file once .env exists.
// replace('\r', '') keeps it valid bash even if this file is saved with Windows line endings.
var bootScript = replace(replace(replace(replace('''#!/bin/bash
set -euo pipefail
mkdir -p /opt/nocturne
chmod 700 /opt/nocturne
umask 077
echo '__INSTALLER_B64__' | base64 -d > /opt/nocturne/install-nocturne.sh
echo '__SECRETS_B64__' | base64 -d > /opt/nocturne/secrets.env
chmod 700 /opt/nocturne/install-nocturne.sh
/opt/nocturne/install-nocturne.sh --secrets-file /opt/nocturne/secrets.env --remove-secrets-file__IMAGE_ARGS__
''', '\r', ''), '__INSTALLER_B64__', loadFileAsBase64('../install-nocturne.sh')), '__SECRETS_B64__', base64(secretsEnv)), '__IMAGE_ARGS__', imageArgs)

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

output baseDomain string = baseDomain
output azureFqdn string = azureFqdn
output publicIpAddress string = publicIp.properties.ipAddress
output vmName string = vm.name
output adminUsername string = adminUsername
output usesCustomDomain bool = !empty(customDomain)
