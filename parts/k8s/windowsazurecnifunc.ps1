

# TODO: remove - dead code?
function
Set-VnetPluginMode()
{
    Param(
        [Parameter(Mandatory=$true)][string]
        $AzureCNIConfDir,
        [Parameter(Mandatory=$true)][string]
        $Mode
    )
    # Sets Azure VNET CNI plugin operational mode.
    $fileName  = [Io.path]::Combine("$AzureCNIConfDir", "10-azure.conflist")
    (Get-Content $fileName) | %{$_ -replace "`"mode`":.*", "`"mode`": `"$Mode`","} | Out-File -encoding ASCII -filepath $fileName
}


function
Install-VnetPlugins
{
    Param(
        [Parameter(Mandatory=$true)][string]
        $AzureCNIConfDir,
        [Parameter(Mandatory=$true)][string]
        $AzureCNIBinDir,
        [Parameter(Mandatory=$true)][string]
        $VNetCNIPluginsURL
    )
    # Create CNI directories.
    mkdir $AzureCNIBinDir
    mkdir $AzureCNIConfDir

    # Download Azure VNET CNI plugins.
    # Mirror from https://github.com/Azure/azure-container-networking/releases
    $zipfile =  [Io.path]::Combine("$AzureCNIDir", "azure-vnet.zip")
    DownloadFileOverHttp -Url $VNetCNIPluginsURL -DestinationPath $zipfile
    Expand-Archive -path $zipfile -DestinationPath $AzureCNIBinDir
    del $zipfile

    # Windows does not need a separate CNI loopback plugin because the Windows
    # kernel automatically creates a loopback interface for each network namespace.
    # Copy CNI network config file and set bridge mode.
    move $AzureCNIBinDir/*.conflist $AzureCNIConfDir
}

# TODO: remove - dead code?
function
Set-AzureNetworkPlugin()
{
    # Azure VNET network policy requires tunnel (hairpin) mode because policy is enforced in the host.
    Set-VnetPluginMode "tunnel"
}

function
Set-AzureCNIConfig
{
    Param(
        [Parameter(Mandatory=$true)][string]
        $AzureCNIConfDir,
        [Parameter(Mandatory=$true)][string]
        $KubeDnsSearchPath,
        [Parameter(Mandatory=$true)][string]
        $KubeClusterCIDR,
        [Parameter(Mandatory=$true)][string]
        $MasterSubnet,
        [Parameter(Mandatory=$true)][string]
        $KubeServiceCIDR
    )
    # Fill in DNS information for kubernetes.
    $fileName  = [Io.path]::Combine("$AzureCNIConfDir", "10-azure.conflist")
    $configJson = Get-Content $fileName | ConvertFrom-Json
    $configJson.plugins.dns.Nameservers[0] = $KubeDnsServiceIp
    $configJson.plugins.dns.Search[0] = $KubeDnsSearchPath
    $configJson.plugins.AdditionalArgs[0].Value.ExceptionList[0] = $KubeClusterCIDR
    $configJson.plugins.AdditionalArgs[0].Value.ExceptionList[1] = $MasterSubnet
    $configJson.plugins.AdditionalArgs[1].Value.DestinationPrefix  = $KubeServiceCIDR

    $configJson | ConvertTo-Json -depth 20 | Out-File -encoding ASCII -filepath $fileName
}


function DeployCNSServiceAndLinkToKubelet()
{
    Param(
        [Parameter(Mandatory=$true)][string]
        $KubeDir,
        [Parameter(Mandatory=$true)][string]
        $AzureCNIBinDir,
        [Parameter(Mandatory=$true)][string]
        $VNetCNSPluginsURL
    )
    $output = "$PSScriptRoot\azure-vnet-cns.zip"

    Invoke-WebRequest -Uri $VNetCNSPluginsURL -OutFile $output
    Expand-Archive -Path $output -DestinationPath $AzureCNIBinDir

    $AzureCNS = [Io.path]::Combine("$AzureCNIBinDir", "azure-cns.exe")
    $AzureCNSStartFile = [Io.path]::Combine("$AzureCNIBinDir", "startazurecns.ps1")

    $azureCNSstartStr = "$AzureCNS -c tcp://0.0.0.0:10090"
    $azureCNSstartStr | Out-File -encoding ASCII -filepath $AzureCNSStartFile

    "$KubeDir\nssm.exe" install CNSService C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
    & "$KubeDir\nssm.exe" set CNSService AppDirectory $AzureCNIBinDir
    & "$KubeDir\nssm.exe" set CNSService AppParameters $AzureCNSStartFile
    & "$KubeDir\nssm.exe" set CNSService DisplayName CNSService
    & "$KubeDir\nssm.exe" set CNSService Description CNSService
    & "$KubeDir\nssm.exe" set CNSService Start SERVICE_AUTO_START
    & "$KubeDir\nssm.exe" set CNSService ObjectName LocalSystem
    & "$KubeDir\nssm.exe" set CNSService Type SERVICE_WIN32_OWN_PROCESS
    & "$KubeDir\nssm.exe" set CNSService AppThrottle 1500
    & "$KubeDir\nssm.exe" set CNSService AppStdoutCreationDisposition 4
    & "$KubeDir\nssm.exe" set CNSService AppStderrCreationDisposition 4
    & "$KubeDir\nssm.exe" set CNSService AppRotateFiles 1
    & "$KubeDir\nssm.exe" set CNSService AppRotateOnline 1
    & "$KubeDir\nssm.exe" set CNSService AppRotateSeconds 86400
    & "$KubeDir\nssm.exe" set CNSService AppRotateBytes 1048576

    sc.exe failure "CNSService" actions= restart/60000/restart/60000/restart/60000 reset= 900

    $value = Get-ItemProperty -Path "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\kubelet" | Select-Object -ExpandProperty "DependOnService" -ErrorAction Stop
    Set-ItemProperty -Path "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\kubelet" -Name "DependOnService" -Value "$value\0CNSService"
}