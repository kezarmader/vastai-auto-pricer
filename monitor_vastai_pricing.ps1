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
    [switch]$TestMode,                  # Run in test mode (no actual price changes)
    [string]$TargetGPU = "RTX_5090",    # Filter for specific GPU model
    [int]$TargetNumGPUs = 1             # Filter for specific number of GPUs
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
        # Search for similar offers - same GPU model and count, available for rent
        $searchQuery = "gpu_name=$TargetGPU num_gpus=$TargetNumGPUs rentable=true reliability>0.95"
        $offers = vastai search offers $searchQuery --raw | ConvertFrom-Json
        
        if ($offers.Count -eq 0) { 
            Write-Log "No comparable offers found in market"
            return @{ DemandPercent = 50; AvgPrice = $null; MedianPrice = $null; MinPrice = $null; RentedCount = 0; TotalCount = 0 }
        }
        
        # Calculate demand metrics
        $totalOffers = $offers.Count
        $rentedOffers = ($offers | Where-Object { $_.rented -eq $true }).Count
        $demandPercent = [math]::Round(($rentedOffers / $totalOffers) * 100, 1)
        
        # Analyze pricing of available (not rented) similar machines
        $availableOffers = $offers | Where-Object { $_.rented -eq $false }
        $prices = $availableOffers | ForEach-Object { $_.dph_base } | Where-Object { $_ -gt 0 }
        
        $avgPrice = if ($prices.Count -gt 0) { [math]::Round(($prices | Measure-Object -Average).Average, 4) } else { $null }
        $medianPrice = if ($prices.Count -gt 0) { 
            $sorted = $prices | Sort-Object
            $mid = [math]::Floor($sorted.Count / 2)
            [math]::Round($sorted[$mid], 4)
        } else { $null }
        $minPrice = if ($prices.Count -gt 0) { [math]::Round(($prices | Measure-Object -Minimum).Minimum, 4) } else { $null }
        
        return @{
            DemandPercent = $demandPercent
            AvgPrice = $avgPrice
            MedianPrice = $medianPrice
            MinPrice = $minPrice
            RentedCount = $rentedOffers
            TotalCount = $totalOffers
        }
    }
    catch {
        Write-Log "ERROR getting market demand: $($_.Exception.Message)"
        return @{ DemandPercent = 50; AvgPrice = $null; MedianPrice = $null; MinPrice = $null; RentedCount = 0; TotalCount = 0 }
    }
}

