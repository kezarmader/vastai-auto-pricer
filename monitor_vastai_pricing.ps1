# Vast.ai Auto-Pricer
# Monitors demand and automatically adjusts pricing for your Vast.ai hosted machines

param(
    [int]$IntervalMinutes = 10,
    [string]$LogFile = "vastai_pricing_log.txt",
    [double]$BasePrice = 0.50,          # Your base minimum price per GPU per hour
    [double]$MaxPrice = 2.00,           # Maximum price per GPU per hour
    [double]$PriceStepPercent = 10,     # Percentage to adjust price (10 = 10%)
    [int]$HighDemandThreshold = 80,     # If utilization > 80%, increase price
    [int]$LowDemandThreshold = 30,      # If utilization < 30%, decrease price
    [switch]$TestMode                   # Run in test mode (no actual price changes)
)

$LogPath = Join-Path $PSScriptRoot $LogFile
$script:lastUtilization = @{}
$script:priceHistory = @{}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Write-Host $logMessage
    Add-Content -Path $LogPath -Value $logMessage
}

function Get-MarketDemand {
    param([string]$GpuName, [int]$NumGpus)
    
    try {
        # Search for similar offers to gauge market demand
        $searchQuery = "gpu_name=$GpuName num_gpus=$NumGpus rentable=true"
        $offers = vastai search offers $searchQuery --raw | ConvertFrom-Json
        
        if ($offers.Count -eq 0) { return 50 } # Default to 50% if no data
        
        # Calculate percentage of rented machines (demand indicator)
        $totalOffers = $offers.Count
        $rentedOffers = ($offers | Where-Object { $_.rented -eq $true }).Count
        $demandPercent = [math]::Round(($rentedOffers / $totalOffers) * 100, 1)
        
        return $demandPercent
    }
    catch {
        Write-Log "ERROR getting market demand: $($_.Exception.Message)"
        return 50 # Default to 50% on error
    }
}

function Calculate-NewPrice {
    param(
        [double]$CurrentPrice,
        [double]$DemandPercent,
        [string]$MachineId
    )
    
    $newPrice = $CurrentPrice
    $action = "HOLD"
    
    # Get historical trend
    if ($script:lastUtilization.ContainsKey($MachineId)) {
        $lastDemand = $script:lastUtilization[$MachineId]
        $trendUp = $DemandPercent -gt $lastDemand
    }
    
    # High demand - increase price
    if ($DemandPercent -ge $HighDemandThreshold) {
        $increase = $CurrentPrice * ($PriceStepPercent / 100)
        $newPrice = [math]::Min($CurrentPrice + $increase, $MaxPrice)
        $action = "INCREASE"
    }
    # Low demand - decrease price
    elseif ($DemandPercent -le $LowDemandThreshold) {
        $decrease = $CurrentPrice * ($PriceStepPercent / 100)
        $newPrice = [math]::Max($CurrentPrice - $decrease, $BasePrice)
        $action = "DECREASE"
    }
    
    $script:lastUtilization[$MachineId] = $DemandPercent
    
    return @{
        NewPrice = [math]::Round($newPrice, 4)
        Action = $action
        Reason = "Demand: ${DemandPercent}%"
    }
}

function Update-MachinePrice {
    param([int]$MachineId, [double]$NewPrice)
    
    if ($TestMode) {
        Write-Log "TEST MODE: Would update machine $MachineId to `$$NewPrice/GPU/hr"
        return $true
    }
    
    try {
        $result = vastai set min-bid $MachineId --price $NewPrice --raw | ConvertFrom-Json
        
        if ($result.success) {
            Write-Log "SUCCESS: Updated machine $MachineId to `$$NewPrice/GPU/hr"
            return $true
        }
        else {
            Write-Log "FAILED: Could not update machine $MachineId - $($result.msg)"
            return $false
        }
    }
    catch {
        Write-Log "ERROR updating price for machine ${MachineId}: $($_.Exception.Message)"
        return $false
    }
}

function Monitor-And-Reprice {
    try {
        $machines = vastai show machines --raw | ConvertFrom-Json
        
        if ($machines.Count -eq 0) {
            Write-Log "No machines found"
            return
        }

        foreach ($machine in $machines) {
            $machineId = $machine.id
            $gpuName = $machine.gpu_name -replace ' ', '_'
            $numGpus = $machine.num_gpus
            $currentPrice = $machine.min_bid
            $status = $machine.rented
            $rentedStr = if ($status) { "RENTED" } else { "AVAILABLE" }
            
            # Initialize price history if needed
            if (-not $script:priceHistory.ContainsKey($machineId)) {
                $script:priceHistory[$machineId] = $currentPrice
            }
            
            Write-Log "--- Machine $machineId ($numGpus x $gpuName) | Status: $rentedStr | Current: `$$currentPrice/GPU/hr ---"
            
            # Get market demand
            $demandPercent = Get-MarketDemand -GpuName $gpuName -NumGpus $numGpus
            Write-Log "Market demand for $gpuName (x$numGpus): ${demandPercent}%"
            
            # Calculate new price
            $priceDecision = Calculate-NewPrice -CurrentPrice $currentPrice -DemandPercent $demandPercent -MachineId $machineId
            
            if ($priceDecision.Action -ne "HOLD") {
                Write-Log "Action: $($priceDecision.Action) | $($priceDecision.Reason) | New Price: `$$($priceDecision.NewPrice)/GPU/hr"
                
                # Update the price
                $success = Update-MachinePrice -MachineId $machineId -NewPrice $priceDecision.NewPrice
                
                if ($success) {
                    $script:priceHistory[$machineId] = $priceDecision.NewPrice
                }
            }
            else {
                Write-Log "Action: HOLD | $($priceDecision.Reason) | Price unchanged: `$$currentPrice/GPU/hr"
            }
        }
    }
Write-Log "=== Vast.ai Auto-Pricer Started ==="
if ($TestMode) {
    Write-Log "*** RUNNING IN TEST MODE - NO ACTUAL PRICE CHANGES WILL BE MADE ***"
}
Write-Log "Check interval: $IntervalMinutes minutes"
Write-Log "Base price: `$$BasePrice | Max price: `$$MaxPrice | Price step: ${PriceStepPercent}%"
Write-Log "High demand threshold: ${HighDemandThreshold}% | Low demand threshold: ${LowDemandThreshold}%"
Write-Log "Log file: $LogPath"
Write-Log ""== Vast.ai Auto-Pricer Started ==="
Write-Log "Check interval: $IntervalMinutes minutes"
Write-Log "Base price: `$$BasePrice | Max price: `$$MaxPrice | Price step: ${PriceStepPercent}%"
Write-Log "High demand threshold: ${HighDemandThreshold}% | Low demand threshold: ${LowDemandThreshold}%"
Write-Log "Log file: $LogPath"
Write-Log ""

while ($true) {
    Monitor-And-Reprice
    Write-Log ""
    Start-Sleep -Seconds ($IntervalMinutes * 60)
}
