param
(
    [string]$resourceGroup,
    [string]$location,
    [string]$storageSKU,
    [string]$boshStorageAccountName,
    [string]$deploymentStorageAccountNameRoot,
    [string]$deploymentStorageAccountCount,
    [string]$ops_mgr_vhd_pivnet_url,
    [string]$ssh_key_path,
    [string]$vmName,
    [string]$environment
)

$DebugPreference = 'SilentlyContinue'

function Test-Storage-Names {

    [CmdletBinding()]
    param 
    (
        [string]$boshStorageAccountName,
        [string]$deploymentStorageAccountNameRoot,
        [string]$deploymentStorageAccountCount
    )

    $acctNames = Get-StorageAccount-Names $boshStorageAccountName $deploymentStorageAccountNameRoot $deploymentStorageAccountCount

    $allNamesAvailable = $true
    foreach ($acctName in $acctNames) {
        $allNamesAvailable = $allNamesAvailable -and (Get-AzureRmStorageAccountNameAvailability -Name $acctName).NameAvailable
    }

    $allNamesAvailable
    return
}

function Get-StorageAccount-Names {


    [CmdletBinding()]
    param 
    (
        [string]$boshStorageAccountName,
        [string]$deploymentStorageAccountNameRoot,
        [string]$deploymentStorageAccountCount
    )

    $storageAccountNames = @($boshStorageAccountName)
    for ($i=1; $i -le $deploymentStorageAccountCount; $i++) {
        $storageAccountNames  += "$deploymentStorageAccountNameRoot$i"
    }
    
    $storageAccountNames
    return
}

function New-Storage-Assets {

    [CmdletBinding()]
    param 
    (
        [string]$resourceGroup,
        [string]$location,
        [hashtable]$opts
    )

    $acctNames = Get-StorageAccount-Names $opts.boshStorageAccountName $opts.deploymentStorageAccountNameRoot $opts.deploymentStorageAccountCount

    $boshAcct = New-AzureRmStorageAccount -ResourceGroupName $resourceGroup -AccountName $acctNames[0] -Location $location -SkuName $opts.storageSKU -Kind "Storage"
    New-AzureStorageContainer -Name stemcell -Context $boshAcct.Context -Permission Blob
    New-AzureStorageContainer -Name opsmanager -Context $boshAcct.Context 
    New-AzureStorageContainer -Name bosh -Context $boshAcct.Context 
    New-AzureStorageTable -Name stemcells -Context $boshAcct.Context
    
    for ($i=1; $i -le $opts.deploymentStorageAccountCount; $i++) {
        $acct = New-AzureRmStorageAccount -ResourceGroupName $resourceGroup -AccountName $acctNames[$i] -Location $location -SkuName $opts.storageSKU -Kind "Storage"
        New-AzureStorageContainer -Name stemcell -Context $acct.Context
        New-AzureStorageContainer -Name bosh -Context $acct.Context 
    }

    Start-AzureStorageBlobCopy -AbsoluteUri $opts.ops_mgr_vhd_pivnet_url -DestBlob 'image.vhd' -DestContainer 'opsmanager' -DestContext $boshAcct.Context -Verbose
    
    Write-Verbose 'Copying VHD - this will take about 10 minutes.'
    do {
        Start-Sleep -s 30
        $status = Get-AzureStorageBlobCopyState -Blob image.vhd -Container 'opsmanager' -Context $boshAcct.context -Verbose
        Write-Verbose 'Copying...'
    } until ($status.Status -eq 'Success')
}

