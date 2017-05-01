
configuration ConfigS2D
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds,

        [Parameter(Mandatory)]
        [String]$ClusterName,

        [Parameter(Mandatory)]
        [String]$LBIPAddress,

        [Parameter(Mandatory)]
        [String]$vmNamePrefix,

        [Parameter(Mandatory)]
        [Int]$vmCount,

        [Parameter(Mandatory)]
        [Int]$vmDiskSize,

        [Parameter(Mandatory)]
        [String]$witnessStorageName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$witnessStorageKey,

        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30

    )

    Import-DscResource -ModuleName xComputerManagement, xNetworking, xFailOverCluster, xClusterGroup
 
    [System.Collections.ArrayList]$Nodes=@()
    For ($count=0; $count -lt $vmCount; $count++) {
        $Nodes.Add($vmNamePrefix + $Count.ToString())
    }

    Node localhost
    {

        WindowsFeature FC
        {
            Name = "Failover-Clustering"
            Ensure = "Present"
        }

        WindowsFeature FCPS
        {
            Name = "RSAT-Clustering-PowerShell"
            Ensure = "Present"
            DependsOn = "[WindowsFeature]FC"
        }

        WindowsFeature FS
        {
            Name = "FS-FileServer"
            Ensure = "Present"
        } 

        xFirewall LBProbePortRule
        {
            Direction = "Inbound"
            Name = "Azure Load Balancer Customer Probe Port"
            DisplayName = "Azure Load Balancer Customer Probe Port (TCP-In)"
            Description = "Inbound TCP rule for Azure Load Balancer Customer Probe Port."
            DisplayGroup = "Azure"
            State = "Enabled"
            Access = "Allow"
            Protocol = "TCP"
            LocalPort = "59001" -as [String]
            Ensure = "Present"
        }

        Script DNSSuffix
        {
            SetScript = "Set-DnsClientGlobalSetting -SuffixSearchList $DomainName -Verbose; Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\' -Name Domain -Value $DomainName; Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\' -Name 'NV Domain' -Value $DomainName -Verbose"
            TestScript = "'$DomainName' -in (Get-DNSClientGlobalSetting).SuffixSearchList"
            GetScript = "@{Ensure = if (('$DomainName' -in (Get-DNSClientGlobalSetting).SuffixSearchList) {'Present'} else {'Absent'}}"
        }

        Script FirewallProfile
        {
            SetScript = 'Get-NetConnectionProfile | Where-Object NetworkCategory -eq "Public" | Set-NetConnectionProfile -NetworkCategory Private -Verbose; $global:DSCMachineStatus = 1'
            TestScript = '(Get-NetConnectionProfile | Where-Object NetworkCategory -eq "Public").Count -eq 0'
            GetScript = '@{Ensure = if ((Get-NetConnectionProfile | Where-Object NetworkCategory -eq "Public").Count -eq 0) {"Present"} else {"Absent"}}'
            DependsOn = "[Script]DNSSuffix"
        }

        xCluster FailoverCluster
        {
            Name = $ClusterName
            Nodes = $Nodes
            PsDscRunAsCredential = $AdminCreds
            DependsOn = @("[WindowsFeature]FCPS","[Script]FirewallProfile")
        }

        Script CloudWitness
        {
            SetScript = "Set-ClusterQuorum -CloudWitness -AccountName ${witnessStorageName} -AccessKey $($witnessStorageKey.GetNetworkCredential().Password) -Verbose"
            TestScript = "(Get-ClusterQuorum).QuorumResource.Name -eq 'Cloud Witness'"
            GetScript = "@{Ensure = if ((Get-ClusterQuorum).QuorumResource.Name -eq 'Cloud Witness') {'Present'} else {'Absent'}}"
            DependsOn = "[xCluster]FailoverCluster"
        }

        Script IncreaseClusterTimeouts
        {
            SetScript = "(Get-Cluster).SameSubnetDelay = 2000; (Get-Cluster).SameSubnetThreshold = 15; (Get-Cluster).CrossSubnetDelay = 3000; (Get-Cluster).CrossSubnetThreshold = 15"
            TestScript = "(Get-Cluster).SameSubnetDelay -eq 2000 -and (Get-Cluster).SameSubnetThreshold -eq 15 -and (Get-Cluster).CrossSubnetDelay -eq 3000 -and (Get-Cluster).CrossSubnetThreshold -eq 15"
            GetScript = "@{Ensure = if ((Get-Cluster).SameSubnetDelay -eq 2000 -and (Get-Cluster).SameSubnetThreshold -eq 15 -and (Get-Cluster).CrossSubnetDelay -eq 3000 -and (Get-Cluster).CrossSubnetThreshold -eq 15) {'Present'} else {'Absent'}}"
            DependsOn = "[Script]CloudWitness"
        }

        Script EnableS2D
        {
            SetScript = "Enable-ClusterS2D -Confirm:0; New-Volume -StoragePoolFriendlyName S2D* -FriendlyName ${ClusterName}-role-vol0 -FileSystem CSVFS_REFS -UseMaximumSize"
            TestScript = "(Get-ClusterSharedVolume).State -eq 'Online'"
            GetScript = "@{Ensure = if ((Get-ClusterSharedVolume).State -eq 'Online') {'Present'} Else {'Absent'}}"
            DependsOn = "[Script]IncreaseClusterTimeouts"
        }

        xClusterGroup EnableServerRole
        {
            Name = "${ClusterName}-role"
            LBIPAddress = $LBIPAddress
            PsDscRunAsCredential = $AdminCreds
            DependsOn = @("[Script]EnableS2D","[xFirewall]LBProbePortRule")
        }

        LocalConfigurationManager 
        {
            RebootNodeIfNeeded = $true
        }

    }

}
