#!/usr/bin/env python3
"""
Vast.ai Auto-Pricer
Automatically adjusts pricing for Vast.ai hosted machines based on market demand and rental status.
"""

import argparse
import json
import logging
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Optional, List, Dict


@dataclass
class MarketData:
    """Market analysis data for comparable machines"""
    avg_price: Optional[float]
    median_price: Optional[float]
    min_price: Optional[float]
    available_count: int  # Number of machines available to rent
    verified_count: int
    avg_reliability: float
    min_verified_price: Optional[float]
    # Unverified machine stats
    unverified_count: int = 0
    unverified_avg_price: Optional[float] = None
    unverified_median_price: Optional[float] = None
    unverified_min_price: Optional[float] = None


@dataclass
class PriceDecision:
    """Pricing decision with reasoning"""
    new_price: float
    action: str  # INCREASE, DECREASE, HOLD
    reason: str


@dataclass
class Machine:
    """Vast.ai machine information"""
    id: int
    gpu_name: str
    num_gpus: int
    current_price: float
    is_rented: bool
    verified: bool
    reliability: float
    disk_space: float
    inet_down: float
    inet_up: float


class VastAIPricer:
    """Main auto-pricer class"""
    
    def __init__(self, config: Dict):
        self.config = config
        self.setup_logging()
        
    def setup_logging(self):
        """Configure logging"""
        log_format = '[%(asctime)s] %(message)s'
        date_format = '%Y-%m-%d %H:%M:%S'
        
        logging.basicConfig(
            level=logging.DEBUG,  # Changed to DEBUG to see debug messages
            format=log_format,
            datefmt=date_format,
            handlers=[
                logging.FileHandler(self.config['log_file']),
                logging.StreamHandler()
            ]
        )
        self.logger = logging.getLogger(__name__)
    
    def run_vastai_command(self, command: List[str]) -> Optional[Dict]:
        """Execute vastai CLI command and return JSON result"""
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                check=True
            )
            return json.loads(result.stdout) if result.stdout else None
        except subprocess.CalledProcessError as e:
            self.logger.error(f"Command failed: {' '.join(command)}")
            self.logger.error(f"Error: {e.stderr}")
            return None
        except json.JSONDecodeError as e:
            self.logger.error(f"Failed to parse JSON response: {e}")
            return None
    
    def get_my_machines(self) -> List[Machine]:
        """Get list of user's machines"""
        response = self.run_vastai_command(['vastai', 'show', 'machines', '--raw'])
        if not response or 'machines' not in response:
            return []
        
        machines = []
        target_gpu = self.config['target_gpu']
        target_count = self.config['target_num_gpus']
        
        for machine_data in response['machines']:
            gpu_name = machine_data['gpu_name'].replace(' ', '_')
            num_gpus = machine_data['num_gpus']
            
            # Filter by target GPU and count
            if gpu_name == target_gpu and num_gpus == target_count:
                machines.append(Machine(
                    id=machine_data['id'],
                    gpu_name=gpu_name,
                    num_gpus=num_gpus,
                    current_price=machine_data['min_bid_price'],
                    is_rented=machine_data['current_rentals_running'] > 0,
                    verified=machine_data.get('verified', False),
                    reliability=machine_data.get('reliability2', 0.0),
                    disk_space=machine_data.get('disk_space', 0.0),
                    inet_down=machine_data.get('inet_down', 0.0),
                    inet_up=machine_data.get('inet_up', 0.0)
                ))
        
        return machines
    
    def get_market_data(self, gpu_name: str, num_gpus: int) -> MarketData:
        """Analyze market for comparable machines"""
        search_query = f"gpu_name={gpu_name} num_gpus={num_gpus} rentable=true reliability>0.95 verified=any"
        offers = self.run_vastai_command(['vastai', 'search', 'offers', search_query, '--raw'])
        
        if not offers or len(offers) == 0:
            self.logger.warning("No comparable offers found in market")
            return MarketData(None, None, None, 0, 0, 0.0, None)
        
        # Note: search offers only returns AVAILABLE machines, not rented ones
        # So we can't calculate true demand % from this API
        available_count = len(offers)
        
        # Analyze verified machines - check 'verification' string field
        verified_offers = [o for o in offers if o.get('verification') == 'verified']
        verified_count = len(verified_offers)
        
        # Calculate average reliability
        reliabilities = [o.get('reliability2', 0) for o in offers if o.get('reliability2', 0) > 0]
        avg_reliability = round(sum(reliabilities) / len(reliabilities), 2) if reliabilities else 0.0
        
        # Get pricing from available (not rented) machines
        available_prices = [
            offer['dph_base'] 
            for offer in offers 
            if not offer.get('rented', False) and offer.get('dph_base', 0) > 0
        ]
        
        # Debug: log the price range found
        if available_prices:
            self.logger.debug(f"Found {len(available_prices)} priced offers: min=${min(available_prices):.4f}, max=${max(available_prices):.4f}")
        
        # Get verified-only pricing
        verified_available_prices = [
            offer['dph_base']
            for offer in offers
            if offer.get('verification') == 'verified'
               and not offer.get('rented', False) and offer.get('dph_base', 0) > 0
        ]
        min_verified_price = round(min(verified_available_prices), 4) if verified_available_prices else None
        
        # Get unverified-only pricing (includes 'unverified' and 'deverified')
        unverified_offers = [o for o in offers if o.get('verification') in ['unverified', 'deverified']]
        unverified_count = len(unverified_offers)
        unverified_available_prices = [
            offer['dph_base']
            for offer in unverified_offers
            if not offer.get('rented', False) and offer.get('dph_base', 0) > 0
        ]
        
        unverified_avg_price = None
        unverified_median_price = None
        unverified_min_price = None
        
        if unverified_available_prices:
            unverified_available_prices.sort()
            unverified_avg_price = round(sum(unverified_available_prices) / len(unverified_available_prices), 4)
            unverified_min_price = round(min(unverified_available_prices), 4)
            unverified_median_price = round(unverified_available_prices[len(unverified_available_prices) // 2], 4)
            self.logger.debug(f"Unverified prices: {len(unverified_available_prices)} offers, range ${unverified_min_price}-${max(unverified_available_prices):.4f}")
        
        if not available_prices:
            return MarketData(None, None, None, available_count, verified_count, avg_reliability, min_verified_price,
                            unverified_count, unverified_avg_price, unverified_median_price, unverified_min_price)
        
        available_prices.sort()
        avg_price = round(sum(available_prices) / len(available_prices), 4)
        min_price = round(min(available_prices), 4)
        median_price = round(available_prices[len(available_prices) // 2], 4)
        
        return MarketData(avg_price, median_price, min_price, available_count, verified_count, avg_reliability, min_verified_price,
                        unverified_count, unverified_avg_price, unverified_median_price, unverified_min_price)
    
    def calculate_price(self, machine: Machine, market: MarketData) -> PriceDecision:
        """Calculate optimal price based on market conditions and machine status"""
        config = self.config
        current = machine.current_price
        
        # Log machine status
        status = "VERIFIED" if machine.verified else "UNVERIFIED"
        self.logger.info(
            f"Machine #{machine.id}: ${current} | {status} | "
            f"Reliability: {machine.reliability:.2f} | Disk: {machine.disk_space:.0f}GB | "
            f"Network: {machine.inet_down:.0f}↓/{machine.inet_up:.0f}↑ Mbps"
        )
        
        # Log market analysis
        if market.median_price:
            self.logger.info(
                f"Market: {market.available_count} available machines (Verified: {market.verified_count}, Unverified: {market.unverified_count})"
            )
            
            if machine.verified and market.min_verified_price:
                self.logger.info(
                    f"Verified Market | Median=${market.median_price}, Avg=${market.avg_price}, Min=${market.min_verified_price}"
                )
            elif not machine.verified and market.unverified_median_price:
                self.logger.info(
                    f"Unverified Market | Median=${market.unverified_median_price}, Avg=${market.unverified_avg_price}, Min=${market.unverified_min_price}"
                )
            else:
                self.logger.info(
                    f"Overall Market | Median=${market.median_price}, Avg=${market.avg_price}, Min=${market.min_price}"
                )
            
            self.logger.info(f"Avg Reliability: {market.avg_reliability}")
            
            position = self._get_price_position(current, market, machine.verified)
            self.logger.info(f"Your price position: {position}")
        
        # Strategy depends on rental status
        if machine.is_rented:
            return self._price_for_rented_machine(current, market)
        else:
            return self._price_for_idle_machine(current, market, machine)
    
    def _get_price_position(self, current_price: float, market: MarketData, is_verified: bool) -> str:
        """Determine price position relative to market"""
        # Compare against the appropriate peer group
        if is_verified:
            median = market.median_price
            min_price = market.min_verified_price if market.min_verified_price else market.min_price
        else:
            median = market.unverified_median_price if market.unverified_median_price else market.median_price
            min_price = market.unverified_min_price if market.unverified_min_price else market.min_price
        
        if not median:
            return "Unknown"
        
        if current_price > median:
            return "Above median"
        elif current_price > min_price:
            return "Competitive"
        else:
            return "Below market"
    
    def _price_for_rented_machine(self, current: float, market: MarketData) -> PriceDecision:
        """Pricing strategy for currently rented machines"""
        # Conservative: hold price while rented
        return PriceDecision(
            current,
            "HOLD",
            f"Machine is RENTED - holding current price"
        )
    
    def _price_for_idle_machine(self, current: float, market: MarketData, machine: Machine) -> PriceDecision:
        """Pricing strategy for idle machines - be aggressive to get rentals"""
        config = self.config
        
        if not market.median_price:
            # No market data - decrease to attract
            return PriceDecision(
                self._clamp_price(current * 0.9),
                "DECREASE",
                "Machine IDLE + no market data - decreasing to attract customers"
            )
        
        # Use verified minimum as benchmark if machine is verified
        reference_min = market.min_verified_price if (machine.verified and market.min_verified_price) else market.min_price
        
        # Diagnose why machine is idle based on price position
        
        if current > market.median_price:
            # Too expensive - drop to 90% of median (or 95% if verified)
            multiplier = 0.95 if machine.verified else 0.90
            target = market.median_price * multiplier
            return PriceDecision(
                self._clamp_price(target),
                "DECREASE",
                f"Machine IDLE + priced above median - dropping to {int(multiplier*100)}% of median"
            )
        
        elif current > reference_min:
            # Between min and median - be aggressive
            target = reference_min * 0.92
            if abs(target - current) > current * 0.05:  # Only if 5%+ change
                return PriceDecision(
                    self._clamp_price(target),
                    "DECREASE",
                    f"Machine IDLE - pricing near market minimum to attract customers"
                )
        
        else:
            # Already cheapest - hold and wait
            pass
        
        return PriceDecision(
            current,
            "HOLD",
            f"Machine IDLE but already at/below market minimum - holding price"
        )
    
    def _clamp_price(self, price: float) -> float:
        """Ensure price stays within configured bounds"""
        return round(max(self.config['base_price'], min(price, self.config['max_price'])), 4)
    
    def update_machine_price(self, machine_id: int, new_price: float) -> bool:
        """Update machine price on Vast.ai"""
        if self.config['test_mode']:
            self.logger.info(f"TEST MODE: Would update machine {machine_id} to ${new_price}/GPU/hr")
            return True
        
        result = self.run_vastai_command([
            'vastai', 'set', 'min-bid', str(machine_id), '--price', str(new_price), '--raw'
        ])
        
        if result and result.get('success'):
            self.logger.info(f"SUCCESS: Updated machine {machine_id} to ${new_price}/GPU/hr")
            return True
        else:
            self.logger.error(f"FAILED: Could not update machine {machine_id}")
            return False
    
    def process_machines(self):
        """Main processing loop - analyze and reprice machines"""
        machines = self.get_my_machines()
        
        if not machines:
            self.logger.info("No matching machines found")
            return
        
        for machine in machines:
            status = "RENTED" if machine.is_rented else "AVAILABLE"
            self.logger.info(
                f"--- Machine {machine.id} ({machine.num_gpus} x {machine.gpu_name}) | "
                f"Status: {status} | Current: ${machine.current_price}/GPU/hr ---"
            )
            
            # Get market data
            market = self.get_market_data(machine.gpu_name, machine.num_gpus)
            self.logger.info(f"Market: {market.available_count} available machines")
            
            # Calculate optimal price
            decision = self.calculate_price(machine, market)
            
            if decision.action != "HOLD":
                self.logger.info(f"Action: {decision.action} | {decision.reason} | New Price: ${decision.new_price}/GPU/hr")
                self.update_machine_price(machine.id, decision.new_price)
            else:
                self.logger.info(f"Action: HOLD | {decision.reason}")
        
        self.logger.info("")
    
    def run(self):
        """Main run loop"""
        self.logger.info("=== Vast.ai Auto-Pricer Started ===")
        if self.config['test_mode']:
            self.logger.info("*** RUNNING IN TEST MODE - NO ACTUAL PRICE CHANGES WILL BE MADE ***")
        
        self.logger.info(f"Target GPU: {self.config['target_gpu']} x{self.config['target_num_gpus']}")
        self.logger.info(f"Check interval: {self.config['interval_minutes']} minutes")
        self.logger.info(f"Price range: ${self.config['base_price']} - ${self.config['max_price']}")
        self.logger.info(f"Demand thresholds: High={self.config['high_demand_threshold']}%, Low={self.config['low_demand_threshold']}%")
        self.logger.info("")
        
        try:
            while True:
                self.process_machines()
                self.logger.info(f"Sleeping for {self.config['interval_minutes']} minutes until next check...")
                sys.stdout.flush()
                sys.stderr.flush()
                time.sleep(self.config['interval_minutes'] * 60)
        except KeyboardInterrupt:
            self.logger.info("Auto-pricer stopped by user")


def main():
    parser = argparse.ArgumentParser(description='Vast.ai Auto-Pricer')
    parser.add_argument('--interval', type=int, default=10, help='Check interval in minutes (default: 10)')
    parser.add_argument('--base-price', type=float, default=0.50, help='Minimum price per GPU/hr (default: 0.50)')
    parser.add_argument('--max-price', type=float, default=2.00, help='Maximum price per GPU/hr (default: 2.00)')
    parser.add_argument('--high-demand', type=int, default=80, help='High demand threshold %% (default: 80)')
    parser.add_argument('--low-demand', type=int, default=30, help='Low demand threshold %% (default: 30)')
    parser.add_argument('--target-gpu', type=str, default='RTX_5090', help='Target GPU model (default: RTX_5090)')
    parser.add_argument('--num-gpus', type=int, default=1, help='Number of GPUs (default: 1)')
    parser.add_argument('--log-file', type=str, default='vastai_pricing_log.txt', help='Log file path')
    parser.add_argument('--test-mode', action='store_true', help='Run in test mode (no actual changes)')
    
    args = parser.parse_args()
    
    config = {
        'interval_minutes': args.interval,
        'base_price': args.base_price,
        'max_price': args.max_price,
        'high_demand_threshold': args.high_demand,
        'low_demand_threshold': args.low_demand,
        'target_gpu': args.target_gpu,
        'target_num_gpus': args.num_gpus,
        'log_file': args.log_file,
        'test_mode': args.test_mode
    }
    
    pricer = VastAIPricer(config)
    pricer.run()


if __name__ == '__main__':
    main()
