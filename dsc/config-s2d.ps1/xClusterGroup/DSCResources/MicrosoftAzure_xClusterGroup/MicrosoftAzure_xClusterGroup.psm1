#
# xClusterGroup: DSC resource to configure a generic FCI cluster group. 
#

function Get-TargetResource
{
    param
    (
        [parameter(Mandatory)]
        [string] $Name,

        [parameter(Mandatory)]
        [string] $LBIPAddress

    )
  
    $retvalue = @{Ensure = if ((Get-ClusterGroup -Name ${Name} -ErrorAction SilentlyContinue).State -eq 'Online') {'Present'} Else {'Absent'}}

    $retvalue
}

function Set-TargetResource
{
    param
    (
        [parameter(Mandatory)]
        [string] $Name,

        [parameter(Mandatory)]
        [string] $LBIPAddress

    )
 
    # Add Server role to Cluster
    
    Add-ClusterServerRole -Name $Name -StaticAddress $LBIPAddress -ErrorAction Stop -Verbose

    # Make sure Server role is active on this node

    Move-ClusterGroup -Name $Name -Node $env:COMPUTERNAME -ErrorAction Stop -Verbose

    # Update IP Address Resource for Cluster Group with Azure Load Balancer IP Address

    $ClusterNetworkName = "Cluster Network 1"
    $IPResourceName = "IP Address ${LBIPAddress}"
    $ProbePort = "59001"

    Get-ClusterResource $IPResourceName | 
    Set-ClusterParameter -Verbose -Multiple @{
        "Address"="$LBIPAddress";
        "ProbePort"="$ProbePort";
        "SubnetMask"="255.255.255.255";
        "Network"="$ClusterNetworkName";
        "OverrideAddressMatch"=1;
        "EnableDhcp"=0
        }

    # Stop and Start Cluster Group so that IP Resource change takes effect
    
    Stop-ClusterGroup -Name $Name -ErrorAction SilentlyContinue -Verbose

    Start-ClusterGroup -Name $Name -ErrorAction Stop -Verbose

 }

function Test-TargetResource
{
    param
    (
        [parameter(Mandatory)]
        [string] $Name,

        [parameter(Mandatory)]
        [string] $LBIPAddress

    )

    $retvalue = (Get-ClusterGroup -Name ${Name} -ErrorAction SilentlyContinue).State -eq 'Online'
 
    $retvalue
    
}

Export-ModuleMember -Function *-TargetResource