function Calculate-NewPrice {
    param(
        [double]$CurrentPrice,
        [hashtable]$MarketData,
        [string]$MachineId
    )
    
    $demandPercent = $MarketData.DemandPercent
    $newPrice = $CurrentPrice
    $action = "HOLD"
    $reason = "Demand: ${demandPercent}%"
    
    # Strategy: Price competitively based on market conditions
    # High demand (>80%) = Price above median for max profit
    # Medium demand (30-80%) = Price near median for balance
    # Low demand (<30%) = Price below median for occupancy
    
    if ($MarketData.MedianPrice -and $MarketData.AvgPrice) {
        $medianPrice = $MarketData.MedianPrice
        $avgPrice = $MarketData.AvgPrice
        $minMarketPrice = $MarketData.MinPrice
        
        Write-Log "Market analysis: Median=`$$medianPrice, Avg=`$$avgPrice, Min=`$$minMarketPrice, Rented=$($MarketData.RentedCount)/$($MarketData.TotalCount)"
        
        if ($demandPercent -ge $HighDemandThreshold) {
            # High demand: Price at 90-100% of median (competitive but profitable)
            $targetPrice = $medianPrice * 0.95
            $targetPrice = [math]::Min($targetPrice, $MaxPrice)
            $targetPrice = [math]::Max($targetPrice, $BasePrice)
            
            if ($targetPrice -gt $CurrentPrice) {
                $newPrice = $targetPrice
                $action = "INCREASE"
                $reason = "High demand (${demandPercent}%) - pricing at 95% of market median"
            }
        }
        elseif ($demandPercent -le $LowDemandThreshold) {
            # Low demand: Price at 80-90% of minimum to attract renters
            $targetPrice = $minMarketPrice * 0.85
            $targetPrice = [math]::Max($targetPrice, $BasePrice)
            $targetPrice = [math]::Min($targetPrice, $MaxPrice)
            
            if ($targetPrice -lt $CurrentPrice) {
                $newPrice = $targetPrice
                $action = "DECREASE"
                $reason = "Low demand (${demandPercent}%) - pricing at 85% of market minimum for occupancy"
            }
        }
        else {
            # Medium demand: Price around median
            $targetPrice = $medianPrice * 0.90
            $targetPrice = [math]::Min($targetPrice, $MaxPrice)
            $targetPrice = [math]::Max($targetPrice, $BasePrice)
            
            $priceDiff = [math]::Abs($targetPrice - $CurrentPrice)
            if ($priceDiff -gt ($CurrentPrice * 0.05)) { # Only adjust if >5% difference
                $newPrice = $targetPrice
                $action = if ($targetPrice -gt $CurrentPrice) { "INCREASE" } else { "DECREASE" }
                $reason = "Medium demand (${demandPercent}%) - aligning with market median"
            }
        }
    }
    else {
        # Fallback to simple demand-based pricing if no market data
        Write-Log "No market pricing data available, using demand-based strategy"
        
        if ($demandPercent -ge $HighDemandThreshold) {
            $increase = $CurrentPrice * ($PriceStepPercent / 100)
            $newPrice = [math]::Min($CurrentPrice + $increase, $MaxPrice)
            $action = "INCREASE"
            $reason = "High demand (${demandPercent}%) - no market data"
        }
        elseif ($demandPercent -le $LowDemandThreshold) {
            $decrease = $CurrentPrice * ($PriceStepPercent / 100)
            $newPrice = [math]::Max($CurrentPrice - $decrease, $BasePrice)
            $action = "DECREASE"
            $reason = "Low demand (${demandPercent}%) - no market data"
        }
    }
    
    $script:lastUtilization[$MachineId] = $demandPercent
    
    return @{
        NewPrice = [math]::Round($newPrice, 4)
        Action = $action
        Reason = $reason
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
        $response = vastai show machines --raw | ConvertFrom-Json
        
        # Extract machines array from response
        $machines = $response.machines
        
        if (-not $machines -or $machines.Count -eq 0) {
            Write-Log "No machines found"
            return
        }

        foreach ($machine in $machines) {
            $machineId = $machine.id
            $gpuName = $machine.gpu_name -replace ' ', '_'
            $numGpus = $machine.num_gpus
            
            # Skip machines that don't match target GPU and count
            if ($gpuName -ne $TargetGPU -or $numGpus -ne $TargetNumGPUs) {
                continue
            }
            
            $currentPrice = $machine.min_bid_price
            $isRented = $machine.current_rentals_running -gt 0
            $rentedStr = if ($isRented) { "RENTED" } else { "AVAILABLE" }
            
            # Initialize price history if needed
            if (-not $script:priceHistory.ContainsKey($machineId)) {
                $script:priceHistory[$machineId] = $currentPrice
            }
            
            Write-Log "--- Machine $machineId ($numGpus x $gpuName) | Status: $rentedStr | Current: `$$currentPrice/GPU/hr ---"
            
            # Get market demand and pricing data
            $marketData = Get-MarketDemand -GpuName $gpuName -NumGpus $numGpus
            Write-Log "Market: $($marketData.RentedCount)/$($marketData.TotalCount) rented (${($marketData.DemandPercent)}% demand)"
            
            # Calculate new price based on market conditions
            $priceDecision = Calculate-NewPrice -CurrentPrice $currentPrice -MarketData $marketData -MachineId $machineId
            
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
Write-Log "Target GPU: $TargetGPU x$TargetNumGPUs"
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
