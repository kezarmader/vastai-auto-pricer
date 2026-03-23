#!/usr/bin/env python3
"""
Vast.ai Auto-Pricer
Automatically adjusts pricing for Vast.ai hosted machines based on market demand and rental status.
"""

import argparse
import json
import logging
import math
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional, List, Dict


@dataclass
class MarketData:
    """Market analysis data for comparable machines"""
    avg_price: Optional[float]
    median_price: Optional[float]
    min_price: Optional[float]
    p25_price: Optional[float]  # 25th percentile
    p75_price: Optional[float]  # 75th percentile
    available_count: int  # Number of machines available to rent
    verified_count: int
    avg_reliability: float
    avg_disk_space: float
    avg_inet_down: float
    avg_inet_up: float
    min_verified_price: Optional[float]
    # Verified machine stats
    verified_avg_price: Optional[float] = None
    verified_median_price: Optional[float] = None
    verified_p25_price: Optional[float] = None
    verified_p75_price: Optional[float] = None
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
    current_price: float    # min_bid_price (listing floor)
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
        self.idle_since: Dict[int, float] = {}  # machine_id -> timestamp when idle was first seen
        self.last_rented_price: Dict[int, float] = {}  # machine_id -> price it was last rented at
        self._state_file = 'vastai_pricer_state.json'
        self._load_state()
        self.setup_logging()
        
    def _load_state(self):
        """Load persisted state from disk"""
        if os.path.exists(self._state_file):
            try:
                with open(self._state_file, 'r') as f:
                    raw = json.load(f)
                self.idle_since = {int(k): v for k, v in raw.get('idle_since', {}).items()}
                self.last_rented_price = {int(k): v for k, v in raw.get('last_rented_price', {}).items()}
            except (json.JSONDecodeError, IOError):
                self.idle_since = {}
                self.last_rented_price = {}
        # Migrate old idle-only state file
        elif os.path.exists('vastai_idle_state.json'):
            try:
                with open('vastai_idle_state.json', 'r') as f:
                    raw = json.load(f)
                self.idle_since = {int(k): v for k, v in raw.items()}
            except (json.JSONDecodeError, IOError):
                self.idle_since = {}

    def _save_state(self):
        """Persist state to disk"""
        try:
            with open(self._state_file, 'w') as f:
                json.dump({
                    'idle_since': self.idle_since,
                    'last_rented_price': self.last_rented_price
                }, f)
        except IOError:
            pass

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
                    current_price=machine_data.get('listed_gpu_cost') or machine_data.get('min_bid_price', 0),
                    is_rented=machine_data['current_rentals_running'] > 0,
                    verified=machine_data.get('verification') == 'verified' or machine_data.get('verified', False),
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
            return MarketData(None, None, None, None, None, 0, 0, 0.0, 0.0, 0.0, 0.0, None)
        
        available_count = len(offers)
        
        # Analyze verified machines
        verified_offers = [o for o in offers if o.get('verification') == 'verified']
        verified_count = len(verified_offers)
        
        verification_stats = {}
        for o in offers:
            ver = o.get('verification', 'unknown')
            verification_stats[ver] = verification_stats.get(ver, 0) + 1
        self.logger.debug(f"Verification breakdown: {verification_stats}")
        
        # Average specs across all offers (for quality comparison)
        reliabilities = [o.get('reliability2', 0) for o in offers if o.get('reliability2', 0) > 0]
        avg_reliability = round(sum(reliabilities) / len(reliabilities), 2) if reliabilities else 0.0
        disk_spaces = [o.get('disk_space', 0) for o in offers if o.get('disk_space', 0) > 0]
        avg_disk_space = round(sum(disk_spaces) / len(disk_spaces), 0) if disk_spaces else 0.0
        inet_downs = [o.get('inet_down', 0) for o in offers if o.get('inet_down', 0) > 0]
        avg_inet_down = round(sum(inet_downs) / len(inet_downs), 0) if inet_downs else 0.0
        inet_ups = [o.get('inet_up', 0) for o in offers if o.get('inet_up', 0) > 0]
        avg_inet_up = round(sum(inet_ups) / len(inet_ups), 0) if inet_ups else 0.0
        
        # Get pricing from available machines
        available_prices = [
            offer['dph_base'] 
            for offer in offers 
            if not offer.get('rented', False) and offer.get('dph_base', 0) > 0
        ]
        
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
        verified_avg_price = None
        verified_median_price = None
        verified_p25 = None
        verified_p75 = None
        if verified_available_prices:
            verified_available_prices = self._filter_outliers(verified_available_prices)
            verified_available_prices.sort()
            verified_avg_price = round(sum(verified_available_prices) / len(verified_available_prices), 4)
            verified_median_price = self._percentile(verified_available_prices, 50)
            verified_p25 = self._percentile(verified_available_prices, 25)
            verified_p75 = self._percentile(verified_available_prices, 75)
            self.logger.debug(f"Verified prices (filtered): {len(verified_available_prices)} offers, "
                           f"P25=${verified_p25}, median=${verified_median_price}, P75=${verified_p75}, "
                           f"range ${min(verified_available_prices):.4f}-${max(verified_available_prices):.4f}")
        
        # Get unverified-only pricing
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
            unverified_available_prices = self._filter_outliers(unverified_available_prices)
            unverified_available_prices.sort()
            unverified_avg_price = round(sum(unverified_available_prices) / len(unverified_available_prices), 4)
            unverified_min_price = round(min(unverified_available_prices), 4)
            unverified_median_price = self._percentile(unverified_available_prices, 50)
            self.logger.debug(f"Unverified prices (filtered): {len(unverified_available_prices)} offers, "
                           f"range ${unverified_min_price}-${max(unverified_available_prices):.4f}")
        
        if not available_prices:
            return MarketData(None, None, None, None, None, available_count, verified_count,
                            avg_reliability, avg_disk_space, avg_inet_down, avg_inet_up, min_verified_price,
                            verified_avg_price, verified_median_price, verified_p25, verified_p75,
                            unverified_count, unverified_avg_price, unverified_median_price, unverified_min_price)
        
        available_prices = self._filter_outliers(available_prices)
        available_prices.sort()
        avg_price = round(sum(available_prices) / len(available_prices), 4)
        min_price = round(min(available_prices), 4)
        median_price = self._percentile(available_prices, 50)
        p25_price = self._percentile(available_prices, 25)
        p75_price = self._percentile(available_prices, 75)
        
        return MarketData(avg_price, median_price, min_price, p25_price, p75_price,
                        available_count, verified_count,
                        avg_reliability, avg_disk_space, avg_inet_down, avg_inet_up, min_verified_price,
                        verified_avg_price, verified_median_price, verified_p25, verified_p75,
                        unverified_count, unverified_avg_price, unverified_median_price, unverified_min_price)
    
    @staticmethod
    def _filter_outliers(prices: List[float]) -> List[float]:
        """Remove extreme outliers using IQR method"""
        if len(prices) < 4:
            return prices
        sorted_p = sorted(prices)
        q1 = sorted_p[len(sorted_p) // 4]
        q3 = sorted_p[3 * len(sorted_p) // 4]
        iqr = q3 - q1
        lower = q1 - 1.5 * iqr
        upper = q3 + 1.5 * iqr
        filtered = [p for p in sorted_p if lower <= p <= upper]
        return filtered if len(filtered) >= 3 else sorted_p  # fallback if too aggressive
    
    @staticmethod
    def _percentile(sorted_prices: List[float], pct: int) -> float:
        """Get percentile from a sorted price list"""
        if not sorted_prices:
            return 0.0
        idx = (len(sorted_prices) - 1) * pct / 100
        lower = int(math.floor(idx))
        upper = int(math.ceil(idx))
        if lower == upper:
            return round(sorted_prices[lower], 4)
        frac = idx - lower
        return round(sorted_prices[lower] * (1 - frac) + sorted_prices[upper] * frac, 4)
    
    def _get_quality_premium(self, machine: Machine, market: MarketData) -> float:
        """Calculate a quality multiplier based on machine specs vs market.
        Uses weighted scoring: reliability (40%), disk (35%), network (25%).
        Compares against medians to avoid outlier skew."""
        weighted_score = 0.0
        total_weight = 0.0
        
        # Reliability: most important for uptime-sensitive renters (weight: 40%)
        if market.avg_reliability > 0 and machine.reliability > 0:
            ratio = min(machine.reliability / market.avg_reliability, 1.5)
            weighted_score += ratio * 0.40
            total_weight += 0.40
        
        # Disk: matters for datasets/models (weight: 35%)
        if market.avg_disk_space > 0 and machine.disk_space > 0:
            ratio = min(machine.disk_space / market.avg_disk_space, 2.0)
            weighted_score += ratio * 0.35
            total_weight += 0.35
        
        # Network: nice-to-have but a few 10Gbps machines skew averages (weight: 25%)
        # Use geometric mean of down+up vs market to reduce outlier impact
        if market.avg_inet_down > 0 and market.avg_inet_up > 0 and machine.inet_down > 0 and machine.inet_up > 0:
            my_net = math.sqrt(machine.inet_down * machine.inet_up)
            market_net = math.sqrt(market.avg_inet_down * market.avg_inet_up)
            ratio = min(my_net / market_net, 2.0)
            weighted_score += ratio * 0.25
            total_weight += 0.25
        
        if total_weight == 0:
            return 1.0
        
        avg_score = weighted_score / total_weight
        # Scale: 1.0 = average, cap premium at +10%, discount at -5%
        premium = 1.0 + (avg_score - 1.0) * 0.25
        return max(0.95, min(premium, 1.10))

    def _apply_step_limit(self, current: float, target: float) -> float:
        """Limit price changes to max 15% per cycle to avoid whiplash"""
        if current <= 0:
            return target
        max_change = current * 0.15
        if target > current:
            return min(target, current + max_change)
        else:
            return max(target, current - max_change)

    def calculate_price(self, machine: Machine, market: MarketData) -> PriceDecision:
        """Calculate optimal price based on market conditions and machine status"""
        config = self.config
        current = machine.current_price
        
        # Log machine status
        status = "VERIFIED" if machine.verified else "UNVERIFIED"
        rental_info = f" | Rented at: ~${machine.current_price}" if machine.is_rented else ""
        self.logger.info(
            f"Machine #{machine.id}: listing=${current} | {status}{rental_info} | "
            f"Reliability: {machine.reliability:.2f} | Disk: {machine.disk_space:.0f}GB | "
            f"Network: {machine.inet_down:.0f}↓/{machine.inet_up:.0f}↑ Mbps"
        )
        
        # Log market analysis
        if market.median_price:
            self.logger.info(
                f"Market: {market.available_count} available machines (Verified: {market.verified_count}, Unverified: {market.unverified_count})"
            )
            self.logger.info(
                f"Market Specs Avg | Reliability: {market.avg_reliability}, Disk: {market.avg_disk_space:.0f}GB, "
                f"Net: {market.avg_inet_down:.0f}↓/{market.avg_inet_up:.0f}↑ Mbps"
            )
            
            if machine.verified and market.verified_median_price:
                self.logger.info(
                    f"Verified Market | P25=${market.verified_p25_price}, Median=${market.verified_median_price}, "
                    f"P75=${market.verified_p75_price}, Min=${market.min_verified_price}"
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
            
            quality_premium = self._get_quality_premium(machine, market)
            self.logger.info(f"Your quality premium: {quality_premium:.2f}x ({'+' if quality_premium >= 1 else ''}{(quality_premium-1)*100:.1f}%)")
            
            position = self._get_price_position(current, market, machine.verified)
            self.logger.info(f"Your price position: {position}")
            
            if machine.id in self.last_rented_price:
                self.logger.info(f"Last rented at: ${self.last_rented_price[machine.id]}")
        
        # Track idle duration
        idle_hours = self._get_idle_hours(machine)
        if not machine.is_rented:
            self.logger.info(f"Idle for: {idle_hours:.1f} hours")

        # Strategy depends on rental status
        if machine.is_rented:
            return self._price_for_rented_machine(current, market, machine)
        else:
            return self._price_for_idle_machine(current, market, machine, idle_hours)
    
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
    
    def _get_idle_hours(self, machine: Machine) -> float:
        """Get how many hours this machine has been continuously idle"""
        if machine.is_rented:
            return 0.0
        if machine.id not in self.idle_since:
            return 0.0
        return (time.time() - self.idle_since[machine.id]) / 3600.0

    def update_idle_tracking(self, machine: Machine):
        """Update idle-since tracking and last-rented-price for a machine"""
        if machine.is_rented:
            # Record listing price on idle->rented transition as best approximation
            # The actual rental rate is >= min_bid_price but not exposed by host API
            if machine.id in self.idle_since:
                # This is the transition moment — the listing price right before rental
                self.last_rented_price[machine.id] = machine.current_price
                self.logger.info(f"Machine {machine.id} rented! Listing was ${machine.current_price} (actual rate >= this)")
                del self.idle_since[machine.id]
        else:
            # Record first-seen idle time if not already tracked
            if machine.id not in self.idle_since:
                self.idle_since[machine.id] = time.time()
        self._save_state()

    def _price_for_rented_machine(self, current: float, market: MarketData, machine: Machine) -> PriceDecision:
        """Pricing strategy for currently rented machines - raise price above peer-group median with quality premium"""
        if machine.verified and market.verified_median_price:
            peer_median = market.verified_median_price
            peer_p75 = market.verified_p75_price
            peer_label = "verified median"
        else:
            peer_median = market.median_price
            peer_p75 = market.p75_price
            peer_label = "overall median"

        if not peer_median:
            return PriceDecision(current, "HOLD", "Machine is RENTED but no market data - holding price")

        quality = self._get_quality_premium(machine, market)
        # Target: 105% of median * quality premium, but don't exceed P75
        target = peer_median * 1.05 * quality
        if peer_p75:
            target = min(target, peer_p75)
        target = self._apply_step_limit(current, target)
        target = self._clamp_price(target)

        if current >= target:
            return PriceDecision(current, "HOLD",
                f"Machine is RENTED and already at ${current} (target ${target} from {peer_label}) - holding")

        return PriceDecision(
            target,
            "INCREASE",
            f"Machine is RENTED - raising to ${target} ({peer_label}=${peer_median}, quality={quality:.2f}x)"
        )
    
    def _price_for_idle_machine(self, current: float, market: MarketData, machine: Machine, idle_hours: float) -> PriceDecision:
        """Pricing strategy for idle machines - gradual descent from last rented price:
        - 0-6h:   Hold at last rented price (give the market time)
        - 6-12h:  Drop 5% from last rented price
        - 12-24h: Drop 10% from last rented price
        - 24-48h: Drop 20% from last rented price
        - 48h+:   Drop to median as last resort
        All targets are floored at base_price via clamp.
        """
        if machine.verified and market.verified_median_price:
            peer_median = market.verified_median_price
            peer_label = "verified"
        else:
            peer_median = market.median_price
            peer_label = "overall"
        reference_min = market.min_verified_price if (machine.verified and market.min_verified_price) else market.min_price

        # Anchor: last rented price, or current listing if no history
        anchor = self.last_rented_price.get(machine.id, current)

        if not market.median_price:
            target = anchor * 0.95
            return PriceDecision(
                self._clamp_price(target),
                "DECREASE",
                f"Machine IDLE + no market data - 5% off anchor ${anchor}"
            )

        # Graduated descent from anchor price
        if idle_hours < 6:
            target = anchor
            tier = f"<6h: holding at anchor ${anchor}"
        elif idle_hours < 12:
            target = anchor * 0.95
            tier = f"6-12h: 95% of anchor ${anchor}"
        elif idle_hours < 24:
            target = anchor * 0.90
            tier = f"12-24h: 90% of anchor ${anchor}"
        elif idle_hours < 48:
            target = anchor * 0.80
            tier = f"24-48h: 80% of anchor ${anchor}"
        else:
            # Last resort: fall to median
            target = peer_median
            tier = f"48h+: {peer_label} median ${peer_median}"

        # Never go below market minimum regardless of tier
        if reference_min and target < reference_min * 0.90:
            target = reference_min * 0.90
            tier += f" (floored at 90% of market min ${reference_min})"

        target = self._apply_step_limit(current, target)
        target = self._clamp_price(target)

        if current > target:
            return PriceDecision(
                target,
                "DECREASE",
                f"Machine IDLE {idle_hours:.1f}h - {tier} -> ${target}"
            )
        return PriceDecision(
            current,
            "HOLD",
            f"Machine IDLE {idle_hours:.1f}h - already at/below target ${target} ({tier})"
        )
    
    def _clamp_price(self, price: float) -> float:
        """Ensure price stays within configured bounds"""
        return round(max(self.config['base_price'], min(price, self.config['max_price'])), 4)
    
    def update_machine_price(self, machine_id: int, new_price: float) -> bool:
        """Update machine listing price on Vast.ai using 'list machine --price_gpu'"""
        if self.config['test_mode']:
            self.logger.info(f"TEST MODE: Would update machine {machine_id} to ${new_price}/GPU/hr")
            return True
        
        result = self.run_vastai_command([
            'vastai', 'list', 'machine', str(machine_id),
            '--price_gpu', str(new_price), '--raw'
        ])
        
        if result and result.get('success'):
            self.logger.info(f"SUCCESS: Updated machine {machine_id} listing to ${new_price}/GPU/hr")
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
            # Update idle tracking before pricing
            self.update_idle_tracking(machine)

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
