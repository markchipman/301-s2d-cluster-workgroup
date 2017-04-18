#
# CopyrightMicrosoft Corporation. All rights reserved."
#

configuration PrepS2D
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [String]$EnableAutomaticPatching,

        [Parameter(Mandatory)]
        [Int]$AutomaticPatchingHour,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds,

        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30
    )

    Import-DscResource -ModuleName xComputerManagement, xNetworking

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
            SetScript = "Set-DnsClientGlobalSetting -SuffixSearchList $DomainName; Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\' -Name Domain -Value $DomainName; Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\' -Name 'NV Domain' -Value $DomainName"
            TestScript = "'$DomainName' -in (Get-DNSClientGlobalSetting).SuffixSearchList"
            GetScript = "@{Ensure = if (('$DomainName' -in (Get-DNSClientGlobalSetting).SuffixSearchList) {'Present'} else {'Absent'}}"
        }

        Script FirewallProfile
        {
            SetScript = 'Get-NetConnectionProfile | Where-Object NetworkCategory -eq "Public" | Set-NetConnectionProfile -NetworkCategory Private; $global:DSCMachineStatus = 1'
            TestScript = '(Get-NetConnectionProfile | Where-Object NetworkCategory -eq "Public").Count -eq 0'
            GetScript = '@{Ensure = if ((Get-NetConnectionProfile | Where-Object NetworkCategory -eq "Public").Count -eq 0) {"Present"} else {"Absent"}}'
            DependsOn = "[Script]DNSSuffix"
        }

        LocalConfigurationManager 
        {
            RebootNodeIfNeeded = $True
        }

    }
}
