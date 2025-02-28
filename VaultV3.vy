# @version 0.3.7

struct StrategyParams:
    activation: uint256
    last_report: uint256
    current_debt: uint256
    max_debt: uint256

event StrategyChanged:
    strategy: indexed(address)
    change_type: indexed(StrategyChangeType)

event StrategyReported:
    strategy: indexed(address)
    gain: uint256
    loss: uint256
    current_debt: uint256
    protocol_fees: uint256
    total_fees: uint256
    total_refunds: uint256

event DebtUpdated:
    strategy: indexed(address)
    current_debt: uint256
    new_debt: uint256

enum Roles:
    ADD_STRATEGY_MANAGER
    REVOKE_STRATEGY_MANAGER
    FORCE_REVOKE_MANAGER
    ACCOUNTANT_MANAGER
    QUEUE_MANAGER
    REPORTING_MANAGER
    DEBT_MANAGER
    MAX_DEBT_MANAGER
    DEPOSIT_LIMIT_MANAGER
    WITHDRAW_LIMIT_MANAGER
    MINIMUM_IDLE_MANAGER
    PROFIT_UNLOCK_MANAGER
    DEBT_PURCHASER
    EMERGENCY_MANAGER

enum StrategyChangeType:
    ADDED
    REVOKED

MAX_QUEUE: constant(uint256) = 10
MAX_BPS: constant(uint256) = 10_000
MAX_BPS_EXTENDED: constant(uint256) = 1_000_000_000_000

asset: public(address)
decimals: public(uint8)
factory: address
strategies: public(HashMap[address, StrategyParams])
default_queue: public(DynArray[address, MAX_QUEUE])
use_default_queue: public(bool)
total_debt: uint256
total_idle: uint256
minimum_total_idle: public(uint256)
shutdown: bool
profit_max_unlock_time: uint256
full_profit_unlock_date: uint256
profit_unlocking_rate: uint256
last_profit_update: uint256

@external
def __init__():
    self.asset = self

@external
def initialize(asset: address, name: String[64], symbol: String[32], role_manager: address, profit_max_unlock_time: uint256):
    assert self.asset == empty(address), "initialized"
    self.asset = asset
    self.decimals = ERC20Detailed(asset).decimals()
    self.factory = msg.sender
    self.profit_max_unlock_time = profit_max_unlock_time
    self.role_manager = role_manager

@internal
def _add_strategy(new_strategy: address, add_to_queue: bool):
    assert new_strategy not in [self, empty(address)], "strategy cannot be zero address"
    self.strategies[new_strategy] = StrategyParams({
        activation: block.timestamp,
        last_report: block.timestamp,
        current_debt: 0,
        max_debt: 0
    })
    if add_to_queue and len(self.default_queue) < MAX_QUEUE:
        self.default_queue.append(new_strategy)
    log StrategyChanged(new_strategy, StrategyChangeType.ADDED)

@internal
def _revoke_strategy(strategy: address, force: bool=False):
    assert self.strategies[strategy].activation != 0, "strategy not active"
    loss: uint256 = self.strategies[strategy].current_debt if force else 0
    if loss > 0:
        self.total_debt -= loss
    self.strategies[strategy] = empty(StrategyParams)
    new_queue: DynArray[address, MAX_QUEUE] = []
    for _strategy in self.default_queue:
        if _strategy != strategy:
            new_queue.append(_strategy)
    self.default_queue = new_queue
    log StrategyChanged(strategy, StrategyChangeType.REVOKED)

@internal
def _update_debt(strategy: address, target_debt: uint256, max_loss: uint256) -> uint256:
    current_debt: uint256 = self.strategies[strategy].current_debt
    if current_debt > target_debt:
        assets_to_withdraw: uint256 = current_debt - target_debt
        pre_balance: uint256 = ERC20(self.asset).balanceOf(self)
        self._withdraw_from_strategy(strategy, assets_to_withdraw)
        post_balance: uint256 = ERC20(self.asset).balanceOf(self)
        withdrawn: uint256 = post_balance - pre_balance
        self.total_idle += withdrawn
        self.total_debt -= assets_to_withdraw
        new_debt = current_debt - assets_to_withdraw
    else:
        assets_to_deposit: uint256 = target_debt - current_debt
        self._erc20_safe_approve(self.asset, strategy, assets_to_deposit)
        IStrategy(strategy).deposit(assets_to_deposit, self)
        self.total_idle -= assets_to_deposit
        self.total_debt += assets_to_deposit
        new_debt = current_debt + assets_to_deposit
    self.strategies[strategy].current_debt = new_debt
    log DebtUpdated(strategy, current_debt, new_debt)
    return new_debt

@internal
def _process_report(strategy: address) -> (uint256, uint256):
    strategy_shares: uint256 = IStrategy(strategy).balanceOf(self)
    total_assets: uint256 = IStrategy(strategy).convertToAssets(strategy_shares)
    current_debt: uint256 = self.strategies[strategy].current_debt
    gain: uint256 = total_assets - current_debt if total_assets > current_debt else 0
    loss: uint256 = current_debt - total_assets if total_assets < current_debt else 0
    if gain > 0:
        self.strategies[strategy].current_debt = current_debt + gain
        self.total_debt += gain
    elif loss > 0:
        self.strategies[strategy].current_debt = current_debt - loss
        self.total_debt -= loss
    self.strategies[strategy].last_report = block.timestamp
    log StrategyReported(strategy, gain, loss, self.strategies[strategy].current_debt, 0, 0, 0)
    return (gain, loss)

@internal
def _unlocked_shares() -> uint256:
    if self.full_profit_unlock_date > block.timestamp:
        return self.profit_unlocking_rate * (block.timestamp - self.last_profit_update) / MAX_BPS_EXTENDED
    elif self.full_profit_unlock_date != 0:
        return self.balance_of[self]
    return 0

@external
def shutdown_vault():
    self._enforce_role(msg.sender, Roles.EMERGENCY_MANAGER)
    self.shutdown = True
    self.deposit_limit = 0
    log Shutdown()
