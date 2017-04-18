#
# xCluster: DSC resource to configure a Windows Failover Cluster. If the
# cluster does not exist, it will create one in the domain and assign a local
# link address to the cluster. Then, it will add all specified nodes to the
# cluster.
#

function Get-TargetResource
{
    param
    (
        [parameter(Mandatory)]
        [string] $Name,

        [string[]] $Nodes
    )
  
    $cluster = Get-Cluster -Name . -ErrorAction SilentlyContinue

    if ($null -eq $cluster)
    {
        throw "Can't find the cluster '$($Name)'."
    }

    $allNodes = @()

    foreach ($node in ($cluster | Get-ClusterNode -ErrorAction SilentlyContinue))
    {
        $allNodes += $node.Name
    }

    $retvalue = @{
        Name = $Name
        Nodes = $allNodes
    }

    $retvalue
}

function Set-TargetResource
{
    param
    (
        [parameter(Mandatory)]
        [string] $Name,

        [string[]] $Nodes
    )

    $bCreate = $true

    if ($bCreate)
    { 
        $cluster = CreateFailoverCluster -ClusterName $Name 

        Sleep 5
        # See http://social.technet.microsoft.com/wiki/contents/articles/14776.how-to-configure-windows-failover-cluster-in-azure-for-alwayson-availability-groups.aspx
        # for why the following workaround is necessary.
        Write-Verbose -Message "Stopping the Cluster Name resource ..."
            #maker
        $clusterGroup = $cluster | Get-ClusterGroup -ErrorAction SilentlyContinue
        
        $clusterNameRes = $clusterGroup | Get-ClusterResource "Cluster Name" -ErrorAction SilentlyContinue
        
        $clusterNameRes | Stop-ClusterResource -ErrorAction SilentlyContinue | Out-Null

        Sleep 5
        
        Write-Verbose -Message "Stopping the Cluster IP Address resources ..."
        
        $clusterIpAddrRes = $clusterGroup | Get-ClusterResource | Where-Object { $_.ResourceType.Name -in "IP Address", "IPv6 Address", "IPv6 Tunnel Address" }
        
        $clusterIpAddrRes | Stop-ClusterResource -ErrorAction SilentlyContinue | Out-Null
        
        Sleep 5
        
        Write-Verbose -Message "Removing all Cluster IP Address resources except the first IPv4 Address ..."
        
        $firstClusterIpv4AddrRes = $clusterIpAddrRes | Where-Object { $_.ResourceType.Name -eq "IP Address" } | Select-Object -First 1
        
        $clusterIpAddrRes | Where-Object { $_.Name -ne $firstClusterIpv4AddrRes.Name } | Remove-ClusterResource -Force | Out-Null

        Write-Verbose -Message "Seting the Cluster IP Address to a local link address ..."
        
        Sleep 5

        $clusterIpAddrRes | Set-ClusterParameter -Multiple @{
            "Address" = "169.254.1.1"
            "SubnetMask" = "255.255.0.0"
            "EnableDhcp" = 0
            "OverrideAddressMatch" = 1
        } -ErrorAction Stop

        Write-Verbose -Message "Starting the Cluster Name resource ..."
        
        $clusterNameRes | Start-ClusterResource -ErrorAction Stop | Out-Null

    }

    $nostorage=$true
    
    #Add Nodes to cluster

    $allNodes = @()

    While (!$allNodes) {

        Start-Sleep -Seconds 30

        Write-Verbose -Message "Finding nodes in cluster '$($Name)' ..."

        $allNodes = Get-ClusterNode -Cluster $Name -ErrorAction SilentlyContinue

    }

    Write-Verbose -Message "Existing nodes found in cluster '$($Name)' are: $($allNodes) ..."
    
    Write-Verbose -Message "Adding specified nodes to cluster '$($Name)' ..."

    foreach ($node in $Nodes)
    {
        $foundNode = $allNodes | where-object { $_.Name -eq $node }

        if ($foundNode -and ($foundNode.State -ne "Up"))
        {
            Write-Verbose -Message "Removing node '$($node)' since it's in the cluster but is not UP ..."
            
            Remove-ClusterNode $foundNode -Cluster $Name -Force | Out-Null

            AddNodeToCluster -ClusterName $Name -NodeName $node -Nostorage $nostorage

            continue
        }
        elseif ($foundNode)
        {
            Write-Verbose -Message "Node '$($node)' already in the cluster, skipping ..."

            continue
        }

        AddNodeToCluster -ClusterName $Name -NodeName $node -Nostorage $nostorage
    }
   
}