function New-Network-Assets {

    [CmdletBinding()]
    param 
    (
        [string]$resourceGroup,
        [string]$location,
        [hashtable]$opts
    )

    # subnet
    #$subnetConfig = New-AzureRmVirtualNetworkSubnetConfig -Name $opts.subnetName -AddressPrefix $opts.subnetAddressPrefix

    # vnet
   # $vnet = New-AzureRmVirtualNetwork -ResourceGroupName $resourceGroup -Location $location -Name $opts.vnetName -AddressPrefix $opts.vnetAddressPrefix -Subnet $subnetConfig

    # nsg rule
    $nsgRuleInternetToLB = New-AzureRmNetworkSecurityRuleConfig -Name internet-to-lb  -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange * -Access Allow

    #nsg
    $nsgInternetToLB = New-AzureRmNetworkSecurityGroup -ResourceGroupName $resourceGroup -Location $location -Name 'pcf-nsg' -SecurityRules $nsgRuleInternetToLB

    #nsg rules
    $nsgRuleOpsmgrHttp = New-AzureRmNetworkSecurityRuleConfig -Name http  -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80 -Access Allow
    $nsgRuleOpsmgrHttps = New-AzureRmNetworkSecurityRuleConfig -Name https  -Protocol Tcp -Direction Inbound -Priority 200 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 443 -Access Allow
    $nsgRuleOpsmgrSSH = New-AzureRmNetworkSecurityRuleConfig -Name ssh  -Protocol Tcp -Direction Inbound -Priority 300 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22 -Access Allow
    
    #nsg
    $nsgOpsMgr = New-AzureRmNetworkSecurityGroup -ResourceGroupName $resourceGroup -Location $location -Name 'opsmgr-nsg' -SecurityRules $nsgRuleOpsmgrHttp,$nsgRuleOpsmgrHttps,$nsgRuleOpsmgrSSH
    
    # create static ip for front-end IP pool
  #  $publicIP = New-AzureRmPublicIpAddress -Name pcf-lb-ip -ResourceGroupName $resourceGroup -Location $location -AllocationMethod Static
    $vnet = Get-AzureRmVirtualNetwork -Name existingnet -ResourceGroupName existing ##CHANGE NAME PARAMERS, CHANGE TO RG FOR Vnet#$resourceGroup
    $subnet = Get-AzureRmVirtualNetworkSubnetConfig -Name pcfexistingsubnet -VirtualNetwork $vnet #CHANGE NAME
    # create front-end IP pool
      $frontendIP = New-AzureRmLoadBalancerFrontendIpConfig -Name pcf-fe-ip -PrivateIpAddress 172.16.2.20 -SubnetId $subnet.id #-PublicIpAddress $publicIP
    
    # create back-end address pool
    $beaddresspool = New-AzureRmLoadBalancerBackendAddressPoolConfig -Name pcf-vms
    
    # create probe
    $healthProbe = New-AzureRmLoadBalancerProbeConfig -Name tcp80 -Protocol tcp -Port 80 -IntervalInSeconds 5 -ProbeCount 2
    
    # create LB rule
    $lbruleHttp = New-AzureRmLoadBalancerRuleConfig -Name HTTP -FrontendIpConfiguration $frontendIP -BackendAddressPool  $beAddressPool -Probe $healthProbe -Protocol Tcp -FrontendPort 80 -BackendPort 80
    $lbruleHttps = New-AzureRmLoadBalancerRuleConfig -Name HTTPS -FrontendIpConfiguration $frontendIP -BackendAddressPool  $beAddressPool -Probe $healthProbe -Protocol Tcp -FrontendPort 443 -BackendPort 443
    $lbruleSSH = New-AzureRmLoadBalancerRuleConfig -Name SSH -FrontendIpConfiguration $frontendIP -BackendAddressPool  $beAddressPool -Probe $healthProbe -Protocol Tcp -FrontendPort 2222 -BackendPort 2222
    
    # create LB
    $NRPLB = New-AzureRmLoadBalancer -ResourceGroupName $resourceGroup -Name 'pcf-lb' -Location $location -FrontendIpConfiguration $frontendIP -LoadBalancingRule $lbruleHttp,$lbruleHttps,$lbruleSSH -BackendAddressPool $beAddressPool -Probe $healthProbe
   
    # create public IP for ops mgr
   # $opsMgrIP = New-AzureRmPublicIpAddress -Name 'ops-manager-ip' -ResourceGroupName $resourceGroup -Location $location -AllocationMethod Static
    
}

function New-VM {
    
    [CmdletBinding()]
    param 
    (
        [string]$resourceGroup,
        [string]$location,
        [hashtable]$networkOpts,
        [hashtable]$storageOpts
    )
    
    $vnet = Get-AzureRmVirtualNetwork -Name $networkOpts.vnetName -ResourceGroupName existing #CHANGE TO RG FOR Vnet#$resourceGroup
    $subnet = Get-AzureRmVirtualNetworkSubnetConfig -Name pcfexistingsubnet -VirtualNetwork $vnet  #change to existing subnet name
  #  $pip = Get-AzureRmPublicIpAddress -ResourceGroupName $resourceGroup -Name 'ops-manager-ip'

    $nsgOpsMgr = Get-AzureRmNetworkSecurityGroup -resourceGroupName $resourceGroup -name 'opsmgr-nsg'
    $vmNic = New-AzureRmNetworkInterface -ResourceGroupName $resourceGroup -Name 'ops-manager-nic' `
        -Location $location -PrivateIpAddress $networkOpts.opsMgrPrivateIP -SubnetId $subnet.Id `
        -NetworkSecurityGroupId $nsgOpsMgr.Id #-PublicIpAddressId $pip.Id
    
    $vhdContainerUri = 'https://' + $storageOpts.boshStorageAccountName + $storageOpts.storageDomain + '/opsmanager/'
    $sourceVhdUrl = $vhdContainerUri + 'image.vhd'
    $targetVhdUrl = $vhdContainerUri + 'os_disk.vhd'

    # Define user name and blank password - used to create home directory but not to authenticate to the VM.
    $securePassword = ConvertTo-SecureString ' ' -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ("ubuntu", $securePassword)
    $vmConfig = New-AzureRmVMConfig -VMName $vmName -VMSize 'Standard_DS2_v2' | `
    Set-AzureRmVMOperatingSystem -Linux -ComputerName $vmName -Credential $cred -DisablePasswordAuthentication | `
    Set-AzureRmVMOSDisk -Name "image.vhd" -SourceImageUri $sourceVhdUrl -VhdUri $targetVhdUrl -CreateOption fromImage -Linux | `
    Add-AzureRmVMNetworkInterface -Id $vmNic.Id
    
    # Configure SSH Keys
    $sshPublicKey = Get-Content $ssh_key_path -Raw   
    Add-AzureRmVMSshPublicKey -VM $vmconfig -KeyData $sshPublicKey -Path "/home/ubuntu/.ssh/authorized_keys"
    
    # Create a virtual machine
    New-AzureRmVM -ResourceGroupName $resourceGroup -Location $location -VM $vmConfig
}

# fail fast if storage names are not globally unique
$storageNamesAvailable = Test-Storage-Names $boshStorageAccountName $deploymentStorageAccountNameRoot $deploymentStorageAccountCount
if (-not $storageNamesAvailable) {
    Write-Host "Not all storage names are available."
    return
}

# test if the resource group name is available and if not, create it
$ErrorActionPreference = 'SilentlyContinue'
$testRg = Get-AzureRmResourceGroup -name $resourceGroup
if ($testRg -eq $Null) {
    New-AzureRmResourceGroup -Name $resourceGroup -Location $location
}
$ErrorActionPreference = 'Continue'

$networkOptions = @{}
$networkOptions.subnetName = 'pcf'
$networkOptions.vnetName = 'existingnet'
$networkOptions.subnetAddressPrefix = '172.16.2.0/24'
$networkOptions.vnetAddressPrefix = '172.16.0.0/16'
$networkOptions.opsMgrPrivateIP = '172.16.2.5'

New-Network-Assets -resourceGroup $resourceGroup -location $location -opts $networkOptions

switch ($environment.ToLower())
{
    'AzurePublicCloud' {$storageDomain = '.blob.core.windows.net'}
    'AzureGermanCloud' {$storageDomain = '.blob.core.cloudapi.de'}
    'AzureChinaCloud' {$storageDomain = '.blob.core.chinacloudapi.cn'}
    'AzureUSGovernment' {$storageDomain = '.blob.core.usgovcloudapi.net'}
    default {$storageDomain = '.blob.core.windows.net'}
}
$storageOptions = @{}
$storageOptions.storageSKU = $storageSKU
$storageOptions.boshStorageAccountName = $boshStorageAccountName
$storageOptions.deploymentStorageAccountNameRoot = $deploymentStorageAccountNameRoot
$storageOptions.deploymentStorageAccountCount = $deploymentStorageAccountCount
$storageOptions.ops_mgr_vhd_pivnet_url = $ops_mgr_vhd_pivnet_url
$storageOptions.storageDomain = $storageDomain

New-Storage-Assets -resourceGroup $resourceGroup -location $location -opts $storageOptions 

New-VM -resourceGroup $resourceGroup -location $location -networkOpts $networkOptions -storageOpts $storageOptions

$DebugPreference = "SilentlyContinue"