#
# The Test-TargetResource function will check the following (in order):
# 1. Is the machine in a domain?
# 2. Does the cluster exist in the domain?
# 3. Are the expected nodes in the cluster's nodelist, and are they all up?
#
# This will return FALSE if any of the above is not true, which will cause
# the cluster to be configured.
#
function Test-TargetResource
{
    param
    (
        [parameter(Mandatory)]
        [string] $Name,

        [string[]] $Nodes
    )

    $bRet = $false

    Write-Verbose -Message "Checking if cluster '$($Name)' is present ..."
    try
        {
            $cluster = Get-Cluster -Name . -ErrorAction SilentlyContinue
            
            if ($cluster)
            {
                Write-Verbose -Message "Cluster $($Name)' is present."
                Write-Verbose -Message "Checking if the expected nodes are in cluster $($Name)' ..."

                $allNodes = @()

                While (!$allNodes) {

                    Start-Sleep -Seconds 30

                    Write-Verbose -Message "Finding nodes in cluster '$($Name)' ..."

                    $allNodes = Get-ClusterNode -Cluster . -ErrorAction SilentlyContinue

                }

                Write-Verbose -Message "Existing nodes found in cluster '$($Name)' are: $($allNodes) ..."

                $bRet = $true
                foreach ($node in $Nodes)
                {
                    $foundNode = $allNodes | where-object { $_.Name -eq $node }

                    if (!$foundNode)
                    {
                        Write-Verbose -Message "Node '$($node)' NOT found in the cluster."
                        $bRet = $bRet -and $false
                    }
                    elseif ($foundNode.State -ne "Up")
                    {
                        Write-Verbose -Message "Node '$($node)' found in the cluster, but is not UP."
                        $bRet = $bRet -and $false
                    }
                    else
                    {
                        Write-Verbose -Message "Node '$($node)' found in the cluster."
                        $bRet = $bRet -and $true
                    }
                }

                if ($bRet)
                {
                    Write-Verbose -Message "All expected nodes found in cluster $($Name)."
                }
                else
                {
                    Write-Verbose -Message "At least one node is missing from cluster $($Name)."
                }
            }
        }
        catch
        {
            Write-Verbose -Message "Error testing cluster $($Name)."
            throw $_
        }

        $bRet
}


function AddNodeToCluster
{
    param
    (
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$NodeName,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Bool]$Nostorage,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$ClusterName
    )

    
    $RetryCounter = 0

    While ($true) {
        
        try {
            
            if ($Nostorage)
            {
               Write-Verbose -Message "Adding node $($node)' to the cluster without storage ..."
                
               Add-ClusterNode -Cluster $ClusterName -Name $NodeName -NoStorage -ErrorAction Stop | Out-Null
           
            }
            else
            {
               Write-Verbose -Message "Adding node $($node)' to the cluster"
                
               Add-ClusterNode -Cluster $ClusterName -Name $NodeName -ErrorAction Stop | Out-Null

            }

            Write-Verbose -Message "Successfully added node $($node)' to cluster '$($Name)'."

            return $true
        }
        catch [System.Exception] 
        {
            $RetryCounter = $RetryCounter + 1
            
            $ErrorMSG = "Error occured: '$($_.Exception.Message)', failed after '$($RetryCounter)' times"
            
            if ($RetryCounter -eq 10) 
            {
                Write-Verbose "Error occured: $ErrorMSG, reach the maximum re-try: '$($RetryCounter)' times, exiting...."

                Throw $ErrorMSG
            }

            start-sleep -seconds 5

            Write-Verbose "Error occured: $ErrorMSG, retry for '$($RetryCounter)' times"
        }
    }
}

function CreateFailoverCluster
{
    param
    (
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$ClusterName
    )

    $RetryCounter = 0

    While ($true) {
        
        try {
            
            Write-Verbose -Message "Creating Cluster '$($Name)'."
            
            $cluster = New-Cluster -Name $ClusterName -Node $env:COMPUTERNAME -NoStorage -AdministrativeAccessPoint DNS -Force -ErrorAction Stop
    
            Write-Verbose -Message "Successfully created cluster '$($Name)'."

            return $cluster
        }
        catch [System.Exception] 
        {
            $RetryCounter = $RetryCounter + 1
            
            $ErrorMSG = "Error occured: '$($_.Exception.Message)', failed after '$($RetryCounter)' times"
            
            if ($RetryCounter -eq 10) 
            {
                Write-Verbose "Error occured: $ErrorMSG, reach the maximum re-try: '$($RetryCounter)' times, exiting...."

                Throw $ErrorMSG
            }

            start-sleep -seconds 5

            Write-Verbose "Error occured: $ErrorMSG, retry for '$($RetryCounter)' times"
        }
    }
}

Export-ModuleMember -Function *-TargetResource
